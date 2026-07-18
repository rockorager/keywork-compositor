//! Application entry point.

const std = @import("std");
const OutputBackend = @import("backend/output.zig");
const Config = @import("config.zig");
const Launcher = @import("launcher.zig");
const Renderer = @import("render/renderer.zig").Renderer;
const render = @import("render/types.zig");
const Server = @import("server.zig");
const Systemd = @import("systemd.zig");

const log = std.log.scoped(.main);
const default_cursor_size = "24";

pub fn main(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    const explicit_config = try parseArguments(&arguments);
    const output_kind: OutputBackend.Kind = if (init.environ_map.get("KEYWORK_OUTPUT")) |value|
        std.meta.stringToEnum(OutputBackend.Kind, value) orelse return error.InvalidOutputBackend
    else
        .drm;
    const renderer_kind: Renderer.Kind = if (init.environ_map.get("KEYWORK_RENDERER")) |value|
        std.meta.stringToEnum(Renderer.Kind, value) orelse return error.InvalidRenderer
    else if (output_kind == .drm)
        .vulkan
    else
        .cpu;
    const native_session = output_kind == .drm;
    if (native_session) {
        _ = init.environ_map.swapRemove("WAYLAND_DISPLAY");
        _ = init.environ_map.swapRemove("DISPLAY");
        _ = init.environ_map.swapRemove("KEYWORK_CONTROL");
        try init.environ_map.put("XDG_CURRENT_DESKTOP", "keywork");
        try init.environ_map.put("XDG_SESSION_DESKTOP", "keywork");
        try init.environ_map.put("XDG_SESSION_TYPE", "wayland");
    }
    const session_lock = if (native_session)
        try acquireSessionLock(
            init.gpa,
            init.io,
            init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory,
        )
    else
        null;
    defer if (session_lock) |file| file.close(init.io);
    var systemd: Systemd = .init(init.io, init.environ_map, native_session);
    try systemd.prepare();
    var launcher: Launcher = .init(init.gpa, init.io, init.environ_map);
    defer launcher.deinit();
    var virtual_output: Server.VirtualOutputConfig = .{};
    if (output_kind == .headless) {
        if (init.environ_map.get("KEYWORK_HEADLESS_SIZE")) |value| {
            virtual_output.size = parseHeadlessSize(value) catch return error.InvalidHeadlessSize;
        }
        if (init.environ_map.get("KEYWORK_HEADLESS_SCALE")) |value| {
            virtual_output.scale = parseHeadlessScale(value) catch return error.InvalidHeadlessScale;
        }
    }
    if (init.environ_map.get("XCURSOR_SIZE") == null) {
        try init.environ_map.put("XCURSOR_SIZE", default_cursor_size);
    }
    const server = try Server.createWithVirtualOutput(
        init.gpa,
        init.io,
        renderer_kind,
        output_kind,
        init.environ_map.get("KEYWORK_DRM_DEVICE"),
        virtual_output,
    );
    defer server.destroy();
    var configuration = try Config.Store.init(
        init.gpa,
        init.io,
        init.environ_map,
        explicit_config,
    );
    server.setConfiguration(&configuration);
    if (init.environ_map.get("KEYWORK_BLUR_RADIUS")) |value| {
        server.setWindowBlurRadius(parseBlurRadius(value) catch
            return error.InvalidBlurRadius);
    }

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
    const reload_signal = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.HUP),
        reloadConfiguration,
        server,
    );
    defer reload_signal.remove();
    const child_signal = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.CHLD),
        reapChildren,
        server,
    );
    defer child_signal.remove();

    const socket_name = try server.listen();
    try init.environ_map.put("WAYLAND_DISPLAY", socket_name);
    const control_address = try server.listenControl(
        init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory,
    );
    try init.environ_map.put("KEYWORK_CONTROL", control_address);
    server.setLauncher(&launcher);
    server.setXwaylandReadyListener(.{
        .context = &systemd,
        .ready = xwaylandReady,
    });
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print(
        "WAYLAND_DISPLAY={s}\nKEYWORK_CONTROL={s}\n",
        .{ socket_name, control_address },
    );
    try writer.interface.flush();
    server.startXwayland(init.environ_map);
    systemd.ready(socket_name, control_address, init.environ_map.get("XCURSOR_SIZE").?) catch |err| {
        systemd.shutdown() catch |shutdown_err| {
            log.warn("failed to roll back graphical session startup: {t}", .{shutdown_err});
        };
        return err;
    };

    server.run();
    systemd.shutdown() catch |err| {
        log.warn("failed to shut down the graphical session targets: {t}", .{err});
    };
}

fn parseArguments(arguments: anytype) !?[]const u8 {
    const first = arguments.next() orelse return null;
    if (!std.mem.eql(u8, first, "--config")) return error.InvalidArgument;
    const path = arguments.next() orelse return error.MissingConfigPath;
    if (arguments.next() != null) return error.InvalidArgument;
    return path;
}

fn xwaylandReady(context: *anyopaque, display_name: []const u8) void {
    const systemd: *Systemd = @ptrCast(@alignCast(context));
    systemd.publishDisplay(display_name) catch |err| {
        log.warn("failed to publish DISPLAY to the activation environment: {t}", .{err});
    };
}

fn acquireSessionLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_directory: []const u8,
) !std.Io.File {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    const path = try std.fs.path.join(allocator, &.{ runtime_directory, "keywork-compositor.lock" });
    defer allocator.free(path);
    return std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = false,
        .lock = .exclusive,
    });
}

fn parseHeadlessSize(value: []const u8) !render.Size {
    const separator = std.mem.indexOfScalar(u8, value, 'x') orelse
        return error.InvalidHeadlessSize;
    const width = std.fmt.parseInt(u32, value[0..separator], 10) catch
        return error.InvalidHeadlessSize;
    const height = std.fmt.parseInt(u32, value[separator + 1 ..], 10) catch
        return error.InvalidHeadlessSize;
    if (width == 0 or height == 0) return error.InvalidHeadlessSize;
    return .{ .width = width, .height = height };
}

fn parseHeadlessScale(value: []const u8) !render.Scale {
    const scale = std.fmt.parseFloat(f64, value) catch return error.InvalidHeadlessScale;
    const scaled = @round(scale * render.Scale.denominator);
    if (!std.math.isFinite(scaled) or scaled < 1 or
        scaled > @as(f64, @floatFromInt(std.math.maxInt(u32))))
    {
        return error.InvalidHeadlessScale;
    }
    return .{ .numerator = @intFromFloat(scaled) };
}

fn parseBlurRadius(value: []const u8) !u32 {
    const radius = std.fmt.parseInt(u32, value, 10) catch return error.InvalidBlurRadius;
    if (radius > 256) return error.InvalidBlurRadius;
    return radius;
}

fn terminate(_: c_int, server: *Server) c_int {
    server.terminate();
    return 0;
}

fn reloadConfiguration(_: c_int, server: *Server) c_int {
    server.reloadConfiguration() catch |err| {
        log.warn("configuration reload failed: {t}", .{err});
    };
    return 0;
}

fn reapChildren(_: c_int, _: *Server) c_int {
    // Detached launchers and Xwayland deliberately transfer wait ownership here.
    while (std.c.waitpid(-1, null, std.os.linux.W.NOHANG) > 0) {}
    return 0;
}

test "headless output configuration parses physical size and fractional scale" {
    try std.testing.expectEqual(
        render.Size{ .width = 2880, .height = 1800 },
        try parseHeadlessSize("2880x1800"),
    );
    try std.testing.expectEqual(@as(u32, 180), (try parseHeadlessScale("1.5")).numerator);
    try std.testing.expectError(error.InvalidHeadlessSize, parseHeadlessSize("2880"));
    try std.testing.expectError(error.InvalidHeadlessScale, parseHeadlessScale("0"));
}

test "window blur radius is bounded" {
    try std.testing.expectEqual(@as(u32, 0), try parseBlurRadius("0"));
    try std.testing.expectEqual(@as(u32, 24), try parseBlurRadius("24"));
    try std.testing.expectError(error.InvalidBlurRadius, parseBlurRadius("257"));
}

test {
    _ = @import("render/types.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/cpu.zig");
    _ = @import("render/vulkan.zig");
    _ = @import("backend/headless.zig");
    _ = @import("backend/nested_wayland.zig");
    _ = @import("backend/drm.zig");
    _ = @import("backend/drm_device.zig");
    _ = @import("backend/native_input.zig");
    _ = @import("backend/output.zig");
    _ = @import("backend/session.zig");
    _ = @import("presentation.zig");
    _ = @import("region.zig");
    _ = @import("scene.zig");
    _ = @import("slot_map.zig");
    _ = @import("window_manager.zig");
    _ = @import("builtin_keybindings.zig");
    _ = @import("config.zig");
    _ = @import("launcher.zig");
    _ = @import("command.zig");
    _ = @import("input_manager.zig");
    _ = @import("window_manager/types.zig");
    _ = @import("window_manager/backend.zig");
    _ = @import("window_manager/layout.zig");
    _ = @import("window_manager/workspace.zig");
    _ = @import("wayland/compositor.zig");
    _ = @import("wayland/surface.zig");
    _ = @import("wayland/region.zig");
    _ = @import("wayland/subcompositor.zig");
    _ = @import("wayland/seat.zig");
    _ = @import("wayland/output.zig");
    _ = @import("wayland/output_layout.zig");
    _ = @import("wayland/output_management.zig");
    _ = @import("wayland/output_power.zig");
    _ = @import("wayland/data_device.zig");
    _ = @import("wayland/primary_selection.zig");
    _ = @import("wayland/selection_source.zig");
    _ = @import("wayland/data_control.zig");
    _ = @import("wayland/foreign_toplevel_list.zig");
    _ = @import("wayland/image_capture_source.zig");
    _ = @import("wayland/image_copy_capture.zig");
    _ = @import("wayland/screencopy.zig");
    _ = @import("wayland/xwayland_shell.zig");
    _ = @import("xwayland/server.zig");
    _ = @import("xwayland/xwm.zig");
    _ = @import("wayland/workspace.zig");
    _ = @import("wayland/text_input.zig");
    _ = @import("wayland/input_method.zig");
    _ = @import("wayland/virtual_keyboard.zig");
    _ = @import("wayland/presentation.zig");
    _ = @import("wayland/fractional_scale.zig");
    _ = @import("wayland/fixes.zig");
    _ = @import("wayland/linux_dmabuf.zig");
    _ = @import("wayland/single_pixel_buffer.zig");
    _ = @import("wayland/content_type.zig");
    _ = @import("wayland/security_context.zig");
    _ = @import("wayland/session_lock.zig");
    _ = @import("wayland/cursor_shape.zig");
    _ = @import("wayland/tablet.zig");
    _ = @import("wayland/pointer_gestures.zig");
    _ = @import("wayland/relative_pointer.zig");
    _ = @import("wayland/pointer_constraints.zig");
    _ = @import("wayland/idle_inhibit.zig");
    _ = @import("wayland/keyboard_shortcuts_inhibit.zig");
    _ = @import("wayland/idle_notify.zig");
    _ = @import("wayland/xdg_activation.zig");
    _ = @import("wayland/xdg_foreign.zig");
    _ = @import("wayland/xdg_output.zig");
    _ = @import("wayland/viewporter.zig");
    _ = @import("wayland/xdg_shell.zig");
    _ = @import("wayland/layer_shell.zig");
    _ = @import("control.zig");
    _ = @import("server.zig");
}
