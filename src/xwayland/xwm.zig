//! X11 window-manager bootstrap and event-loop integration.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/composite.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.xwm);

connection: *c.xcb_connection_t,
screen: *c.xcb_screen_t,
event_source: *wl.EventSource,
wm_window: c.xcb_window_t,
atoms: [atom_count]c.xcb_atom_t,
listener: Listener,

const Atom = enum {
    wm_s0,
    net_wm_cm_s0,
    net_supported,
    net_supporting_wm_check,
    net_wm_name,
    utf8_string,
};

const atom_count = std.meta.fields(Atom).len;
const atom_names: [atom_count][]const u8 = .{
    "WM_S0",
    "_NET_WM_CM_S0",
    "_NET_SUPPORTED",
    "_NET_SUPPORTING_WM_CHECK",
    "_NET_WM_NAME",
    "UTF8_STRING",
};

pub const Listener = struct {
    context: *anyopaque,
    failed: *const fn (*anyopaque) void,
};

pub fn init(
    self: *Self,
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
        .connection = connection,
        .screen = screen,
        .event_source = undefined,
        .wm_window = c.XCB_WINDOW_NONE,
        .atoms = undefined,
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
    c.xcb_disconnect(self.connection);
    self.* = undefined;
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
            if (event.*.response_type & 0x7f == 0)
                logX11Error("event", @ptrCast(event));
            std.c.free(event);
        }
    }
    if (c.xcb_connection_has_error(self.connection) != 0) {
        self.listener.failed(self.listener.context);
        return 0;
    }
    return 0;
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
