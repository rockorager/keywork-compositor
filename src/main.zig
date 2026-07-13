//! Application entry point.

const std = @import("std");
const Server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const server = try Server.create(init.gpa);
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
    _ = @import("render.zig");
    _ = @import("renderer.zig");
    _ = @import("headless.zig");
    _ = @import("cpu_renderer.zig");
    _ = @import("region.zig");
    _ = @import("slot_map.zig");
    _ = @import("subcompositor.zig");
    _ = @import("xdg_shell.zig");
    _ = @import("server.zig");
}
