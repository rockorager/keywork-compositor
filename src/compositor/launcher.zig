//! Application launching through transient systemd user services.

const Self = @This();

const std = @import("std");
const varlink = @import("varlink");

const log = std.log.scoped(.launcher);
const manager_interface = "io.systemd.Unit";
const start_transient_method = manager_interface ++ ".StartTransient";
const start_transient_signature = "method StartTransient(";
const manager_socket_suffix = "/systemd/io.systemd.Manager";

allocator: std.mem.Allocator,
io: std.Io,
environ_map: *const std.process.Environ.Map,
client: ?varlink.Client = null,
capability: Capability = .unknown,
next_unit_id: u64 = 1,

const Capability = enum {
    unknown,
    varlink,
    systemd_run,
};

const StartTransientParameters = struct {
    context: Context,

    const Context = struct {
        ID: []const u8,
        Service: Service,
    };

    const Service = struct {
        Type: []const u8 = "oneshot",
        ExecStart: []const ExecCommand,
    };

    const ExecCommand = struct {
        path: []const u8,
        arguments: []const []const u8,
    };
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) Self {
    var self: Self = .{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
    };
    self.discover();
    return self;
}

pub fn deinit(self: *Self) void {
    self.clearClient();
    self.* = undefined;
}

pub fn launch(self: *Self, argv: []const []const u8) !void {
    try validateArgv(argv);
    if (self.capability == .unknown) self.discover();
    switch (self.capability) {
        .unknown => unreachable,
        .systemd_run => try self.launchWithSystemdRun(argv),
        .varlink => self.launchWithVarlink(argv) catch |err| {
            // A disconnected persistent connection is ambiguous: systemd may
            // have accepted the request before the reply was lost. Re-probe
            // on the next launch, but never risk duplicating this one.
            self.clearClient();
            self.capability = .unknown;
            return err;
        },
    }
}

fn discover(self: *Self) void {
    std.debug.assert(self.client == null);
    const runtime_directory = self.environ_map.get("XDG_RUNTIME_DIR") orelse {
        self.useSystemdRun("XDG_RUNTIME_DIR is unset");
        return;
    };
    if (!std.fs.path.isAbsolute(runtime_directory)) {
        self.useSystemdRun("XDG_RUNTIME_DIR is not absolute");
        return;
    }
    const address = std.fmt.allocPrint(
        self.allocator,
        "unix:{s}{s}",
        .{ runtime_directory, manager_socket_suffix },
    ) catch {
        self.useSystemdRun("could not allocate the manager address");
        return;
    };
    defer self.allocator.free(address);
    self.client = varlink.Client.connect(self.allocator, self.io, address) catch |err| {
        log.info("systemd Varlink manager unavailable ({t}); using systemd-run", .{err});
        self.capability = .systemd_run;
        return;
    };
    var reply = self.client.?.call(
        varlink.service_interface_name ++ ".GetInterfaceDescription",
        .{ .interface = manager_interface },
    ) catch |err| {
        log.info("could not probe systemd's transient-unit API ({t}); using systemd-run", .{err});
        self.clearClient();
        self.capability = .systemd_run;
        return;
    };
    defer reply.deinit();
    if (reply.value.@"error") |name| {
        log.info("systemd's transient-unit API is unavailable ({s}); using systemd-run", .{name});
        self.clearClient();
        self.capability = .systemd_run;
        return;
    }
    const parameters = reply.value.parameters orelse {
        self.clearClient();
        self.useSystemdRun("systemd returned no interface description");
        return;
    };
    const description_value = switch (parameters) {
        .object => |object| object.get("description") orelse {
            self.clearClient();
            self.useSystemdRun("systemd returned no interface description");
            return;
        },
        else => {
            self.clearClient();
            self.useSystemdRun("systemd returned an invalid interface description");
            return;
        },
    };
    const description = switch (description_value) {
        .string => |value| value,
        else => {
            self.clearClient();
            self.useSystemdRun("systemd returned an invalid interface description");
            return;
        },
    };
    if (std.mem.indexOf(u8, description, start_transient_signature) == null) {
        self.clearClient();
        self.useSystemdRun("systemd does not implement StartTransient");
        return;
    }
    self.capability = .varlink;
    log.info("application launching will use systemd Varlink", .{});
}

fn launchWithVarlink(self: *Self, argv: []const []const u8) !void {
    var unit_name_buffer: [96]u8 = undefined;
    const unit_name = try std.fmt.bufPrint(
        &unit_name_buffer,
        "keywork-app-{d}-{d}.service",
        .{ std.c.getpid(), self.next_unit_id },
    );
    self.next_unit_id +%= 1;
    const commands = [_]StartTransientParameters.ExecCommand{.{
        .path = argv[0],
        .arguments = argv,
    }};
    var reply = try self.client.?.call(start_transient_method, StartTransientParameters{
        .context = .{
            .ID = unit_name,
            .Service = .{ .ExecStart = &commands },
        },
    });
    defer reply.deinit();
    if (reply.value.@"error") |name| {
        if (unsupportedError(name)) {
            self.clearClient();
            self.capability = .systemd_run;
            return self.launchWithSystemdRun(argv);
        }
        log.err("systemd rejected launch request for {s}: {s}", .{ argv[0], name });
        return error.SystemdLaunchRejected;
    }
    if (reply.value.continues) return error.UnexpectedContinuation;
    log.info("launched {s} as {s}", .{ argv[0], unit_name });
}

fn launchWithSystemdRun(self: *Self, argv: []const []const u8) !void {
    const prefix = [_][]const u8{ "systemd-run", "--user", "--collect", "--" };
    const child_argv = try self.allocator.alloc([]const u8, prefix.len + argv.len);
    defer self.allocator.free(child_argv);
    @memcpy(child_argv[0..prefix.len], &prefix);
    @memcpy(child_argv[prefix.len..], argv);
    const child = try std.process.spawn(self.io, .{
        .argv = child_argv,
        .environ_map = self.environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    log.info("submitted {s} through systemd-run (pid {d})", .{ argv[0], child.id.? });
}

fn useSystemdRun(self: *Self, reason: []const u8) void {
    log.info("{s}; using systemd-run", .{reason});
    self.capability = .systemd_run;
}

fn clearClient(self: *Self) void {
    if (self.client) |*client| client.deinit();
    self.client = null;
}

fn unsupportedError(name: []const u8) bool {
    return std.mem.eql(u8, name, "org.varlink.service.InterfaceNotFound") or
        std.mem.eql(u8, name, "org.varlink.service.MethodNotFound") or
        std.mem.eql(u8, name, "org.varlink.service.MethodNotImplemented");
}

pub fn validateArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv[0].len == 0) return error.InvalidCommand;
    if (!std.fs.path.isAbsolute(argv[0]) and std.mem.indexOfScalar(u8, argv[0], '/') != null) {
        return error.InvalidExecutable;
    }
    for (argv) |argument| if (std.mem.indexOfScalar(u8, argument, 0) != null) {
        return error.InvalidArgument;
    };
}

test "launcher accepts absolute and search-path executables only" {
    try validateArgv(&.{ "foot", "--server" });
    try validateArgv(&.{"/usr/bin/foot"});
    try std.testing.expectError(error.InvalidCommand, validateArgv(&.{}));
    try std.testing.expectError(error.InvalidCommand, validateArgv(&.{""}));
    try std.testing.expectError(error.InvalidExecutable, validateArgv(&.{"./foot"}));
    try std.testing.expectError(error.InvalidExecutable, validateArgv(&.{"bin/foot"}));
    try std.testing.expectError(error.InvalidArgument, validateArgv(&.{ "foot", "bad\x00argument" }));
}

test "only capability errors permit an unambiguous fallback" {
    try std.testing.expect(unsupportedError("org.varlink.service.MethodNotFound"));
    try std.testing.expect(!unsupportedError("io.systemd.Unit.UnitExists"));
    try std.testing.expect(!unsupportedError("org.varlink.service.InvalidParameter"));
}
