//! Application entry point.

const std = @import("std");
const OutputBackend = @import("backend/output.zig");
const Renderer = @import("render/renderer.zig").Renderer;
const Server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const renderer_kind: Renderer.Kind = if (init.environ_map.get("KEYWORK_RENDERER")) |value|
        std.meta.stringToEnum(Renderer.Kind, value) orelse return error.InvalidRenderer
    else
        .cpu;
    const output_kind: OutputBackend.Kind = if (init.environ_map.get("KEYWORK_OUTPUT")) |value|
        std.meta.stringToEnum(OutputBackend.Kind, value) orelse return error.InvalidOutputBackend
    else
        .headless;
    const server = try Server.create(init.gpa, init.io, renderer_kind, output_kind);
    defer server.destroy();

    const interrupt = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.INT),
        terminate,
        server,
    );
    defer interrupt.remove();
    const terminate_signal = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.TERM),
        terminate,
        server,
    );
    defer terminate_signal.remove();

    const socket_name = try server.listen();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("WAYLAND_DISPLAY={s}\n", .{socket_name});
    try writer.interface.flush();

    server.run();
}

fn terminate(_: c_int, server: *Server) c_int {
    server.terminate();
    return 0;
}

test {
    _ = @import("render/types.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/cpu.zig");
    _ = @import("render/vulkan.zig");
    _ = @import("backend/headless.zig");
    _ = @import("backend/nested_wayland.zig");
    _ = @import("backend/output.zig");
    _ = @import("presentation.zig");
    _ = @import("region.zig");
    _ = @import("scene.zig");
    _ = @import("slot_map.zig");
    _ = @import("wayland/compositor.zig");
    _ = @import("wayland/surface.zig");
    _ = @import("wayland/region.zig");
    _ = @import("wayland/subcompositor.zig");
    _ = @import("wayland/seat.zig");
    _ = @import("wayland/output.zig");
    _ = @import("wayland/data_device.zig");
    _ = @import("wayland/primary_selection.zig");
    _ = @import("wayland/presentation.zig");
    _ = @import("wayland/fractional_scale.zig");
    _ = @import("wayland/fixes.zig");
    _ = @import("wayland/linux_dmabuf.zig");
    _ = @import("wayland/xdg_activation.zig");
    _ = @import("wayland/xdg_output.zig");
    _ = @import("wayland/viewporter.zig");
    _ = @import("wayland/xdg_shell.zig");
    _ = @import("wayland/layer_shell.zig");
    _ = @import("river/window_manager.zig");
    _ = @import("server.zig");
}
