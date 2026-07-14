//! Shared DRM device and session ownership.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("drm.zig");
const Session = @import("session.zig");

const c = @cImport({
    @cInclude("libudev.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.drm);

allocator: std.mem.Allocator,
session: *Session,
session_listener: Session.Listener,
event_loop: *wl.EventLoop,
event_source: ?*wl.EventSource,
udev: ?*c.struct_udev,
udev_monitor: ?*c.struct_udev_monitor,
hotplug_source: ?*wl.EventSource,
device_path: ?[:0]u8,
device: ?Session.Device,
output: DrmOutput,
initialized: bool,
failed: bool,

const OpenedDevice = struct {
    device: Session.Device,
    selection: DrmOutput.Selection,
};

pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, event_loop: *wl.EventLoop, session: *Session, device_path: ?[]const u8) !void {
    const path = if (device_path) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    self.* = .{
        .allocator = allocator,
        .session = session,
        .session_listener = .{ .context = self, .activated = handleSessionActivated, .deactivated = handleSessionDeactivated, .failed = handleSessionFailed },
        .event_loop = event_loop,
        .event_source = null,
        .udev = null,
        .udev_monitor = null,
        .hotplug_source = null,
        .device_path = path,
        .device = null,
        .output = undefined,
        .initialized = false,
        .failed = false,
    };
    self.output.init(io, .{ .context = self, .fd = accessFd, .active = accessActive, .fail = accessFail });
    errdefer self.output.deinit();
    errdefer if (self.device_path) |value| allocator.free(value);
    try session.addListener(&self.session_listener);
    errdefer session.removeListener(&self.session_listener);
    if (!session.isActive()) return error.SessionInactive;
    if (self.failed or self.device == null) return error.DrmInitializationFailed;
    errdefer self.deactivate();
    try self.initHotplugMonitor();
    self.initialized = true;
}

pub fn deinit(self: *Self) void {
    self.initialized = false;
    self.session.removeListener(&self.session_listener);
    self.deinitHotplugMonitor();
    self.deactivate();
    self.output.deinit();
    if (self.device_path) |value| self.allocator.free(value);
    self.* = undefined;
}

fn activate(self: *Self) !void {
    std.debug.assert(self.device == null);
    const opened = if (self.device_path) |path| try self.openDevice(path) else try self.discoverDevice();
    self.device = opened.device;
    errdefer {
        self.session.closeDevice(opened.device) catch {};
        self.device = null;
    }
    try self.output.activate(opened.device.fd, opened.selection, self.device_path.?);
    errdefer self.output.deactivate(opened.device.fd);
    self.event_source = try self.event_loop.addFd(*Self, opened.device.fd, .{ .readable = true }, handleDrmEvent, self);
}

fn deactivate(self: *Self) void {
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    const device = self.device orelse return;
    self.output.deactivate(device.fd);
    self.session.closeDevice(device) catch |err| log.err("failed to close DRM device: {t}", .{err});
    self.device = null;
}

fn openDevice(self: *Self, path: [:0]const u8) !OpenedDevice {
    const device = try self.session.openDevice(path);
    errdefer self.session.closeDevice(device) catch {};
    if (c.drmIsKMS(device.fd) != 1) return error.NotKmsDevice;
    return .{ .device = device, .selection = try DrmOutput.selectOutput(device.fd) };
}

fn discoverDevice(self: *Self) !OpenedDevice {
    const udev = c.udev_new() orelse return error.UdevContextFailed;
    defer _ = c.udev_unref(udev);
    const enumerate = c.udev_enumerate_new(udev) orelse return error.UdevEnumerateFailed;
    defer _ = c.udev_enumerate_unref(enumerate);
    if (c.udev_enumerate_add_match_subsystem(enumerate, "drm") != 0 or c.udev_enumerate_scan_devices(enumerate) != 0) return error.UdevEnumerateFailed;
    var entry = c.udev_enumerate_get_list_entry(enumerate);
    while (entry) |current| : (entry = c.udev_list_entry_get_next(current)) {
        const syspath = c.udev_list_entry_get_name(current) orelse continue;
        const udev_device = c.udev_device_new_from_syspath(udev, syspath) orelse continue;
        defer _ = c.udev_device_unref(udev_device);
        const path = std.mem.span(c.udev_device_get_devnode(udev_device) orelse continue);
        if (!DrmOutput.isPrimaryNode(path)) continue;
        const opened = self.openDevice(path) catch continue;
        self.device_path = self.allocator.dupeSentinel(u8, path, 0) catch |err| {
            self.session.closeDevice(opened.device) catch {};
            return err;
        };
        return opened;
    }
    return error.NoDrmDevice;
}

fn initHotplugMonitor(self: *Self) !void {
    const udev = c.udev_new() orelse return error.UdevContextFailed;
    self.udev = udev;
    errdefer {
        _ = c.udev_unref(udev);
        self.udev = null;
    }
    const monitor = c.udev_monitor_new_from_netlink(udev, "udev") orelse return error.UdevMonitorFailed;
    self.udev_monitor = monitor;
    errdefer {
        _ = c.udev_monitor_unref(monitor);
        self.udev_monitor = null;
    }
    if (c.udev_monitor_filter_add_match_subsystem_devtype(monitor, "drm", null) != 0 or c.udev_monitor_enable_receiving(monitor) != 0) return error.UdevMonitorFailed;
    const fd = c.udev_monitor_get_fd(monitor);
    if (fd < 0) return error.UdevMonitorFailed;
    self.hotplug_source = try self.event_loop.addFd(*Self, fd, .{ .readable = true }, handleHotplugEvent, self);
}

fn deinitHotplugMonitor(self: *Self) void {
    if (self.hotplug_source) |source| {
        source.remove();
        self.hotplug_source = null;
    }
    if (self.udev_monitor) |monitor| {
        _ = c.udev_monitor_unref(monitor);
        self.udev_monitor = null;
    }
    if (self.udev) |udev| {
        _ = c.udev_unref(udev);
        self.udev = null;
    }
}

fn fail(self: *Self, err: anyerror) void {
    if (!self.output.beginFail(err)) return;
    self.failed = true;
    self.deinitHotplugMonitor();
    self.deactivate();
    if (self.initialized) self.output.notifyClose();
}

fn handleSessionActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.failed) return;
    self.activate() catch |err| {
        self.fail(err);
        return;
    };
    if (self.initialized) self.output.notifyReady();
}

fn handleSessionDeactivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.output.notifyDeactivated();
    self.deactivate();
}

fn handleSessionFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(error.SessionFailed);
}

fn handleDrmEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") self.fail(error.DeviceDisconnected) else if (mask.readable) self.output.dispatchEvent(self.device.?.fd) catch |err| self.fail(err);
    return 0;
}

fn handleHotplugEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail(error.UdevMonitorFailed);
        return 0;
    }
    if (!mask.readable) return 0;
    var received = false;
    while (c.udev_monitor_receive_device(self.udev_monitor.?)) |device| {
        received = true;
        _ = c.udev_device_unref(device);
    }
    if (received) if (self.device) |device| if (!DrmOutput.connectorAvailable(device.fd, self.output.connector_id, self.output.size)) self.fail(error.OutputDisconnected);
    return 0;
}

fn accessFd(context: *anyopaque) ?std.posix.fd_t {
    const self: *Self = @ptrCast(@alignCast(context));
    return if (self.device) |device| device.fd else null;
}

fn accessActive(context: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return !self.failed and self.session.isActive() and self.device != null;
}

fn accessFail(context: *anyopaque, err: anyerror) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(err);
}
