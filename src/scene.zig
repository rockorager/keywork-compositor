//! Compositor-owned window placement and visual effect state.

const Self = @This();

const std = @import("std");
const render = @import("render.zig");
const slot_map = @import("slot_map.zig");
const Surface = @import("surface.zig");

allocator: std.mem.Allocator,
windows: Store,
stack: std.ArrayList(Id),
repaint_listener: ?RepaintListener,

pub const Store = slot_map.SlotMap(Window, enum { scene_window });
pub const Id = Store.Id;

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const BorderEdges = packed struct(u8) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _padding: u4 = 0,
};

pub const Borders = struct {
    edges: BorderEdges,
    width: u32,
    color: render.Color,
};

pub const ClipBox = render.Rect;

pub const ContentGeometry = struct {
    offset: Position = .{},
    size: render.Size,
};

pub const Blur = struct {
    radius: u32,
};

pub const Shadow = struct {
    offset: Position = .{},
    blur_radius: u32,
    spread: i32 = 0,
    color: render.Color,
};

pub const Effects = struct {
    corner_radius: u32 = 0,
    blur: ?Blur = null,
    shadow: ?Shadow = null,
};

pub const default_effects: Effects = .{
    .corner_radius = 12,
    .shadow = .{
        .offset = .{ .y = 8 },
        .blur_radius = 16,
        .color = render.Color.rgba(0, 0, 0, 96),
    },
};

pub const Window = struct {
    surface_id: Surface.Id,
    position: Position = .{},
    mapped: bool = false,
    focused: bool = false,
    effects: Effects = default_effects,
    borders: ?Borders = null,
    clip_box: ?ClipBox = null,
    content_clip_box: ?ClipBox = null,
    content_geometry: ?ContentGeometry = null,
};

pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
};

pub const Iterator = struct {
    scene: *Self,
    index: usize = 0,

    pub const Entry = struct {
        id: Id,
        window: *Window,
    };

    pub fn next(self: *Iterator) ?Entry {
        while (self.index < self.scene.stack.items.len) {
            const id = self.scene.stack.items[self.index];
            self.index += 1;
            const window = self.scene.windows.get(id) orelse continue;
            return .{ .id = id, .window = window };
        }
        return null;
    }
};

pub fn init(self: *Self, allocator: std.mem.Allocator) void {
    self.* = .{
        .allocator = allocator,
        .windows = .{},
        .stack = .empty,
        .repaint_listener = null,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.windows.len() == 0);
    std.debug.assert(self.stack.items.len == 0);
    self.windows.deinit(self.allocator);
    self.stack.deinit(self.allocator);
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

pub fn addWindow(self: *Self, surface_id: Surface.Id) error{OutOfMemory}!Id {
    const id = try self.windows.insert(self.allocator, .{ .surface_id = surface_id });
    errdefer _ = self.windows.remove(id);
    try self.stack.append(self.allocator, id);
    return id;
}

pub fn removeWindow(self: *Self, id: Id) void {
    const window = self.windows.remove(id) orelse return;
    for (self.stack.items, 0..) |candidate, index| {
        if (std.meta.eql(candidate, id)) {
            _ = self.stack.orderedRemove(index);
            break;
        }
    }
    if (window.mapped) self.requestRepaint();
}

pub fn setMapped(self: *Self, id: Id, mapped: bool) void {
    const window = self.windows.get(id) orelse return;
    if (window.mapped == mapped) return;
    window.mapped = mapped;
    self.requestRepaint();
}

pub fn surfaceCommitted(self: *Self, id: Id) void {
    const window = self.windows.get(id) orelse return;
    if (window.mapped) self.requestRepaint();
}

pub fn setPosition(self: *Self, id: Id, position: Position) void {
    const window = self.windows.get(id) orelse return;
    if (std.meta.eql(window.position, position)) return;
    window.position = position;
    if (window.mapped) self.requestRepaint();
}

pub fn placeTop(self: *Self, id: Id) void {
    const index = self.stackIndex(id) orelse return;
    if (index == self.stack.items.len - 1) return;
    const moved = self.stack.orderedRemove(index);
    self.stack.appendAssumeCapacity(moved);
    if (self.windows.get(id).?.mapped) self.requestRepaint();
}

pub fn placeBottom(self: *Self, id: Id) void {
    const index = self.stackIndex(id) orelse return;
    if (index == 0) return;
    const moved = self.stack.orderedRemove(index);
    self.stack.insertAssumeCapacity(0, moved);
    if (self.windows.get(id).?.mapped) self.requestRepaint();
}

pub fn placeAbove(self: *Self, id: Id, other: Id) void {
    if (std.meta.eql(id, other)) return;
    const index = self.stackIndex(id) orelse return;
    if (self.stackIndex(other) == null) return;
    const moved = self.stack.orderedRemove(index);
    const other_index = self.stackIndex(other) orelse unreachable;
    self.stack.insertAssumeCapacity(other_index + 1, moved);
    if (self.windows.get(id).?.mapped) self.requestRepaint();
}

pub fn placeBelow(self: *Self, id: Id, other: Id) void {
    if (std.meta.eql(id, other)) return;
    const index = self.stackIndex(id) orelse return;
    if (self.stackIndex(other) == null) return;
    const moved = self.stack.orderedRemove(index);
    const other_index = self.stackIndex(other) orelse unreachable;
    self.stack.insertAssumeCapacity(other_index, moved);
    if (self.windows.get(id).?.mapped) self.requestRepaint();
}

pub fn setFocused(self: *Self, id: Id, focused: bool) void {
    const window = self.windows.get(id) orelse return;
    if (window.focused == focused) return;
    window.focused = focused;
    if (window.mapped) self.requestRepaint();
}

pub fn setBorders(self: *Self, id: Id, borders: ?Borders) void {
    if (borders) |value| {
        std.debug.assert(value.width > 0);
        std.debug.assert(value.width <= std.math.maxInt(i32));
        std.debug.assert(@as(u8, @bitCast(value.edges)) & 0x0f != 0);
    }
    const window = self.windows.get(id) orelse return;
    if (std.meta.eql(window.borders, borders)) return;
    window.borders = borders;
    if (window.mapped) self.requestRepaint();
}

pub fn setClipBox(self: *Self, id: Id, clip_box: ?ClipBox) void {
    setWindowClipBox(self, id, clip_box, false);
}

pub fn setContentClipBox(self: *Self, id: Id, clip_box: ?ClipBox) void {
    setWindowClipBox(self, id, clip_box, true);
}

pub fn setContentGeometry(self: *Self, id: Id, geometry: ?ContentGeometry) void {
    if (geometry) |value| {
        std.debug.assert(value.size.width > 0);
        std.debug.assert(value.size.height > 0);
        std.debug.assert(value.size.width <= std.math.maxInt(i32));
        std.debug.assert(value.size.height <= std.math.maxInt(i32));
    }
    const window = self.windows.get(id) orelse return;
    if (std.meta.eql(window.content_geometry, geometry)) return;
    window.content_geometry = geometry;
    if (window.mapped) self.requestRepaint();
}

pub fn setEffects(self: *Self, id: Id, effects: Effects) void {
    const window = self.windows.get(id) orelse return;
    window.effects = effects;
    if (window.mapped) self.requestRepaint();
}

pub fn iterator(self: *Self) Iterator {
    return .{ .scene = self };
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

fn setWindowClipBox(self: *Self, id: Id, clip_box: ?ClipBox, content_only: bool) void {
    if (clip_box) |box| {
        std.debug.assert(box.width > 0);
        std.debug.assert(box.height > 0);
        std.debug.assert(box.width <= std.math.maxInt(i32));
        std.debug.assert(box.height <= std.math.maxInt(i32));
    }
    const window = self.windows.get(id) orelse return;
    const destination = if (content_only) &window.content_clip_box else &window.clip_box;
    if (std.meta.eql(destination.*, clip_box)) return;
    destination.* = clip_box;
    if (window.mapped) self.requestRepaint();
}

fn stackIndex(self: *Self, id: Id) ?usize {
    if (self.windows.get(id) == null) return null;
    for (self.stack.items, 0..) |candidate, index| {
        if (std.meta.eql(candidate, id)) return index;
    }
    unreachable;
}

test "scene keeps visual state behind generational handles" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const surface_id: Surface.Id = .{ .index = 4, .generation = 2 };
    const id = try scene.addWindow(surface_id);
    scene.setPosition(id, .{ .x = 30, .y = 40 });
    scene.setFocused(id, true);
    scene.setEffects(id, .{ .corner_radius = 12 });
    scene.setBorders(id, .{
        .edges = .{ .top = true },
        .width = 4,
        .color = render.Color.rgba(0x80, 0x40, 0x20, 0xff),
    });
    scene.setClipBox(id, .{ .x = -4, .y = 2, .width = 80, .height = 60 });
    scene.setContentClipBox(id, .{ .x = 3, .y = 4, .width = 70, .height = 50 });
    scene.setContentGeometry(id, .{
        .offset = .{ .x = 2, .y = 3 },
        .size = .{ .width = 640, .height = 480 },
    });
    scene.setMapped(id, true);

    var iterator_value = scene.iterator();
    const entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(id, entry.id));
    try std.testing.expect(std.meta.eql(surface_id, entry.window.surface_id));
    try std.testing.expectEqual(Position{ .x = 30, .y = 40 }, entry.window.position);
    try std.testing.expect(entry.window.focused);
    try std.testing.expect(entry.window.mapped);
    try std.testing.expectEqual(@as(u32, 12), entry.window.effects.corner_radius);
    try std.testing.expectEqual(@as(u32, 4), entry.window.borders.?.width);
    try std.testing.expect(entry.window.borders.?.edges.top);
    try std.testing.expectEqual(ClipBox{
        .x = -4,
        .y = 2,
        .width = 80,
        .height = 60,
    }, entry.window.clip_box.?);
    try std.testing.expectEqual(ClipBox{
        .x = 3,
        .y = 4,
        .width = 70,
        .height = 50,
    }, entry.window.content_clip_box.?);
    try std.testing.expectEqual(ContentGeometry{
        .offset = .{ .x = 2, .y = 3 },
        .size = .{ .width = 640, .height = 480 },
    }, entry.window.content_geometry.?);
    try std.testing.expectEqual(@as(?Iterator.Entry, null), iterator_value.next());

    scene.removeWindow(id);
    try std.testing.expectEqual(@as(?*Window, null), scene.windows.get(id));
}

test "scene reorders windows through handles" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const first = try scene.addWindow(.{ .index = 1, .generation = 1 });
    const second = try scene.addWindow(.{ .index = 2, .generation = 1 });
    const third = try scene.addWindow(.{ .index = 3, .generation = 1 });

    scene.placeTop(first);
    try std.testing.expectEqualSlices(Id, &.{ second, third, first }, scene.stack.items);
    scene.placeBelow(first, third);
    try std.testing.expectEqualSlices(Id, &.{ second, first, third }, scene.stack.items);
    scene.placeAbove(second, third);
    try std.testing.expectEqualSlices(Id, &.{ first, third, second }, scene.stack.items);
    scene.placeBottom(second);
    try std.testing.expectEqualSlices(Id, &.{ second, first, third }, scene.stack.items);

    scene.removeWindow(first);
    scene.removeWindow(second);
    scene.removeWindow(third);
}
