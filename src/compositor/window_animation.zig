//! Renderer-independent timing and bounded snapshot lifecycle for tiling transitions.

const WindowAnimation = @This();

const std = @import("std");
const render = @import("render/types.zig");

pub const duration_nanoseconds: u64 = 140 * std.time.ns_per_ms;
pub const target_wait_nanoseconds: u64 = 100 * std.time.ns_per_ms;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub fn progress(start: i96, now: i96, duration: u64) u32 {
    if (now <= start) return 0;
    const elapsed: u128 = @intCast(now - start);
    if (elapsed >= duration) return std.math.maxInt(u32);
    const linear: u32 = @intCast((elapsed * std.math.maxInt(u32)) / duration);
    return easeOutCubic(linear);
}

fn easeOutCubic(linear: u32) u32 {
    const maximum: u128 = std.math.maxInt(u32);
    const remaining: u128 = maximum - linear;
    const denominator = maximum * maximum;
    const eased_remaining = (remaining * remaining * remaining + denominator / 2) / denominator;
    return @intCast(maximum - eased_remaining);
}

pub fn interpolate(old: Rect, target: Rect, factor: u32) Rect {
    return .{
        .x = interpolateSigned(old.x, target.x, factor),
        .y = interpolateSigned(old.y, target.y, factor),
        .width = interpolateUnsigned(old.width, target.width, factor),
        .height = interpolateUnsigned(old.height, target.height, factor),
    };
}

pub fn targetReady(
    old: Rect,
    target: Rect,
    old_source: render.SourceCache,
    current_source: render.SourceCache,
) bool {
    if (old.width == target.width and old.height == target.height) return true;
    return !std.meta.eql(old_source, current_source);
}

pub fn appearanceStart(target: Rect) Rect {
    return .{
        .x = target.x +| @as(i32, @intCast(target.width / 2)),
        .y = target.y +| @as(i32, @intCast(target.height / 2)),
        .width = 1,
        .height = 1,
    };
}

fn interpolateSigned(old: i32, target: i32, factor: u32) i32 {
    const delta: i64 = @as(i64, target) - old;
    return @intCast(@as(i64, old) + @divTrunc(delta * factor, std.math.maxInt(u32)));
}

fn interpolateUnsigned(old: u32, target: u32, factor: u32) u32 {
    return @intCast(interpolateSigned(@intCast(old), @intCast(target), factor));
}

pub const Snapshot = struct {
    source: render.ImageSource,
    owned_pixels: ?[]u32 = null,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator, offscreen: ?render.OffscreenRenderer) void {
        switch (self.source) {
            .pixels => if (self.owned_pixels) |pixels| allocator.free(pixels),
            .offscreen => |target| if (offscreen) |access| access.release_target(access.context, target.id),
        }
        self.* = undefined;
    }
};

test "interpolation has exact endpoints" {
    const old: Rect = .{ .x = -20, .y = 10, .width = 100, .height = 80 };
    const target: Rect = .{ .x = 200, .y = -40, .width = 640, .height = 480 };
    try std.testing.expectEqual(old, interpolate(old, target, 0));
    try std.testing.expectEqual(target, interpolate(old, target, std.math.maxInt(u32)));
}

test "progress is monotonic and clamps" {
    var previous: u32 = 0;
    for (0..201) |millisecond| {
        const current = progress(100, 100 + @as(i96, @intCast(millisecond * std.time.ns_per_ms)), duration_nanoseconds);
        try std.testing.expect(current >= previous);
        previous = current;
    }
    try std.testing.expectEqual(std.math.maxInt(u32), previous);
}

test "progress eases out with exact endpoints" {
    try std.testing.expectEqual(@as(u32, 0), progress(0, 0, duration_nanoseconds));
    const midpoint = progress(0, duration_nanoseconds / 2, duration_nanoseconds);
    try std.testing.expect(midpoint > std.math.maxInt(u32) / 2);
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        progress(0, duration_nanoseconds, duration_nanoseconds),
    );
}

test "retarget starts at currently displayed position" {
    const first = interpolate(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, .{ .x = 200, .y = 80, .width = 300, .height = 200 }, progress(0, 50 * std.time.ns_per_ms, duration_nanoseconds));
    const retargeted = interpolate(first, .{ .x = -100, .y = 20, .width = 500, .height = 400 }, 0);
    try std.testing.expectEqual(first, retargeted);
}

test "a resize waits for a new buffer generation" {
    const old: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const moved: Rect = .{ .x = 20, .y = 10, .width = 100, .height = 80 };
    const resized: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 160 };
    const generation: render.SourceCache = .{ .id = 1, .version = 1 };
    try std.testing.expect(targetReady(old, moved, generation, generation));
    try std.testing.expect(!targetReady(old, resized, generation, generation));
    try std.testing.expect(targetReady(
        old,
        resized,
        generation,
        .{ .id = 1, .version = 2 },
    ));
}

test "a first presentation starts collapsed at its target center" {
    try std.testing.expectEqual(
        Rect{ .x = 250, .y = 140, .width = 1, .height = 1 },
        appearanceStart(.{ .x = 50, .y = 40, .width = 400, .height = 200 }),
    );
}
