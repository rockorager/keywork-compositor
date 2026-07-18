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
    \\          switch-workspace WORKSPACE | move-focused-to-workspace WORKSPACE
    \\          reload | quit
    \\directions: next, previous, left, down, up, right
    \\targets: focused
    \\layouts: master-stack, dwindle, scrolling
    \\
;

const Command = union(enum) {
    focus: control.Direction,
    move_focused: control.Direction,
    close: control.WindowTarget,
    set_layout: control.Layout,
    switch_workspace: i64,
    move_to_workspace: i64,
    reload,
    quit,
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

    var allocated_address: ?[]u8 = null;
    defer if (allocated_address) |value| init.gpa.free(value);
    const address = init.environ_map.get(control.environment_name) orelse address: {
        const runtime_directory = init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
        if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
        allocated_address = try std.fmt.allocPrint(init.gpa, "unix:{s}/{s}", .{ runtime_directory, control.socket_name });
        break :address allocated_address.?;
    };
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
        .set_layout => |layout| try client.call(control.set_layout_method, .{ .layout = layout }),
        .switch_workspace => |workspace| try client.call(control.switch_workspace_method, .{ .workspace = workspace }),
        .move_to_workspace => |workspace| try client.call(control.move_focused_to_workspace_method, .{ .workspace = workspace }),
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
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "reload")) return .reload;
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "quit")) return .quit;
    if (arguments.len != 2) return error.InvalidArguments;
    const name = arguments[0];
    const value = arguments[1];
    if (std.mem.eql(u8, name, "focus")) return .{ .focus = parseDirection(value) orelse return error.InvalidDirection };
    if (std.mem.eql(u8, name, "move-focused")) return .{ .move_focused = parseDirection(value) orelse return error.InvalidDirection };
    if (std.mem.eql(u8, name, "close")) return .{ .close = parseWindowTarget(value) orelse return error.InvalidWindowTarget };
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
    try std.testing.expectEqual(control.Layout.master_stack, (try parse(&.{ "set-layout", "master-stack" })).set_layout);
    try std.testing.expectEqual(@as(i64, 10), (try parse(&.{ "switch-workspace", "10" })).switch_workspace);
    try std.testing.expectEqual(Command.reload, try parse(&.{"reload"}));
    try std.testing.expectEqual(Command.quit, try parse(&.{"quit"}));
    try std.testing.expectError(error.InvalidWorkspace, parse(&.{ "switch-workspace", "11" }));
    try std.testing.expectError(error.InvalidDirection, parse(&.{ "focus", "sideways" }));
    try std.testing.expectError(error.InvalidWindowTarget, parse(&.{ "close", "all" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "unknown", "value" }));
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
