//! Varlink ingress for compositor policy commands.

const Self = @This();

const std = @import("std");
const command = @import("command.zig");
const control = @import("keywork-control");
const varlink = @import("varlink");
const wayland = @import("wayland");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.control);

pub const socket_name = control.socket_name;
pub const interface_name = control.interface_name;
pub const environment_name = control.environment_name;

const service_interface_name = varlink.service_interface_name;
const interface_description = control.interface_description;
const service_interface_description = varlink.service_interface_description;
const maximum_message_size = 1024 * 1024;
const maximum_output_size = 1024 * 1024;
const Empty = struct {};

allocator: std.mem.Allocator,
io: std.Io,
event_loop: *wl.EventLoop,
executor: Executor,
address: [:0]u8,
listener: std.Io.net.Server,
listen_source: *wl.EventSource,
clients: std.ArrayList(*Client),

pub const Executor = struct {
    context: *anyopaque,
    execute: *const fn (*anyopaque, command.Command) void,
    reload: *const fn (*anyopaque) anyerror!void,
};

const Direction = control.Direction;
const Layout = control.Layout;

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    event_loop: *wl.EventLoop,
    executor: Executor,
    runtime_directory: []const u8,
) !void {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    const address = try std.fmt.allocPrintSentinel(
        allocator,
        "unix:{s}/{s}",
        .{ runtime_directory, socket_name },
        0,
    );
    errdefer allocator.free(address);
    const path = socketPath(address);
    const unix_address = try std.Io.net.UnixAddress.init(path);
    var listener = try listen(io, &unix_address, path);
    errdefer listener.deinit(io);
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    try setNonblocking(listener.socket.handle);
    if (std.c.chmod(path.ptr, 0o600) < 0) return error.SetSocketPermissionsFailed;
    const listen_source = try event_loop.addFd(
        *Self,
        listener.socket.handle,
        .{ .readable = true, .hangup = true, .@"error" = true },
        handleListenEvent,
        self,
    );
    self.* = .{
        .allocator = allocator,
        .io = io,
        .event_loop = event_loop,
        .executor = executor,
        .address = address,
        .listener = listener,
        .listen_source = listen_source,
        .clients = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.listen_source.remove();
    while (self.clients.items.len > 0) {
        self.clients.items[self.clients.items.len - 1].destroy();
    }
    self.clients.deinit(self.allocator);
    self.listener.deinit(self.io);
    std.Io.Dir.deleteFileAbsolute(self.io, socketPath(self.address)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to remove control socket: {t}", .{err}),
    };
    self.allocator.free(self.address);
    self.* = undefined;
}

pub fn varlinkAddress(self: *const Self) []const u8 {
    return self.address;
}

fn socketPath(address: [:0]const u8) [:0]const u8 {
    const prefix = "unix:";
    std.debug.assert(std.mem.startsWith(u8, address, prefix));
    return address[prefix.len.. :0];
}

fn listen(
    io: std.Io,
    address: *const std.Io.net.UnixAddress,
    path: [:0]const u8,
) !std.Io.net.Server {
    return address.listen(io, .{}) catch |err| {
        if (err != error.AddressInUse) return err;
        if (try socketActive(path)) return err;
        std.Io.Dir.deleteFileAbsolute(io, path) catch |delete_err| switch (delete_err) {
            error.FileNotFound => {},
            else => return delete_err,
        };
        return try address.listen(io, .{});
    };
}

fn socketActive(path: [:0]const u8) !bool {
    if (path.len >= @sizeOf(@FieldType(c.sockaddr_un, "sun_path"))) return error.NameTooLong;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketProbeFailed;
    defer _ = std.c.close(fd);
    var address = std.mem.zeroes(c.sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..path.len], path);
    while (true) {
        const result = c.connect(
            fd,
            .{ .__sockaddr_un__ = &address },
            @sizeOf(c.sockaddr_un),
        );
        if (result == 0) return true;
        switch (std.posix.errno(result)) {
            .CONNREFUSED, .NOENT => return false,
            .INTR => continue,
            else => return error.SocketProbeFailed,
        }
    }
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return error.SetNonblockingFailed;
    var status: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    status.NONBLOCK = true;
    if (std.c.fcntl(
        fd,
        std.posix.F.SETFL,
        @as(c_int, @intCast(@as(u32, @bitCast(status)))),
    ) < 0) return error.SetNonblockingFailed;
}

fn handleListenEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.readable) self.acceptClients();
    if (mask.hangup or mask.@"error") log.warn("control listener reported a socket error", .{});
    return 0;
}

fn acceptClients(self: *Self) void {
    while (true) {
        const fd = c.accept4(
            self.listener.socket.handle,
            .{ .__sockaddr__ = null },
            null,
            c.SOCK_CLOEXEC | c.SOCK_NONBLOCK,
        );
        if (fd < 0) {
            switch (std.posix.errno(fd)) {
                .AGAIN => return,
                .INTR, .CONNABORTED => continue,
                else => log.warn("failed to accept control client", .{}),
            }
            return;
        }
        Client.create(self, fd) catch |err| {
            _ = std.c.close(fd);
            log.warn("failed to register control client: {t}", .{err});
        };
    }
}

const Client = struct {
    owner: *Self,
    fd: std.posix.fd_t,
    source: *wl.EventSource,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    output_offset: usize = 0,

    fn create(owner: *Self, fd: std.posix.fd_t) !void {
        const self = try owner.allocator.create(Client);
        errdefer owner.allocator.destroy(self);
        self.* = .{
            .owner = owner,
            .fd = fd,
            .source = undefined,
        };
        self.source = try owner.event_loop.addFd(
            *Client,
            fd,
            .{ .readable = true, .hangup = true, .@"error" = true },
            handleEvent,
            self,
        );
        errdefer self.source.remove();
        try owner.clients.append(owner.allocator, self);
    }

    fn destroy(self: *Client) void {
        const owner = self.owner;
        self.source.remove();
        _ = std.c.close(self.fd);
        for (owner.clients.items, 0..) |client, index| {
            if (client != self) continue;
            _ = owner.clients.swapRemove(index);
            break;
        }
        self.output.deinit(owner.allocator);
        self.input.deinit(owner.allocator);
        owner.allocator.destroy(self);
    }

    fn handleEvent(_: c_int, mask: wl.EventMask, self: *Client) c_int {
        var keep = true;
        if (mask.readable) keep = self.readAvailable();
        if (keep and (mask.writable or self.output_offset < self.output.items.len)) {
            keep = self.writeAvailable();
        }
        if (keep and (mask.hangup or mask.@"error")) keep = false;
        if (!keep) self.destroy();
        return 0;
    }

    fn readAvailable(self: *Client) bool {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = std.c.recv(self.fd, &buffer, buffer.len, 0);
            if (result > 0) {
                const count: usize = @intCast(result);
                if (self.input.items.len + count > maximum_message_size) return false;
                self.input.appendSlice(self.owner.allocator, buffer[0..count]) catch return false;
                processInput(
                    self.owner.allocator,
                    self.owner.executor,
                    &self.input,
                    &self.output,
                ) catch return false;
                continue;
            }
            if (result == 0) return false;
            switch (std.posix.errno(result)) {
                .AGAIN => return self.updateMask(),
                .INTR => continue,
                else => return false,
            }
        }
    }

    fn writeAvailable(self: *Client) bool {
        while (self.output_offset < self.output.items.len) {
            const pending = self.output.items[self.output_offset..];
            const result = std.c.send(self.fd, pending.ptr, pending.len, c.MSG_NOSIGNAL);
            if (result > 0) {
                self.output_offset += @intCast(result);
                continue;
            }
            if (result == 0) return false;
            switch (std.posix.errno(result)) {
                .AGAIN => return self.updateMask(),
                .INTR => continue,
                else => return false,
            }
        }
        self.output.clearRetainingCapacity();
        self.output_offset = 0;
        return self.updateMask();
    }

    fn updateMask(self: *Client) bool {
        self.source.fdUpdate(.{
            .readable = true,
            .writable = self.output_offset < self.output.items.len,
            .hangup = true,
            .@"error" = true,
        }) catch return false;
        return true;
    }
};

fn processInput(
    allocator: std.mem.Allocator,
    executor: Executor,
    input: *std.ArrayList(u8),
    output: *std.ArrayList(u8),
) !void {
    var frames: varlink.FrameIterator = .init(input.items);
    while (try frames.next()) |message| try handleMessage(allocator, executor, message, output);
    const consumed = frames.consumed();
    if (consumed == 0) return;
    const remaining = input.items[consumed..];
    @memmove(input.items[0..remaining.len], remaining);
    input.shrinkRetainingCapacity(remaining.len);
}

fn handleMessage(
    allocator: std.mem.Allocator,
    executor: Executor,
    message: []const u8,
    output: *std.ArrayList(u8),
) !void {
    const parsed = try std.json.parseFromSlice(varlink.Call, allocator, message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const call = parsed.value;
    if (call.upgrade) {
        if (!call.oneway) try writeInvalidParameter(allocator, output, "upgrade");
        return;
    }

    if (std.mem.eql(u8, call.method, service_interface_name ++ ".GetInfo")) {
        if (!emptyParameters(call.parameters)) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "parameters");
            return;
        }
        if (!call.oneway) try writeMessage(allocator, output, .{ .parameters = .{
            .vendor = "rockorager",
            .product = "Keywork compositor",
            .version = "0.0.0",
            .url = "https://github.com/rockorager/keywork-compositor",
            .interfaces = [_][]const u8{ service_interface_name, interface_name },
        } });
        return;
    }
    if (std.mem.eql(u8, call.method, service_interface_name ++ ".GetInterfaceDescription")) {
        const parameters = parseParameters(struct { interface: []const u8 }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "interface");
            return;
        };
        defer parameters.deinit();
        const requested = parameters.value.interface;
        const description: ?[]const u8 = if (std.mem.eql(u8, requested, service_interface_name))
            service_interface_description
        else if (std.mem.eql(u8, requested, interface_name))
            interface_description
        else
            null;
        if (description) |value| {
            if (!call.oneway) try writeMessage(allocator, output, .{
                .parameters = .{ .description = value },
            });
        } else if (!call.oneway) {
            try writeMessage(allocator, output, .{
                .@"error" = service_interface_name ++ ".InterfaceNotFound",
                .parameters = .{ .interface = requested },
            });
        }
        return;
    }
    if (std.mem.eql(u8, call.method, control.focus_method)) {
        const parameters = parseParameters(struct { direction: Direction }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "direction");
            return;
        };
        defer parameters.deinit();
        executor.execute(executor.context, focusCommand(parameters.value.direction));
        if (!call.oneway) try writeSuccess(allocator, output);
        return;
    }
    if (std.mem.eql(u8, call.method, control.move_focused_method)) {
        const parameters = parseParameters(struct { direction: Direction }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "direction");
            return;
        };
        defer parameters.deinit();
        executor.execute(executor.context, moveCommand(parameters.value.direction));
        if (!call.oneway) try writeSuccess(allocator, output);
        return;
    }
    if (std.mem.eql(u8, call.method, control.set_layout_method)) {
        const parameters = parseParameters(struct { layout: Layout }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "layout");
            return;
        };
        defer parameters.deinit();
        executor.execute(executor.context, switch (parameters.value.layout) {
            .master_stack => .layout_master_stack,
            .dwindle => .layout_dwindle,
            .scrolling => .layout_scrolling,
        });
        if (!call.oneway) try writeSuccess(allocator, output);
        return;
    }
    if (std.mem.eql(u8, call.method, control.switch_workspace_method)) {
        const parameters = parseParameters(struct { workspace: i64 }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "workspace");
            return;
        };
        defer parameters.deinit();
        if (!control.validWorkspace(parameters.value.workspace)) {
            if (!call.oneway) try writeInvalidWorkspace(allocator, output, parameters.value.workspace);
            return;
        }
        executor.execute(executor.context, .{ .switch_workspace = @intCast(parameters.value.workspace) });
        if (!call.oneway) try writeSuccess(allocator, output);
        return;
    }
    if (std.mem.eql(u8, call.method, control.move_focused_to_workspace_method)) {
        const parameters = parseParameters(struct { workspace: i64 }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "workspace");
            return;
        };
        defer parameters.deinit();
        if (!control.validWorkspace(parameters.value.workspace)) {
            if (!call.oneway) try writeInvalidWorkspace(allocator, output, parameters.value.workspace);
            return;
        }
        executor.execute(executor.context, .{ .move_to_workspace = @intCast(parameters.value.workspace) });
        if (!call.oneway) try writeSuccess(allocator, output);
        return;
    }
    if (std.mem.eql(u8, call.method, control.reload_configuration_method)) {
        if (!emptyParameters(call.parameters)) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "parameters");
            return;
        }
        executor.reload(executor.context) catch {
            if (!call.oneway) try writeConfigurationReloadFailed(allocator, output);
            return;
        };
        if (!call.oneway) try writeSuccess(allocator, output);
        return;
    }

    if (!call.oneway) try writeMessage(allocator, output, .{
        .@"error" = service_interface_name ++ ".MethodNotFound",
        .parameters = .{ .method = call.method },
    });
}

fn parseParameters(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !std.json.Parsed(T) {
    return std.json.parseFromValue(T, allocator, value orelse return error.MissingField, .{});
}

fn emptyParameters(value: ?std.json.Value) bool {
    const parameters = value orelse return true;
    return switch (parameters) {
        .object => |object| object.count() == 0,
        else => false,
    };
}

fn focusCommand(direction: Direction) command.Command {
    return switch (direction) {
        .next => .focus_next,
        .previous => .focus_previous,
        .left => .{ .focus_direction = .left },
        .down => .{ .focus_direction = .down },
        .up => .{ .focus_direction = .up },
        .right => .{ .focus_direction = .right },
    };
}

fn moveCommand(direction: Direction) command.Command {
    return switch (direction) {
        .next => .move_focused_next,
        .previous => .move_focused_previous,
        .left => .{ .move_focused_direction = .left },
        .down => .{ .move_focused_direction = .down },
        .up => .{ .move_focused_direction = .up },
        .right => .{ .move_focused_direction = .right },
    };
}

fn writeSuccess(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    try writeMessage(allocator, output, .{ .parameters = Empty{} });
}

fn writeInvalidParameter(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    parameter: []const u8,
) !void {
    try writeMessage(allocator, output, .{
        .@"error" = service_interface_name ++ ".InvalidParameter",
        .parameters = .{ .parameter = parameter },
    });
}

fn writeInvalidWorkspace(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    workspace: i64,
) !void {
    try writeMessage(allocator, output, .{
        .@"error" = interface_name ++ ".InvalidWorkspace",
        .parameters = .{ .workspace = workspace },
    });
}

fn writeConfigurationReloadFailed(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
) !void {
    try writeMessage(allocator, output, .{
        .@"error" = interface_name ++ ".ConfigurationReloadFailed",
        .parameters = Empty{},
    });
}

fn writeMessage(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: anytype,
) !void {
    try varlink.encode(allocator, output, value, maximum_output_size);
}

const Recorder = struct {
    commands: std.ArrayList(command.Command) = .empty,
    reload_count: usize = 0,
    reload_error: ?anyerror = null,

    fn deinit(self: *Recorder) void {
        self.commands.deinit(std.testing.allocator);
    }

    fn executor(self: *Recorder) Executor {
        return .{ .context = self, .execute = execute, .reload = reload };
    }

    fn execute(context: *anyopaque, value: command.Command) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.commands.append(std.testing.allocator, value) catch unreachable;
    }

    fn reload(context: *anyopaque) !void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.reload_count += 1;
        if (self.reload_error) |err| return err;
    }
};

test "fragmented and coalesced calls execute typed commands in order" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    const focus =
        \\{"method":"dev.rockorager.keywork.compositor.Focus","parameters":{"direction":"left"}}
    ;
    const workspace =
        \\{"method":"dev.rockorager.keywork.compositor.SwitchWorkspace","parameters":{"workspace":3}}
    ;
    try input.appendSlice(std.testing.allocator, focus[0..20]);
    try processInput(std.testing.allocator, recorder.executor(), &input, &output);
    try std.testing.expectEqual(@as(usize, 0), recorder.commands.items.len);
    try input.appendSlice(std.testing.allocator, focus[20..]);
    try input.append(std.testing.allocator, 0);
    try input.appendSlice(std.testing.allocator, workspace);
    try input.append(std.testing.allocator, 0);
    try processInput(std.testing.allocator, recorder.executor(), &input, &output);

    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    try std.testing.expect(std.meta.eql(
        command.Command{ .focus_direction = .left },
        recorder.commands.items[0],
    ));
    try std.testing.expect(std.meta.eql(
        command.Command{ .switch_workspace = 3 },
        recorder.commands.items[1],
    ));
    try std.testing.expectEqualStrings(
        "{\"parameters\":{}}\x00{\"parameters\":{}}\x00",
        output.items,
    );
}

test "oneway calls suppress replies and invalid workspaces return typed errors" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SetLayout\",\"parameters\":{\"layout\":\"dwindle\"},\"oneway\":true}",
        &output,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), output.items.len);

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SwitchWorkspace\",\"parameters\":{\"workspace\":0}}",
        &output,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqualStrings(
        "{\"error\":\"dev.rockorager.keywork.compositor.InvalidWorkspace\",\"parameters\":{\"workspace\":0}}\x00",
        output.items,
    );
}

test "configuration reload returns success or a typed failure" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    const call =
        \\{"method":"dev.rockorager.keywork.compositor.ReloadConfiguration","parameters":{}}
    ;
    try handleMessage(std.testing.allocator, recorder.executor(), call, &output);
    try std.testing.expectEqual(@as(usize, 1), recorder.reload_count);
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);

    output.clearRetainingCapacity();
    recorder.reload_error = error.InvalidConfiguration;
    try handleMessage(std.testing.allocator, recorder.executor(), call, &output);
    try std.testing.expectEqual(@as(usize, 2), recorder.reload_count);
    try std.testing.expectEqualStrings(
        "{\"error\":\"dev.rockorager.keywork.compositor.ConfigurationReloadFailed\",\"parameters\":{}}\x00",
        output.items,
    );
}

test "standard service introspection returns the control interface" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"org.varlink.service.GetInterfaceDescription\",\"parameters\":{\"interface\":\"dev.rockorager.keywork.compositor\"}}",
        &output,
    );
    const parsed = try std.json.parseFromSlice(
        struct { parameters: struct { description: []const u8 } },
        std.testing.allocator,
        output.items[0 .. output.items.len - 1],
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(interface_description, parsed.value.parameters.description);
}
