//! xdg-shell globals and toplevel protocol state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Scene = @import("scene.zig");
const slot_map = @import("slot_map.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

allocator: std.mem.Allocator,
display: *wl.Server,
surface_store: *Surface.Store,
scene: *Scene,
global: *wl.Global,
bindings: BindingStore,
xdg_surfaces: XdgSurfaceStore,
windows: WindowStore,
window_listener: ?WindowListener,

const BindingStore = slot_map.SlotMap(BindingState, enum { xdg_binding });
const BindingId = BindingStore.Id;

const XdgSurfaceStore = slot_map.SlotMap(XdgSurfaceState, enum { xdg_surface });
const XdgSurfaceId = XdgSurfaceStore.Id;

pub const WindowStore = slot_map.SlotMap(WindowState, enum { window });
pub const WindowId = WindowStore.Id;

const BindingState = struct {
    surface_count: usize = 0,
};

const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const SizeHint = struct {
    width: i32 = 0,
    height: i32 = 0,
};

const XdgSurfaceState = struct {
    surface_id: Surface.Id,
    role: ?WindowId = null,
    pending_geometry: ?Geometry = null,
    current_geometry: ?Geometry = null,
    configure_serials: std.ArrayList(u32) = .empty,
    last_acked_serial: ?u32 = null,
    initial_configure_sent: bool = false,
    configured: bool = false,
    mapped: bool = false,
    surface_alive: bool = true,
    toplevel_resource: ?*xdg.Toplevel = null,

    fn deinit(self: *XdgSurfaceState, allocator: std.mem.Allocator) void {
        self.configure_serials.deinit(allocator);
        self.* = undefined;
    }
};

pub const WindowState = struct {
    xdg_surface_id: XdgSurfaceId,
    scene_id: Scene.Id,
    parent: ?WindowId = null,
    title: ?[:0]u8 = null,
    app_id: ?[:0]u8 = null,
    pending_min_size: SizeHint = .{},
    pending_max_size: SizeHint = .{},
    current_min_size: SizeHint = .{},
    current_max_size: SizeHint = .{},
    mapped: bool = false,
    ready: bool = false,

    fn deinit(self: *WindowState, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.app_id) |app_id| allocator.free(app_id);
        self.* = undefined;
    }

    fn commit(self: *WindowState) bool {
        const changed = !std.meta.eql(self.current_min_size, self.pending_min_size) or
            !std.meta.eql(self.current_max_size, self.pending_max_size);
        self.current_min_size = self.pending_min_size;
        self.current_max_size = self.pending_max_size;
        return changed;
    }

    fn reset(self: *WindowState, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.app_id) |app_id| allocator.free(app_id);
        self.title = null;
        self.app_id = null;
        self.parent = null;
        self.pending_min_size = .{};
        self.pending_max_size = .{};
        self.current_min_size = .{};
        self.current_max_size = .{};
        self.mapped = false;
        self.ready = false;
    }
};

pub const Dimensions = struct {
    width: i32,
    height: i32,
};

pub const WindowInfo = struct {
    scene_id: Scene.Id,
    title: ?[:0]const u8,
    app_id: ?[:0]const u8,
    parent: ?WindowId,
    min_size: SizeHint,
    max_size: SizeHint,
    dimensions: ?Dimensions,
    ready: bool,
    mapped: bool,
};

pub const WindowListener = struct {
    context: *anyopaque,
    ready: *const fn (*anyopaque, WindowId) bool,
    committed: *const fn (*anyopaque, WindowId, ?u32) bool,
    unmapped: *const fn (*anyopaque, WindowId) void,
    destroyed: *const fn (*anyopaque, WindowId) void,
    metadata_changed: *const fn (*anyopaque, WindowId) void,
};

pub const WindowIterator = struct {
    inner: WindowStore.Iterator,

    pub fn next(self: *WindowIterator) ?WindowId {
        const entry = self.inner.next() orelse return null;
        return entry.id;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surface_store: *Surface.Store,
    scene: *Scene,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .surface_store = surface_store,
        .scene = scene,
        .global = undefined,
        .bindings = .{},
        .xdg_surfaces = .{},
        .windows = .{},
        .window_listener = null,
    };
    errdefer self.bindings.deinit(allocator);
    errdefer self.xdg_surfaces.deinit(allocator);
    errdefer self.windows.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.WmBase, 5, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.window_listener == null);
    self.global.destroy();
    self.bindings.deinit(self.allocator);
    self.xdg_surfaces.deinit(self.allocator);
    self.windows.deinit(self.allocator);
    self.* = undefined;
}

pub fn setWindowListener(self: *Self, listener: WindowListener) void {
    std.debug.assert(self.window_listener == null);
    self.window_listener = listener;
}

pub fn clearWindowListener(self: *Self) void {
    std.debug.assert(self.window_listener != null);
    self.window_listener = null;
}

pub fn windowIterator(self: *Self) WindowIterator {
    return .{ .inner = self.windows.iterator() };
}

pub fn windowInfo(self: *Self, id: WindowId) ?WindowInfo {
    const window = self.windows.get(id) orelse return null;
    const xdg_surface = self.xdg_surfaces.get(window.xdg_surface_id) orelse return null;
    const dimensions: ?Dimensions = if (xdg_surface.current_geometry) |geometry|
        .{ .width = geometry.width, .height = geometry.height }
    else if (Surface.currentBuffer(self.surface_store, xdg_surface.surface_id)) |buffer|
        .{
            .width = @intCast(buffer.logical_size.width),
            .height = @intCast(buffer.logical_size.height),
        }
    else
        null;
    return .{
        .scene_id = window.scene_id,
        .title = window.title,
        .app_id = window.app_id,
        .parent = window.parent,
        .min_size = window.current_min_size,
        .max_size = window.current_max_size,
        .dimensions = dimensions,
        .ready = window.ready,
        .mapped = window.mapped,
    };
}

pub fn configureWindow(
    self: *Self,
    id: WindowId,
    dimensions: Dimensions,
) error{ InvalidWindow, OutOfMemory }!u32 {
    if (dimensions.width < 0 or dimensions.height < 0) return error.InvalidWindow;
    const window = self.windows.get(id) orelse return error.InvalidWindow;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse
        return error.InvalidWindow;
    const toplevel = state.toplevel_resource orelse return error.InvalidWindow;
    const serial = self.display.nextSerial();
    state.configure_serials.append(self.allocator, serial) catch return error.OutOfMemory;

    const values: std.ArrayList(u32) = .empty;
    var array = wl.Array.fromArrayList(u32, values);
    if (toplevel.getVersion() >= 5 and !state.initial_configure_sent) {
        toplevel.sendWmCapabilities(&array);
    }
    toplevel.sendConfigure(dimensions.width, dimensions.height, &array);
    const adapter: *ToplevelResource = @ptrCast(@alignCast(toplevel.getUserData().?));
    adapter.xdg_surface_resource.resource.sendConfigure(serial);
    state.initial_configure_sent = true;
    return serial;
}

pub fn restoreStandaloneWindow(self: *Self, id: WindowId) void {
    const window = self.windows.get(id) orelse return;
    const state = self.xdg_surfaces.get(window.xdg_surface_id) orelse return;
    if (window.ready and !state.initial_configure_sent) {
        _ = self.configureWindow(id, .{ .width = 0, .height = 0 }) catch |err| switch (err) {
            error.OutOfMemory => if (state.toplevel_resource) |resource| resource.postNoMemory(),
            error.InvalidWindow => {},
        };
    }
    if (window.mapped) self.scene.setMapped(window.scene_id, true);
}

pub fn setWindowVisible(self: *Self, id: WindowId, visible: bool) void {
    const window = self.windows.get(id) orelse return;
    self.scene.setMapped(window.scene_id, visible and window.mapped);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    WmBaseResource.create(self, client, version, id) catch client.postNoMemory();
}

const WmBaseResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: BindingId,

    fn create(
        shell: *Self,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.WmBase.create(client, version, id);
        errdefer resource.destroy();

        const self = shell.allocator.create(WmBaseResource) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const binding_id = shell.bindings.insert(shell.allocator, .{}) catch
            return error.OutOfMemory;
        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = binding_id,
        };
        resource.setHandler(*WmBaseResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.WmBase,
        request: xdg.WmBase.Request,
        self: *WmBaseResource,
    ) void {
        switch (request) {
            .destroy => {
                const binding = self.shell.bindings.get(self.id) orelse unreachable;
                if (binding.surface_count != 0) {
                    resource.postError(
                        .defunct_surfaces,
                        "xdg_wm_base still owns xdg_surface objects",
                    );
                    return;
                }
                resource.destroy();
            },
            .create_positioner => |positioner| Positioner.create(
                self.allocator,
                resource.getClient(),
                resource.getVersion(),
                positioner.id,
            ) catch resource.postNoMemory(),
            .get_xdg_surface => |get| XdgSurfaceResource.create(
                self.shell,
                self.id,
                resource,
                get.surface,
                get.id,
            ) catch resource.postNoMemory(),
            .pong => {},
        }
    }

    fn handleDestroy(_: *xdg.WmBase, self: *WmBaseResource) void {
        _ = self.shell.bindings.remove(self.id);
        self.allocator.destroy(self);
    }
};

const Positioner = struct {
    allocator: std.mem.Allocator,

    fn create(
        allocator: std.mem.Allocator,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.Positioner.create(client, version, id);
        errdefer resource.destroy();

        const self = allocator.create(Positioner) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator };
        resource.setHandler(*Positioner, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Positioner,
        request: xdg.Positioner.Request,
        _: *Positioner,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_size => |set| {
                if (set.width <= 0 or set.height <= 0) {
                    resource.postError(.invalid_input, "positioner size must be positive");
                }
            },
            .set_anchor_rect => |set| {
                if (set.width < 0 or set.height < 0) {
                    resource.postError(.invalid_input, "anchor rectangle size must not be negative");
                }
            },
            .set_anchor => |set| if (!validAnchor(set.anchor)) {
                resource.postError(.invalid_input, "invalid positioner anchor");
            },
            .set_gravity => |set| if (!validGravity(set.gravity)) {
                resource.postError(.invalid_input, "invalid positioner gravity");
            },
            .set_constraint_adjustment => |set| {
                const adjustment: u32 = @bitCast(set.constraint_adjustment);
                if (adjustment & ~@as(u32, 0x3f) != 0) {
                    resource.postError(.invalid_input, "invalid constraint adjustment");
                }
            },
            .set_offset, .set_reactive, .set_parent_configure => {},
            .set_parent_size => |set| {
                if (set.parent_width <= 0 or set.parent_height <= 0) {
                    resource.postError(.invalid_input, "parent size must be positive");
                }
            },
        }
    }

    fn handleDestroy(_: *xdg.Positioner, self: *Positioner) void {
        self.allocator.destroy(self);
    }

    fn validAnchor(anchor: xdg.Positioner.Anchor) bool {
        return switch (anchor) {
            .none,
            .top,
            .bottom,
            .left,
            .right,
            .top_left,
            .bottom_left,
            .top_right,
            .bottom_right,
            => true,
            else => false,
        };
    }

    fn validGravity(gravity: xdg.Positioner.Gravity) bool {
        return switch (gravity) {
            .none,
            .top,
            .bottom,
            .left,
            .right,
            .top_left,
            .bottom_left,
            .top_right,
            .bottom_right,
            => true,
            else => false,
        };
    }
};

const XdgSurfaceResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: XdgSurfaceId,
    binding_id: BindingId,
    resource: *xdg.Surface,
    surface: ?*Surface,
    toplevel_resource: ?*xdg.Toplevel,

    fn create(
        shell: *Self,
        binding_id: BindingId,
        wm_base_resource: *xdg.WmBase,
        wl_surface_resource: *wl.Surface,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try xdg.Surface.create(
            wm_base_resource.getClient(),
            wm_base_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const self = shell.allocator.create(XdgSurfaceResource) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const surface = Surface.fromResource(wl_surface_resource);
        const state_id = shell.xdg_surfaces.insert(shell.allocator, .{
            .surface_id = surface.handle(),
        }) catch return error.OutOfMemory;
        errdefer {
            var removed = shell.xdg_surfaces.remove(state_id).?;
            removed.deinit(shell.allocator);
        }

        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = state_id,
            .binding_id = binding_id,
            .resource = resource,
            .surface = surface,
            .toplevel_resource = null,
        };

        if (surface.assignedRole() != null) {
            wm_base_resource.postError(.role, "wl_surface already has a role");
            var removed = shell.xdg_surfaces.remove(state_id) orelse unreachable;
            removed.deinit(shell.allocator);
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        }
        if (surface.hasBufferAttachedOrCommitted()) {
            wm_base_resource.postError(
                .invalid_surface_state,
                "wl_surface already has a buffer attached or committed",
            );
            var removed = shell.xdg_surfaces.remove(state_id) orelse unreachable;
            removed.deinit(shell.allocator);
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        }
        surface.reserveRole(.xdg_toplevel, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch {
            wm_base_resource.postError(.role, "wl_surface is not available for an xdg role");
            var removed = shell.xdg_surfaces.remove(state_id) orelse unreachable;
            removed.deinit(shell.allocator);
            shell.allocator.destroy(self);
            resource.destroy();
            return;
        };

        if (shell.bindings.get(binding_id)) |binding| binding.surface_count += 1;
        resource.setHandler(*XdgSurfaceResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Surface,
        request: xdg.Surface.Request,
        self: *XdgSurfaceResource,
    ) void {
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        switch (request) {
            .destroy => {
                if (state.role != null) {
                    resource.postError(
                        .defunct_role_object,
                        "destroy the xdg role object before xdg_surface",
                    );
                    return;
                }
                resource.destroy();
            },
            .get_toplevel => |get| {
                if (state.role != null) {
                    resource.postError(.already_constructed, "xdg_surface already has a role");
                    return;
                }
                ToplevelResource.create(self, get.id) catch resource.postNoMemory();
            },
            .get_popup => resource.getClient().postImplementationError(
                "xdg_popup is not implemented",
            ),
            .set_window_geometry => |set| {
                if (!self.requireRole()) return;
                if (set.width <= 0 or set.height <= 0) {
                    resource.postError(.invalid_size, "window geometry size must be positive");
                    return;
                }
                state.pending_geometry = .{
                    .x = set.x,
                    .y = set.y,
                    .width = set.width,
                    .height = set.height,
                };
            },
            .ack_configure => |ack| {
                if (!self.requireRole()) return;
                self.ackConfigure(ack.serial);
            },
        }
    }

    fn handleDestroy(_: *xdg.Surface, self: *XdgSurfaceResource) void {
        if (self.surface) |surface| surface.releaseRole(self);

        if (self.shell.bindings.get(self.binding_id)) |binding| {
            std.debug.assert(binding.surface_count > 0);
            binding.surface_count -= 1;
        }

        var removed = self.shell.xdg_surfaces.remove(self.id) orelse {
            self.allocator.destroy(self);
            return;
        };
        if (removed.role) |window_id| {
            if (self.shell.windows.remove(window_id)) |window_value| {
                if (self.shell.window_listener) |listener| {
                    listener.destroyed(listener.context, window_id);
                }
                var window = window_value;
                self.shell.scene.removeWindow(window.scene_id);
                window.deinit(self.allocator);
            }
        }
        removed.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn requireRole(self: *XdgSurfaceResource) bool {
        const state = self.shell.xdg_surfaces.get(self.id) orelse return false;
        if (state.role == null) {
            self.resource.postError(.not_constructed, "xdg_surface has no role");
            return false;
        }
        return true;
    }

    fn ackConfigure(self: *XdgSurfaceResource, serial: u32) void {
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        const index = for (state.configure_serials.items, 0..) |candidate, i| {
            if (candidate == serial) break i;
        } else {
            self.resource.postError(.invalid_serial, "unknown xdg_surface configure serial");
            return;
        };

        const consumed = index + 1;
        std.mem.copyForwards(
            u32,
            state.configure_serials.items[0 .. state.configure_serials.items.len - consumed],
            state.configure_serials.items[consumed..],
        );
        state.configure_serials.items.len -= consumed;
        state.last_acked_serial = serial;
    }

    fn beforeSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) Surface.CommitAction {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        const state = self.shell.xdg_surfaces.get(self.id) orelse unreachable;
        if (state.role == null) {
            self.resource.postError(.not_constructed, "xdg_surface committed before role creation");
            return .reject;
        }
        if (info.has_buffer and !state.configured and state.last_acked_serial == null) {
            self.resource.postError(
                .unconfigured_buffer,
                "buffer committed before the initial configure was acknowledged",
            );
            return .reject;
        }
        return .apply;
    }

    fn afterSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        state.current_geometry = state.pending_geometry;

        const window_id = state.role orelse return;
        const window = self.shell.windows.get(window_id) orelse return;
        if (window.commit()) {
            if (self.shell.window_listener) |listener| {
                listener.metadata_changed(listener.context, window_id);
            }
        }

        if (info.had_buffer and !info.has_buffer) {
            if (self.shell.window_listener) |listener| {
                listener.unmapped(listener.context, window_id);
            }
            state.mapped = false;
            state.configured = false;
            state.initial_configure_sent = false;
            state.last_acked_serial = null;
            state.configure_serials.clearRetainingCapacity();
            self.shell.scene.setMapped(window.scene_id, false);
            window.reset(self.allocator);
            return;
        }

        if (info.has_buffer) {
            const was_mapped = window.mapped;
            const configure_serial = state.last_acked_serial;
            if (configure_serial != null) {
                state.configured = true;
                state.last_acked_serial = null;
            }
            state.mapped = state.configured;
            window.mapped = state.mapped;
            const externally_managed = if (self.shell.window_listener) |listener|
                listener.committed(listener.context, window_id, configure_serial)
            else
                false;
            if (!externally_managed) self.shell.scene.setMapped(window.scene_id, state.mapped);
            if (was_mapped and state.mapped) {
                self.shell.scene.surfaceCommitted(window.scene_id);
            }
            return;
        }

        if (!window.ready) {
            window.ready = true;
            const externally_managed = if (self.shell.window_listener) |listener|
                listener.ready(listener.context, window_id)
            else
                false;
            if (!externally_managed) self.sendInitialConfigure(window_id);
        }
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        self.surface = null;
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        state.surface_alive = false;
        state.mapped = false;
        if (state.role) |window_id| {
            if (self.shell.windows.get(window_id)) |window| {
                if (window.ready) {
                    if (self.shell.window_listener) |listener| {
                        listener.unmapped(listener.context, window_id);
                    }
                }
                window.mapped = false;
                window.ready = false;
                self.shell.scene.setMapped(window.scene_id, false);
            }
        }
    }

    fn sendInitialConfigure(self: *XdgSurfaceResource, window_id: WindowId) void {
        _ = self.shell.configureWindow(window_id, .{ .width = 0, .height = 0 }) catch |err| switch (err) {
            error.OutOfMemory => self.resource.postNoMemory(),
            error.InvalidWindow => {},
        };
    }
};

const ToplevelResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: WindowId,
    xdg_surface_id: XdgSurfaceId,
    xdg_surface_resource: *XdgSurfaceResource,

    fn create(
        xdg_surface: *XdgSurfaceResource,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const surface = xdg_surface.surface orelse return error.ResourceCreateFailed;
        surface.assignReservedRole(.xdg_toplevel, xdg_surface) catch {
            xdg_surface.resource.postError(.already_constructed, "wl_surface already has a role");
            return;
        };

        const resource = try xdg.Toplevel.create(
            xdg_surface.resource.getClient(),
            xdg_surface.resource.getVersion(),
            id,
        );
        errdefer resource.destroy();

        const self = xdg_surface.allocator.create(ToplevelResource) catch
            return error.OutOfMemory;
        errdefer xdg_surface.allocator.destroy(self);

        const scene_id = xdg_surface.shell.scene.addWindow(surface.handle()) catch
            return error.OutOfMemory;
        errdefer xdg_surface.shell.scene.removeWindow(scene_id);
        const window_id = xdg_surface.shell.windows.insert(xdg_surface.allocator, .{
            .xdg_surface_id = xdg_surface.id,
            .scene_id = scene_id,
        }) catch return error.OutOfMemory;

        self.* = .{
            .allocator = xdg_surface.allocator,
            .shell = xdg_surface.shell,
            .id = window_id,
            .xdg_surface_id = xdg_surface.id,
            .xdg_surface_resource = xdg_surface,
        };
        const state = xdg_surface.shell.xdg_surfaces.get(xdg_surface.id) orelse unreachable;
        state.role = window_id;
        state.toplevel_resource = resource;
        xdg_surface.toplevel_resource = resource;
        resource.setHandler(*ToplevelResource, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.Toplevel,
        request: xdg.Toplevel.Request,
        self: *ToplevelResource,
    ) void {
        const window = self.shell.windows.get(self.id) orelse return;
        switch (request) {
            .destroy => resource.destroy(),
            .set_parent => |set| self.setParent(resource, set.parent),
            .set_title => |set| self.setText(resource, &window.title, set.title),
            .set_app_id => |set| self.setText(resource, &window.app_id, set.app_id),
            .set_max_size => |set| {
                const size: SizeHint = .{ .width = set.width, .height = set.height };
                if (!validMaxSize(size, window.pending_min_size)) {
                    resource.postError(.invalid_size, "invalid maximum window size");
                    return;
                }
                window.pending_max_size = size;
            },
            .set_min_size => |set| {
                const size: SizeHint = .{ .width = set.width, .height = set.height };
                if (!validMinSize(size, window.pending_max_size)) {
                    resource.postError(.invalid_size, "invalid minimum window size");
                    return;
                }
                window.pending_min_size = size;
            },
            .resize => |resize| if (!validResizeEdge(resize.edges)) {
                resource.postError(.invalid_resize_edge, "invalid resize edge");
            },
            .show_window_menu,
            .move,
            .set_maximized,
            .unset_maximized,
            .set_fullscreen,
            .unset_fullscreen,
            .set_minimized,
            => {},
        }
    }

    fn handleDestroy(_: *xdg.Toplevel, self: *ToplevelResource) void {
        if (self.shell.xdg_surfaces.get(self.xdg_surface_id)) |xdg_surface| {
            xdg_surface.role = null;
            xdg_surface.mapped = false;
            xdg_surface.configured = false;
            xdg_surface.initial_configure_sent = false;
            xdg_surface.last_acked_serial = null;
            xdg_surface.configure_serials.clearRetainingCapacity();
            xdg_surface.toplevel_resource = null;
            self.xdg_surface_resource.toplevel_resource = null;
        }
        if (self.shell.windows.remove(self.id)) |window_value| {
            if (self.shell.window_listener) |listener| {
                listener.destroyed(listener.context, self.id);
            }
            var window = window_value;
            self.shell.scene.removeWindow(window.scene_id);
            window.deinit(self.allocator);
        }
        self.allocator.destroy(self);
    }

    fn setText(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        destination: *?[:0]u8,
        source_z: [*:0]const u8,
    ) void {
        const source = std.mem.span(source_z);
        if (!std.unicode.utf8ValidateSlice(source)) {
            resource.getClient().postImplementationError("xdg_toplevel string is not valid UTF-8");
            return;
        }
        const copy = self.allocator.dupeSentinel(u8, source, 0) catch {
            resource.postNoMemory();
            return;
        };
        if (destination.*) |old| self.allocator.free(old);
        destination.* = copy;
        if (self.shell.window_listener) |listener| {
            listener.metadata_changed(listener.context, self.id);
        }
    }

    fn setParent(
        self: *ToplevelResource,
        resource: *xdg.Toplevel,
        parent_resource: ?*xdg.Toplevel,
    ) void {
        const window = self.shell.windows.get(self.id) orelse return;
        const parent_id = if (parent_resource) |parent| parent: {
            const adapter: *ToplevelResource = @ptrCast(@alignCast(parent.getUserData().?));
            const parent_window = self.shell.windows.get(adapter.id) orelse break :parent null;
            if (!parent_window.mapped) break :parent null;
            break :parent adapter.id;
        } else null;

        var ancestor = parent_id;
        while (ancestor) |candidate| {
            if (std.meta.eql(candidate, self.id)) {
                resource.postError(.invalid_parent, "xdg_toplevel parent cycle");
                return;
            }
            const candidate_window = self.shell.windows.get(candidate) orelse break;
            ancestor = candidate_window.parent;
        }
        window.parent = parent_id;
        if (self.shell.window_listener) |listener| {
            listener.metadata_changed(listener.context, self.id);
        }
    }

    fn validMaxSize(maximum: SizeHint, minimum: SizeHint) bool {
        if (maximum.width < 0 or maximum.height < 0) return false;
        if (maximum.width != 0 and minimum.width != 0 and maximum.width < minimum.width) {
            return false;
        }
        if (maximum.height != 0 and minimum.height != 0 and maximum.height < minimum.height) {
            return false;
        }
        return true;
    }

    fn validMinSize(minimum: SizeHint, maximum: SizeHint) bool {
        if (minimum.width < 0 or minimum.height < 0) return false;
        if (maximum.width != 0 and minimum.width != 0 and minimum.width > maximum.width) {
            return false;
        }
        if (maximum.height != 0 and minimum.height != 0 and minimum.height > maximum.height) {
            return false;
        }
        return true;
    }

    fn validResizeEdge(edge: xdg.Toplevel.ResizeEdge) bool {
        return switch (edge) {
            .none,
            .top,
            .bottom,
            .left,
            .top_left,
            .bottom_left,
            .right,
            .top_right,
            .bottom_right,
            => true,
            else => false,
        };
    }
};

test "xdg size hints reject contradictory bounds" {
    try std.testing.expect(ToplevelResource.validMaxSize(
        .{ .width = 100, .height = 100 },
        .{ .width = 50, .height = 50 },
    ));
    try std.testing.expect(!ToplevelResource.validMaxSize(
        .{ .width = 40, .height = 100 },
        .{ .width = 50, .height = 50 },
    ));
    try std.testing.expect(!ToplevelResource.validMinSize(
        .{ .width = -1, .height = 0 },
        .{},
    ));
}
