//! X11 window-manager bootstrap and event-loop integration.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("../wayland/surface.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.xwm);

allocator: std.mem.Allocator,
connection: *c.xcb_connection_t,
screen: *c.xcb_screen_t,
event_source: *wl.EventSource,
wm_window: c.xcb_window_t,
atoms: [atom_count]c.xcb_atom_t,
windows: std.AutoHashMapUnmanaged(WindowId, Window),
serial_windows: std.AutoHashMapUnmanaged(u64, WindowId),
listener: Listener,

pub const WindowId = u32;

pub const Geometry = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

pub const WindowInfo = struct {
    id: WindowId,
    geometry: Geometry,
    override_redirect: bool,
    mapped: bool,
    surface_id: ?Surface.Id,
};

const Window = struct {
    geometry: Geometry,
    override_redirect: bool,
    mapped: bool = false,
    serial: ?u64 = null,
    surface_id: ?Surface.Id = null,
};

const Atom = enum {
    wm_s0,
    net_wm_cm_s0,
    net_supported,
    net_supporting_wm_check,
    net_wm_name,
    utf8_string,
    wl_surface_serial,
};

const atom_count = std.meta.fields(Atom).len;
const atom_names: [atom_count][]const u8 = .{
    "WM_S0",
    "_NET_WM_CM_S0",
    "_NET_SUPPORTED",
    "_NET_SUPPORTING_WM_CHECK",
    "_NET_WM_NAME",
    "UTF8_STRING",
    "WL_SURFACE_SERIAL",
};

pub const Listener = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
    created: *const fn (*anyopaque, WindowInfo) void,
    destroyed: *const fn (*anyopaque, WindowId) void,
    mapped: *const fn (*anyopaque, WindowId, bool) void,
    configured: *const fn (*anyopaque, WindowId, Geometry, bool) void,
    serial: *const fn (*anyopaque, WindowId, u64) void,
    associated: *const fn (*anyopaque, WindowId, Surface.Id) void,
    dissociated: *const fn (*anyopaque, WindowId, Surface.Id) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    fd: std.posix.fd_t,
    listener: Listener,
) !void {
    const connection = c.xcb_connect_to_fd(fd, null) orelse {
        _ = std.c.close(fd);
        return error.XcbConnectFailed;
    };
    errdefer c.xcb_disconnect(connection);
    if (c.xcb_connection_has_error(connection) != 0)
        return error.XcbConnectFailed;

    const setup = c.xcb_get_setup(connection) orelse return error.XcbSetupFailed;
    const screen: *c.xcb_screen_t = @ptrCast(
        c.xcb_setup_roots_iterator(setup).data orelse
            return error.XcbSetupFailed,
    );
    self.* = .{
        .allocator = allocator,
        .connection = connection,
        .screen = screen,
        .event_source = undefined,
        .wm_window = c.XCB_WINDOW_NONE,
        .atoms = undefined,
        .windows = .empty,
        .serial_windows = .empty,
        .listener = listener,
    };

    try self.resolveAtoms();
    try self.checkComposite();
    self.wm_window = c.xcb_generate_id(connection);
    if (self.wm_window == c.XCB_WINDOW_NONE) return error.XidAllocationFailed;
    try checkRequest(connection, c.xcb_create_window_checked(
        connection,
        c.XCB_COPY_FROM_PARENT,
        self.wm_window,
        screen.root,
        0,
        0,
        10,
        10,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        0,
        null,
    ));

    const root_event_mask: u32 = c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    try checkRequest(connection, c.xcb_change_window_attributes_checked(
        connection,
        screen.root,
        c.XCB_CW_EVENT_MASK,
        &root_event_mask,
    ));
    try checkRequest(connection, c.xcb_composite_redirect_subwindows_checked(
        connection,
        screen.root,
        c.XCB_COMPOSITE_REDIRECT_MANUAL,
    ));
    try self.publishWmIdentity();
    try self.claimSelection(.wm_s0);
    try self.claimSelection(.net_wm_cm_s0);
    if (c.xcb_flush(connection) <= 0) return error.XcbFlushFailed;

    const event_fd = c.xcb_get_file_descriptor(connection);
    if (event_fd < 0) return error.XcbConnectionFailed;
    self.event_source = try event_loop.addFd(
        *Self,
        event_fd,
        .{ .readable = true, .hangup = true, .@"error" = true },
        handleEvents,
        self,
    );
    self.event_source.check();
}

pub fn deinit(self: *Self) void {
    self.event_source.remove();
    while (self.windows.count() > 0) {
        var iterator = self.windows.iterator();
        const entry = iterator.next().?;
        self.removeWindow(entry.key_ptr.*);
    }
    std.debug.assert(self.serial_windows.count() == 0);
    self.serial_windows.deinit(self.allocator);
    self.windows.deinit(self.allocator);
    c.xcb_disconnect(self.connection);
    self.* = undefined;
}

pub fn associateSurface(self: *Self, serial: u64, surface_id: Surface.Id) bool {
    const window_id = self.serial_windows.get(serial) orelse return false;
    const window = self.windows.getPtr(window_id) orelse return false;
    if (window.surface_id) |current| return std.meta.eql(current, surface_id);
    window.surface_id = surface_id;
    log.debug("associated X11 window {d} with surface serial {d}", .{ window_id, serial });
    self.listener.associated(self.listener.context, window_id, surface_id);
    return true;
}

pub fn removeSurfaceAssociation(
    self: *Self,
    serial: u64,
    surface_id: Surface.Id,
) void {
    const window_id = self.serial_windows.get(serial) orelse return;
    const window = self.windows.getPtr(window_id) orelse return;
    if (window.surface_id) |current| {
        if (!std.meta.eql(current, surface_id)) return;
        self.listener.dissociated(self.listener.context, window_id, current);
    }
    std.debug.assert(self.serial_windows.remove(serial));
    window.serial = null;
    window.surface_id = null;
    log.debug("removed surface association from X11 window {d}", .{window_id});
}

pub fn windowInfo(self: *const Self, window_id: WindowId) ?WindowInfo {
    const window = self.windows.get(window_id) orelse return null;
    return info(window_id, window);
}

pub fn windowForSerial(self: *const Self, serial: u64) ?WindowId {
    return self.serial_windows.get(serial);
}

fn resolveAtoms(self: *Self) !void {
    var cookies: [atom_count]c.xcb_intern_atom_cookie_t = undefined;
    for (atom_names, &cookies) |name, *cookie| {
        cookie.* = c.xcb_intern_atom(
            self.connection,
            0,
            @intCast(name.len),
            name.ptr,
        );
    }
    for (atom_names, cookies, &self.atoms) |name, cookie, *resolved_atom| {
        var x_error: ?*c.xcb_generic_error_t = null;
        const reply = c.xcb_intern_atom_reply(
            self.connection,
            cookie,
            &x_error,
        ) orelse {
            if (x_error) |err| {
                logX11Error("intern atom", err);
                std.c.free(err);
            }
            log.err("failed to resolve X11 atom {s}", .{name});
            return error.AtomResolutionFailed;
        };
        defer std.c.free(reply);
        if (x_error) |err| {
            logX11Error("intern atom", err);
            std.c.free(err);
            return error.AtomResolutionFailed;
        }
        resolved_atom.* = reply.*.atom;
    }
}

fn checkComposite(self: *Self) !void {
    var x_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_composite_query_version_reply(
        self.connection,
        c.xcb_composite_query_version(self.connection, 0, 4),
        &x_error,
    ) orelse {
        if (x_error) |err| {
            logX11Error("query Composite", err);
            std.c.free(err);
        }
        return error.CompositeUnavailable;
    };
    defer std.c.free(reply);
    if (x_error) |err| {
        logX11Error("query Composite", err);
        std.c.free(err);
        return error.CompositeUnavailable;
    }
}

fn publishWmIdentity(self: *Self) !void {
    const wm_name = "Keywork";
    try checkRequest(self.connection, c.xcb_change_property_checked(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.wm_window,
        self.atomValue(.net_wm_name),
        self.atomValue(.utf8_string),
        8,
        wm_name.len,
        wm_name.ptr,
    ));
    try self.setWindowProperty(
        self.screen.root,
        .net_supporting_wm_check,
        self.wm_window,
    );
    try self.setWindowProperty(
        self.wm_window,
        .net_supporting_wm_check,
        self.wm_window,
    );
    const supported = [_]c.xcb_atom_t{
        self.atomValue(.net_supporting_wm_check),
        self.atomValue(.net_wm_name),
    };
    try checkRequest(self.connection, c.xcb_change_property_checked(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        self.screen.root,
        self.atomValue(.net_supported),
        c.XCB_ATOM_ATOM,
        32,
        supported.len,
        &supported,
    ));
}

fn setWindowProperty(
    self: *Self,
    window: c.xcb_window_t,
    property: Atom,
    value: c.xcb_window_t,
) !void {
    try checkRequest(self.connection, c.xcb_change_property_checked(
        self.connection,
        c.XCB_PROP_MODE_REPLACE,
        window,
        self.atomValue(property),
        c.XCB_ATOM_WINDOW,
        32,
        1,
        &value,
    ));
}

fn claimSelection(self: *Self, selection: Atom) !void {
    const selection_atom = self.atomValue(selection);
    try checkRequest(self.connection, c.xcb_set_selection_owner_checked(
        self.connection,
        self.wm_window,
        selection_atom,
        c.XCB_CURRENT_TIME,
    ));
    var x_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_selection_owner_reply(
        self.connection,
        c.xcb_get_selection_owner(self.connection, selection_atom),
        &x_error,
    ) orelse {
        if (x_error) |err| {
            logX11Error("get selection owner", err);
            std.c.free(err);
        }
        return error.SelectionClaimFailed;
    };
    defer std.c.free(reply);
    if (x_error) |err| {
        logX11Error("get selection owner", err);
        std.c.free(err);
        return error.SelectionClaimFailed;
    }
    if (reply.*.owner != self.wm_window) return error.SelectionClaimFailed;
}

fn atomValue(self: *const Self, name: Atom) c.xcb_atom_t {
    return self.atoms[@intFromEnum(name)];
}

fn checkRequest(
    connection: *c.xcb_connection_t,
    cookie: c.xcb_void_cookie_t,
) !void {
    const x_error = c.xcb_request_check(connection, cookie) orelse return;
    defer std.c.free(x_error);
    logX11Error("checked request", x_error);
    return error.X11RequestFailed;
}

fn handleEvents(_: std.posix.fd_t, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.listener.failed(self.listener.context);
        return 0;
    }
    if (mask.readable) {
        while (c.xcb_poll_for_event(self.connection)) |event| {
            if (event.*.response_type & 0x7f == 0) {
                logX11Error("event", @ptrCast(event));
            } else {
                self.dispatchEvent(event) catch |err| {
                    log.err("failed to process X11 event: {t}", .{err});
                    std.c.free(event);
                    self.listener.failed(self.listener.context);
                    return 0;
                };
            }
            std.c.free(event);
        }
        if (c.xcb_flush(self.connection) <= 0) {
            self.listener.failed(self.listener.context);
            return 0;
        }
    }
    if (c.xcb_connection_has_error(self.connection) != 0) {
        self.listener.failed(self.listener.context);
        return 0;
    }
    return 0;
}

fn dispatchEvent(self: *Self, event: [*c]c.xcb_generic_event_t) !void {
    switch (event.*.response_type & 0x7f) {
        c.XCB_CREATE_NOTIFY => try self.handleCreate(@ptrCast(event)),
        c.XCB_DESTROY_NOTIFY => self.handleDestroy(@ptrCast(event)),
        c.XCB_MAP_REQUEST => self.handleMapRequest(@ptrCast(event)),
        c.XCB_MAP_NOTIFY => self.handleMapNotify(@ptrCast(event)),
        c.XCB_UNMAP_NOTIFY => self.handleUnmapNotify(@ptrCast(event)),
        c.XCB_CONFIGURE_REQUEST => self.handleConfigureRequest(@ptrCast(event)),
        c.XCB_CONFIGURE_NOTIFY => self.handleConfigureNotify(@ptrCast(event)),
        c.XCB_CLIENT_MESSAGE => try self.handleClientMessage(@ptrCast(event)),
        else => {},
    }
}

fn handleCreate(self: *Self, event: *const c.xcb_create_notify_event_t) !void {
    if (event.window == self.wm_window or self.windows.contains(event.window)) return;
    const window: Window = .{
        .geometry = .{
            .x = event.x,
            .y = event.y,
            .width = event.width,
            .height = event.height,
        },
        .override_redirect = event.override_redirect != 0,
    };
    try self.windows.put(self.allocator, event.window, window);
    self.listener.created(self.listener.context, info(event.window, window));
}

fn handleDestroy(self: *Self, event: *const c.xcb_destroy_notify_event_t) void {
    self.removeWindow(event.window);
}

fn removeWindow(self: *Self, window_id: WindowId) void {
    const removed = self.windows.fetchRemove(window_id) orelse return;
    if (removed.value.serial) |serial|
        std.debug.assert(self.serial_windows.remove(serial));
    if (removed.value.surface_id) |surface_id|
        self.listener.dissociated(self.listener.context, window_id, surface_id);
    self.listener.destroyed(self.listener.context, window_id);
}

fn handleMapRequest(self: *Self, event: *const c.xcb_map_request_event_t) void {
    if (!self.windows.contains(event.window)) return;
    _ = c.xcb_map_window(self.connection, event.window);
}

fn handleMapNotify(self: *Self, event: *const c.xcb_map_notify_event_t) void {
    const window = self.windows.getPtr(event.window) orelse return;
    const override_redirect = event.override_redirect != 0;
    if (window.override_redirect != override_redirect) {
        window.override_redirect = override_redirect;
        self.listener.configured(
            self.listener.context,
            event.window,
            window.geometry,
            override_redirect,
        );
    }
    if (window.mapped) return;
    window.mapped = true;
    self.listener.mapped(self.listener.context, event.window, true);
}

fn handleUnmapNotify(self: *Self, event: *const c.xcb_unmap_notify_event_t) void {
    const window = self.windows.getPtr(event.window) orelse return;
    if (window.surface_id) |surface_id|
        self.listener.dissociated(self.listener.context, event.window, surface_id);
    if (window.serial) |serial|
        std.debug.assert(self.serial_windows.remove(serial));
    window.serial = null;
    window.surface_id = null;
    if (!window.mapped) return;
    window.mapped = false;
    self.listener.mapped(self.listener.context, event.window, false);
}

fn handleConfigureRequest(
    self: *Self,
    event: *const c.xcb_configure_request_event_t,
) void {
    const window = self.windows.getPtr(event.window) orelse return;
    var requested = window.geometry;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_X != 0) requested.x = event.x;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_Y != 0) requested.y = event.y;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_WIDTH != 0) requested.width = event.width;
    if (event.value_mask & c.XCB_CONFIG_WINDOW_HEIGHT != 0) requested.height = event.height;
    const values = [_]u32{
        signedValue(requested.x),
        signedValue(requested.y),
        requested.width,
        requested.height,
        0,
    };
    _ = c.xcb_configure_window(
        self.connection,
        event.window,
        c.XCB_CONFIG_WINDOW_X |
            c.XCB_CONFIG_WINDOW_Y |
            c.XCB_CONFIG_WINDOW_WIDTH |
            c.XCB_CONFIG_WINDOW_HEIGHT |
            c.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &values,
    );
    if (!window.override_redirect and std.meta.eql(window.geometry, requested))
        self.sendConfigureNotify(event.window, window.*);
}

fn handleConfigureNotify(
    self: *Self,
    event: *const c.xcb_configure_notify_event_t,
) void {
    const window = self.windows.getPtr(event.window) orelse return;
    const geometry: Geometry = .{
        .x = event.x,
        .y = event.y,
        .width = event.width,
        .height = event.height,
    };
    const override_redirect = event.override_redirect != 0;
    if (std.meta.eql(window.geometry, geometry) and
        window.override_redirect == override_redirect) return;
    window.geometry = geometry;
    window.override_redirect = override_redirect;
    self.listener.configured(
        self.listener.context,
        event.window,
        geometry,
        override_redirect,
    );
}

fn sendConfigureNotify(self: *Self, window_id: WindowId, window: Window) void {
    var event: c.xcb_configure_notify_event_t = std.mem.zeroes(c.xcb_configure_notify_event_t);
    event.response_type = c.XCB_CONFIGURE_NOTIFY;
    event.event = window_id;
    event.window = window_id;
    event.above_sibling = c.XCB_WINDOW_NONE;
    event.x = window.geometry.x;
    event.y = window.geometry.y;
    event.width = window.geometry.width;
    event.height = window.geometry.height;
    event.override_redirect = @intFromBool(window.override_redirect);
    _ = c.xcb_send_event(
        self.connection,
        0,
        window_id,
        c.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        @ptrCast(&event),
    );
}

fn handleClientMessage(
    self: *Self,
    event: *const c.xcb_client_message_event_t,
) !void {
    if (event.type != self.atomValue(.wl_surface_serial) or event.format != 32) return;
    const window = self.windows.getPtr(event.window) orelse return;
    const serial = @as(u64, event.data.data32[1]) << 32 | event.data.data32[0];
    if (serial == 0 or window.serial != null or self.serial_windows.contains(serial)) {
        log.warn("ignored invalid surface serial for X11 window {d}", .{event.window});
        return;
    }
    try self.serial_windows.put(self.allocator, serial, event.window);
    window.serial = serial;
    self.listener.serial(self.listener.context, event.window, serial);
}

fn info(window_id: WindowId, window: Window) WindowInfo {
    return .{
        .id = window_id,
        .geometry = window.geometry,
        .override_redirect = window.override_redirect,
        .mapped = window.mapped,
        .surface_id = window.surface_id,
    };
}

fn signedValue(value: i16) u32 {
    return @bitCast(@as(i32, value));
}

fn logX11Error(operation: []const u8, x_error: *const c.xcb_generic_error_t) void {
    log.err(
        "X11 {s} failed: error={d} major={d} minor={d} resource={d}",
        .{
            operation,
            x_error.error_code,
            x_error.major_code,
            x_error.minor_code,
            x_error.resource_id,
        },
    );
}

test "XWM atom table covers every atom" {
    try std.testing.expectEqual(atom_count, atom_names.len);
}
