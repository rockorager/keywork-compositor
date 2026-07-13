//! xdg-shell globals and toplevel protocol state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("slot_map.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

allocator: std.mem.Allocator,
display: *wl.Server,
surface_store: *Surface.Store,
global: *wl.Global,
bindings: BindingStore,
xdg_surfaces: XdgSurfaceStore,
windows: WindowStore,
repaint_listener: ?RepaintListener,

const BindingStore = slot_map.SlotMap(BindingState, enum { xdg_binding });
const BindingId = BindingStore.Id;

const XdgSurfaceStore = slot_map.SlotMap(XdgSurfaceState, enum { xdg_surface });
const XdgSurfaceId = XdgSurfaceStore.Id;

pub const WindowStore = slot_map.SlotMap(WindowState, enum { window });
pub const WindowId = WindowStore.Id;

pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
};

const BindingState = struct {
    surface_count: usize = 0,
};

const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const SizeHint = struct {
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

    fn deinit(self: *XdgSurfaceState, allocator: std.mem.Allocator) void {
        self.configure_serials.deinit(allocator);
        self.* = undefined;
    }
};

pub const WindowState = struct {
    xdg_surface_id: XdgSurfaceId,
    parent: ?WindowId = null,
    title: ?[:0]u8 = null,
    app_id: ?[:0]u8 = null,
    pending_min_size: SizeHint = .{},
    pending_max_size: SizeHint = .{},
    current_min_size: SizeHint = .{},
    current_max_size: SizeHint = .{},
    mapped: bool = false,

    fn deinit(self: *WindowState, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.app_id) |app_id| allocator.free(app_id);
        self.* = undefined;
    }

    fn commit(self: *WindowState) void {
        self.current_min_size = self.pending_min_size;
        self.current_max_size = self.pending_max_size;
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
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surface_store: *Surface.Store,
) !void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .surface_store = surface_store,
        .global = undefined,
        .bindings = .{},
        .xdg_surfaces = .{},
        .windows = .{},
        .repaint_listener = null,
    };
    errdefer self.bindings.deinit(allocator);
    errdefer self.xdg_surfaces.deinit(allocator);
    errdefer self.windows.deinit(allocator);
    self.global = try wl.Global.create(display, xdg.WmBase, 5, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.bindings.deinit(self.allocator);
    self.xdg_surfaces.deinit(self.allocator);
    self.windows.deinit(self.allocator);
    self.* = undefined;
}

pub fn setRepaintListener(self: *Self, listener: RepaintListener) void {
    std.debug.assert(self.repaint_listener == null);
    self.repaint_listener = listener;
}

pub fn clearRepaintListener(self: *Self) void {
    std.debug.assert(self.repaint_listener != null);
    self.repaint_listener = null;
}

pub fn windowIterator(self: *Self) WindowStore.Iterator {
    return self.windows.iterator();
}

pub fn surfaceForWindow(self: *Self, id: WindowId) ?Surface.Id {
    const window = self.windows.get(id) orelse return null;
    const xdg_surface = self.xdg_surfaces.get(window.xdg_surface_id) orelse return null;
    return if (xdg_surface.surface_alive) xdg_surface.surface_id else null;
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
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
                var window = window_value;
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
        window.commit();

        if (info.had_buffer and !info.has_buffer) {
            state.mapped = false;
            state.configured = false;
            state.initial_configure_sent = false;
            state.last_acked_serial = null;
            state.configure_serials.clearRetainingCapacity();
            window.reset(self.allocator);
            self.shell.requestRepaint();
            return;
        }

        if (info.has_buffer) {
            if (state.last_acked_serial != null) {
                state.configured = true;
                state.last_acked_serial = null;
            }
            state.mapped = state.configured;
            window.mapped = state.mapped;
            self.shell.requestRepaint();
            return;
        }

        if (!state.initial_configure_sent) self.sendInitialConfigure();
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *XdgSurfaceResource = @ptrCast(@alignCast(context));
        self.surface = null;
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        const was_mapped = state.mapped;
        state.surface_alive = false;
        state.mapped = false;
        if (state.role) |window_id| {
            if (self.shell.windows.get(window_id)) |window| window.mapped = false;
        }
        if (was_mapped) self.shell.requestRepaint();
    }

    fn sendInitialConfigure(self: *XdgSurfaceResource) void {
        const state = self.shell.xdg_surfaces.get(self.id) orelse return;
        const toplevel = self.toplevel_resource orelse return;
        const serial = self.shell.display.nextSerial();
        state.configure_serials.append(self.allocator, serial) catch {
            self.resource.postNoMemory();
            return;
        };

        const values: std.ArrayList(u32) = .empty;
        var array = wl.Array.fromArrayList(u32, values);
        if (toplevel.getVersion() >= 5) toplevel.sendWmCapabilities(&array);
        toplevel.sendConfigure(0, 0, &array);
        self.resource.sendConfigure(serial);
        state.initial_configure_sent = true;
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

        const window_id = xdg_surface.shell.windows.insert(xdg_surface.allocator, .{
            .xdg_surface_id = xdg_surface.id,
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
            self.xdg_surface_resource.toplevel_resource = null;
        }
        if (self.shell.windows.remove(self.id)) |window_value| {
            var window = window_value;
            const was_mapped = window.mapped;
            window.deinit(self.allocator);
            if (was_mapped) self.shell.requestRepaint();
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
