//! Pixman-backed CPU renderer.

const Self = @This();

const std = @import("std");
const headless = @import("headless.zig");
const render_types = @import("render.zig");

const pixman = @cImport({
    @cInclude("pixman.h");
});

pub const Error = error{
    InvalidTarget,
    OutOfMemory,
};

pub fn init() Self {
    return .{};
}

pub fn deinit(_: *Self) void {}

pub fn render(_: *Self, frame: render_types.Frame, target: render_types.PixelBuffer) Error!void {
    const destination = try createDestination(frame, target);
    defer _ = pixman.pixman_image_unref(destination);

    for (frame.commands) |command| {
        switch (command) {
            .clear => |color| try fill(
                destination,
                .{ .x = 0, .y = 0, .width = frame.size.width, .height = frame.size.height },
                color,
                pixman.PIXMAN_OP_SRC,
            ),
            .solid_rect => |solid| {
                const clipped = solid.rect.clipTo(frame.size) orelse continue;
                try fill(destination, clipped, solid.color, pixman.PIXMAN_OP_OVER);
            },
            .image => |image| try composite(destination, frame.size, image),
        }
    }
}

fn createDestination(
    frame: render_types.Frame,
    target: render_types.PixelBuffer,
) Error!*pixman.pixman_image_t {
    if (frame.size.width == 0 or frame.size.height == 0) return error.InvalidTarget;
    if (!std.meta.eql(frame.size, target.size)) return error.InvalidTarget;
    return createImage(target);
}

fn createImage(buffer: render_types.PixelBuffer) Error!*pixman.pixman_image_t {
    if (buffer.size.width == 0 or buffer.size.height == 0) return error.InvalidTarget;
    if (buffer.stride_pixels < buffer.size.width) return error.InvalidTarget;

    const stride_bytes = std.math.mul(u32, buffer.stride_pixels, @sizeOf(u32)) catch
        return error.InvalidTarget;
    if (stride_bytes > std.math.maxInt(c_int)) return error.InvalidTarget;
    if (buffer.size.width > std.math.maxInt(c_int) or
        buffer.size.height > std.math.maxInt(c_int)) return error.InvalidTarget;

    const row_offset = std.math.mul(
        usize,
        buffer.size.height - 1,
        buffer.stride_pixels,
    ) catch return error.InvalidTarget;
    const required_pixels = std.math.add(usize, row_offset, buffer.size.width) catch
        return error.InvalidTarget;
    if (buffer.pixels.len < required_pixels) return error.InvalidTarget;

    return pixman.pixman_image_create_bits(
        pixman.PIXMAN_a8r8g8b8,
        @intCast(buffer.size.width),
        @intCast(buffer.size.height),
        buffer.pixels.ptr,
        @intCast(stride_bytes),
    ) orelse error.OutOfMemory;
}

fn composite(
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    image: render_types.Image,
) Error!void {
    const source = try createImage(image.buffer);
    defer _ = pixman.pixman_image_unref(source);
    if (image.size.width == 0 or image.size.height == 0) return error.InvalidTarget;
    if (!std.meta.eql(image.size, image.buffer.size)) {
        var transform: pixman.pixman_transform_t = undefined;
        pixman.pixman_transform_init_scale(
            &transform,
            try fixedRatio(image.buffer.size.width, image.size.width),
            try fixedRatio(image.buffer.size.height, image.size.height),
        );
        if (pixman.pixman_image_set_transform(source, &transform) == 0 or
            pixman.pixman_image_set_filter(source, pixman.PIXMAN_FILTER_NEAREST, null, 0) == 0)
        {
            return error.OutOfMemory;
        }
    }

    const destination_rect: render_types.Rect = .{
        .x = image.x,
        .y = image.y,
        .width = image.size.width,
        .height = image.size.height,
    };
    const clipped = destination_rect.clipTo(destination_size) orelse return;
    const source_x: i32 = clipped.x - image.x;
    const source_y: i32 = clipped.y - image.y;
    pixman.pixman_image_composite32(
        pixman.PIXMAN_OP_OVER,
        source,
        null,
        destination,
        source_x,
        source_y,
        0,
        0,
        clipped.x,
        clipped.y,
        @intCast(clipped.width),
        @intCast(clipped.height),
    );
}

fn fixedRatio(numerator: u32, denominator: u32) Error!pixman.pixman_fixed_t {
    std.debug.assert(denominator > 0);
    const scaled = @as(u64, numerator) << 16;
    const ratio = scaled / denominator;
    if (ratio > std.math.maxInt(pixman.pixman_fixed_t)) return error.InvalidTarget;
    return @intCast(ratio);
}

fn fill(
    destination: *pixman.pixman_image_t,
    rect: render_types.Rect,
    color: render_types.Color,
    operator: pixman.pixman_op_t,
) Error!void {
    std.debug.assert(rect.width > 0 and rect.height > 0);

    const pixman_color: pixman.pixman_color_t = .{
        .red = expand(color.red),
        .green = expand(color.green),
        .blue = expand(color.blue),
        .alpha = expand(color.alpha),
    };
    const box: pixman.pixman_box32_t = .{
        .x1 = rect.x,
        .y1 = rect.y,
        .x2 = rect.x + @as(i32, @intCast(rect.width)),
        .y2 = rect.y + @as(i32, @intCast(rect.height)),
    };

    if (pixman.pixman_image_fill_boxes(operator, destination, &pixman_color, 1, &box) == 0) {
        return error.OutOfMemory;
    }
}

fn expand(component: u8) u16 {
    return @as(u16, component) * 257;
}

test "CPU renderer draws clipped premultiplied rectangles" {
    const size: render_types.Size = .{ .width = 4, .height = 3 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 255, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = -1, .y = 1, .width = 3, .height = 2 },
            .color = render_types.Color.rgba(255, 0, 0, 128),
        } },
    };

    var renderer = Self.init();
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff80007f), output.pixel(0, 1));
    try std.testing.expectEqual(@as(u32, 0xff80007f), output.pixel(1, 2));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(2, 1));
}

test "CPU renderer rejects undersized targets" {
    var renderer = Self.init();
    defer renderer.deinit();

    var pixels = [_]u32{0} ** 3;
    const target: render_types.PixelBuffer = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &pixels,
    };

    try std.testing.expectError(error.InvalidTarget, renderer.render(.{
        .size = target.size,
        .commands = &.{},
    }, target));
}

test "CPU renderer composites clipped images" {
    const size: render_types.Size = .{ .width = 3, .height = 2 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    var source_pixels = [_]u32{
        0xffff0000, 0xff00ff00,
        0xff0000ff, 0x80808080,
    };
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = -1,
            .y = 0,
            .size = .{ .width = 2, .height = 2 },
            .buffer = .{
                .size = .{ .width = 2, .height = 2 },
                .stride_pixels = 2,
                .pixels = &source_pixels,
            },
        } },
    };

    var renderer = Self.init();
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff00ff00), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff808080), output.pixel(0, 1));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 0));
}

test "CPU renderer scales images to logical size" {
    var output = try headless.init(std.testing.allocator, .{ .width = 1, .height = 1 });
    defer output.deinit();

    var source_pixels = [_]u32{0xff336699} ** 4;
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .buffer = .{
                .size = .{ .width = 2, .height = 2 },
                .stride_pixels = 2,
                .pixels = &source_pixels,
            },
        } },
    };

    var renderer = Self.init();
    defer renderer.deinit();
    try renderer.render(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &commands,
    }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff336699), output.pixel(0, 0));
}
