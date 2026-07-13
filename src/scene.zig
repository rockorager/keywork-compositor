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

pub fn setFocused(self: *Self, id: Id, focused: bool) void {
    const window = self.windows.get(id) orelse return;
    if (window.focused == focused) return;
    window.focused = focused;
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

test "scene keeps visual state behind generational handles" {
    var scene: Self = undefined;
    scene.init(std.testing.allocator);
    defer scene.deinit();

    const surface_id: Surface.Id = .{ .index = 4, .generation = 2 };
    const id = try scene.addWindow(surface_id);
    scene.setPosition(id, .{ .x = 30, .y = 40 });
    scene.setFocused(id, true);
    scene.setEffects(id, .{ .corner_radius = 12 });
    scene.setMapped(id, true);

    var iterator_value = scene.iterator();
    const entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(id, entry.id));
    try std.testing.expect(std.meta.eql(surface_id, entry.window.surface_id));
    try std.testing.expectEqual(Position{ .x = 30, .y = 40 }, entry.window.position);
    try std.testing.expect(entry.window.focused);
    try std.testing.expect(entry.window.mapped);
    try std.testing.expectEqual(@as(u32, 12), entry.window.effects.corner_radius);
    try std.testing.expectEqual(@as(?Iterator.Entry, null), iterator_value.next());

    scene.removeWindow(id);
    try std.testing.expectEqual(@as(?*Window, null), scene.windows.get(id));
}
