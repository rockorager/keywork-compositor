//! In-memory output storage for the headless backend.

const Self = @This();

const std = @import("std");
const render = @import("../render/types.zig");
const log = std.log.scoped(.headless);

allocator: std.mem.Allocator,
size: render.Size,
scale: render.Scale,
pixels: []u32,
offscreen_renderer: ?render.OffscreenRenderer,
offscreen_target: ?render.OffscreenTarget,

pub const Error = error{
    InvalidDimensions,
    Overflow,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator, size: render.Size) Error!Self {
    return initForRenderer(allocator, size, .{}, null) catch |err| switch (err) {
        error.InvalidDimensions, error.Overflow, error.OutOfMemory => |known| return known,
        else => unreachable,
    };
}

pub fn initForRenderer(
    allocator: std.mem.Allocator,
    size: render.Size,
    scale: render.Scale,
    offscreen_renderer: ?render.OffscreenRenderer,
) !Self {
    if (size.width == 0 or size.height == 0) return error.InvalidDimensions;
    _ = scale.logicalSize(size) catch return error.InvalidDimensions;

    if (offscreen_renderer) |renderer| {
        const offscreen = try renderer.create_target(renderer.context, size);
        std.debug.assert(offscreen.id != 0 and std.meta.eql(offscreen.size, size));
        log.info("allocated GPU-resident output at {}x{}", .{ size.width, size.height });
        return .{
            .allocator = allocator,
            .size = size,
            .scale = scale,
            .pixels = &.{},
            .offscreen_renderer = renderer,
            .offscreen_target = offscreen,
        };
    }

    const pixel_count = size.pixelCount() catch return error.Overflow;
    const pixels = allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    @memset(pixels, 0);
    log.info("allocated CPU output at {}x{}", .{ size.width, size.height });

    return .{
        .allocator = allocator,
        .size = size,
        .scale = scale,
        .pixels = pixels,
        .offscreen_renderer = null,
        .offscreen_target = null,
    };
}

pub fn deinit(self: *Self) void {
    if (self.offscreen_target) |offscreen| {
        const renderer = self.offscreen_renderer.?;
        renderer.release_target(renderer.context, offscreen.id);
    } else {
        self.allocator.free(self.pixels);
    }
    self.* = undefined;
}

pub fn logicalSize(self: *const Self) render.Size {
    return self.scale.logicalSize(self.size) catch unreachable;
}

pub fn renderTarget(self: *Self) render.Target {
    if (self.offscreen_target) |offscreen| return .{ .offscreen = offscreen };
    return .{ .pixels = self.target() };
}

pub fn target(self: *Self) render.PixelBuffer {
    std.debug.assert(self.offscreen_target == null);
    return .{
        .size = self.size,
        .stride_pixels = self.size.width,
        .pixels = self.pixels,
    };
}

pub fn pixel(self: *const Self, x: u32, y: u32) u32 {
    std.debug.assert(self.offscreen_target == null);
    std.debug.assert(x < self.size.width);
    std.debug.assert(y < self.size.height);

    return self.pixels[@as(usize, y) * self.size.width + x];
}

test "headless output starts transparent" {
    var output = try Self.init(std.testing.allocator, .{ .width = 2, .height = 3 });
    defer output.deinit();

    try std.testing.expectEqual(@as(usize, 6), output.pixels.len);
    try std.testing.expectEqual(@as(u32, 0), output.pixel(1, 2));
}
