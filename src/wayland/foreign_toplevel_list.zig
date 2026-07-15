//! Privileged mapped-toplevel discovery.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const SecurityContext = @import("security_context.zig");
const XdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
xdg_shell: *XdgShell,
lists: std.ArrayList(*List),
mappings: std.ArrayList(*Mapping),
handles: std.ArrayList(*Handle),
next_identifier: u64,

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

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    xdg_shell: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .xdg_shell = xdg_shell,
        .lists = .empty,
        .mappings = .empty,
        .handles = .empty,
        .next_identifier = 0,
    };
    errdefer self.lists.deinit(allocator);
    errdefer self.mappings.deinit(allocator);
    errdefer self.handles.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        ext.ForeignToplevelListV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    try xdg_shell.addWindowObserver(.{
        .context = self,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
    });
    errdefer xdg_shell.removeWindowObserver(self);
    self.syncMappedWindows();
}

pub fn deinit(self: *Self) void {
    self.xdg_shell.removeWindowObserver(self);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.lists.items.len == 0);
    std.debug.assert(self.handles.items.len == 0);
    for (self.mappings.items) |mapping| self.destroyMapping(mapping);
    self.handles.deinit(self.allocator);
    self.mappings.deinit(self.allocator);
    self.lists.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    List.create(self, client, version, id) catch client.postNoMemory();
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
}

fn removeMapping(self: *Self, window_id: XdgShell.WindowId) void {
    for (self.mappings.items, 0..) |mapping, index| {
        if (!std.meta.eql(mapping.window_id, window_id)) continue;
        for (self.handles.items) |handle| {
            if (handle.mapping == mapping) handle.close();
        }
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

fn postNoMemory(self: *Self) void {
    for (self.lists.items) |list| list.resource.postNoMemory();
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
