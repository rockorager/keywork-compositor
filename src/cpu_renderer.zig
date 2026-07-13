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
    const mask = if (image.corner_radius > 0)
        try createRoundedMask(image.size, image.corner_radius)
    else
        null;
    defer if (mask) |rounded_mask| {
        _ = pixman.pixman_image_unref(rounded_mask);
    };
    pixman.pixman_image_composite32(
        pixman.PIXMAN_OP_OVER,
        source,
        mask,
        destination,
        source_x,
        source_y,
        source_x,
        source_y,
        clipped.x,
        clipped.y,
        @intCast(clipped.width),
        @intCast(clipped.height),
    );
}

fn createRoundedMask(
    size: render_types.Size,
    requested_radius: u32,
) Error!*pixman.pixman_image_t {
    const mask = pixman.pixman_image_create_bits(
        pixman.PIXMAN_a8,
        @intCast(size.width),
        @intCast(size.height),
        null,
        0,
    ) orelse return error.OutOfMemory;
    errdefer _ = pixman.pixman_image_unref(mask);

    const data: [*]u8 = @ptrCast(pixman.pixman_image_get_data(mask));
    const stride: usize = @intCast(pixman.pixman_image_get_stride(mask));
    const radius = @min(requested_radius, @min(size.width, size.height) / 2);
    if (radius == 0) {
        for (0..size.height) |y| @memset(data[y * stride ..][0..size.width], 255);
        return mask;
    }

    const radius_float: f32 = @floatFromInt(radius);
    for (0..size.height) |y| {
        for (0..size.width) |x| {
            const pixel_x: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            const pixel_y: f32 = @as(f32, @floatFromInt(y)) + 0.5;
            const center_x: f32 = if (x < radius)
                radius_float
            else if (x >= size.width - radius)
                @floatFromInt(size.width - radius)
            else
                pixel_x;
            const center_y: f32 = if (y < radius)
                radius_float
            else if (y >= size.height - radius)
                @floatFromInt(size.height - radius)
            else
                pixel_y;
            const distance = @sqrt(
                (pixel_x - center_x) * (pixel_x - center_x) +
                    (pixel_y - center_y) * (pixel_y - center_y),
            );
            const coverage = std.math.clamp(radius_float + 0.5 - distance, 0.0, 1.0);
            data[y * stride + x] = @intFromFloat(coverage * 255.0);
        }
    }
    return mask;
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

test "CPU renderer clips image corners with an antialiased mask" {
    const size: render_types.Size = .{ .width = 4, .height = 4 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    var source_pixels = [_]u32{0xffffffff} ** 16;
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = size.width,
                .pixels = &source_pixels,
            },
            .corner_radius = 2,
        } },
    };

    var renderer = Self.init();
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    const corner_alpha: u8 = @truncate(output.pixel(0, 0) >> 24);
    try std.testing.expect(corner_alpha > 0 and corner_alpha < 255);
    try std.testing.expectEqual(@as(u32, 0xffffffff), output.pixel(1, 1));
}
