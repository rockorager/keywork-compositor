//! Workspace membership, ordering, focus, and classification tags.

const std = @import("std");
const layout_mod = @import("layout.zig");
const types = @import("types.zig");

pub const TagSet = struct {
    items: std.ArrayList(types.TagId) = .empty,

    pub fn deinit(self: *TagSet, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn contains(self: *const TagSet, tag: types.TagId) bool {
        return std.mem.indexOfScalar(types.TagId, self.items.items, tag) != null;
    }

    pub fn add(self: *TagSet, allocator: std.mem.Allocator, tag: types.TagId) !bool {
        if (self.contains(tag)) return false;
        try self.items.append(allocator, tag);
        return true;
    }

    pub fn remove(self: *TagSet, tag: types.TagId) bool {
        const index = std.mem.indexOfScalar(types.TagId, self.items.items, tag) orelse return false;
        _ = self.items.orderedRemove(index);
        return true;
    }
};

pub const Workspace = struct {
    layout: layout_mod.Layout = .{ .tiled = .{ .master_stack = .{} } },
    members: std.ArrayList(types.WindowId) = .empty,
    focused: ?types.WindowId = null,

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.members.deinit(allocator);
    }

    pub fn contains(self: *const Workspace, id: types.WindowId) bool {
        return self.indexOf(id) != null;
    }

    pub fn insert(self: *Workspace, allocator: std.mem.Allocator, id: types.WindowId) !bool {
        if (self.contains(id)) return false;
        try self.members.append(allocator, id);
        if (self.focused == null) self.focused = id;
        return true;
    }

    pub fn remove(self: *Workspace, id: types.WindowId) bool {
        const index = self.indexOf(id) orelse return false;
        _ = self.members.orderedRemove(index);
        if (self.focused != null and self.focused.?.eql(id))
            self.focused = if (self.members.items.len == 0) null else self.members.items[@min(index, self.members.items.len - 1)];
        return true;
    }

    pub fn focus(self: *Workspace, id: types.WindowId) bool {
        if (!self.contains(id)) return false;
        self.focused = id;
        return true;
    }

    pub fn raise(self: *Workspace, id: types.WindowId) bool {
        const index = self.indexOf(id) orelse return false;
        const value = self.members.orderedRemove(index);
        self.members.appendAssumeCapacity(value);
        return true;
    }

    pub fn moveWindow(allocator: std.mem.Allocator, from: *Workspace, to: *Workspace, id: types.WindowId) !bool {
        if (!from.contains(id) or to.contains(id)) return false;
        try to.members.ensureUnusedCapacity(allocator, 1);
        const was_focused = from.focused != null and from.focused.?.eql(id);
        std.debug.assert(from.remove(id));
        to.members.appendAssumeCapacity(id);
        if (to.focused == null or was_focused) to.focused = id;
        return true;
    }

    fn indexOf(self: *const Workspace, id: types.WindowId) ?usize {
        for (self.members.items, 0..) |candidate, index| if (candidate.eql(id)) return index;
        return null;
    }
};

test "tag set prevents duplicates and removes tags" {
    var tags: TagSet = .{};
    defer tags.deinit(std.testing.allocator);
    try std.testing.expect(try tags.add(std.testing.allocator, 42));
    try std.testing.expect(!(try tags.add(std.testing.allocator, 42)));
    try std.testing.expect(try tags.add(std.testing.allocator, 1000));
    try std.testing.expectEqual(@as(usize, 2), tags.items.items.len);
    try std.testing.expect(tags.remove(42));
    try std.testing.expect(!tags.contains(42));
    try std.testing.expect(!tags.remove(42));
}

test "workspace membership move focus and order have single ownership" {
    var first: Workspace = .{};
    defer first.deinit(std.testing.allocator);
    var second: Workspace = .{};
    defer second.deinit(std.testing.allocator);
    const one = types.id(1);
    const two = types.id(2);
    try std.testing.expect(try first.insert(std.testing.allocator, one));
    try std.testing.expect(!(try first.insert(std.testing.allocator, one)));
    try std.testing.expect(try first.insert(std.testing.allocator, two));
    try std.testing.expect(first.focus(two));
    try std.testing.expect(first.raise(one));
    try std.testing.expectEqual(one, first.members.items[1]);
    try std.testing.expect(try Workspace.moveWindow(std.testing.allocator, &first, &second, two));
    try std.testing.expect(!first.contains(two));
    try std.testing.expect(second.contains(two));
    try std.testing.expectEqual(two, second.focused.?);
    try std.testing.expect(!first.remove(two));
}

test "exposed tiled policy state changes" {
    var workspace: Workspace = .{};
    workspace.layout.tiled.master_stack.setMasterCount(2);
    workspace.layout.tiled.master_stack.setMasterRatio(70);
    try std.testing.expectEqual(@as(u32, 2), workspace.layout.tiled.master_stack.master_count);
    try std.testing.expectEqual(@as(u8, 70), workspace.layout.tiled.master_stack.master_ratio_percent);
}
