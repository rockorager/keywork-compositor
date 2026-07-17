//! systemd readiness and desktop activation environment publication.

const Self = @This();

const std = @import("std");

const c = @cImport({
    @cInclude("systemd/sd-daemon.h");
});
const log = std.log.scoped(.systemd);

const current_desktop = "XDG_CURRENT_DESKTOP=keywork";
const session_desktop = "XDG_SESSION_DESKTOP=keywork";
const session_type = "XDG_SESSION_TYPE=wayland";
const max_assignments = 6;

io: std.Io,
notify_enabled: bool,
session_enabled: bool,

pub fn init(io: std.Io, environ_map: *const std.process.Environ.Map) Self {
    const notify_enabled = environ_map.get("NOTIFY_SOCKET") != null;
    return .{
        .io = io,
        .notify_enabled = notify_enabled,
        .session_enabled = notify_enabled and std.mem.eql(
            u8,
            environ_map.get("KEYWORK_SYSTEMD_SESSION") orelse "",
            "1",
        ),
    };
}

pub fn ready(
    self: *const Self,
    wayland_display: []const u8,
    control_address: []const u8,
    cursor_size: []const u8,
) !void {
    if (self.session_enabled) {
        var display_buffer: [64]u8 = undefined;
        const display = try std.fmt.bufPrint(
            &display_buffer,
            "WAYLAND_DISPLAY={s}",
            .{wayland_display},
        );
        var control_buffer: [256]u8 = undefined;
        const control = try std.fmt.bufPrint(
            &control_buffer,
            "KEYWORK_CONTROL={s}",
            .{control_address},
        );
        var cursor_size_buffer: [64]u8 = undefined;
        const cursor_size_assignment = try std.fmt.bufPrint(
            &cursor_size_buffer,
            "XCURSOR_SIZE={s}",
            .{cursor_size},
        );
        try self.updateActivationEnvironment(&.{
            display,
            control,
            current_desktop,
            session_desktop,
            session_type,
            cursor_size_assignment,
        });
    }

    if (!self.notify_enabled) return;
    const notified = c.sd_notify(0, "READY=1");
    if (notified <= 0) return error.NotifyFailed;
}

pub fn publishDisplay(self: *const Self, display_name: []const u8) !void {
    if (!self.session_enabled) return;

    var display_buffer: [32]u8 = undefined;
    const display = try std.fmt.bufPrint(
        &display_buffer,
        "DISPLAY={s}",
        .{display_name},
    );
    try self.updateActivationEnvironment(&.{display});
}

fn updateActivationEnvironment(self: *const Self, assignments: []const []const u8) !void {
    std.debug.assert(assignments.len > 0 and assignments.len <= max_assignments);

    var systemctl_argv: [3 + max_assignments][]const u8 = undefined;
    systemctl_argv[0] = "systemctl";
    systemctl_argv[1] = "--user";
    systemctl_argv[2] = "set-environment";
    @memcpy(systemctl_argv[3 .. 3 + assignments.len], assignments);
    if (!try run(self.io, systemctl_argv[0 .. 3 + assignments.len])) {
        return error.SystemdEnvironmentUpdateFailed;
    }

    var dbus_argv: [1 + max_assignments][]const u8 = undefined;
    dbus_argv[0] = "dbus-update-activation-environment";
    @memcpy(dbus_argv[1 .. 1 + assignments.len], assignments);
    const updated = run(self.io, dbus_argv[0 .. 1 + assignments.len]) catch |err| {
        log.warn("could not update the D-Bus activation environment: {t}", .{err});
        return;
    };
    if (!updated) {
        // dbus-broker services still receive the systemd manager environment.
        log.warn("dbus-update-activation-environment exited unsuccessfully", .{});
    }
}

fn run(io: std.Io, argv: []const []const u8) !bool {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |status| status == 0,
        else => false,
    };
}

test "session publication requires notification and explicit ownership" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    var systemd: Self = .init(std.testing.io, &environ_map);
    try std.testing.expect(!systemd.notify_enabled);
    try std.testing.expect(!systemd.session_enabled);

    try environ_map.put("NOTIFY_SOCKET", "/run/notify");
    systemd = .init(std.testing.io, &environ_map);
    try std.testing.expect(systemd.notify_enabled);
    try std.testing.expect(!systemd.session_enabled);

    try environ_map.put("KEYWORK_SYSTEMD_SESSION", "1");
    systemd = .init(std.testing.io, &environ_map);
    try std.testing.expect(systemd.notify_enabled);
    try std.testing.expect(systemd.session_enabled);
}
