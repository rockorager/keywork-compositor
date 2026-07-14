//! Pixman-backed CPU renderer.

const Self = @This();

const std = @import("std");
const headless = @import("../backend/headless.zig");
const render_types = @import("types.zig");

const pixman = @cImport({
    @cInclude("pixman.h");
});

allocator: std.mem.Allocator,

pub const Error = error{
    InvalidTarget,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn render(self: *Self, frame: render_types.Frame, target: render_types.PixelBuffer) Error!void {
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
                var clipped = solid.rect.clipTo(frame.size) orelse continue;
                if (solid.clip) |clip| {
                    clipped = clipped.intersection(clip) orelse continue;
                }
                try fill(destination, clipped, solid.color, pixman.PIXMAN_OP_OVER);
            },
            .shadow => |shadow| try self.drawShadow(destination, frame.size, shadow),
            .backdrop_blur => |blur| try self.drawBackdropBlur(target, blur),
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

fn drawShadow(
    self: *Self,
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    shadow: render_types.Shadow,
) Error!void {
    if (shadow.rect.width == 0 or shadow.rect.height == 0 or shadow.color.alpha == 0) return;

    const spread: i64 = shadow.spread;
    const shape_x = @as(i64, shadow.rect.x) - spread;
    const shape_y = @as(i64, shadow.rect.y) - spread;
    const shape_width = @as(i64, shadow.rect.width) + 2 * spread;
    const shape_height = @as(i64, shadow.rect.height) + 2 * spread;
    if (shape_width <= 0 or shape_height <= 0) return;

    const blur: i64 = shadow.blur_radius;
    const mask_x = shape_x - blur;
    const mask_y = shape_y - blur;
    const mask_width = shape_width + 2 * blur;
    const mask_height = shape_height + 2 * blur;
    const mask_right = mask_x + mask_width;
    const mask_bottom = mask_y + mask_height;
    if (mask_right <= 0 or mask_bottom <= 0 or
        mask_x >= destination_size.width or mask_y >= destination_size.height)
    {
        return;
    }
    var composite_rect = (render_types.Rect{
        .x = @intCast(@max(mask_x, 0)),
        .y = @intCast(@max(mask_y, 0)),
        .width = @intCast(@min(mask_right, destination_size.width) - @max(mask_x, 0)),
        .height = @intCast(@min(mask_bottom, destination_size.height) - @max(mask_y, 0)),
    });
    if (shadow.clip) |clip| {
        composite_rect = composite_rect.intersection(clip) orelse return;
    }

    const sample_x = @max(mask_x, @as(i64, composite_rect.x) - blur);
    const sample_y = @max(mask_y, @as(i64, composite_rect.y) - blur);
    const sample_right = @min(
        mask_right,
        @as(i64, composite_rect.x) + composite_rect.width + blur,
    );
    const sample_bottom = @min(
        mask_bottom,
        @as(i64, composite_rect.y) + composite_rect.height + blur,
    );
    const sample_width = sample_right - sample_x;
    const sample_height = sample_bottom - sample_y;
    if (sample_width > std.math.maxInt(c_int) or sample_height > std.math.maxInt(c_int)) {
        return error.InvalidTarget;
    }
    const width: u32 = @intCast(sample_width);
    const height: u32 = @intCast(sample_height);
    const mask = pixman.pixman_image_create_bits(
        pixman.PIXMAN_a8,
        @intCast(width),
        @intCast(height),
        null,
        0,
    ) orelse return error.OutOfMemory;
    defer _ = pixman.pixman_image_unref(mask);

    const data: [*]u8 = @ptrCast(pixman.pixman_image_get_data(mask));
    const stride: usize = @intCast(pixman.pixman_image_get_stride(mask));
    const radius_value = @max(@as(i64, shadow.corner_radius) + spread, 0);
    const radius: f64 = @floatFromInt(@min(
        radius_value,
        @divTrunc(@min(shape_width, shape_height), 2),
    ));
    const shape_left: f64 = @floatFromInt(shape_x - sample_x);
    const shape_top: f64 = @floatFromInt(shape_y - sample_y);
    const shape_size_x: f64 = @floatFromInt(shape_width);
    const shape_size_y: f64 = @floatFromInt(shape_height);
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel_x: f64 = @as(f64, @floatFromInt(x)) + 0.5;
            const pixel_y: f64 = @as(f64, @floatFromInt(y)) + 0.5;
            const coverage = roundedRectCoverage(
                pixel_x,
                pixel_y,
                shape_left,
                shape_top,
                shape_size_x,
                shape_size_y,
                radius,
            );
            data[y * stride + x] = @intFromFloat(coverage * 255.0);
        }
    }
    if (shadow.blur_radius > 0) {
        try blurMask(self.allocator, data, stride, width, height, shadow.blur_radius);
    }

    const color: pixman.pixman_color_t = .{
        .red = expand(shadow.color.red),
        .green = expand(shadow.color.green),
        .blue = expand(shadow.color.blue),
        .alpha = expand(shadow.color.alpha),
    };
    const source = pixman.pixman_image_create_solid_fill(&color) orelse
        return error.OutOfMemory;
    defer _ = pixman.pixman_image_unref(source);
    pixman.pixman_image_composite32(
        pixman.PIXMAN_OP_OVER,
        source,
        mask,
        destination,
        0,
        0,
        @intCast(@as(i64, composite_rect.x) - sample_x),
        @intCast(@as(i64, composite_rect.y) - sample_y),
        composite_rect.x,
        composite_rect.y,
        @intCast(composite_rect.width),
        @intCast(composite_rect.height),
    );
}

fn drawBackdropBlur(
    self: *Self,
    target: render_types.PixelBuffer,
    blur: render_types.BackdropBlur,
) Error!void {
    if (blur.radius == 0 or blur.rect.width == 0 or blur.rect.height == 0) return;
    var clipped = blur.rect.clipTo(target.size) orelse return;
    if (blur.clip) |clip| clipped = clipped.intersection(clip) orelse return;

    const radius: i64 = blur.radius;
    const sample_left: u32 = @intCast(@max(@as(i64, clipped.x) - radius, 0));
    const sample_top: u32 = @intCast(@max(@as(i64, clipped.y) - radius, 0));
    const sample_right: u32 = @intCast(@min(
        @as(i64, clipped.x) + clipped.width + radius,
        target.size.width,
    ));
    const sample_bottom: u32 = @intCast(@min(
        @as(i64, clipped.y) + clipped.height + radius,
        target.size.height,
    ));
    const sample_width = sample_right - sample_left;
    const sample_height = sample_bottom - sample_top;
    const pixel_count = std.math.mul(usize, sample_width, sample_height) catch
        return error.InvalidTarget;

    const pixels = self.allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    defer self.allocator.free(pixels);
    const temporary = self.allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    defer self.allocator.free(temporary);

    for (0..sample_height) |y| {
        const source_offset = (@as(usize, sample_top) + y) * target.stride_pixels + sample_left;
        const destination_offset = y * sample_width;
        @memcpy(
            pixels[destination_offset..][0..sample_width],
            target.pixels[source_offset..][0..sample_width],
        );
    }
    blurArgb(pixels, temporary, sample_width, sample_height, blur.radius);

    const requested_corner_radius = @min(
        blur.corner_radius,
        @min(blur.rect.width, blur.rect.height) / 2,
    );
    for (0..clipped.height) |y| {
        const output_y: u32 = @intCast(@as(i64, clipped.y) + @as(i64, @intCast(y)));
        for (0..clipped.width) |x| {
            const output_x: u32 = @intCast(@as(i64, clipped.x) + @as(i64, @intCast(x)));
            const coverage: u8 = if (requested_corner_radius == 0)
                255
            else
                @intFromFloat(roundedRectCoverage(
                    @as(f64, @floatFromInt(output_x)) + 0.5,
                    @as(f64, @floatFromInt(output_y)) + 0.5,
                    @floatFromInt(blur.rect.x),
                    @floatFromInt(blur.rect.y),
                    @floatFromInt(blur.rect.width),
                    @floatFromInt(blur.rect.height),
                    @floatFromInt(requested_corner_radius),
                ) * 255.0);
            const output_index = @as(usize, output_y) * target.stride_pixels + output_x;
            const blurred_index = @as(usize, output_y - sample_top) * sample_width +
                output_x - sample_left;
            target.pixels[output_index] = blendArgb(
                pixels[blurred_index],
                target.pixels[output_index],
                coverage,
            );
        }
    }
}

fn blurArgb(
    pixels: []u32,
    temporary: []u32,
    width_value: u32,
    height_value: u32,
    radius_value: u32,
) void {
    std.debug.assert(pixels.len == temporary.len);
    std.debug.assert(pixels.len == @as(usize, width_value) * height_value);

    const width: usize = width_value;
    const height: usize = height_value;
    const radius: usize = radius_value;
    for (0..height) |y| {
        var sums: [4]u64 = @splat(0);
        var count = @min(radius + 1, width);
        for (0..count) |x| addPixel(&sums, pixels[y * width + x]);
        for (0..width) |x| {
            temporary[y * width + x] = averagePixel(sums, count);
            if (x >= radius) {
                subtractPixel(&sums, pixels[y * width + x - radius]);
                count -= 1;
            }
            const added = x + radius + 1;
            if (added < width) {
                addPixel(&sums, pixels[y * width + added]);
                count += 1;
            }
        }
    }

    for (0..width) |x| {
        var sums: [4]u64 = @splat(0);
        var count = @min(radius + 1, height);
        for (0..count) |y| addPixel(&sums, temporary[y * width + x]);
        for (0..height) |y| {
            pixels[y * width + x] = averagePixel(sums, count);
            if (y >= radius) {
                subtractPixel(&sums, temporary[(y - radius) * width + x]);
                count -= 1;
            }
            const added = y + radius + 1;
            if (added < height) {
                addPixel(&sums, temporary[added * width + x]);
                count += 1;
            }
        }
    }
}

fn addPixel(sums: *[4]u64, pixel: u32) void {
    inline for (0..4) |component| sums[component] += @as(u8, @truncate(pixel >> component * 8));
}

fn subtractPixel(sums: *[4]u64, pixel: u32) void {
    inline for (0..4) |component| sums[component] -= @as(u8, @truncate(pixel >> component * 8));
}

fn averagePixel(sums: [4]u64, count: usize) u32 {
    std.debug.assert(count > 0);
    var pixel: u32 = 0;
    inline for (0..4) |component| {
        pixel |= @as(u32, @intCast(sums[component] / count)) << component * 8;
    }
    return pixel;
}

fn blendArgb(source: u32, destination: u32, coverage: u8) u32 {
    if (coverage == 255) return source;
    if (coverage == 0) return destination;

    const inverse = 255 - @as(u16, coverage);
    var result: u32 = 0;
    inline for (0..4) |component| {
        const source_component: u8 = @truncate(source >> component * 8);
        const destination_component: u8 = @truncate(destination >> component * 8);
        const blended = (@as(u16, source_component) * coverage +
            @as(u16, destination_component) * inverse + 127) / 255;
        result |= @as(u32, @intCast(blended)) << component * 8;
    }
    return result;
}

fn roundedRectCoverage(
    pixel_x: f64,
    pixel_y: f64,
    left: f64,
    top: f64,
    width: f64,
    height: f64,
    radius: f64,
) f64 {
    const half_width = width / 2.0;
    const half_height = height / 2.0;
    const center_x = left + half_width;
    const center_y = top + half_height;
    const inner_half_width = @max(half_width - radius, 0.0);
    const inner_half_height = @max(half_height - radius, 0.0);
    const distance_x = @abs(pixel_x - center_x) - inner_half_width;
    const distance_y = @abs(pixel_y - center_y) - inner_half_height;
    const outside_x = @max(distance_x, 0.0);
    const outside_y = @max(distance_y, 0.0);
    const signed_distance = @sqrt(outside_x * outside_x + outside_y * outside_y) +
        @min(@max(distance_x, distance_y), 0.0) - radius;
    return std.math.clamp(0.5 - signed_distance, 0.0, 1.0);
}

fn blurMask(
    allocator: std.mem.Allocator,
    data: [*]u8,
    stride: usize,
    width: u32,
    height: u32,
    radius_value: u32,
) Error!void {
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidTarget;
    const temporary = allocator.alloc(u8, pixel_count) catch return error.OutOfMemory;
    defer allocator.free(temporary);

    const radius: usize = radius_value;
    const kernel = std.math.add(usize, std.math.mul(usize, radius, 2) catch
        return error.InvalidTarget, 1) catch return error.InvalidTarget;
    for (0..height) |y| {
        var sum: u64 = 0;
        for (0..@min(radius + 1, width)) |x| sum += data[y * stride + x];
        for (0..width) |x| {
            temporary[y * width + x] = @intCast(sum / kernel);
            if (x >= radius) sum -= data[y * stride + x - radius];
            const added = x + radius + 1;
            if (added < width) sum += data[y * stride + added];
        }
    }

    for (0..width) |x| {
        var sum: u64 = 0;
        for (0..@min(radius + 1, height)) |y| sum += temporary[y * width + x];
        for (0..height) |y| {
            data[y * stride + x] = @intCast(sum / kernel);
            if (y >= radius) sum -= temporary[(y - radius) * width + x];
            const added = y + radius + 1;
            if (added < height) sum += temporary[added * width + x];
        }
    }
}

fn composite(
    destination: *pixman.pixman_image_t,
    destination_size: render_types.Size,
    image: render_types.Image,
) Error!void {
    const source = try createImage(image.buffer);
    defer _ = pixman.pixman_image_unref(source);
    if (image.size.width == 0 or image.size.height == 0) return error.InvalidTarget;
    const source_rect = image.source orelse render_types.SourceRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(image.buffer.size.width),
        .height = @floatFromInt(image.buffer.size.height),
    };
    if (!validSourceRect(source_rect, image.buffer.size)) return error.InvalidTarget;
    if (image.source != null or
        source_rect.width != @as(f64, @floatFromInt(image.size.width)) or
        source_rect.height != @as(f64, @floatFromInt(image.size.height)))
    {
        const floating_transform: pixman.pixman_f_transform_t = .{ .m = .{
            .{ source_rect.width / @as(f64, @floatFromInt(image.size.width)), 0, source_rect.x },
            .{ 0, source_rect.height / @as(f64, @floatFromInt(image.size.height)), source_rect.y },
            .{ 0, 0, 1 },
        } };
        var transform: pixman.pixman_transform_t = undefined;
        if (pixman.pixman_transform_from_pixman_f_transform(
            &transform,
            &floating_transform,
        ) == 0 or pixman.pixman_image_set_transform(source, &transform) == 0 or
            pixman.pixman_image_set_filter(source, pixman.PIXMAN_FILTER_BILINEAR, null, 0) == 0)
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
    var clipped = destination_rect.clipTo(destination_size) orelse return;
    if (image.clip) |clip| clipped = clipped.intersection(clip) orelse return;
    if (image.rounded_clip) |clip| clipped = clipped.intersection(clip.rect) orelse return;
    const source_x: i32 = clipped.x - image.x;
    const source_y: i32 = clipped.y - image.y;
    const mask = if (image.rounded_clip) |clip|
        try createRoundedMask(
            .{ .width = clip.rect.width, .height = clip.rect.height },
            clip.radius,
        )
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
        if (image.rounded_clip) |clip| clipped.x - clip.rect.x else 0,
        if (image.rounded_clip) |clip| clipped.y - clip.rect.y else 0,
        clipped.x,
        clipped.y,
        @intCast(clipped.width),
        @intCast(clipped.height),
    );
}

fn validSourceRect(source: render_types.SourceRect, buffer_size: render_types.Size) bool {
    return std.math.isFinite(source.x) and std.math.isFinite(source.y) and
        std.math.isFinite(source.width) and std.math.isFinite(source.height) and
        source.x >= 0 and source.y >= 0 and source.width > 0 and source.height > 0 and
        source.x + source.width <= @as(f64, @floatFromInt(buffer_size.width)) and
        source.y + source.height <= @as(f64, @floatFromInt(buffer_size.height));
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
            .clip = .{ .x = 1, .y = 0, .width = 1, .height = 3 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(0, 1));
    try std.testing.expectEqual(@as(u32, 0xff80007f), output.pixel(1, 2));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(2, 1));
}

test "CPU renderer rejects undersized targets" {
    var renderer = Self.init(std.testing.allocator);
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
            .clip = .{ .x = 0, .y = 1, .width = 1, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(0, 0));
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

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{
        .size = .{ .width = 1, .height = 1 },
        .commands = &commands,
    }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff336699), output.pixel(0, 0));
}

test "CPU renderer crops an image source rectangle" {
    var output = try headless.init(std.testing.allocator, .{ .width = 2, .height = 1 });
    defer output.deinit();

    var source_pixels = [_]u32{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff };
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 2, .height = 1 },
            .buffer = .{
                .size = .{ .width = 4, .height = 1 },
                .stride_pixels = 4,
                .pixels = &source_pixels,
            },
            .source = .{ .x = 1, .y = 0, .width = 2, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{
        .size = .{ .width = 2, .height = 1 },
        .commands = &commands,
    }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff00ff00), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(1, 0));
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
            .rounded_clip = .{
                .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
                .radius = 2,
            },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    const corner_alpha: u8 = @truncate(output.pixel(0, 0) >> 24);
    try std.testing.expect(corner_alpha > 0 and corner_alpha < 255);
    try std.testing.expectEqual(@as(u32, 0xffffffff), output.pixel(1, 1));
}

test "CPU renderer positions rounded clips independently from images" {
    const size: render_types.Size = .{ .width = 6, .height = 4 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    var source_pixels = [_]u32{0xffffffff} ** 24;
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
            .rounded_clip = .{
                .rect = .{ .x = 2, .y = 0, .width = 4, .height = 4 },
                .radius = 2,
            },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0), output.pixel(1, 1));
    const corner_alpha: u8 = @truncate(output.pixel(2, 0) >> 24);
    try std.testing.expect(corner_alpha > 0 and corner_alpha < 255);
    try std.testing.expectEqual(@as(u32, 0xffffffff), output.pixel(3, 1));
}

test "CPU renderer draws blurred rounded shadows" {
    const size: render_types.Size = .{ .width = 9, .height = 9 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .shadow = .{
            .rect = .{ .x = 3, .y = 3, .width = 3, .height = 3 },
            .corner_radius = 1,
            .blur_radius = 2,
            .spread = 0,
            .color = render_types.Color.rgba(0, 0, 0, 255),
            .clip = .{ .x = 4, .y = 0, .width = 1, .height = 9 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    const center_alpha: u8 = @truncate(output.pixel(4, 4) >> 24);
    try std.testing.expect(center_alpha > 0);
    try std.testing.expectEqual(@as(u32, 0), output.pixel(3, 4));
    try std.testing.expectEqual(@as(u32, 0), output.pixel(5, 4));
    try std.testing.expectEqual(@as(u32, 0), output.pixel(8, 8));
}

test "CPU renderer bounds shadow work to the clipped output" {
    const size: render_types.Size = .{ .width = 9, .height = 9 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .shadow = .{
            .rect = .{
                .x = 0,
                .y = 0,
                .width = std.math.maxInt(i32),
                .height = std.math.maxInt(i32),
            },
            .corner_radius = 0,
            .blur_radius = 2,
            .spread = 0,
            .color = render_types.Color.rgba(0, 0, 0, 255),
            .clip = .{ .x = 4, .y = 4, .width = 1, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, output.target());

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(4, 4));
    try std.testing.expectEqual(@as(u32, 0), output.pixel(3, 4));
}

test "CPU renderer blurs the backdrop inside a window region" {
    const size: render_types.Size = .{ .width = 5, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const target = output.target();
    @memcpy(target.pixels[0..5], &[_]u32{
        0xff000000,
        0xff000000,
        0xffffffff,
        0xff000000,
        0xff000000,
    });
    const commands = [_]render_types.Command{
        .{ .backdrop_blur = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
        } },
    };

    var renderer = Self.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.render(.{ .size = size, .commands = &commands }, target);

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 0));
    try std.testing.expectEqual(@as(u32, 0xff555555), output.pixel(2, 0));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(3, 0));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(4, 0));
}
