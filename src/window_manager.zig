//! river-window-management-v1 lifecycle and transaction boundary.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const Scene = @import("scene.zig");
const Seat = @import("seat.zig");
const slot_map = @import("slot_map.zig");
const Surface = @import("surface.zig");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const river = wayland.server.river;

const protocol_version = 3;

allocator: std.mem.Allocator,
global: *wl.Global,
output: *Output,
seat: *Seat,
xdg_shell: *XdgShell,
active: ?*river.WindowManagerV1,
session_generation: u64,
sequence: Sequence,
windows: WindowStore,
decorations: DecorationStore,
stack_operations: std.ArrayList(StackOperation),
focused: ?WindowId,
pending_focus: PendingFocus,
configure_timer: *wl.EventSource,

const WindowStore = slot_map.SlotMap(ManagedWindow, enum { managed_window });
const WindowId = WindowStore.Id;
const DecorationStore = slot_map.SlotMap(ManagedDecoration, enum { managed_decoration });
const DecorationId = DecorationStore.Id;

const ManagedWindow = struct {
    xdg_id: XdgShell.WindowId,
    resource: ?*river.WindowV1 = null,
    node_resource: ?*river.NodeV1 = null,
    node_created: bool = false,
    metadata_dirty: bool = true,
    proposed_dimensions: ?XdgShell.Dimensions = null,
    requested_dimensions: XdgShell.Dimensions = .{ .width = 0, .height = 0 },
    requested_configuration: XdgShell.ToplevelConfigure = .{},
    sent_configuration: XdgShell.ToplevelConfigure = .{},
    fullscreen_output: bool = false,
    fullscreen_dimensions_pending: bool = false,
    configure: ConfigureState = .idle,
    dimensions_pending: bool = false,
    last_dimensions: ?XdgShell.Dimensions = null,
    display_ready: bool = false,
    requested_visible: bool = true,
    pending_position: ?Scene.Position = null,
    pending_borders: PendingBorders = .unchanged,
    pending_clip_box: PendingClipBox = .unchanged,
    pending_content_clip_box: PendingClipBox = .unchanged,
    borders: ?Scene.Borders = null,
    clip_box: ?Scene.ClipBox = null,
    content_clip_box: ?Scene.ClipBox = null,
};

const ManagedDecoration = struct {
    window_id: WindowId,
    scene_id: ?Scene.DecorationId,
    adapter: *DecorationResource,
    pending_offset: ?Scene.Position = null,
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

const PendingBorders = union(enum) {
    unchanged,
    set: ?Scene.Borders,
};

const PendingClipBox = union(enum) {
    unchanged,
    set: ?Scene.ClipBox,
};

fn protocolColorComponent(value: u32) u8 {
    const maximum = std.math.maxInt(u32);
    return @intCast((@as(u64, value) * 255 + maximum / 2) / maximum);
}

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
        .decorations = .{},
        .stack_operations = .empty,
        .focused = null,
        .pending_focus = .unchanged,
        .configure_timer = undefined,
    };
    errdefer self.windows.deinit(allocator);
    errdefer self.decorations.deinit(allocator);
    errdefer self.stack_operations.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        river.WindowManagerV1,
        protocol_version,
        *Self,
        self,
        bind,
    );
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
    self.decorations.deinit(self.allocator);
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
    if (resource.getVersion() >= river.WindowV1.unreliable_pid_since_version) {
        const info = self.xdg_shell.windowInfo(window.xdg_id) orelse unreachable;
        resource.sendUnreliablePid(info.unreliable_pid);
    }
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
        const activated = if (focused) |id| std.meta.eql(id, entry.id) else false;
        entry.value.requested_configuration.activated = activated;
        const report_dimensions = entry.value.proposed_dimensions != null or
            entry.value.fullscreen_dimensions_pending;
        const configuration_changed = !std.meta.eql(
            entry.value.requested_configuration,
            entry.value.sent_configuration,
        );
        if (!report_dimensions and !configuration_changed) continue;
        const proposed_dimensions = entry.value.proposed_dimensions;
        const dimensions = if (entry.value.fullscreen_output) fullscreen: {
            const size = self.output.logicalSize();
            break :fullscreen XdgShell.Dimensions{
                .width = @intCast(size.width),
                .height = @intCast(size.height),
            };
        } else proposed_dimensions orelse
            (self.xdg_shell.windowInfo(entry.value.xdg_id) orelse continue).dimensions orelse
            entry.value.requested_dimensions;
        const serial = self.xdg_shell.configureWindowState(
            entry.value.xdg_id,
            dimensions,
            entry.value.requested_configuration,
        ) catch |err| {
            switch (err) {
                error.OutOfMemory => manager.postNoMemory(),
                error.InvalidWindow => {},
            }
            continue;
        };
        if (report_dimensions) {
            entry.value.proposed_dimensions = null;
            entry.value.fullscreen_dimensions_pending = false;
            if (!entry.value.fullscreen_output and proposed_dimensions != null) {
                entry.value.requested_dimensions = dimensions;
            }
        }
        entry.value.sent_configuration = entry.value.requested_configuration;
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
    if (!self.validateDecorationCommits()) return;
    self.applyDecorationState();

    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.pending_position) |position| {
            if (!entry.value.fullscreen_output) {
                self.xdg_shell.setWindowPosition(entry.value.xdg_id, position);
            }
            entry.value.pending_position = null;
        }
        if (entry.value.fullscreen_output) {
            self.xdg_shell.setWindowPosition(entry.value.xdg_id, .{});
        }
        self.xdg_shell.setWindowFocused(
            entry.value.xdg_id,
            if (self.focused) |id| std.meta.eql(id, entry.id) else false,
        );
        self.xdg_shell.setWindowFullscreen(entry.value.xdg_id, entry.value.fullscreen_output);
        switch (entry.value.pending_borders) {
            .unchanged => {},
            .set => |borders| {
                entry.value.borders = borders;
                entry.value.pending_borders = .unchanged;
            },
        }
        switch (entry.value.pending_clip_box) {
            .unchanged => {},
            .set => |clip_box| {
                entry.value.clip_box = clip_box;
                entry.value.pending_clip_box = .unchanged;
            },
        }
        switch (entry.value.pending_content_clip_box) {
            .unchanged => {},
            .set => |clip_box| {
                entry.value.content_clip_box = clip_box;
                entry.value.pending_content_clip_box = .unchanged;
            },
        }
        if (entry.value.fullscreen_output) {
            const size = self.output.logicalSize();
            self.xdg_shell.setWindowBorders(entry.value.xdg_id, null);
            self.xdg_shell.setWindowClipBox(entry.value.xdg_id, .{
                .x = 0,
                .y = 0,
                .width = size.width,
                .height = size.height,
            });
            self.xdg_shell.setWindowContentClipBox(entry.value.xdg_id, null);
        } else {
            self.xdg_shell.setWindowBorders(entry.value.xdg_id, entry.value.borders);
            self.xdg_shell.setWindowClipBox(entry.value.xdg_id, entry.value.clip_box);
            self.xdg_shell.setWindowContentClipBox(
                entry.value.xdg_id,
                entry.value.content_clip_box,
            );
        }
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

fn validateDecorationCommits(self: *Self) bool {
    var iterator = self.decorations.iterator();
    while (iterator.next()) |entry| {
        const adapter = entry.value.adapter;
        if (adapter.owner_generation != self.session_generation) continue;
        if (!adapter.synchronized_commit_requested) continue;
        adapter.resource.postError(
            .no_commit,
            "sync_next_commit was not followed by wl_surface.commit",
        );
        return false;
    }
    return true;
}

fn applyDecorationState(self: *Self) void {
    var iterator = self.decorations.iterator();
    while (iterator.next()) |entry| {
        const adapter = entry.value.adapter;
        if (adapter.owner_generation != self.session_generation) continue;
        if (entry.value.pending_offset) |offset| {
            if (entry.value.scene_id) |scene_id| {
                self.xdg_shell.setWindowDecorationOffset(scene_id, offset);
            }
            entry.value.pending_offset = null;
        }
        if (adapter.synchronized_commit_cached) {
            if (adapter.surface) |surface| {
                surface.applyCachedCommit();
                if (surface.hasCachedCommit()) surface.discardCachedCommit();
            }
            adapter.synchronized_commit_cached = false;
        }
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
        self.detachDecorations(entry.id);
        self.xdg_shell.setWindowFocused(entry.value.xdg_id, false);
        self.xdg_shell.setWindowFullscreen(entry.value.xdg_id, false);
        self.xdg_shell.setWindowBorders(entry.value.xdg_id, null);
        self.xdg_shell.setWindowClipBox(entry.value.xdg_id, null);
        self.xdg_shell.setWindowContentClipBox(entry.value.xdg_id, null);
        self.xdg_shell.restoreStandaloneWindow(
            entry.value.xdg_id,
            entry.value.sent_configuration.activated,
            entry.value.requested_dimensions,
        );
        _ = self.windows.remove(entry.id);
    }
}

fn detachDecorations(self: *Self, window_id: WindowId) void {
    var iterator = self.decorations.iterator();
    while (iterator.next()) |entry| {
        if (!std.meta.eql(entry.value.window_id, window_id)) continue;
        entry.value.adapter.detach();
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
    self.detachDecorations(id);
    self.xdg_shell.setWindowFocused(window.xdg_id, false);
    self.xdg_shell.setWindowFullscreen(window.xdg_id, false);
    self.xdg_shell.setWindowBorders(window.xdg_id, null);
    self.xdg_shell.setWindowClipBox(window.xdg_id, null);
    self.xdg_shell.setWindowContentClipBox(window.xdg_id, null);
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
            .use_csd, .use_ssd => _ = self.requireManage(manager_resource),
            .set_tiled => |tiled| {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.tiled = .{
                    .top = tiled.edges.top,
                    .bottom = tiled.edges.bottom,
                    .left = tiled.edges.left,
                    .right = tiled.edges.right,
                };
            },
            .inform_resize_start => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.resizing = true;
            },
            .inform_resize_end => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.resizing = false;
            },
            .set_capabilities => |capabilities| {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.capabilities = .{
                    .window_menu = capabilities.caps.window_menu,
                    .maximize = capabilities.caps.maximize,
                    .fullscreen = capabilities.caps.fullscreen,
                    .minimize = capabilities.caps.minimize,
                };
            },
            .inform_maximized => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.maximized = true;
            },
            .inform_unmaximized => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.maximized = false;
            },
            .inform_fullscreen => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.fullscreen = true;
            },
            .inform_not_fullscreen => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.fullscreen = false;
            },
            .fullscreen => |fullscreen| {
                if (!self.requireManage(manager_resource)) return;
                if (!self.resolveOutput(fullscreen.output)) return;
                window.fullscreen_output = true;
                window.fullscreen_dimensions_pending = true;
            },
            .exit_fullscreen => {
                if (!self.requireManage(manager_resource)) return;
                window.fullscreen_output = false;
            },
            .get_node => |get| NodeResource.create(
                self.manager,
                self.id,
                resource,
                get.id,
            ) catch resource.postNoMemory(),
            .set_borders => |borders| {
                if (!self.requireRendering(manager_resource)) return;
                const edges: u32 = @bitCast(borders.edges);
                if (borders.width < 0 or edges & ~@as(u32, 0xf) != 0) {
                    resource.postError(.invalid_border, "invalid window border");
                    return;
                }
                window.pending_borders = .{ .set = if (borders.width == 0 or edges == 0)
                    null
                else
                    .{
                        .edges = .{
                            .top = borders.edges.top,
                            .bottom = borders.edges.bottom,
                            .left = borders.edges.left,
                            .right = borders.edges.right,
                        },
                        .width = @intCast(borders.width),
                        .color = .{
                            .red = protocolColorComponent(borders.r),
                            .green = protocolColorComponent(borders.g),
                            .blue = protocolColorComponent(borders.b),
                            .alpha = protocolColorComponent(borders.a),
                        },
                    } };
            },
            .set_clip_box => |box| {
                if (!self.requireRendering(manager_resource)) return;
                if (box.width < 0 or box.height < 0) {
                    resource.postError(.invalid_clip_box, "invalid window clip box");
                    return;
                }
                window.pending_clip_box = .{ .set = protocolClipBox(
                    box.x,
                    box.y,
                    box.width,
                    box.height,
                ) };
            },
            .set_content_clip_box => |box| {
                if (!self.requireRendering(manager_resource)) return;
                if (box.width < 0 or box.height < 0) {
                    resource.postError(.invalid_clip_box, "invalid window content clip box");
                    return;
                }
                window.pending_content_clip_box = .{ .set = protocolClipBox(
                    box.x,
                    box.y,
                    box.width,
                    box.height,
                ) };
            },
            .get_decoration_above => |get| DecorationResource.create(
                self.manager,
                self.id,
                manager_resource,
                resource,
                Surface.fromResource(get.surface),
                .above,
                get.id,
            ) catch resource.postNoMemory(),
            .get_decoration_below => |get| DecorationResource.create(
                self.manager,
                self.id,
                manager_resource,
                resource,
                Surface.fromResource(get.surface),
                .below,
                get.id,
            ) catch resource.postNoMemory(),
            .set_dimension_bounds => unreachable,
        }
    }

    fn activeManager(self: *WindowResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn resolveOutput(self: *WindowResource, resource: *river.OutputV1) bool {
        const data = resource.getUserData() orelse return false;
        const output: *OutputResource = @ptrCast(@alignCast(data));
        return output.manager == self.manager and
            output.owner_generation == self.owner_generation;
    }

    fn requireManage(self: *WindowResource, manager: *river.WindowManagerV1) bool {
        if (self.manager.sequence.state == .manage) return true;
        manager.postError(.sequence_order, "window request outside a manage sequence");
        return false;
    }

    fn protocolClipBox(x: i32, y: i32, width: i32, height: i32) ?Scene.ClipBox {
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        if (width == 0 or height == 0) return null;
        return .{
            .x = x,
            .y = y,
            .width = @intCast(width),
            .height = @intCast(height),
        };
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

const DecorationResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: DecorationId,
    resource: *river.DecorationV1,
    surface: ?*Surface,
    owner_generation: u64,
    synchronized_commit_requested: bool,
    synchronized_commit_cached: bool,

    fn create(
        manager: *Self,
        window_id: WindowId,
        manager_resource: *river.WindowManagerV1,
        window_resource: *river.WindowV1,
        surface: *Surface,
        layer: Scene.DecorationLayer,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const window = manager.windows.get(window_id) orelse
            return error.ResourceCreateFailed;
        const resource = try river.DecorationV1.create(
            window_resource.getClient(),
            window_resource.getVersion(),
            protocol_id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(DecorationResource) catch
            return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = undefined,
            .resource = resource,
            .surface = surface,
            .owner_generation = manager.session_generation,
            .synchronized_commit_requested = false,
            .synchronized_commit_cached = false,
        };

        if (surface.assignedRole() != null or surface.hasBufferAttachedOrCommitted()) {
            manager_resource.postError(
                .role,
                "decoration wl_surface already has a role or buffer",
            );
            manager.allocator.destroy(self);
            resource.destroy();
            return;
        }
        surface.reserveRole(.river_decoration, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch {
            manager_resource.postError(.role, "wl_surface is unavailable for decoration role");
            manager.allocator.destroy(self);
            resource.destroy();
            return;
        };
        errdefer surface.releaseRole(self);

        const scene_id = manager.xdg_shell.addWindowDecoration(
            window.xdg_id,
            surface.handle(),
            layer,
        ) catch |err| switch (err) {
            error.InvalidWindow => return error.ResourceCreateFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer manager.xdg_shell.removeWindowDecoration(scene_id);
        const id = manager.decorations.insert(manager.allocator, .{
            .window_id = window_id,
            .scene_id = scene_id,
            .adapter = self,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.decorations.remove(id);
        self.id = id;

        surface.assignReservedRole(.river_decoration, self) catch unreachable;
        resource.setHandler(
            *DecorationResource,
            DecorationResource.handleRequest,
            DecorationResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *river.DecorationV1,
        request: river.DecorationV1.Request,
        self: *DecorationResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const manager_resource = self.activeManager() orelse return;
        const decoration = self.manager.decorations.get(self.id) orelse return;
        if (!self.requireRendering(manager_resource)) return;

        switch (request) {
            .destroy => unreachable,
            .set_offset => |offset| decoration.pending_offset = .{
                .x = offset.x,
                .y = offset.y,
            },
            .sync_next_commit => self.synchronized_commit_requested = true,
        }
    }

    fn beforeSurfaceCommit(
        context: *anyopaque,
        _: Surface.CommitInfo,
    ) Surface.CommitAction {
        const self: *DecorationResource = @ptrCast(@alignCast(context));
        if (self.synchronized_commit_requested) {
            self.synchronized_commit_requested = false;
            self.synchronized_commit_cached = true;
            return .cache;
        }
        if (self.synchronized_commit_cached) return .cache;
        return .apply;
    }

    fn afterSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *DecorationResource = @ptrCast(@alignCast(context));
        const decoration = self.manager.decorations.get(self.id) orelse return;
        const scene_id = decoration.scene_id orelse return;
        self.manager.xdg_shell.setWindowDecorationMapped(scene_id, info.has_buffer);
        self.manager.xdg_shell.windowDecorationCommitted(scene_id);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *DecorationResource = @ptrCast(@alignCast(context));
        self.surface = null;
        self.synchronized_commit_requested = false;
        self.synchronized_commit_cached = false;
        const decoration = self.manager.decorations.get(self.id) orelse return;
        if (decoration.scene_id) |scene_id| {
            self.manager.xdg_shell.removeWindowDecoration(scene_id);
            decoration.scene_id = null;
        }
    }

    fn detach(self: *DecorationResource) void {
        const decoration = self.manager.decorations.get(self.id) orelse return;
        if (decoration.scene_id) |scene_id| {
            self.manager.xdg_shell.removeWindowDecoration(scene_id);
            decoration.scene_id = null;
        }
        decoration.pending_offset = null;
        if (self.surface) |surface| surface.discardCachedCommit();
        self.synchronized_commit_requested = false;
        self.synchronized_commit_cached = false;
    }

    fn activeManager(self: *DecorationResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn requireRendering(
        self: *DecorationResource,
        manager: *river.WindowManagerV1,
    ) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "decoration request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(_: *river.DecorationV1, self: *DecorationResource) void {
        self.detach();
        if (self.surface) |surface| surface.releaseRole(self);
        _ = self.manager.decorations.remove(self.id);
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
            => resource.getClient().postImplementationError(
                "river seat operation is not implemented",
            ),
            .set_xcursor_theme => {},
            .pointer_warp => _ = self.requireManage(manager_resource),
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

test "river color components retain full-range endpoints" {
    try std.testing.expectEqual(@as(u8, 0), protocolColorComponent(0));
    try std.testing.expectEqual(@as(u8, 128), protocolColorComponent(0x80808080));
    try std.testing.expectEqual(@as(u8, 255), protocolColorComponent(std.math.maxInt(u32)));
}
