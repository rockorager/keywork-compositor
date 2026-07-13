//! wl_subcompositor and synchronized subsurface state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("slot_map.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
surface_store: *Surface.Store,
subsurfaces: Store,
by_surface: std.AutoHashMapUnmanaged(Surface.Id, Id),
adapters: std.AutoHashMapUnmanaged(Id, *SubsurfaceResource),
parents: std.AutoHashMapUnmanaged(Surface.Id, *Parent),
repaint_listener: ?RepaintListener,

pub const Store = slot_map.SlotMap(State, enum { subsurface });
pub const Id = Store.Id;

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
};

pub const StackEntry = union(enum) {
    parent: void,
    child: struct {
        surface_id: Surface.Id,
        position: Point,
    },
};

pub const StackIterator = struct {
    shell: *Self,
    parent: ?*Parent,
    index: usize = 0,

    pub fn next(self: *StackIterator) ?StackEntry {
        const parent = self.parent orelse {
            if (self.index != 0) return null;
            self.index = 1;
            return .{ .parent = {} };
        };
        while (self.index < parent.current.items.len) {
            const node = parent.current.items[self.index];
            self.index += 1;
            switch (node) {
                .parent => return .{ .parent = {} },
                .child => |id| {
                    const state = self.shell.subsurfaces.get(id) orelse continue;
                    if (!state.active) continue;
                    return .{ .child = .{
                        .surface_id = state.surface_id,
                        .position = state.current_position,
                    } };
                },
            }
        }
        return null;
    }
};

pub const ReverseStackIterator = struct {
    shell: *Self,
    parent: ?*Parent,
    index: usize,

    pub fn next(self: *ReverseStackIterator) ?StackEntry {
        const parent = self.parent orelse {
            if (self.index == 0) return null;
            self.index = 0;
            return .{ .parent = {} };
        };
        while (self.index > 0) {
            self.index -= 1;
            const node = parent.current.items[self.index];
            switch (node) {
                .parent => return .{ .parent = {} },
                .child => |id| {
                    const state = self.shell.subsurfaces.get(id) orelse continue;
                    if (!state.active) continue;
                    return .{ .child = .{
                        .surface_id = state.surface_id,
                        .position = state.current_position,
                    } };
                },
            }
        }
        return null;
    }
};

pub const State = struct {
    surface_id: Surface.Id,
    parent_id: Surface.Id,
    pending_position: Point = .{},
    current_position: Point = .{},
    synchronized: bool = true,
    active: bool = false,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surface_store: *Surface.Store,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .surface_store = surface_store,
        .subsurfaces = .{},
        .by_surface = .empty,
        .adapters = .empty,
        .parents = .empty,
        .repaint_listener = null,
    };
    errdefer self.subsurfaces.deinit(allocator);
    errdefer self.by_surface.deinit(allocator);
    errdefer self.adapters.deinit(allocator);
    errdefer self.parents.deinit(allocator);
    self.global = try wl.Global.create(display, wl.Subcompositor, 1, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    std.debug.assert(self.parents.count() == 0);
    std.debug.assert(self.by_surface.count() == 0);
    std.debug.assert(self.adapters.count() == 0);
    self.parents.deinit(self.allocator);
    self.by_surface.deinit(self.allocator);
    self.adapters.deinit(self.allocator);
    self.subsurfaces.deinit(self.allocator);
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

pub fn stackIterator(self: *Self, surface_id: Surface.Id) StackIterator {
    return .{
        .shell = self,
        .parent = self.parents.get(surface_id),
    };
}

pub fn reverseStackIterator(self: *Self, surface_id: Surface.Id) ReverseStackIterator {
    const parent = self.parents.get(surface_id);
    return .{
        .shell = self,
        .parent = parent,
        .index = if (parent) |value| value.current.items.len else 1,
    };
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Subcompositor.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wl.Subcompositor,
    request: wl.Subcompositor.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_subsurface => |get| SubsurfaceResource.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            get.id,
            Surface.fromResource(get.surface),
            Surface.fromResource(get.parent),
        ) catch |err| switch (err) {
            error.BadSurface => resource.postError(
                .bad_surface,
                "wl_surface already has another role or subsurface object",
            ),
            error.BadParent => resource.postError(
                .bad_parent,
                "subsurface parent would create a cycle",
            ),
            error.OutOfMemory, error.ResourceCreateFailed => resource.postNoMemory(),
        },
    }
}

fn effectivelySynchronized(self: *Self, id: Id) bool {
    const state = self.subsurfaces.get(id) orelse return false;
    if (state.synchronized) return true;
    const parent_subsurface = self.by_surface.get(state.parent_id) orelse return false;
    return self.effectivelySynchronized(parent_subsurface);
}

fn applyParent(self: *Self, parent: *Parent) void {
    if (parent.surface == null) return;
    parent.current.clearRetainingCapacity();
    parent.current.appendSliceAssumeCapacity(parent.pending.items);

    for (parent.current.items) |node| switch (node) {
        .parent => {},
        .child => |id| {
            const state = self.subsurfaces.get(id) orelse continue;
            state.current_position = state.pending_position;
            state.active = true;
        },
    };

    for (parent.current.items) |node| switch (node) {
        .parent => {},
        .child => |id| {
            if (!self.effectivelySynchronized(id)) continue;
            const adapter = self.adapters.get(id) orelse continue;
            const surface = adapter.surface orelse continue;
            if (surface.hasCachedCommit()) {
                surface.applyCachedCommit();
            }
        },
    };
}

fn flushDesynchronizedDescendants(self: *Self, parent_id: Surface.Id) void {
    const parent = self.parents.get(parent_id) orelse return;
    for (parent.pending.items) |node| switch (node) {
        .parent => {},
        .child => |id| {
            if (self.effectivelySynchronized(id)) continue;
            const adapter = self.adapters.get(id) orelse continue;
            const surface = adapter.surface orelse continue;
            if (surface.hasCachedCommit()) surface.applyCachedCommit();
            self.flushDesynchronizedDescendants(surface.handle());
        },
    };
}

const Parent = struct {
    const Node = union(enum) {
        parent: void,
        child: Id,
    };

    allocator: std.mem.Allocator,
    shell: *Self,
    surface_id: Surface.Id,
    surface: ?*Surface,
    listener: Surface.CommitListener,
    pending: std.ArrayList(Node),
    current: std.ArrayList(Node),
    child_count: usize,

    fn create(shell: *Self, surface: *Surface) error{OutOfMemory}!*Parent {
        const self = shell.allocator.create(Parent) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .surface_id = surface.handle(),
            .surface = surface,
            .listener = undefined,
            .pending = .empty,
            .current = .empty,
            .child_count = 0,
        };
        errdefer self.pending.deinit(shell.allocator);
        errdefer self.current.deinit(shell.allocator);
        try self.pending.append(shell.allocator, .{ .parent = {} });
        try self.current.append(shell.allocator, .{ .parent = {} });

        self.listener = .{
            .context = self,
            .applied = handleApplied,
            .surface_destroyed = handleSurfaceDestroyed,
        };
        try surface.addCommitListener(&self.listener);
        errdefer surface.removeCommitListener(&self.listener);
        shell.parents.put(shell.allocator, self.surface_id, self) catch
            return error.OutOfMemory;
        return self;
    }

    fn destroy(self: *Parent) void {
        std.debug.assert(self.child_count == 0);
        if (self.surface) |surface| {
            surface.removeCommitListener(&self.listener);
            _ = self.shell.parents.remove(self.surface_id);
        }
        self.pending.deinit(self.allocator);
        self.current.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn addChild(self: *Parent, id: Id) error{OutOfMemory}!void {
        try self.pending.append(self.allocator, .{ .child = id });
        errdefer _ = self.pending.pop();
        try self.current.ensureTotalCapacity(self.allocator, self.pending.items.len);
        self.child_count += 1;
    }

    fn removeChild(self: *Parent, id: Id) void {
        removeNode(&self.pending, id);
        removeNode(&self.current, id);
        std.debug.assert(self.child_count > 0);
        self.child_count -= 1;
    }

    fn place(
        self: *Parent,
        child_id: Id,
        sibling_id: Surface.Id,
        above: bool,
    ) error{ BadSurface, OutOfMemory }!void {
        const child_index = findChild(self.pending.items, child_id) orelse
            return error.BadSurface;
        const sibling_index = self.findSurface(sibling_id) orelse
            return error.BadSurface;
        if (child_index == sibling_index) return error.BadSurface;

        const node = self.pending.orderedRemove(child_index);
        const reference_index = self.findSurface(sibling_id) orelse unreachable;
        const insertion_index = reference_index + @intFromBool(above);
        self.pending.insert(self.allocator, insertion_index, node) catch {
            self.pending.insertAssumeCapacity(child_index, node);
            return error.OutOfMemory;
        };
        try self.current.ensureTotalCapacity(self.allocator, self.pending.items.len);
    }

    fn findSurface(self: *const Parent, surface_id: Surface.Id) ?usize {
        if (std.meta.eql(surface_id, self.surface_id)) {
            for (self.pending.items, 0..) |node, index| switch (node) {
                .parent => return index,
                .child => {},
            };
        }
        const subsurface_id = self.shell.by_surface.get(surface_id) orelse return null;
        return findChild(self.pending.items, subsurface_id);
    }

    fn findChild(nodes: []const Node, id: Id) ?usize {
        for (nodes, 0..) |node, index| switch (node) {
            .parent => {},
            .child => |candidate| if (std.meta.eql(candidate, id)) return index,
        };
        return null;
    }

    fn removeNode(nodes: *std.ArrayList(Node), id: Id) void {
        const index = findChild(nodes.items, id) orelse return;
        _ = nodes.orderedRemove(index);
    }

    fn handleApplied(context: *anyopaque) void {
        const self: *Parent = @ptrCast(@alignCast(context));
        self.shell.applyParent(self);
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *Parent = @ptrCast(@alignCast(context));
        const surface = self.surface orelse return;
        surface.removeCommitListener(&self.listener);
        _ = self.shell.parents.remove(self.surface_id);
        self.surface = null;
        for (self.pending.items) |node| switch (node) {
            .parent => {},
            .child => |id| {
                if (self.shell.subsurfaces.get(id)) |state| state.active = false;
            },
        };
    }
};

fn getParent(self: *Self, surface: *Surface) error{OutOfMemory}!*Parent {
    return self.parents.get(surface.handle()) orelse try Parent.create(self, surface);
}

fn releaseParent(parent: *Parent) void {
    if (parent.child_count == 0) parent.destroy();
}

const SubsurfaceResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: Id,
    resource: *wl.Subsurface,
    surface: ?*Surface,
    parent: ?*Parent,

    const CreateError = error{
        OutOfMemory,
        ResourceCreateFailed,
        BadSurface,
        BadParent,
    };

    fn create(
        shell: *Self,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
        surface: *Surface,
        parent_surface: *Surface,
    ) CreateError!void {
        if (shell.by_surface.contains(surface.handle())) return error.BadSurface;
        if (surface.assignedRole()) |role| {
            if (role != .subsurface) return error.BadSurface;
        }
        var ancestor = parent_surface.handle();
        while (true) {
            if (std.meta.eql(ancestor, surface.handle())) return error.BadParent;
            const ancestor_id = shell.by_surface.get(ancestor) orelse break;
            const ancestor_state = shell.subsurfaces.get(ancestor_id) orelse break;
            ancestor = ancestor_state.parent_id;
        }

        const resource = try wl.Subsurface.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = shell.allocator.create(SubsurfaceResource) catch
            return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const id = shell.subsurfaces.insert(shell.allocator, .{
            .surface_id = surface.handle(),
            .parent_id = parent_surface.handle(),
        }) catch return error.OutOfMemory;
        errdefer _ = shell.subsurfaces.remove(id);

        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = id,
            .resource = resource,
            .surface = surface,
            .parent = null,
        };

        surface.reserveRole(.subsurface, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch return error.BadSurface;
        errdefer surface.releaseRole(self);
        surface.assignReservedRole(.subsurface, self) catch return error.BadSurface;

        const parent = try shell.getParent(parent_surface);
        var child_added = false;
        errdefer if (child_added) {
            parent.removeChild(id);
            releaseParent(parent);
        } else {
            releaseParent(parent);
        };
        try parent.addChild(id);
        child_added = true;
        self.parent = parent;

        shell.by_surface.put(shell.allocator, surface.handle(), id) catch
            return error.OutOfMemory;
        errdefer _ = shell.by_surface.remove(surface.handle());
        shell.adapters.put(shell.allocator, id, self) catch return error.OutOfMemory;

        resource.setHandler(
            *SubsurfaceResource,
            SubsurfaceResource.handleRequest,
            SubsurfaceResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *wl.Subsurface,
        request: wl.Subsurface.Request,
        self: *SubsurfaceResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            else => {
                const state = self.shell.subsurfaces.get(self.id) orelse return;
                const parent = self.parent orelse return;
                if (parent.surface == null) return;

                switch (request) {
                    .destroy => unreachable,
                    .set_position => |position| state.pending_position = .{
                        .x = position.x,
                        .y = position.y,
                    },
                    .place_above => |place| parent.place(
                        self.id,
                        Surface.fromResource(place.sibling).handle(),
                        true,
                    ) catch |err| switch (err) {
                        error.BadSurface => resource.postError(
                            .bad_surface,
                            "reference is not the parent or a sibling",
                        ),
                        error.OutOfMemory => resource.postNoMemory(),
                    },
                    .place_below => |place| parent.place(
                        self.id,
                        Surface.fromResource(place.sibling).handle(),
                        false,
                    ) catch |err| switch (err) {
                        error.BadSurface => resource.postError(
                            .bad_surface,
                            "reference is not the parent or a sibling",
                        ),
                        error.OutOfMemory => resource.postNoMemory(),
                    },
                    .set_sync => state.synchronized = true,
                    .set_desync => {
                        state.synchronized = false;
                        if (!self.shell.effectivelySynchronized(self.id)) {
                            if (self.surface) |surface| {
                                if (surface.hasCachedCommit()) surface.applyCachedCommit();
                                self.shell.flushDesynchronizedDescendants(surface.handle());
                            }
                        }
                    },
                }
            },
        }
    }

    fn handleDestroy(_: *wl.Subsurface, self: *SubsurfaceResource) void {
        const was_active = if (self.shell.subsurfaces.get(self.id)) |state|
            state.active
        else
            false;
        if (self.surface) |surface| {
            surface.discardCachedCommit();
            surface.releaseRole(self);
            _ = self.shell.by_surface.remove(surface.handle());
        }
        self.detach();
        _ = self.shell.adapters.remove(self.id);
        _ = self.shell.subsurfaces.remove(self.id);
        if (was_active) self.shell.requestRepaint();
        self.allocator.destroy(self);
    }

    fn detach(self: *SubsurfaceResource) void {
        const parent = self.parent orelse return;
        parent.removeChild(self.id);
        self.parent = null;
        releaseParent(parent);
    }

    fn beforeSurfaceCommit(
        context: *anyopaque,
        _: Surface.CommitInfo,
    ) Surface.CommitAction {
        const self: *SubsurfaceResource = @ptrCast(@alignCast(context));
        if (self.shell.effectivelySynchronized(self.id)) return .cache;
        const surface = self.surface orelse return .reject;
        return if (surface.hasCachedCommit()) .apply_cached else .apply;
    }

    fn afterSurfaceCommit(context: *anyopaque, _: Surface.CommitInfo) void {
        const self: *SubsurfaceResource = @ptrCast(@alignCast(context));
        self.shell.requestRepaint();
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *SubsurfaceResource = @ptrCast(@alignCast(context));
        const was_active = if (self.shell.subsurfaces.get(self.id)) |state|
            state.active
        else
            false;
        if (self.surface) |surface| _ = self.shell.by_surface.remove(surface.handle());
        self.surface = null;
        self.detach();
        _ = self.shell.subsurfaces.remove(self.id);
        if (was_active) self.shell.requestRepaint();
    }
};

test "subsurface points support negative positions" {
    const point: Point = .{ .x = -20, .y = 15 };
    try std.testing.expectEqual(@as(i32, -20), point.x);
    try std.testing.expectEqual(@as(i32, 15), point.y);
}

test "stack iterator preserves children below and above their parent" {
    var shell: Self = undefined;
    shell.subsurfaces = .{};
    defer shell.subsurfaces.deinit(std.testing.allocator);

    const parent_surface: Surface.Id = .{ .index = 10, .generation = 1 };
    const below_surface: Surface.Id = .{ .index = 11, .generation = 1 };
    const above_surface: Surface.Id = .{ .index = 12, .generation = 1 };
    const below = try shell.subsurfaces.insert(std.testing.allocator, .{
        .surface_id = below_surface,
        .parent_id = parent_surface,
        .current_position = .{ .x = -2, .y = 3 },
        .active = true,
    });
    defer _ = shell.subsurfaces.remove(below);
    const above = try shell.subsurfaces.insert(std.testing.allocator, .{
        .surface_id = above_surface,
        .parent_id = parent_surface,
        .current_position = .{ .x = 5, .y = 7 },
        .active = true,
    });
    defer _ = shell.subsurfaces.remove(above);

    var parent: Parent = undefined;
    parent.current = .empty;
    defer parent.current.deinit(std.testing.allocator);
    try parent.current.append(std.testing.allocator, .{ .child = below });
    try parent.current.append(std.testing.allocator, .{ .parent = {} });
    try parent.current.append(std.testing.allocator, .{ .child = above });

    var iterator_value: StackIterator = .{
        .shell = &shell,
        .parent = &parent,
    };
    const below_entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(below_surface, below_entry.child.surface_id));
    try std.testing.expectEqual(Point{ .x = -2, .y = 3 }, below_entry.child.position);
    try std.testing.expect(iterator_value.next().? == .parent);
    const above_entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(above_surface, above_entry.child.surface_id));
    try std.testing.expectEqual(Point{ .x = 5, .y = 7 }, above_entry.child.position);
    try std.testing.expectEqual(@as(?StackEntry, null), iterator_value.next());

    var reverse_iterator: ReverseStackIterator = .{
        .shell = &shell,
        .parent = &parent,
        .index = parent.current.items.len,
    };
    const reverse_above = reverse_iterator.next().?;
    try std.testing.expect(std.meta.eql(above_surface, reverse_above.child.surface_id));
    try std.testing.expect(reverse_iterator.next().? == .parent);
    const reverse_below = reverse_iterator.next().?;
    try std.testing.expect(std.meta.eql(below_surface, reverse_below.child.surface_id));
    try std.testing.expectEqual(@as(?StackEntry, null), reverse_iterator.next());
}
