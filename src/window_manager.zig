//! river-window-management-v1 lifecycle and transaction boundary.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const Scene = @import("scene.zig");
const Seat = @import("seat.zig");
const slot_map = @import("slot_map.zig");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const river = wayland.server.river;

allocator: std.mem.Allocator,
global: *wl.Global,
output: *Output,
seat: *Seat,
xdg_shell: *XdgShell,
active: ?*river.WindowManagerV1,
session_generation: u64,
sequence: Sequence,
windows: WindowStore,
stack_operations: std.ArrayList(StackOperation),
focused: ?WindowId,
pending_focus: PendingFocus,
configure_timer: *wl.EventSource,

const WindowStore = slot_map.SlotMap(ManagedWindow, enum { managed_window });
const WindowId = WindowStore.Id;

const ManagedWindow = struct {
    xdg_id: XdgShell.WindowId,
    resource: ?*river.WindowV1 = null,
    node_resource: ?*river.NodeV1 = null,
    node_created: bool = false,
    metadata_dirty: bool = true,
    proposed_dimensions: ?XdgShell.Dimensions = null,
    requested_dimensions: XdgShell.Dimensions = .{ .width = 0, .height = 0 },
    activated: bool = false,
    configure: ConfigureState = .idle,
    dimensions_pending: bool = false,
    last_dimensions: ?XdgShell.Dimensions = null,
    display_ready: bool = false,
    requested_visible: bool = true,
    pending_position: ?Scene.Position = null,
};

const StackOperation = union(enum) {
    top: WindowId,
    bottom: WindowId,
    above: struct { id: WindowId, other: WindowId },
    below: struct { id: WindowId, other: WindowId },
};

const ConfigureState = union(enum) {
    idle,
    inflight: PendingConfigure,
    timed_out: PendingConfigure,
};

const PendingConfigure = struct {
    serial: u32,
    report_dimensions: bool,
};

const PendingFocus = union(enum) {
    unchanged,
    clear,
    window: WindowId,
};

const Sequence = struct {
    state: State = .idle,
    dirty: bool = false,

    const State = union(enum) {
        idle,
        manage,
        inflight_configures: u32,
        render,
    };

    fn reset(self: *Sequence) void {
        self.* = .{};
    }

    fn requestManage(self: *Sequence) bool {
        self.dirty = true;
        if (self.state != .idle) return false;
        self.dirty = false;
        self.state = .manage;
        return true;
    }

    fn finishManage(self: *Sequence, configure_count: u32) bool {
        if (self.state != .manage) return false;
        self.state = if (configure_count == 0)
            .render
        else
            .{ .inflight_configures = configure_count };
        return true;
    }

    fn configureFinished(self: *Sequence) bool {
        switch (self.state) {
            .inflight_configures => |count| {
                std.debug.assert(count > 0);
                if (count == 1) {
                    self.state = .render;
                    return true;
                }
                self.state = .{ .inflight_configures = count - 1 };
                return false;
            },
            else => return false,
        }
    }

    fn configureTimeout(self: *Sequence) bool {
        if (self.state != .inflight_configures) return false;
        self.state = .render;
        return true;
    }

    fn finishRender(self: *Sequence) enum { invalid, idle, manage } {
        if (self.state != .render) return .invalid;
        if (self.dirty) {
            self.dirty = false;
            self.state = .manage;
            return .manage;
        }
        self.state = .idle;
        return .idle;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    output: *Output,
    seat: *Seat,
    xdg_shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .output = output,
        .seat = seat,
        .xdg_shell = xdg_shell,
        .active = null,
        .session_generation = 0,
        .sequence = .{},
        .windows = .{},
        .stack_operations = .empty,
        .focused = null,
        .pending_focus = .unchanged,
        .configure_timer = undefined,
    };
    errdefer self.windows.deinit(allocator);
    errdefer self.stack_operations.deinit(allocator);
    self.global = try wl.Global.create(display, river.WindowManagerV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    self.configure_timer = try display.getEventLoop().addTimer(*Self, handleConfigureTimeout, self);
    xdg_shell.setWindowListener(.{
        .context = self,
        .ready = windowReady,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
    });
}

pub fn deinit(self: *Self) void {
    self.xdg_shell.clearWindowListener();
    self.configure_timer.remove();
    self.releaseWindows();
    self.windows.deinit(self.allocator);
    self.stack_operations.deinit(self.allocator);
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = river.WindowManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, handleDestroy, self);

    if (self.active != null) {
        resource.sendUnavailable();
        return;
    }

    self.active = resource;
    self.session_generation +%= 1;
    self.createOutput(resource) catch {
        resource.postNoMemory();
        return;
    };
    self.createSeat(resource) catch {
        resource.postNoMemory();
        return;
    };
    var windows = self.xdg_shell.windowIterator();
    while (windows.next()) |xdg_id| {
        const info = self.xdg_shell.windowInfo(xdg_id) orelse continue;
        if (!info.ready) continue;
        _ = self.ensureWindow(xdg_id) catch {
            resource.postNoMemory();
            return;
        };
        self.xdg_shell.setWindowVisible(xdg_id, false);
    }
    self.requestManage();
}

fn handleRequest(
    resource: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    self: *Self,
) void {
    if (self.active != resource) {
        if (request == .destroy) resource.destroy();
        return;
    }

    switch (request) {
        .stop => {
            resource.sendFinished();
            self.releaseManager();
        },
        .destroy => resource.postError(.sequence_order, "stop the window manager before destroying it"),
        .manage_finish => {
            self.finishManage(resource);
        },
        .manage_dirty => self.requestManage(),
        .render_finish => self.finishRender(resource),
        .get_shell_surface => resource.getClient().postImplementationError(
            "river shell surfaces are not implemented",
        ),
        .exit_session => unreachable,
    }
}

fn handleDestroy(resource: *river.WindowManagerV1, self: *Self) void {
    if (self.active == resource) self.releaseManager();
}

fn ensureWindow(self: *Self, xdg_id: XdgShell.WindowId) error{OutOfMemory}!WindowId {
    if (self.findWindow(xdg_id)) |id| return id;
    return self.windows.insert(self.allocator, .{ .xdg_id = xdg_id });
}

fn findWindow(self: *Self, xdg_id: XdgShell.WindowId) ?WindowId {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.xdg_id, xdg_id)) return entry.id;
    }
    return null;
}

fn requestManage(self: *Self) void {
    const manager = self.active orelse return;
    if (!self.sequence.requestManage()) return;
    self.sendPendingState(manager) catch {
        manager.postNoMemory();
        return;
    };
    manager.sendManageStart();
}

fn sendPendingState(self: *Self, manager: *river.WindowManagerV1) !void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource == null) try self.createWindowResource(manager, entry.id);
    }

    iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        const window = entry.value;
        if (!window.metadata_dirty) continue;
        const resource = window.resource orelse continue;
        const info = self.xdg_shell.windowInfo(window.xdg_id) orelse continue;
        resource.sendDimensionsHint(
            info.min_size.width,
            info.min_size.height,
            info.max_size.width,
            info.max_size.height,
        );
        resource.sendAppId(if (info.app_id) |app_id| app_id.ptr else null);
        resource.sendTitle(if (info.title) |title| title.ptr else null);
        const parent_resource = if (info.parent) |parent_id| parent: {
            const managed_parent_id = self.findWindow(parent_id) orelse break :parent null;
            const managed_parent = self.windows.get(managed_parent_id) orelse break :parent null;
            break :parent managed_parent.resource;
        } else null;
        resource.sendParent(parent_resource);
        resource.sendDecorationHint(.only_supports_csd);
        window.metadata_dirty = false;
    }
}

fn createWindowResource(
    self: *Self,
    manager: *river.WindowManagerV1,
    id: WindowId,
) !void {
    const resource = try river.WindowV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(WindowResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .id = id,
        .owner_generation = self.session_generation,
    };
    resource.setHandler(*WindowResource, WindowResource.handleRequest, WindowResource.handleDestroy, adapter);

    const window = self.windows.get(id) orelse unreachable;
    window.resource = resource;
    manager.sendWindow(resource);
}

fn finishManage(self: *Self, manager: *river.WindowManagerV1) void {
    if (self.sequence.state != .manage) {
        manager.postError(.sequence_order, "manage_finish outside a manage sequence");
        return;
    }

    const focused = switch (self.pending_focus) {
        .unchanged => self.focused,
        .clear => null,
        .window => |id| if (self.windows.get(id) != null) id else null,
    };
    self.pending_focus = .unchanged;

    var configure_count: u32 = 0;
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        const report_dimensions = entry.value.proposed_dimensions != null;
        const activated = if (focused) |id| std.meta.eql(id, entry.id) else false;
        if (!report_dimensions and activated == entry.value.activated) continue;
        const dimensions = entry.value.proposed_dimensions orelse entry.value.requested_dimensions;
        const serial = self.xdg_shell.configureWindowState(
            entry.value.xdg_id,
            dimensions,
            activated,
        ) catch |err| {
            switch (err) {
                error.OutOfMemory => manager.postNoMemory(),
                error.InvalidWindow => {},
            }
            continue;
        };
        if (report_dimensions) {
            entry.value.proposed_dimensions = null;
            entry.value.requested_dimensions = dimensions;
        }
        entry.value.activated = activated;
        entry.value.configure = .{ .inflight = .{
            .serial = serial,
            .report_dimensions = report_dimensions,
        } };
        configure_count += 1;
    }
    self.focused = focused;

    std.debug.assert(self.sequence.finishManage(configure_count));
    if (configure_count == 0) {
        self.startRender(manager);
    } else {
        self.configure_timer.timerUpdate(100) catch manager.postNoMemory();
    }
}

fn startRender(self: *Self, manager: *river.WindowManagerV1) void {
    std.debug.assert(self.sequence.state == .render);
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value.dimensions_pending) continue;
        const dimensions = (self.xdg_shell.windowInfo(entry.value.xdg_id) orelse continue).dimensions orelse
            continue;
        if (dimensions.width <= 0 or dimensions.height <= 0) continue;
        if (entry.value.resource) |resource| {
            resource.sendDimensions(dimensions.width, dimensions.height);
            entry.value.dimensions_pending = false;
            entry.value.last_dimensions = dimensions;
            entry.value.display_ready = true;
        }
    }
    manager.sendRenderStart();
}

fn finishRender(self: *Self, manager: *river.WindowManagerV1) void {
    if (self.sequence.state != .render) {
        manager.postError(.sequence_order, "render_finish outside a render sequence");
        return;
    }

    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.pending_position) |position| {
            self.xdg_shell.setWindowPosition(entry.value.xdg_id, position);
            entry.value.pending_position = null;
        }
        self.xdg_shell.setWindowFocused(
            entry.value.xdg_id,
            if (self.focused) |id| std.meta.eql(id, entry.id) else false,
        );
        self.xdg_shell.setWindowVisible(
            entry.value.xdg_id,
            entry.value.display_ready and entry.value.requested_visible,
        );
    }
    for (self.stack_operations.items) |operation| switch (operation) {
        .top => |id| {
            const window = self.windows.get(id) orelse continue;
            self.xdg_shell.placeWindowTop(window.xdg_id);
        },
        .bottom => |id| {
            const window = self.windows.get(id) orelse continue;
            self.xdg_shell.placeWindowBottom(window.xdg_id);
        },
        .above => |placement| {
            const window = self.windows.get(placement.id) orelse continue;
            const other = self.windows.get(placement.other) orelse continue;
            self.xdg_shell.placeWindowAbove(window.xdg_id, other.xdg_id);
        },
        .below => |placement| {
            const window = self.windows.get(placement.id) orelse continue;
            const other = self.windows.get(placement.other) orelse continue;
            self.xdg_shell.placeWindowBelow(window.xdg_id, other.xdg_id);
        },
    };
    self.stack_operations.clearRetainingCapacity();
    switch (self.sequence.finishRender()) {
        .invalid => unreachable,
        .idle => {},
        .manage => {
            self.sendPendingState(manager) catch {
                manager.postNoMemory();
                return;
            };
            manager.sendManageStart();
        },
    }
}

fn releaseManager(self: *Self) void {
    self.active = null;
    self.sequence.reset();
    self.stack_operations.clearRetainingCapacity();
    self.focused = null;
    self.pending_focus = .unchanged;
    self.releaseWindows();
}

fn releaseWindows(self: *Self) void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        self.xdg_shell.setWindowFocused(entry.value.xdg_id, false);
        self.xdg_shell.restoreStandaloneWindow(
            entry.value.xdg_id,
            entry.value.activated,
            entry.value.requested_dimensions,
        );
        _ = self.windows.remove(entry.id);
    }
}

fn handleConfigureTimeout(self: *Self) c_int {
    if (!self.sequence.configureTimeout()) return 0;
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| switch (entry.value.configure) {
        .inflight => |configure| entry.value.configure = .{ .timed_out = configure },
        else => {},
    };
    if (self.active) |manager| self.startRender(manager);
    return 0;
}

fn windowReady(context: *anyopaque, xdg_id: XdgShell.WindowId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const manager = self.active orelse return false;
    _ = self.ensureWindow(xdg_id) catch {
        manager.postNoMemory();
        return true;
    };
    var windows = self.windows.iterator();
    while (windows.next()) |entry| entry.value.metadata_dirty = true;
    self.xdg_shell.setWindowVisible(xdg_id, false);
    self.requestManage();
    return true;
}

fn windowCommitted(
    context: *anyopaque,
    xdg_id: XdgShell.WindowId,
    configure_serial: ?u32,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const manager = self.active orelse return false;
    const id = self.findWindow(xdg_id) orelse return false;
    const window = self.windows.get(id) orelse return false;
    const serial = configure_serial orelse {
        const dimensions = (self.xdg_shell.windowInfo(xdg_id) orelse return true).dimensions orelse
            return true;
        if (window.display_ready and
            (window.last_dimensions == null or !std.meta.eql(window.last_dimensions.?, dimensions)))
        {
            window.dimensions_pending = true;
            self.requestManage();
        }
        return true;
    };

    switch (window.configure) {
        .inflight => |configure| {
            if (serial != configure.serial) return true;
            window.configure = .idle;
            if (configure.report_dimensions) window.dimensions_pending = true;
            if (self.sequence.configureFinished()) self.startRender(manager);
        },
        .timed_out => |configure| {
            if (serial != configure.serial) return true;
            window.configure = .idle;
            if (configure.report_dimensions) {
                window.dimensions_pending = true;
                self.requestManage();
            }
        },
        .idle => {
            if (!window.display_ready) return true;
            window.dimensions_pending = true;
            self.requestManage();
        },
    }
    return true;
}

fn windowUnmapped(context: *anyopaque, xdg_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeWindow(xdg_id);
}

fn windowDestroyed(context: *anyopaque, xdg_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeWindow(xdg_id);
}

fn windowMetadataChanged(context: *anyopaque, xdg_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const id = self.findWindow(xdg_id) orelse return;
    const window = self.windows.get(id) orelse return;
    window.metadata_dirty = true;
    self.requestManage();
}

fn removeWindow(self: *Self, xdg_id: XdgShell.WindowId) void {
    const id = self.findWindow(xdg_id) orelse return;
    const window = self.windows.get(id) orelse return;
    if (window.resource) |resource| resource.sendClosed();
    if (self.focused) |focused| {
        if (std.meta.eql(focused, id)) self.focused = null;
    }
    switch (self.pending_focus) {
        .window => |pending| if (std.meta.eql(pending, id)) {
            self.pending_focus = .clear;
        },
        else => {},
    }
    const finish_configure = switch (window.configure) {
        .inflight => true,
        else => false,
    };
    _ = self.windows.remove(id);
    if (finish_configure and self.sequence.configureFinished()) {
        if (self.active) |manager| self.startRender(manager);
    }
    self.requestManage();
}

const WindowResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: WindowId,
    owner_generation: u64,

    fn handleRequest(
        resource: *river.WindowV1,
        request: river.WindowV1.Request,
        self: *WindowResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const manager_resource = self.activeManager() orelse return;
        const window = self.manager.windows.get(self.id) orelse return;

        switch (request) {
            .destroy => unreachable,
            .close => {
                if (!self.requireManage(manager_resource)) return;
                self.manager.xdg_shell.closeWindow(window.xdg_id);
            },
            .propose_dimensions => |dimensions| {
                if (!self.requireManage(manager_resource)) return;
                if (dimensions.width < 0 or dimensions.height < 0) {
                    resource.postError(.invalid_dimensions, "proposed dimensions must not be negative");
                    return;
                }
                window.proposed_dimensions = .{
                    .width = dimensions.width,
                    .height = dimensions.height,
                };
            },
            .hide => {
                if (!self.requireRendering(manager_resource)) return;
                window.requested_visible = false;
            },
            .show => {
                if (!self.requireRendering(manager_resource)) return;
                window.requested_visible = true;
            },
            .use_csd,
            .set_tiled,
            .inform_resize_start,
            .inform_resize_end,
            .set_capabilities,
            .inform_maximized,
            .inform_unmaximized,
            .inform_fullscreen,
            .inform_not_fullscreen,
            .fullscreen,
            .exit_fullscreen,
            => _ = self.requireManage(manager_resource),
            .get_node => |get| NodeResource.create(
                self.manager,
                self.id,
                resource,
                get.id,
            ) catch resource.postNoMemory(),
            .use_ssd => resource.getClient().postImplementationError(
                "server-side xdg decorations are not implemented",
            ),
            .set_borders => resource.getClient().postImplementationError(
                "river window borders are not implemented",
            ),
            .get_decoration_above, .get_decoration_below => resource.getClient().postImplementationError(
                "river decoration surfaces are not implemented",
            ),
            .set_clip_box, .set_content_clip_box, .set_dimension_bounds => unreachable,
        }
    }

    fn activeManager(self: *WindowResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn requireManage(self: *WindowResource, manager: *river.WindowManagerV1) bool {
        if (self.manager.sequence.state == .manage) return true;
        manager.postError(.sequence_order, "window request outside a manage sequence");
        return false;
    }

    fn requireRendering(self: *WindowResource, manager: *river.WindowManagerV1) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "window request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(_: *river.WindowV1, self: *WindowResource) void {
        if (self.manager.session_generation == self.owner_generation) {
            if (self.manager.windows.get(self.id)) |window| window.resource = null;
        }
        self.allocator.destroy(self);
    }
};

const NodeResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: WindowId,
    owner_generation: u64,

    fn create(
        manager: *Self,
        id: WindowId,
        window_resource: *river.WindowV1,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const window = manager.windows.get(id) orelse return error.ResourceCreateFailed;
        if (window.node_created) {
            window_resource.postError(.node_exists, "window already has a render node");
            return;
        }

        const resource = try river.NodeV1.create(
            window_resource.getClient(),
            window_resource.getVersion(),
            protocol_id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(NodeResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
            .owner_generation = manager.session_generation,
        };
        resource.setHandler(*NodeResource, NodeResource.handleRequest, NodeResource.handleDestroy, self);
        window.node_created = true;
        window.node_resource = resource;
    }

    fn handleRequest(
        resource: *river.NodeV1,
        request: river.NodeV1.Request,
        self: *NodeResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const manager_resource = self.activeManager() orelse return;
        const window = self.manager.windows.get(self.id) orelse return;
        if (!self.requireRendering(manager_resource)) return;

        switch (request) {
            .destroy => unreachable,
            .set_position => |position| window.pending_position = .{
                .x = position.x,
                .y = position.y,
            },
            .place_top => self.appendOperation(resource, .{ .top = self.id }),
            .place_bottom => self.appendOperation(resource, .{ .bottom = self.id }),
            .place_above => |placement| {
                const other = self.resolveOther(placement.other) orelse return;
                self.appendOperation(resource, .{ .above = .{ .id = self.id, .other = other } });
            },
            .place_below => |placement| {
                const other = self.resolveOther(placement.other) orelse return;
                self.appendOperation(resource, .{ .below = .{ .id = self.id, .other = other } });
            },
        }
    }

    fn appendOperation(
        self: *NodeResource,
        resource: *river.NodeV1,
        operation: StackOperation,
    ) void {
        self.manager.stack_operations.append(self.manager.allocator, operation) catch
            resource.postNoMemory();
    }

    fn resolveOther(self: *NodeResource, resource: *river.NodeV1) ?WindowId {
        const data = resource.getUserData() orelse return null;
        const other: *NodeResource = @ptrCast(@alignCast(data));
        if (other.manager != self.manager or
            other.owner_generation != self.owner_generation) return null;
        if (self.manager.windows.get(other.id) == null) return null;
        return other.id;
    }

    fn activeManager(self: *NodeResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn requireRendering(self: *NodeResource, manager: *river.WindowManagerV1) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "node request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(resource: *river.NodeV1, self: *NodeResource) void {
        if (self.manager.session_generation == self.owner_generation) {
            if (self.manager.windows.get(self.id)) |window| {
                if (window.node_resource == resource) window.node_resource = null;
            }
        }
        self.allocator.destroy(self);
    }
};

fn createOutput(self: *Self, manager: *river.WindowManagerV1) !void {
    const resource = try river.OutputV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(OutputResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .owner_generation = self.session_generation,
    };
    resource.setHandler(*OutputResource, OutputResource.handleRequest, OutputResource.handleDestroy, adapter);

    manager.sendOutput(resource);
    resource.sendWlOutput(self.output.globalName(manager.getClient()));
    resource.sendPosition(0, 0);
    const size = self.output.logicalSize();
    resource.sendDimensions(@intCast(size.width), @intCast(size.height));
}

fn createSeat(self: *Self, manager: *river.WindowManagerV1) !void {
    const resource = try river.SeatV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(SeatResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .owner_generation = self.session_generation,
    };
    resource.setHandler(*SeatResource, SeatResource.handleRequest, SeatResource.handleDestroy, adapter);

    manager.sendSeat(resource);
    resource.sendWlSeat(self.seat.globalName(manager.getClient()));
}

const OutputResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    owner_generation: u64,

    fn handleRequest(
        resource: *river.OutputV1,
        request: river.OutputV1.Request,
        self: *OutputResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_presentation_mode => if (self.manager.active != null and
                self.manager.session_generation == self.owner_generation)
            {
                resource.getClient().postImplementationError(
                    "river output presentation modes are not implemented",
                );
            },
        }
    }

    fn handleDestroy(_: *river.OutputV1, self: *OutputResource) void {
        self.allocator.destroy(self);
    }
};

const SeatResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    owner_generation: u64,

    fn handleRequest(
        resource: *river.SeatV1,
        request: river.SeatV1.Request,
        self: *SeatResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        if (self.manager.active == null or
            self.manager.session_generation != self.owner_generation) return;
        const manager_resource = self.manager.active.?;

        switch (request) {
            .destroy => unreachable,
            .focus_window => |focus| {
                if (!self.requireManage(manager_resource)) return;
                const id = self.resolveWindow(focus.window) orelse return;
                self.manager.pending_focus = .{ .window = id };
            },
            .clear_focus => {
                if (!self.requireManage(manager_resource)) return;
                self.manager.pending_focus = .clear;
            },
            .op_start_pointer, .op_end => {
                _ = self.requireManage(manager_resource);
            },
            .focus_shell_surface,
            .get_pointer_binding,
            .set_xcursor_theme,
            .pointer_warp,
            => resource.getClient().postImplementationError(
                "river seat operation is not implemented",
            ),
        }
    }

    fn resolveWindow(self: *SeatResource, resource: *river.WindowV1) ?WindowId {
        const data = resource.getUserData() orelse return null;
        const window: *WindowResource = @ptrCast(@alignCast(data));
        if (window.manager != self.manager or
            window.owner_generation != self.owner_generation) return null;
        if (self.manager.windows.get(window.id) == null) return null;
        return window.id;
    }

    fn requireManage(self: *SeatResource, manager: *river.WindowManagerV1) bool {
        if (self.manager.sequence.state == .manage) return true;
        manager.postError(.sequence_order, "seat request outside a manage sequence");
        return false;
    }

    fn handleDestroy(_: *river.SeatV1, self: *SeatResource) void {
        self.allocator.destroy(self);
    }
};

test "window management sequence preserves dirty work across render" {
    var sequence: Sequence = .{};

    try std.testing.expect(sequence.requestManage());
    try std.testing.expect(!sequence.requestManage());
    try std.testing.expect(sequence.finishManage(0));
    try std.testing.expectEqual(.manage, sequence.finishRender());
    try std.testing.expect(sequence.finishManage(0));
    try std.testing.expectEqual(.idle, sequence.finishRender());
}

test "window management sequence rejects out-of-order finishes" {
    var sequence: Sequence = .{};

    try std.testing.expect(!sequence.finishManage(0));
    try std.testing.expectEqual(.invalid, sequence.finishRender());
    try std.testing.expect(sequence.requestManage());
    try std.testing.expectEqual(.invalid, sequence.finishRender());
}

test "window management waits for every configured window" {
    var sequence: Sequence = .{};

    try std.testing.expect(sequence.requestManage());
    try std.testing.expect(sequence.finishManage(2));
    try std.testing.expect(!sequence.configureFinished());
    try std.testing.expect(sequence.configureFinished());
    try std.testing.expectEqual(.idle, sequence.finishRender());
}

test "window management configure timeout advances to render" {
    var sequence: Sequence = .{};

    try std.testing.expect(sequence.requestManage());
    try std.testing.expect(sequence.finishManage(1));
    try std.testing.expect(sequence.configureTimeout());
    try std.testing.expectEqual(.idle, sequence.finishRender());
    try std.testing.expect(!sequence.configureTimeout());
}
