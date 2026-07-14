//! Seat activation and privileged device ownership through libseat.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");

const c = @cImport({
    @cInclude("libseat.h");
});
const wl = wayland.server.wl;

const log = std.log.scoped(.session);

allocator: std.mem.Allocator,
seat: *c.struct_libseat,
event_source: *wl.EventSource,
listeners: std.ArrayList(*Listener),
device_count: usize,
active: bool,
failed: bool,

pub const Listener = struct {
    context: *anyopaque,
    activated: *const fn (*anyopaque) void,
    deactivated: *const fn (*anyopaque) void,
    failed: *const fn (*anyopaque) void,
};

pub const Device = struct {
    id: c_int,
    fd: std.posix.fd_t,
};

const seat_listener: c.struct_libseat_seat_listener = .{
    .enable_seat = handleEnable,
    .disable_seat = handleDisable,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
) !void {
    self.* = .{
        .allocator = allocator,
        .seat = undefined,
        .event_source = undefined,
        .listeners = .empty,
        .device_count = 0,
        .active = false,
        .failed = false,
    };
    errdefer self.listeners.deinit(allocator);

    self.seat = c.libseat_open_seat(&seat_listener, self) orelse
        return error.OpenSeatFailed;
    errdefer _ = c.libseat_close_seat(self.seat);
    const fd = c.libseat_get_fd(self.seat);
    if (fd < 0) return error.GetSeatFdFailed;
    self.event_source = try event_loop.addFd(
        *Self,
        fd,
        .{ .readable = true },
        handleEvent,
        self,
    );
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.device_count == 0);
    std.debug.assert(self.listeners.items.len == 0);
    self.event_source.remove();
    if (c.libseat_close_seat(self.seat) < 0) {
        log.err("failed to close libseat session", .{});
    }
    self.listeners.deinit(self.allocator);
    self.* = undefined;
}

pub fn addListener(self: *Self, listener: *Listener) error{OutOfMemory}!void {
    for (self.listeners.items) |candidate| std.debug.assert(candidate != listener);
    try self.listeners.append(self.allocator, listener);
    if (self.failed) {
        listener.failed(listener.context);
    } else if (self.active) {
        listener.activated(listener.context);
    }
}

pub fn removeListener(self: *Self, listener: *Listener) void {
    for (self.listeners.items, 0..) |candidate, index| {
        if (candidate != listener) continue;
        _ = self.listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

pub fn isActive(self: *const Self) bool {
    return self.active and !self.failed;
}

pub fn name(self: *const Self) []const u8 {
    const value = c.libseat_seat_name(self.seat);
    return if (value == null) "" else std.mem.span(value);
}

pub fn openDevice(self: *Self, path: [:0]const u8) !Device {
    if (!self.isActive()) return error.SessionInactive;
    var fd: c_int = -1;
    const id = c.libseat_open_device(self.seat, path.ptr, &fd);
    if (id < 0 or fd < 0) return error.OpenDeviceFailed;
    self.device_count += 1;
    return .{ .id = id, .fd = fd };
}

pub fn closeDevice(self: *Self, device: Device) !void {
    std.debug.assert(self.device_count > 0);
    if (c.libseat_close_device(self.seat, device.id) < 0) return error.CloseDeviceFailed;
    self.device_count -= 1;
}

fn handleEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail();
        return 0;
    }
    if (mask.readable and c.libseat_dispatch(self.seat, 0) < 0) self.fail();
    return 0;
}

fn handleEnable(_: ?*c.struct_libseat, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    if (self.failed or self.active) return;
    self.active = true;
    for (self.listeners.items) |listener| listener.activated(listener.context);
}

fn handleDisable(seat: ?*c.struct_libseat, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    if (self.active) {
        self.active = false;
        for (self.listeners.items) |listener| listener.deactivated(listener.context);
    }
    if (c.libseat_disable_seat(seat) < 0) self.fail();
}

fn fail(self: *Self) void {
    if (self.failed) return;
    self.failed = true;
    self.active = false;
    log.err("libseat session failed", .{});
    for (self.listeners.items) |listener| listener.failed(listener.context);
}

test "active sessions immediately notify new listeners" {
    const Tracker = struct {
        activated_count: usize = 0,

        fn activated(context: *anyopaque) void {
            const tracker: *@This() = @ptrCast(@alignCast(context));
            tracker.activated_count += 1;
        }

        fn ignored(_: *anyopaque) void {}
    };

    var session: Self = .{
        .allocator = std.testing.allocator,
        .seat = undefined,
        .event_source = undefined,
        .listeners = .empty,
        .device_count = 0,
        .active = true,
        .failed = false,
    };
    defer session.listeners.deinit(std.testing.allocator);
    var tracker: Tracker = .{};
    var listener: Listener = .{
        .context = &tracker,
        .activated = Tracker.activated,
        .deactivated = Tracker.ignored,
        .failed = Tracker.ignored,
    };

    try session.addListener(&listener);
    try std.testing.expectEqual(@as(usize, 1), tracker.activated_count);
    session.removeListener(&listener);
}
