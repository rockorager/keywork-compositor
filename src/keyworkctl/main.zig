//! Command-line client for Keywork's compositor control interface.

const std = @import("std");
const control = @import("keywork-control");
const varlink = @import("varlink");
const Empty = struct {};

const usage =
    \\usage: keyworkctl COMMAND [ARGUMENT]
    \\
    \\commands: focus DIRECTION | move-focused DIRECTION | set-layout LAYOUT
    \\          close TARGET
    \\          toggle-fullscreen TARGET | toggle-floating TARGET
    \\          switch-workspace WORKSPACE | move-focused-to-workspace WORKSPACE
    \\          stats [--reset] | reload | quit
    \\directions: next, previous, left, down, up, right
    \\targets: focused
    \\layouts: master-stack, dwindle, scrolling
    \\
;

const Command = union(enum) {
    focus: control.Direction,
    move_focused: control.Direction,
    close: control.WindowTarget,
    toggle_fullscreen: control.WindowTarget,
    toggle_floating: control.WindowTarget,
    set_layout: control.Layout,
    switch_workspace: i64,
    move_to_workspace: i64,
    stats: bool,
    reload,
    quit,
};

const StatisticsParameters = struct {
    outputs: []control.OutputStatistics,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err == error.Reported) std.process.exit(2);
        if (err == error.RemoteError) std.process.exit(1);
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("keyworkctl: {t}\n", .{err}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer iterator.deinit();
    _ = iterator.next();
    var arguments: [3][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |argument| {
        if (count == arguments.len) return printUsage(init.io, error.InvalidArguments);
        arguments[count] = argument;
        count += 1;
    }
    if (count == 1 and std.mem.eql(u8, arguments[0], "--help")) {
        var buffer: [2048]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        defer stdout.interface.flush() catch {};
        try stdout.interface.writeAll(usage);
        return;
    }
    const command = parse(arguments[0..count]) catch |err| return printUsage(init.io, err);

    const runtime_directory = init.environ_map.get("XDG_RUNTIME_DIR") orelse
        return error.MissingRuntimeDirectory;
    const address = try controlAddress(init.gpa, runtime_directory);
    defer init.gpa.free(address);
    var client = try varlink.Client.connect(init.gpa, init.io, address);
    defer client.deinit();
    switch (command) {
        .quit => {
            try client.notify(control.quit_method, Empty{});
            return;
        },
        else => {},
    }
    var reply = switch (command) {
        .focus => |direction| try client.call(control.focus_method, .{ .direction = direction }),
        .move_focused => |direction| try client.call(control.move_focused_method, .{ .direction = direction }),
        .close => |target| try client.call(control.close_method, .{ .target = target }),
        .toggle_fullscreen => |target| try client.call(control.toggle_fullscreen_method, .{ .target = target }),
        .toggle_floating => |target| try client.call(control.toggle_floating_method, .{ .target = target }),
        .set_layout => |layout| try client.call(control.set_layout_method, .{ .layout = layout }),
        .switch_workspace => |workspace| try client.call(control.switch_workspace_method, .{ .workspace = workspace }),
        .move_to_workspace => |workspace| try client.call(control.move_focused_to_workspace_method, .{ .workspace = workspace }),
        .stats => |reset| try client.call(control.get_performance_statistics_method, .{ .reset = reset }),
        .reload => try client.call(control.reload_configuration_method, Empty{}),
        .quit => unreachable,
    };
    defer reply.deinit();
    if (reply.value.@"error") |name| {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        if (remoteErrorMessage(name, reply.value.parameters)) |message| {
            try stderr.interface.print("keyworkctl: {s}\n", .{message});
        } else {
            try stderr.interface.print("keyworkctl: Varlink error: {s}\n", .{name});
        }
        try stderr.interface.flush();
        return error.RemoteError;
    }
    if (reply.value.continues) return error.UnexpectedContinuation;
    switch (command) {
        .stats => try printStatistics(init.io, init.gpa, reply.value.parameters),
        else => {},
    }
}

fn printStatistics(
    io: std.Io,
    allocator: std.mem.Allocator,
    parameters: ?std.json.Value,
) !void {
    const parsed = try parseStatisticsParameters(allocator, parameters);
    defer parsed.deinit();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};
    try writeStatistics(&stdout.interface, parsed.value.outputs);
}

fn parseStatisticsParameters(
    allocator: std.mem.Allocator,
    parameters: ?std.json.Value,
) !std.json.Parsed(StatisticsParameters) {
    return std.json.parseFromValue(
        StatisticsParameters,
        allocator,
        parameters orelse return error.MissingStatistics,
        .{},
    );
}

fn writeStatistics(writer: *std.Io.Writer, outputs: []const control.OutputStatistics) !void {
    if (outputs.len == 0) return writer.writeAll("No active outputs.\n");
    for (outputs, 0..) |output, index| {
        if (index != 0) try writer.writeByte('\n');
        try writer.print("{s} {d}x{d} ({d}.", .{
            output.name,
            output.width,
            output.height,
            @divTrunc(output.refresh_millihertz, 1000),
        });
        const fractional_refresh = @mod(output.refresh_millihertz, 1000);
        if (fractional_refresh < 10) {
            try writer.print("00{d}", .{fractional_refresh});
        } else if (fractional_refresh < 100) {
            try writer.print("0{d}", .{fractional_refresh});
        } else {
            try writer.print("{d}", .{fractional_refresh});
        }
        try writer.writeAll(" Hz)\n");
        try writer.print(
            "  frames: requested {d}, started {d}, presented {d}, discarded {d}\n",
            .{
                output.frames_requested,
                output.frames_started,
                output.frames_presented,
                output.frames_discarded,
            },
        );
        try writer.print(
            "  paths: composited {d}, direct scanout {d}/{d} candidates\n",
            .{
                output.composited_frames,
                output.direct_scanout_frames,
                output.direct_scanout_candidates,
            },
        );
        try writeDirectScanoutRejections(writer, output.direct_scanout_rejections);
        try writer.print("  acquire retries: {d}, frames over budget: {d}\n", .{
            output.acquire_retries,
            output.frames_over_budget,
        });
        try writeLatency(writer, "GPU total", output.gpu_execution);
        try writeLatency(writer, "GPU composition/effects", output.gpu_composition);
        try writeLatency(writer, "GPU output encode", output.gpu_output_encode);
        try writeLatency(writer, "request -> presentation", output.request_to_presentation);
        try writeLatency(writer, "request -> render", output.request_to_render);
        try writeLatency(writer, "render -> commit", output.render_to_commit);
        try writeLatency(writer, "commit -> presentation", output.commit_to_presentation);
    }
}

fn writeLatency(
    writer: *std.Io.Writer,
    label: []const u8,
    latency: control.LatencyStatistics,
) !void {
    try writer.print(
        "  {s}: p50 {d}us, p95 {d}us, p99 {d}us, max {d}us ({d} samples)\n",
        .{
            label,
            latency.p50_microseconds,
            latency.p95_microseconds,
            latency.p99_microseconds,
            latency.maximum_microseconds,
            latency.samples,
        },
    );
}

fn writeDirectScanoutRejections(
    writer: *std.Io.Writer,
    rejections: control.DirectScanoutRejections,
) !void {
    var wrote_rejection = false;
    try writeDirectScanoutRejection(writer, &wrote_rejection, "no fullscreen surface", rejections.no_fullscreen_surface);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "non-opaque surface", rejections.non_opaque_surface);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "surface transform", rejections.surface_transform);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "non-DMA-BUF", rejections.non_dmabuf);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "Y-inverted buffer", rejections.y_inverted);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "missing buffer identity", rejections.missing_buffer_identity);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "color conversion", rejections.color_conversion);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "unsupported backend", rejections.unsupported_backend);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "output unavailable", rejections.output_unavailable);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "output busy", rejections.output_busy);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "device inactive", rejections.device_inactive);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "unsupported format/modifier", rejections.unsupported_format_or_modifier);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "unsupported layout", rejections.unsupported_layout);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "framebuffer import failed", rejections.framebuffer_import_failed);
    try writeDirectScanoutRejection(writer, &wrote_rejection, "page flip failed", rejections.page_flip_failed);
    if (!wrote_rejection) try writer.writeAll("  direct scanout rejections: none\n");
}

fn writeDirectScanoutRejection(
    writer: *std.Io.Writer,
    wrote_rejection: *bool,
    label: []const u8,
    count: i64,
) !void {
    if (count == 0) return;
    if (!wrote_rejection.*) {
        try writer.writeAll("  direct scanout rejections:\n");
        wrote_rejection.* = true;
    }
    try writer.print("    {s}: {d}\n", .{ label, count });
}

fn controlAddress(allocator: std.mem.Allocator, runtime_directory: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    return std.fmt.allocPrint(
        allocator,
        "unix:{s}/{s}",
        .{ runtime_directory, control.socket_name },
    );
}

fn remoteErrorMessage(name: []const u8, parameters: ?std.json.Value) ?[]const u8 {
    if (!std.mem.eql(u8, name, control.configuration_reload_failed_error)) return null;
    const value = parameters orelse return null;
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const message = object.get("message") orelse return null;
    return switch (message) {
        .string => |string| string,
        else => null,
    };
}

fn printUsage(io: std.Io, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    defer stderr.interface.flush() catch {};
    stderr.interface.print("keyworkctl: {t}\n{s}", .{ err, usage }) catch {};
    return error.Reported;
}

fn parse(arguments: []const []const u8) !Command {
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "stats")) return .{ .stats = false };
    if (arguments.len == 2 and std.mem.eql(u8, arguments[0], "stats") and
        std.mem.eql(u8, arguments[1], "--reset")) return .{ .stats = true };
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "reload")) return .reload;
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "quit")) return .quit;
    if (arguments.len != 2) return error.InvalidArguments;
    const name = arguments[0];
    const value = arguments[1];
    if (std.mem.eql(u8, name, "focus")) return .{ .focus = parseDirection(value) orelse return error.InvalidDirection };
    if (std.mem.eql(u8, name, "move-focused")) return .{ .move_focused = parseDirection(value) orelse return error.InvalidDirection };
    if (std.mem.eql(u8, name, "close")) return .{ .close = parseWindowTarget(value) orelse return error.InvalidWindowTarget };
    if (std.mem.eql(u8, name, "toggle-fullscreen")) return .{ .toggle_fullscreen = parseWindowTarget(value) orelse return error.InvalidWindowTarget };
    if (std.mem.eql(u8, name, "toggle-floating")) return .{ .toggle_floating = parseWindowTarget(value) orelse return error.InvalidWindowTarget };
    if (std.mem.eql(u8, name, "set-layout")) return .{ .set_layout = parseLayout(value) orelse return error.InvalidLayout };
    if (std.mem.eql(u8, name, "switch-workspace")) return .{
        .switch_workspace = try parseWorkspace(value),
    };
    if (std.mem.eql(u8, name, "move-focused-to-workspace")) return .{
        .move_to_workspace = try parseWorkspace(value),
    };
    return error.UnknownCommand;
}

fn parseWorkspace(value: []const u8) !i64 {
    const workspace = std.fmt.parseInt(i64, value, 10) catch return error.InvalidWorkspace;
    if (!control.validWorkspace(workspace)) return error.InvalidWorkspace;
    return workspace;
}

fn parseDirection(value: []const u8) ?control.Direction {
    return std.meta.stringToEnum(control.Direction, value);
}

fn parseWindowTarget(value: []const u8) ?control.WindowTarget {
    return std.meta.stringToEnum(control.WindowTarget, value);
}

fn parseLayout(value: []const u8) ?control.Layout {
    if (std.mem.eql(u8, value, "master-stack")) return .master_stack;
    return std.meta.stringToEnum(control.Layout, value);
}

test "CLI parsing maps wire values and validates workspaces" {
    try std.testing.expectEqual(control.Direction.left, (try parse(&.{ "focus", "left" })).focus);
    try std.testing.expectEqual(control.WindowTarget.focused, (try parse(&.{ "close", "focused" })).close);
    try std.testing.expectEqual(control.WindowTarget.focused, (try parse(&.{ "toggle-fullscreen", "focused" })).toggle_fullscreen);
    try std.testing.expectEqual(control.WindowTarget.focused, (try parse(&.{ "toggle-floating", "focused" })).toggle_floating);
    try std.testing.expectEqual(control.Layout.master_stack, (try parse(&.{ "set-layout", "master-stack" })).set_layout);
    try std.testing.expectEqual(@as(i64, 10), (try parse(&.{ "switch-workspace", "10" })).switch_workspace);
    try std.testing.expect(!(try parse(&.{"stats"})).stats);
    try std.testing.expect((try parse(&.{ "stats", "--reset" })).stats);
    try std.testing.expectEqual(Command.reload, try parse(&.{"reload"}));
    try std.testing.expectEqual(Command.quit, try parse(&.{"quit"}));
    try std.testing.expectError(error.InvalidWorkspace, parse(&.{ "switch-workspace", "11" }));
    try std.testing.expectError(error.InvalidDirection, parse(&.{ "focus", "sideways" }));
    try std.testing.expectError(error.InvalidWindowTarget, parse(&.{ "close", "all" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "unknown", "value" }));
}

test "control address uses the fixed runtime socket" {
    const address = try controlAddress(std.testing.allocator, "/run/user/1000");
    defer std.testing.allocator.free(address);
    try std.testing.expectEqualStrings(
        "unix:/run/user/1000/dev.rockorager.keywork.compositor",
        address,
    );
    try std.testing.expectError(
        error.InvalidRuntimeDirectory,
        controlAddress(std.testing.allocator, "run/user/1000"),
    );
}

test "reload parameters encode as an empty object" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try varlink.encode(
        std.testing.allocator,
        &output,
        .{ .method = control.reload_configuration_method, .parameters = Empty{} },
        1024,
    );
    try std.testing.expectEqualStrings(
        "{\"method\":\"dev.rockorager.keywork.compositor.ReloadConfiguration\",\"parameters\":{}}\x00",
        output.items,
    );
}

test "configuration reload errors expose their message" {
    var parsed = try std.json.parseFromSlice(varlink.Reply, std.testing.allocator,
        \\{"error":"dev.rockorager.keywork.compositor.ConfigurationReloadFailed","parameters":{"message":"/tmp/keywork.conf:4: invalid general setting"}}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "/tmp/keywork.conf:4: invalid general setting",
        remoteErrorMessage(parsed.value.@"error".?, parsed.value.parameters).?,
    );
    try std.testing.expect(remoteErrorMessage("org.varlink.service.MethodNotFound", parsed.value.parameters) == null);
}

test "performance statistics decode and render human-readable output" {
    var reply = try std.json.parseFromSlice(varlink.Reply, std.testing.allocator,
        \\{"parameters":{"outputs":[{"name":"eDP-1","width":2880,"height":1800,"refresh_millihertz":120000,"frames_requested":10,"frames_started":9,"frames_presented":8,"frames_discarded":1,"acquire_retries":2,"composited_frames":7,"direct_scanout_candidates":3,"direct_scanout_frames":1,"direct_scanout_rejections":{"no_fullscreen_surface":4,"non_opaque_surface":0,"surface_transform":0,"non_dmabuf":0,"y_inverted":0,"missing_buffer_identity":0,"color_conversion":1,"unsupported_backend":0,"output_unavailable":0,"output_busy":0,"device_inactive":0,"unsupported_format_or_modifier":0,"unsupported_layout":0,"framebuffer_import_failed":0,"page_flip_failed":2},"frames_over_budget":2,"gpu_execution":{"samples":7,"p50_microseconds":2100,"p95_microseconds":4400,"p99_microseconds":6100,"maximum_microseconds":7200},"gpu_composition":{"samples":7,"p50_microseconds":1500,"p95_microseconds":3300,"p99_microseconds":4700,"maximum_microseconds":5400},"gpu_output_encode":{"samples":7,"p50_microseconds":400,"p95_microseconds":700,"p99_microseconds":900,"maximum_microseconds":1100},"request_to_presentation":{"samples":8,"p50_microseconds":8200,"p95_microseconds":9100,"p99_microseconds":16700,"maximum_microseconds":25000},"request_to_render":{"samples":8,"p50_microseconds":1000,"p95_microseconds":1200,"p99_microseconds":1400,"maximum_microseconds":1600},"render_to_commit":{"samples":8,"p50_microseconds":1100,"p95_microseconds":2800,"p99_microseconds":5600,"maximum_microseconds":7000},"commit_to_presentation":{"samples":8,"p50_microseconds":6800,"p95_microseconds":8000,"p99_microseconds":14900,"maximum_microseconds":18000}}]}}
    , .{});
    defer reply.deinit();
    const parsed = try parseStatisticsParameters(std.testing.allocator, reply.value.parameters);
    defer parsed.deinit();
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writeStatistics(&writer.writer, parsed.value.outputs);
    try std.testing.expectEqualStrings(
        \\eDP-1 2880x1800 (120.000 Hz)
        \\  frames: requested 10, started 9, presented 8, discarded 1
        \\  paths: composited 7, direct scanout 1/3 candidates
        \\  direct scanout rejections:
        \\    no fullscreen surface: 4
        \\    color conversion: 1
        \\    page flip failed: 2
        \\  acquire retries: 2, frames over budget: 2
        \\  GPU total: p50 2100us, p95 4400us, p99 6100us, max 7200us (7 samples)
        \\  GPU composition/effects: p50 1500us, p95 3300us, p99 4700us, max 5400us (7 samples)
        \\  GPU output encode: p50 400us, p95 700us, p99 900us, max 1100us (7 samples)
        \\  request -> presentation: p50 8200us, p95 9100us, p99 16700us, max 25000us (8 samples)
        \\  request -> render: p50 1000us, p95 1200us, p99 1400us, max 1600us (8 samples)
        \\  render -> commit: p50 1100us, p95 2800us, p99 5600us, max 7000us (8 samples)
        \\  commit -> presentation: p50 6800us, p95 8000us, p99 14900us, max 18000us (8 samples)
        \\
    , writer.written());
}
