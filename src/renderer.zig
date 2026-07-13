//! Runtime-selected renderer.

const std = @import("std");
const CpuRenderer = @import("cpu_renderer.zig");
const headless = @import("headless.zig");
const render_types = @import("render.zig");

pub const Target = union(enum) {
    cpu: render_types.PixelBuffer,
};

pub const Renderer = union(enum) {
    cpu: CpuRenderer,

    pub const Error = CpuRenderer.Error;

    pub fn deinit(self: *Renderer) void {
        switch (self.*) {
            .cpu => |*renderer| renderer.deinit(),
        }
        self.* = undefined;
    }

    pub fn render(
        self: *Renderer,
        frame: render_types.Frame,
        target: Target,
    ) Error!void {
        return switch (self.*) {
            .cpu => |*renderer| switch (target) {
                .cpu => |cpu_target| renderer.render(frame, cpu_target),
            },
        };
    }
};

test "renderer dispatches to the selected implementation" {
    const size: render_types.Size = .{ .width = 2, .height = 2 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(10, 20, 30, 255) },
    };

    var renderer: Renderer = .{ .cpu = CpuRenderer.init() };
    defer renderer.deinit();
    try renderer.render(
        .{ .size = size, .commands = &commands },
        .{ .cpu = output.target() },
    );

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(1, 1));
}
