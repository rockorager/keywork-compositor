//! Runtime-selected renderer.

const std = @import("std");
const CpuRenderer = @import("cpu_renderer.zig");
const VulkanRenderer = @import("vulkan_renderer.zig");
const headless = @import("headless.zig");
const render_types = @import("render.zig");

pub const Target = union(enum) {
    cpu: render_types.PixelBuffer,
    vulkan: VulkanRenderer.Target,
};

pub const Renderer = union(enum) {
    cpu: CpuRenderer,
    vulkan: VulkanRenderer,

    pub const Kind = enum {
        cpu,
        vulkan,
    };

    pub const Error = CpuRenderer.Error || VulkanRenderer.Error;

    pub fn init(allocator: std.mem.Allocator, kind: Kind) VulkanRenderer.InitError!Renderer {
        return switch (kind) {
            .cpu => .{ .cpu = CpuRenderer.init(allocator) },
            .vulkan => .{ .vulkan = try VulkanRenderer.init(allocator) },
        };
    }

    pub fn deinit(self: *Renderer) void {
        switch (self.*) {
            .cpu => |*renderer| renderer.deinit(),
            .vulkan => |*renderer| renderer.deinit(),
        }
        self.* = undefined;
    }

    pub fn makeTarget(self: *Renderer, pixels: render_types.PixelBuffer) Target {
        return switch (self.*) {
            .cpu => .{ .cpu = pixels },
            .vulkan => .{ .vulkan = .{ .readback = pixels } },
        };
    }

    pub fn render(
        self: *Renderer,
        frame: render_types.Frame,
        target: Target,
    ) Error!void {
        if (frame.scale.numerator == 0 or frame.scale.numerator > std.math.maxInt(i32)) {
            return error.InvalidTarget;
        }
        if (frame.scale.numerator == render_types.Scale.denominator) {
            return self.renderDirect(frame, target);
        }

        const physical_size = frame.scale.apply(frame.size) catch return error.InvalidTarget;
        for (frame.commands) |command| {
            const commands = [_]render_types.Command{scaleCommand(command, frame.scale)};
            try self.renderDirect(.{ .size = physical_size, .commands = &commands }, target);
        }
    }

    fn renderDirect(
        self: *Renderer,
        frame: render_types.Frame,
        target: Target,
    ) Error!void {
        return switch (self.*) {
            .cpu => |*renderer| switch (target) {
                .cpu => |cpu_target| renderer.render(frame, cpu_target),
                .vulkan => error.InvalidTarget,
            },
            .vulkan => |*renderer| switch (target) {
                .cpu => error.InvalidTarget,
                .vulkan => |vulkan_target| renderer.renderFrame(frame, vulkan_target),
            },
        };
    }
};

fn scaleCommand(command: render_types.Command, scale: render_types.Scale) render_types.Command {
    std.debug.assert(scale.numerator > 0 and scale.numerator <= std.math.maxInt(i32));
    return switch (command) {
        .clear => |color| .{ .clear = color },
        .solid_rect => |solid| .{ .solid_rect = .{
            .rect = scaleRect(solid.rect, scale),
            .color = solid.color,
            .clip = if (solid.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .shadow => |shadow| .{ .shadow = .{
            .rect = scaleRect(shadow.rect, scale),
            .corner_radius = scaleUnsigned(shadow.corner_radius, scale),
            .blur_radius = scaleUnsigned(shadow.blur_radius, scale),
            .spread = scaleSigned(shadow.spread, scale),
            .color = shadow.color,
            .clip = if (shadow.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .backdrop_blur => |blur| .{ .backdrop_blur = .{
            .rect = scaleRect(blur.rect, scale),
            .corner_radius = scaleUnsigned(blur.corner_radius, scale),
            .radius = scaleUnsigned(blur.radius, scale),
            .clip = if (blur.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .image => |image| scaled: {
            const rect = scaleRect(.{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            }, scale);
            break :scaled .{ .image = .{
                .x = rect.x,
                .y = rect.y,
                .size = .{ .width = rect.width, .height = rect.height },
                .buffer = image.buffer,
                .source = image.source,
                .corner_radius = scaleUnsigned(image.corner_radius, scale),
                .clip = if (image.clip) |clip| scaleRect(clip, scale) else null,
            } };
        },
    };
}

fn scaleRect(rect: render_types.Rect, scale: render_types.Scale) render_types.Rect {
    const left = scaleSigned(rect.x, scale);
    const top = scaleSigned(rect.y, scale);
    const right = scaleSigned(@as(i64, rect.x) + rect.width, scale);
    const bottom = scaleSigned(@as(i64, rect.y) + rect.height, scale);
    return .{
        .x = left,
        .y = top,
        .width = @intCast(@max(@as(i64, right) - left, 0)),
        .height = @intCast(@max(@as(i64, bottom) - top, 0)),
    };
}

fn scaleSigned(value: i64, scale: render_types.Scale) i32 {
    const product = @as(i128, value) * scale.numerator;
    const rounded = if (product >= 0)
        @divTrunc(
            product + render_types.Scale.denominator / 2,
            render_types.Scale.denominator,
        )
    else
        -@divTrunc(
            -product + render_types.Scale.denominator / 2,
            render_types.Scale.denominator,
        );
    return @intCast(std.math.clamp(
        rounded,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleUnsigned(value: u32, scale: render_types.Scale) u32 {
    const product = @as(u64, value) * scale.numerator;
    return @intCast(@min(
        (product + render_types.Scale.denominator / 2) / render_types.Scale.denominator,
        std.math.maxInt(u32),
    ));
}

test "renderer dispatches to the selected implementation" {
    const size: render_types.Size = .{ .width = 2, .height = 2 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(10, 20, 30, 255) },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{ .size = size, .commands = &commands },
        .{ .cpu = output.target() },
    );

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(1, 1));
}

test "renderer scales logical commands into a physical target" {
    const logical_size: render_types.Size = .{ .width = 2, .height = 2 };
    var output = try headless.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 0, 0, 255),
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{ .size = logical_size, .commands = &commands, .scale = .{ .numerator = 180 } },
        .{ .cpu = output.target() },
    );

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 1));
    try std.testing.expectEqual(@as(u32, 0xffff0000), output.pixel(2, 1));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(2, 2));
}

test "fractional rendering preserves an exact-scale image" {
    var output = try headless.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer output.deinit();
    var source_pixels = [_]u32{
        0xffff0000, 0xff00ff00, 0xff0000ff,
        0xffffffff, 0xff808080, 0xff000000,
        0xff102030, 0xff405060, 0xff708090,
    };
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 2, .height = 2 },
            .buffer = .{
                .size = .{ .width = 3, .height = 3 },
                .stride_pixels = 3,
                .pixels = &source_pixels,
            },
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{
            .size = .{ .width = 2, .height = 2 },
            .commands = &commands,
            .scale = .{ .numerator = 180 },
        },
        .{ .cpu = output.target() },
    );

    try std.testing.expectEqualSlices(u32, &source_pixels, output.target().pixels);
}
