//! Renderer-independent frame data.

const std = @import("std");

pub const Size = struct {
    width: u32,
    height: u32,

    pub fn pixelCount(self: Size) error{Overflow}!usize {
        return std.math.mul(usize, self.width, self.height);
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn clipTo(self: Rect, size: Size) ?Rect {
        const left = @max(@as(i64, self.x), 0);
        const top = @max(@as(i64, self.y), 0);
        const right = @min(@as(i64, self.x) + self.width, size.width);
        const bottom = @min(@as(i64, self.y) + self.height, size.height);

        if (left >= right or top >= bottom) return null;

        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }
};

/// An 8-bit premultiplied-alpha color.
pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,

    pub fn rgba(red: u8, green: u8, blue: u8, alpha: u8) Color {
        return .{
            .red = premultiply(red, alpha),
            .green = premultiply(green, alpha),
            .blue = premultiply(blue, alpha),
            .alpha = alpha,
        };
    }

    pub fn argb8888(self: Color) u32 {
        return @as(u32, self.alpha) << 24 |
            @as(u32, self.red) << 16 |
            @as(u32, self.green) << 8 |
            self.blue;
    }

    fn premultiply(component: u8, alpha: u8) u8 {
        const product = @as(u16, component) * alpha + 127;
        return @intCast(product / 255);
    }
};

pub const SolidRect = struct {
    rect: Rect,
    color: Color,
};

pub const Image = struct {
    x: i32,
    y: i32,
    size: Size,
    buffer: PixelBuffer,
};

pub const Command = union(enum) {
    clear: Color,
    solid_rect: SolidRect,
    image: Image,
};

pub const Frame = struct {
    size: Size,
    commands: []const Command,
};

/// A CPU-addressable ARGB8888 target. Rows may contain padding.
pub const PixelBuffer = struct {
    size: Size,
    stride_pixels: u32,
    pixels: []u32,
};

test "color conversion premultiplies alpha" {
    const color = Color.rgba(255, 127, 0, 128);

    try std.testing.expectEqual(@as(u8, 128), color.red);
    try std.testing.expectEqual(@as(u8, 64), color.green);
    try std.testing.expectEqual(@as(u8, 0), color.blue);
    try std.testing.expectEqual(@as(u8, 128), color.alpha);
    try std.testing.expectEqual(@as(u32, 0x80804000), color.argb8888());
}

test "rectangle clipping handles negative and overflowing coordinates" {
    const clipped = (Rect{
        .x = -2,
        .y = 3,
        .width = 8,
        .height = 10,
    }).clipTo(.{ .width = 5, .height = 7 });

    try std.testing.expectEqual(Rect{
        .x = 0,
        .y = 3,
        .width = 5,
        .height = 4,
    }, clipped.?);

    try std.testing.expectEqual(@as(?Rect, null), (Rect{
        .x = 5,
        .y = 0,
        .width = 1,
        .height = 1,
    }).clipTo(.{ .width = 5, .height = 7 }));
}
