//! In-memory output storage for the headless backend.

const Self = @This();

const std = @import("std");
const render = @import("render.zig");

allocator: std.mem.Allocator,
size: render.Size,
pixels: []u32,

pub const Error = error{
    InvalidDimensions,
    Overflow,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator, size: render.Size) Error!Self {
    if (size.width == 0 or size.height == 0) return error.InvalidDimensions;

    const pixel_count = size.pixelCount() catch return error.Overflow;
    const pixels = allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    @memset(pixels, 0);

    return .{
        .allocator = allocator,
        .size = size,
        .pixels = pixels,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.pixels);
    self.* = undefined;
}

pub fn target(self: *Self) render.PixelBuffer {
    return .{
        .size = self.size,
        .stride_pixels = self.size.width,
        .pixels = self.pixels,
    };
}

pub fn pixel(self: *const Self, x: u32, y: u32) u32 {
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
