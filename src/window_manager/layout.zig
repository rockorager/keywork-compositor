//! Stateful, protocol-neutral workspace layouts.

const std = @import("std");
const types = @import("types.zig");

pub const Layout = union(enum) {
    tiled: Tiled,
    scrolling: Scrolling,

    pub fn arrange(
        self: *Layout,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
        focused: ?types.WindowId,
    ) !std.ArrayList(types.LayoutPlan) {
        return switch (self.*) {
            .tiled => |*layout| layout.arrange(allocator, windows, usable),
            .scrolling => |*layout| layout.arrange(allocator, windows, usable, focused),
        };
    }
};

pub const Tiled = union(enum) {
    master_stack: MasterStack,

    pub fn arrange(
        self: *Tiled,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
    ) !std.ArrayList(types.LayoutPlan) {
        return switch (self.*) {
            .master_stack => |*policy| policy.arrange(allocator, windows, usable),
        };
    }
};

pub const MasterStack = struct {
    master_count: u32 = 1,
    master_ratio_percent: u8 = 60,
    outer_gap: u32 = 8,
    inner_gap: u32 = 8,

    pub fn setMasterCount(self: *MasterStack, count: u32) void {
        self.master_count = count;
    }

    pub fn setMasterRatio(self: *MasterStack, percent: u8) void {
        std.debug.assert(percent >= 10 and percent <= 90);
        self.master_ratio_percent = percent;
    }

    fn arrange(
        self: *const MasterStack,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
    ) !std.ArrayList(types.LayoutPlan) {
        var plans: std.ArrayList(types.LayoutPlan) = .empty;
        errdefer plans.deinit(allocator);
        try plans.ensureTotalCapacity(allocator, windows.len);
        if (windows.len == 0) return plans;

        const area = inset(usable, self.outer_gap);
        const master_len = @min(windows.len, @max(@as(usize, 1), self.master_count));
        if (master_len == windows.len) {
            appendColumn(&plans, windows, area, self.inner_gap);
            return plans;
        }
        if (area.size.width < 2) {
            appendColumn(&plans, windows, area, self.inner_gap);
            return plans;
        }

        const gap = @min(self.inner_gap, area.size.width - 2);
        const available_width = area.size.width - gap;
        var master_width: u32 = @intCast((@as(u64, available_width) * self.master_ratio_percent) / 100);
        master_width = std.math.clamp(master_width, 1, available_width - 1);
        const stack_width = available_width - master_width;
        appendColumn(&plans, windows[0..master_len], .{
            .x = area.x,
            .y = area.y,
            .size = types.Size.init(master_width, area.size.height),
        }, self.inner_gap);
        appendColumn(&plans, windows[master_len..], .{
            .x = area.x + @as(i32, @intCast(master_width + gap)),
            .y = area.y,
            .size = types.Size.init(stack_width, area.size.height),
        }, self.inner_gap);
        return plans;
    }
};

pub const Scrolling = struct {
    offset: u32 = 0,
    gap: u32 = 8,

    fn arrange(
        self: *Scrolling,
        allocator: std.mem.Allocator,
        windows: []const types.WindowInput,
        usable: types.Rect,
        focused: ?types.WindowId,
    ) !std.ArrayList(types.LayoutPlan) {
        var plans: std.ArrayList(types.LayoutPlan) = .empty;
        errdefer plans.deinit(allocator);
        try plans.ensureTotalCapacity(allocator, windows.len);
        var focus_start: ?u32 = null;
        var focus_end: u32 = 0;
        var cursor: u32 = 0;
        for (windows) |window| {
            const width = @max(@as(u32, 1), window.current.width);
            if (focused != null and window.id.eql(focused.?)) {
                focus_start = cursor;
                focus_end = cursor + width;
            }
            cursor +|= width +| self.gap;
        }
        if (focus_start) |start| {
            if (start < self.offset) self.offset = start;
            if (focus_end > self.offset +| usable.size.width)
                self.offset = focus_end - usable.size.width;
        }

        cursor = 0;
        for (windows) |window| {
            const width = @max(@as(u32, 1), window.current.width);
            const x64 = @as(i64, usable.x) + @as(i64, cursor) - @as(i64, self.offset);
            const rect: types.Rect = .{
                .x = @intCast(std.math.clamp(x64, std.math.minInt(i32), std.math.maxInt(i32))),
                .y = usable.y,
                .size = types.Size.init(width, usable.size.height),
            };
            const clip = intersection(rect, usable);
            plans.appendAssumeCapacity(.{
                .id = window.id,
                .rect = rect,
                .visible = clip != null,
                .clip = clip,
            });
            cursor +|= width +| self.gap;
        }
        return plans;
    }
};

fn inset(rect: types.Rect, requested: u32) types.Rect {
    const gap = @min(requested, @min((rect.size.width - 1) / 2, (rect.size.height - 1) / 2));
    return .{
        .x = rect.x + @as(i32, @intCast(gap)),
        .y = rect.y + @as(i32, @intCast(gap)),
        .size = types.Size.init(rect.size.width - 2 * gap, rect.size.height - 2 * gap),
    };
}

fn appendColumn(
    plans: *std.ArrayList(types.LayoutPlan),
    windows: []const types.WindowInput,
    area: types.Rect,
    requested_gap: u32,
) void {
    const count: u32 = @intCast(windows.len);
    if (area.size.height < count) {
        for (windows) |window| plans.appendAssumeCapacity(.{
            .id = window.id,
            .rect = area,
            .visible = true,
            .tiled_edges = .{ .top = true, .right = true, .bottom = true, .left = true },
        });
        return;
    }
    const gap = if (count > 1) @min(requested_gap, (area.size.height - count) / (count - 1)) else 0;
    const height = area.size.height - gap * (count - 1);
    const base = height / count;
    const remainder = height % count;
    var y = area.y;
    for (windows, 0..) |window, i| {
        const item_height = base + @intFromBool(i < remainder);
        plans.appendAssumeCapacity(.{
            .id = window.id,
            .rect = .{ .x = area.x, .y = y, .size = types.Size.init(area.size.width, item_height) },
            .visible = true,
            .tiled_edges = .{ .top = true, .right = true, .bottom = true, .left = true },
        });
        y += @intCast(item_height + gap);
    }
}

fn intersection(a: types.Rect, b: types.Rect) ?types.Rect {
    const left = @max(@as(i64, a.x), b.x);
    const top = @max(@as(i64, a.y), b.y);
    const right = @min(@as(i64, a.x) + a.size.width, @as(i64, b.x) + b.size.width);
    const bottom = @min(@as(i64, a.y) + a.size.height, @as(i64, b.y) + b.size.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .size = types.Size.init(@intCast(right - left), @intCast(bottom - top)),
    };
}

fn input(index: u32, width: u32) types.WindowInput {
    return .{ .id = types.id(index), .current = types.Size.init(width, 40) };
}

test "master stack geometry is deterministic with offsets gaps and remainders" {
    const area: types.Rect = .{ .x = 100, .y = 50, .size = types.Size.init(103, 65) };
    var layout: Layout = .{ .tiled = .{ .master_stack = .{ .outer_gap = 2, .inner_gap = 3 } } };
    const cases = [_][]const types.WindowInput{
        &.{},
        &.{input(0, 10)},
        &.{ input(0, 10), input(1, 10) },
        &.{ input(0, 10), input(1, 10), input(2, 10), input(3, 10) },
    };
    const expected = [_][]const types.Rect{
        &.{},
        &.{.{ .x = 102, .y = 52, .size = types.Size.init(99, 61) }},
        &.{
            .{ .x = 102, .y = 52, .size = types.Size.init(57, 61) },
            .{ .x = 162, .y = 52, .size = types.Size.init(39, 61) },
        },
        &.{
            .{ .x = 102, .y = 52, .size = types.Size.init(57, 61) },
            .{ .x = 162, .y = 52, .size = types.Size.init(39, 19) },
            .{ .x = 162, .y = 74, .size = types.Size.init(39, 18) },
            .{ .x = 162, .y = 95, .size = types.Size.init(39, 18) },
        },
    };
    for (cases, expected) |windows, rects| {
        var plans = try layout.arrange(std.testing.allocator, windows, area, null);
        defer plans.deinit(std.testing.allocator);
        try std.testing.expectEqual(rects.len, plans.items.len);
        for (plans.items, rects) |plan, rect| try std.testing.expectEqual(rect, plan.rect);
    }
}

test "tiny areas emit every window once without zero sizes" {
    const windows = [_]types.WindowInput{ input(0, 1), input(1, 1), input(2, 1) };
    var layout: Layout = .{ .tiled = .{ .master_stack = .{ .outer_gap = 99, .inner_gap = 99 } } };
    var plans = try layout.arrange(std.testing.allocator, &windows, .{
        .x = 0,
        .y = 0,
        .size = types.Size.init(3, 3),
    }, null);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(windows.len, plans.items.len);
    for (plans.items, 0..) |plan, i| {
        try std.testing.expectEqual(windows[i].id, plan.id);
        try std.testing.expect(plan.rect.size.width > 0 and plan.rect.size.height > 0);
    }
}

test "scrolling keeps focus visible and clips viewport edges" {
    const windows = [_]types.WindowInput{ input(0, 60), input(1, 60), input(2, 60) };
    var layout: Layout = .{ .scrolling = .{ .gap = 5 } };
    var plans = try layout.arrange(std.testing.allocator, &windows, .{
        .x = 10,
        .y = 20,
        .size = types.Size.init(100, 50),
    }, windows[2].id);
    defer plans.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 90), layout.scrolling.offset);
    try std.testing.expect(!plans.items[0].visible);
    try std.testing.expectEqual(@as(u32, 35), plans.items[1].clip.?.size.width);
    try std.testing.expectEqual(@as(u32, 60), plans.items[2].clip.?.size.width);
}
