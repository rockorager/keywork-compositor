//! Privileged mapped-toplevel discovery and compatibility controls.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
ext_global: *wl.Global,
wlr_global: *wl.Global,
security_context: *SecurityContext,
xdg_shell: *XdgShell,
outputs: *OutputLayout,
lists: std.ArrayList(*List),
mappings: std.ArrayList(*Mapping),
handles: std.ArrayList(*Handle),
wlr_managers: std.ArrayList(*WlrManager),
wlr_handles: std.ArrayList(*WlrHandle),
next_identifier: u64,
next_wlr_manager_generation: u64,

const Mapping = struct {
    window_id: XdgShell.WindowId,
    identifier: [:0]u8,
};

const List = struct {
    manager: *Self,
    resource: *ext.ForeignToplevelListV1,
    stopped: bool = false,

    fn create(manager: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try ext.ForeignToplevelListV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(List);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource };
        try manager.lists.append(manager.allocator, self);
        resource.setHandler(*List, handleRequest, handleDestroy, self);
        manager.syncMappedWindows();
        for (manager.mappings.items) |mapping| {
            if (manager.handleFor(self, mapping) != null) continue;
            Handle.create(self, mapping) catch {
                resource.postNoMemory();
                return;
            };
        }
    }

    fn handleRequest(
        resource: *ext.ForeignToplevelListV1,
        request: ext.ForeignToplevelListV1.Request,
        self: *List,
    ) void {
        switch (request) {
            .stop => {
                if (self.stopped) return;
                self.stopped = true;
                resource.sendFinished();
            },
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *ext.ForeignToplevelListV1, self: *List) void {
        for (self.manager.handles.items) |handle| {
            if (handle.list == self) handle.list = null;
        }
        for (self.manager.lists.items, 0..) |list, index| {
            if (list != self) continue;
            _ = self.manager.lists.swapRemove(index);
            break;
        }
        self.manager.allocator.destroy(self);
    }
};

const Handle = struct {
    manager: *Self,
    list: ?*List,
    mapping: ?*Mapping,
    resource: *ext.ForeignToplevelHandleV1,
    closed: bool = false,

    fn create(list: *List, mapping: *Mapping) !void {
        const resource = try ext.ForeignToplevelHandleV1.create(
            list.resource.getClient(),
            list.resource.getVersion(),
            0,
        );
        errdefer resource.destroy();
        const self = try list.manager.allocator.create(Handle);
        errdefer list.manager.allocator.destroy(self);
        self.* = .{
            .manager = list.manager,
            .list = list,
            .mapping = mapping,
            .resource = resource,
        };
        try list.manager.handles.append(list.manager.allocator, self);
        resource.setHandler(*Handle, handleRequest, handleDestroy, self);
        list.resource.sendToplevel(resource);
        resource.sendIdentifier(mapping.identifier.ptr);
        if (list.manager.xdg_shell.windowInfo(mapping.window_id)) |info| {
            if (info.title) |title| resource.sendTitle(title.ptr);
            if (info.app_id) |app_id| resource.sendAppId(app_id.ptr);
        }
        resource.sendDone();
    }

    fn handleRequest(
        resource: *ext.ForeignToplevelHandleV1,
        request: ext.ForeignToplevelHandleV1.Request,
        _: *Handle,
    ) void {
        if (request == .destroy) resource.destroy();
    }

    fn handleDestroy(_: *ext.ForeignToplevelHandleV1, self: *Handle) void {
        for (self.manager.handles.items, 0..) |handle, index| {
            if (handle != self) continue;
            _ = self.manager.handles.swapRemove(index);
            break;
        }
        self.manager.allocator.destroy(self);
    }

    fn close(self: *Handle) void {
        if (self.closed) return;
        self.closed = true;
        self.mapping = null;
        self.resource.sendClosed();
    }
};

const WlrManager = struct {
    owner: *Self,
    resource: *zwlr.ForeignToplevelManagerV1,
    generation: u64,

    fn create(owner: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const resource = try zwlr.ForeignToplevelManagerV1.create(client, version, id);
        errdefer resource.destroy();
        const self = try owner.allocator.create(WlrManager);
        errdefer owner.allocator.destroy(self);
        const generation = std.math.add(u64, owner.next_wlr_manager_generation, 1) catch
            return error.OutOfMemory;
        self.* = .{ .owner = owner, .resource = resource, .generation = generation };
        try owner.wlr_managers.append(owner.allocator, self);
        owner.next_wlr_manager_generation = generation;
        resource.setHandler(*WlrManager, handleRequest, handleDestroy, self);

        owner.syncMappedWindows();
        for (owner.mappings.items) |mapping| {
            if (owner.wlrHandleFor(generation, mapping) != null) continue;
            WlrHandle.create(self, mapping) catch {
                resource.postNoMemory();
                return;
            };
        }
        for (owner.wlr_handles.items) |handle| {
            if (handle.binding_generation != generation or handle.initialized) continue;
            handle.sendInitialDetails() catch {
                resource.postNoMemory();
                return;
            };
        }
    }

    fn handleRequest(
        resource: *zwlr.ForeignToplevelManagerV1,
        request: zwlr.ForeignToplevelManagerV1.Request,
        _: *WlrManager,
    ) void {
        if (request == .stop) resource.destroySendFinished();
    }

    fn handleDestroy(_: *zwlr.ForeignToplevelManagerV1, self: *WlrManager) void {
        for (self.owner.wlr_managers.items, 0..) |manager, index| {
            if (manager != self) continue;
            _ = self.owner.wlr_managers.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }
};

const WlrHandle = struct {
    owner: *Self,
    binding_generation: u64,
    mapping: ?*Mapping,
    resource: *zwlr.ForeignToplevelHandleV1,
    outputs: std.ArrayList(OutputLayout.Id) = .empty,
    initialized: bool = false,
    closed: bool = false,

    fn create(manager: *WlrManager, mapping: *Mapping) !void {
        const resource = try zwlr.ForeignToplevelHandleV1.create(
            manager.resource.getClient(),
            manager.resource.getVersion(),
            0,
        );
        errdefer resource.destroy();
        const self = try manager.owner.allocator.create(WlrHandle);
        errdefer manager.owner.allocator.destroy(self);
        self.* = .{
            .owner = manager.owner,
            .binding_generation = manager.generation,
            .mapping = mapping,
            .resource = resource,
        };
        try manager.owner.wlr_handles.append(manager.owner.allocator, self);
        resource.setHandler(*WlrHandle, handleRequest, handleDestroy, self);
        manager.resource.sendToplevel(resource);
    }

    fn sendInitialDetails(self: *WlrHandle) !void {
        std.debug.assert(!self.initialized and !self.closed);
        const mapping = self.mapping orelse return;
        const info = self.owner.xdg_shell.windowInfo(mapping.window_id) orelse return;
        if (info.title) |title| self.resource.sendTitle(title.ptr);
        if (info.app_id) |app_id| self.resource.sendAppId(app_id.ptr);
        var outputs = self.owner.outputs.iterator();
        while (outputs.next()) |entry| {
            const surface_id = self.owner.xdg_shell.windowSurface(mapping.window_id) orelse break;
            if (!entry.output.containsSurface(surface_id)) continue;
            try self.outputs.append(self.owner.allocator, entry.id);
            self.sendOutput(entry.output, true);
        }
        self.sendState(info.configuration);
        self.sendParent(info.parent);
        self.resource.sendDone();
        self.initialized = true;
    }

    fn handleRequest(
        resource: *zwlr.ForeignToplevelHandleV1,
        request: zwlr.ForeignToplevelHandleV1.Request,
        self: *WlrHandle,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const mapping = self.mapping orelse return;
        const window_id = mapping.window_id;
        switch (request) {
            .destroy => unreachable,
            .set_maximized => self.owner.xdg_shell.requestWindow(window_id, .maximize),
            .unset_maximized => self.owner.xdg_shell.requestWindow(window_id, .unmaximize),
            .set_minimized => self.owner.xdg_shell.requestWindow(window_id, .minimize),
            .unset_minimized => self.owner.xdg_shell.requestWindow(window_id, .unminimize),
            .activate => |activate| self.owner.xdg_shell.requestWindow(
                window_id,
                .{ .activate = Seat.fromResource(activate.seat) },
            ),
            .close => self.owner.xdg_shell.closeWindow(window_id),
            .set_rectangle => |rectangle| {
                if (rectangle.width < 0 or rectangle.height < 0) {
                    resource.postError(.invalid_rectangle, "rectangle dimensions must not be negative");
                    return;
                }
            },
            .set_fullscreen => |fullscreen| self.owner.xdg_shell.requestWindow(
                window_id,
                .{ .fullscreen = fullscreen.output },
            ),
            .unset_fullscreen => self.owner.xdg_shell.requestWindow(window_id, .exit_fullscreen),
        }
    }

    fn handleDestroy(_: *zwlr.ForeignToplevelHandleV1, self: *WlrHandle) void {
        for (self.owner.wlr_handles.items, 0..) |handle, index| {
            if (handle != self) continue;
            _ = self.owner.wlr_handles.swapRemove(index);
            break;
        }
        self.outputs.deinit(self.owner.allocator);
        self.owner.allocator.destroy(self);
    }

    fn sendOutput(self: *WlrHandle, output: *Output, enter: bool) void {
        for (output.boundResources()) |output_resource| {
            if (output_resource.getClient() != self.resource.getClient()) continue;
            if (enter) {
                self.resource.sendOutputEnter(output_resource);
            } else {
                self.resource.sendOutputLeave(output_resource);
            }
        }
    }

    fn sendState(self: *WlrHandle, configuration: XdgShell.ToplevelConfigure) void {
        var values: [4]u32 = undefined;
        var count: usize = 0;
        if (configuration.maximized) appendWlrState(&values, &count, .maximized);
        if (configuration.suspended) appendWlrState(&values, &count, .minimized);
        if (configuration.activated) appendWlrState(&values, &count, .activated);
        if (self.resource.getVersion() >= 2 and configuration.fullscreen) {
            appendWlrState(&values, &count, .fullscreen);
        }
        var array: wl.Array = .{
            .size = count * @sizeOf(u32),
            .alloc = count * @sizeOf(u32),
            .data = if (count == 0) null else @ptrCast(&values),
        };
        self.resource.sendState(&array);
    }

    fn sendParent(self: *WlrHandle, parent_id: ?XdgShell.WindowId) void {
        if (self.resource.getVersion() < 3) return;
        if (parent_id) |id| {
            const mapping = self.owner.mappingFor(id) orelse return;
            const parent = self.owner.wlrHandleFor(self.binding_generation, mapping) orelse return;
            self.resource.sendParent(parent.resource);
        } else {
            self.resource.sendParent(null);
        }
    }

    fn outputIndex(self: *const WlrHandle, output_id: OutputLayout.Id) ?usize {
        for (self.outputs.items, 0..) |candidate, index| {
            if (std.meta.eql(candidate, output_id)) return index;
        }
        return null;
    }

    fn close(self: *WlrHandle) void {
        if (self.closed) return;
        self.closed = true;
        self.mapping = null;
        self.outputs.clearRetainingCapacity();
        self.resource.sendClosed();
    }
};

fn appendWlrState(
    values: *[4]u32,
    count: *usize,
    state: zwlr.ForeignToplevelHandleV1.State,
) void {
    values[count.*] = @intCast(@intFromEnum(state));
    count.* += 1;
}

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    xdg_shell: *XdgShell,
    outputs: *OutputLayout,
) !void {
    self.* = .{
        .allocator = allocator,
        .ext_global = undefined,
        .wlr_global = undefined,
        .security_context = security_context,
        .xdg_shell = xdg_shell,
        .outputs = outputs,
        .lists = .empty,
        .mappings = .empty,
        .handles = .empty,
        .wlr_managers = .empty,
        .wlr_handles = .empty,
        .next_identifier = 0,
        .next_wlr_manager_generation = 0,
    };
    errdefer self.lists.deinit(allocator);
    errdefer self.mappings.deinit(allocator);
    errdefer self.handles.deinit(allocator);
    errdefer self.wlr_managers.deinit(allocator);
    errdefer self.wlr_handles.deinit(allocator);
    self.ext_global = try wl.Global.create(
        display,
        ext.ForeignToplevelListV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.ext_global.destroy();
    try security_context.restrictGlobal(self.ext_global);
    errdefer security_context.unrestrictGlobal(self.ext_global);
    self.wlr_global = try wl.Global.create(
        display,
        zwlr.ForeignToplevelManagerV1,
        3,
        *Self,
        self,
        bindWlr,
    );
    errdefer self.wlr_global.destroy();
    try security_context.restrictGlobal(self.wlr_global);
    errdefer security_context.unrestrictGlobal(self.wlr_global);
    try xdg_shell.addWindowObserver(.{
        .context = self,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .state_changed = windowStateChanged,
    });
    errdefer xdg_shell.removeWindowObserver(self);
    self.syncMappedWindows();
}

pub fn deinit(self: *Self) void {
    self.xdg_shell.removeWindowObserver(self);
    self.security_context.unrestrictGlobal(self.wlr_global);
    self.wlr_global.destroy();
    self.security_context.unrestrictGlobal(self.ext_global);
    self.ext_global.destroy();
    std.debug.assert(self.lists.items.len == 0);
    std.debug.assert(self.handles.items.len == 0);
    std.debug.assert(self.wlr_managers.items.len == 0);
    std.debug.assert(self.wlr_handles.items.len == 0);
    for (self.mappings.items) |mapping| self.destroyMapping(mapping);
    self.wlr_handles.deinit(self.allocator);
    self.wlr_managers.deinit(self.allocator);
    self.handles.deinit(self.allocator);
    self.mappings.deinit(self.allocator);
    self.lists.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    List.create(self, client, version, id) catch client.postNoMemory();
}

fn bindWlr(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    WlrManager.create(self, client, version, id) catch client.postNoMemory();
}

fn syncMappedWindows(self: *Self) void {
    var windows = self.xdg_shell.windowIterator();
    while (windows.next()) |window_id| {
        const info = self.xdg_shell.windowInfo(window_id) orelse continue;
        if (!info.mapped or self.mappingFor(window_id) != null) continue;
        self.addMapping(window_id) catch self.postNoMemory();
    }
}

fn addMapping(self: *Self, window_id: XdgShell.WindowId) !void {
    std.debug.assert(self.mappingFor(window_id) == null);
    self.next_identifier = std.math.add(u64, self.next_identifier, 1) catch
        return error.OutOfMemory;
    const identifier = try identifierFor(self.allocator, self.next_identifier);
    errdefer self.allocator.free(identifier);
    const mapping = try self.allocator.create(Mapping);
    errdefer self.allocator.destroy(mapping);
    mapping.* = .{ .window_id = window_id, .identifier = identifier };
    try self.mappings.append(self.allocator, mapping);
    for (self.lists.items) |list| {
        if (list.stopped) continue;
        Handle.create(list, mapping) catch list.resource.postNoMemory();
    }
    for (self.wlr_managers.items) |manager| {
        WlrHandle.create(manager, mapping) catch manager.resource.postNoMemory();
    }
    for (self.wlr_handles.items) |handle| {
        if (handle.mapping != mapping or handle.initialized) continue;
        handle.sendInitialDetails() catch handle.resource.postNoMemory();
    }
    self.syncWlrChildParents(window_id);
}

fn removeMapping(self: *Self, window_id: XdgShell.WindowId) void {
    for (self.mappings.items, 0..) |mapping, index| {
        if (!std.meta.eql(mapping.window_id, window_id)) continue;
        for (self.handles.items) |handle| {
            if (handle.mapping == mapping) handle.close();
        }
        for (self.wlr_handles.items) |handle| {
            if (handle.mapping == mapping) handle.close();
        }
        self.clearWlrChildParents(window_id);
        _ = self.mappings.swapRemove(index);
        self.destroyMapping(mapping);
        return;
    }
}

fn destroyMapping(self: *Self, mapping: *Mapping) void {
    self.allocator.free(mapping.identifier);
    self.allocator.destroy(mapping);
}

fn mappingFor(self: *Self, window_id: XdgShell.WindowId) ?*Mapping {
    for (self.mappings.items) |mapping| {
        if (std.meta.eql(mapping.window_id, window_id)) return mapping;
    }
    return null;
}

fn handleFor(self: *Self, list: *List, mapping: *Mapping) ?*Handle {
    for (self.handles.items) |handle| {
        if (handle.list == list and handle.mapping == mapping) return handle;
    }
    return null;
}

fn wlrHandleFor(self: *Self, generation: u64, mapping: *Mapping) ?*WlrHandle {
    for (self.wlr_handles.items) |handle| {
        if (handle.binding_generation == generation and handle.mapping == mapping) return handle;
    }
    return null;
}

fn postNoMemory(self: *Self) void {
    for (self.lists.items) |list| list.resource.postNoMemory();
    for (self.wlr_managers.items) |manager| manager.resource.postNoMemory();
}

pub fn syncOutput(self: *Self, output_id: OutputLayout.Id) void {
    const output = self.outputs.get(output_id) orelse return;
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const mapping = handle.mapping orelse continue;
        const surface_id = self.xdg_shell.windowSurface(mapping.window_id) orelse continue;
        const current_index = handle.outputIndex(output_id);
        const visible = output.containsSurface(surface_id);
        if (visible == (current_index != null)) continue;
        if (visible) {
            handle.outputs.append(self.allocator, output_id) catch {
                handle.resource.postNoMemory();
                continue;
            };
            handle.sendOutput(output, true);
        } else {
            handle.sendOutput(output, false);
            _ = handle.outputs.orderedRemove(current_index.?);
        }
        handle.resource.sendDone();
    }
}

pub fn removeOutput(self: *Self, output_id: OutputLayout.Id) void {
    const output = self.outputs.get(output_id) orelse return;
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const index = handle.outputIndex(output_id) orelse continue;
        handle.sendOutput(output, false);
        _ = handle.outputs.orderedRemove(index);
        handle.resource.sendDone();
    }
}

pub fn windowForExtHandle(
    self: *Self,
    resource: *ext.ForeignToplevelHandleV1,
) ?XdgShell.WindowId {
    for (self.handles.items) |handle| {
        if (handle.resource != resource or handle.closed) continue;
        return (handle.mapping orelse return null).window_id;
    }
    return null;
}

fn syncWlrChildParents(self: *Self, parent_id: XdgShell.WindowId) void {
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed) continue;
        const mapping = handle.mapping orelse continue;
        const info = self.xdg_shell.windowInfo(mapping.window_id) orelse continue;
        if (info.parent == null or !std.meta.eql(info.parent.?, parent_id)) continue;
        handle.sendParent(info.parent);
        handle.resource.sendDone();
    }
}

fn clearWlrChildParents(self: *Self, parent_id: XdgShell.WindowId) void {
    for (self.wlr_handles.items) |handle| {
        if (!handle.initialized or handle.closed or handle.resource.getVersion() < 3) continue;
        const mapping = handle.mapping orelse continue;
        const info = self.xdg_shell.windowInfo(mapping.window_id) orelse continue;
        if (info.parent == null or !std.meta.eql(info.parent.?, parent_id)) continue;
        handle.resource.sendParent(null);
        handle.resource.sendDone();
    }
}

fn windowCommitted(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const info = self.xdg_shell.windowInfo(window_id) orelse return;
    if (!info.mapped or self.mappingFor(window_id) != null) return;
    self.addMapping(window_id) catch self.postNoMemory();
}

fn windowUnmapped(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeMapping(window_id);
}

fn windowDestroyed(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeMapping(window_id);
}

fn windowMetadataChanged(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const mapping = self.mappingFor(window_id) orelse return;
    const info = self.xdg_shell.windowInfo(window_id) orelse return;
    for (self.handles.items) |handle| {
        if (handle.mapping != mapping or handle.closed) continue;
        if (info.title) |title| handle.resource.sendTitle(title.ptr);
        if (info.app_id) |app_id| handle.resource.sendAppId(app_id.ptr);
        handle.resource.sendDone();
    }
    for (self.wlr_handles.items) |handle| {
        if (handle.mapping != mapping or !handle.initialized or handle.closed) continue;
        if (info.title) |title| handle.resource.sendTitle(title.ptr);
        if (info.app_id) |app_id| handle.resource.sendAppId(app_id.ptr);
        handle.sendParent(info.parent);
        handle.resource.sendDone();
    }
}

fn windowStateChanged(context: *anyopaque, window_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const mapping = self.mappingFor(window_id) orelse return;
    const info = self.xdg_shell.windowInfo(window_id) orelse return;
    for (self.wlr_handles.items) |handle| {
        if (handle.mapping != mapping or !handle.initialized or handle.closed) continue;
        handle.sendState(info.configuration);
        handle.resource.sendDone();
    }
}

fn identifierFor(allocator: std.mem.Allocator, generation: u64) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "keywork-{x}", .{generation}, 0);
}

test "foreign toplevel identifiers are printable and bounded" {
    const identifier = try identifierFor(std.testing.allocator, std.math.maxInt(u64));
    defer std.testing.allocator.free(identifier);
    try std.testing.expect(identifier.len > 0 and identifier.len <= 32);
    for (identifier) |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x7e);
}
