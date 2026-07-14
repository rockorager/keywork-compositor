//! Shared DRM device, connector outputs, and session ownership.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("drm.zig");
const Session = @import("session.zig");

const c = @cImport({
    @cInclude("libudev.h");
    @cInclude("sys/stat.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.drm);

allocator: std.mem.Allocator,
io: std.Io,
session: *Session,
session_listener: Session.Listener,
event_loop: *wl.EventLoop,
event_source: ?*wl.EventSource,
udev: ?*c.struct_udev,
udev_monitor: ?*c.struct_udev_monitor,
hotplug_source: ?*wl.EventSource,
device_path: ?[:0]u8,
device: ?Session.Device,
device_number: ?c.dev_t,
active_outputs: std.ArrayList(*DrmOutput),
retired_outputs: std.ArrayList(*DrmOutput),
listener: ?Listener,
initialized: bool,
failed: bool,

pub const Listener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, *DrmOutput) void,
    removing: *const fn (*anyopaque, *DrmOutput) void,
    failed: *const fn (*anyopaque) void,
};

pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, event_loop: *wl.EventLoop, session: *Session, device_path: ?[]const u8) !void {
    const path = if (device_path) |value| try allocator.dupeSentinel(u8, value, 0) else null;
    self.* = .{
        .allocator = allocator,
        .io = io,
        .session = session,
        .session_listener = .{ .context = self, .activated = handleSessionActivated, .deactivated = handleSessionDeactivated, .failed = handleSessionFailed },
        .event_loop = event_loop,
        .event_source = null,
        .udev = null,
        .udev_monitor = null,
        .hotplug_source = null,
        .device_path = path,
        .device = null,
        .device_number = null,
        .active_outputs = .empty,
        .retired_outputs = .empty,
        .listener = null,
        .initialized = false,
        .failed = false,
    };
    errdefer if (self.device_path) |value| allocator.free(value);
    errdefer {
        self.destroyList(&self.active_outputs);
        self.destroyList(&self.retired_outputs);
        self.active_outputs.deinit(allocator);
        self.retired_outputs.deinit(allocator);
    }
    try session.addListener(&self.session_listener);
    errdefer session.removeListener(&self.session_listener);
    if (!session.isActive()) return error.SessionInactive;
    if (self.failed or self.device == null) return error.DrmInitializationFailed;
    errdefer self.deactivate();
    try self.initHotplugMonitor();
    self.initialized = true;
}

pub fn deinit(self: *Self) void {
    self.listener = null;
    self.initialized = false;
    self.session.removeListener(&self.session_listener);
    self.deinitHotplugMonitor();
    self.deactivate();
    self.destroyList(&self.active_outputs);
    self.active_outputs.deinit(self.allocator);
    self.retired_outputs.deinit(self.allocator);
    if (self.device_path) |value| self.allocator.free(value);
    self.* = undefined;
}

pub fn outputs(self: *Self) []const *DrmOutput {
    return self.active_outputs.items;
}

pub fn setOutputEnabled(self: *Self, output: *DrmOutput, enabled: bool) !void {
    if (self.failed or self.device == null or !self.session.isActive()) {
        return error.SessionInactive;
    }
    if (self.findOutput(output.connector_id) != output) return error.UnknownOutput;
    if (!enabled) try self.waitOutputIdle(output);
    try output.setEnabled(self.device.?.fd, enabled);
}

fn waitOutputIdle(self: *Self, output: *DrmOutput) !void {
    const fd = self.device.?.fd;
    var attempts: u8 = 0;
    while (output.pending != null) : (attempts += 1) {
        if (attempts == 4) return error.PageFlipTimeout;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 1000) == 0) return error.PageFlipTimeout;
        if (poll_fds[0].revents &
            (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
        {
            return error.DeviceDisconnected;
        }
        try output.dispatchEvent(fd);
    }
}

pub fn setListener(self: *Self, listener: Listener) void {
    std.debug.assert(self.listener == null);
    self.listener = listener;
}

pub fn clearListener(self: *Self) void {
    self.listener = null;
}

fn newOutput(self: *Self, fd: std.posix.fd_t, selection: DrmOutput.Selection) !*DrmOutput {
    const output = try self.allocator.create(DrmOutput);
    errdefer self.allocator.destroy(output);
    output.init(self.io, .{ .context = self, .fd = accessFd, .active = accessActive, .fail = accessFail });
    errdefer output.deinit();
    try output.activate(fd, selection, self.device_path.?);
    return output;
}

fn activate(self: *Self) !void {
    std.debug.assert(self.device == null);
    if (self.device_path) |path| {
        log.info("opening DRM device {s}", .{path});
    } else {
        log.info("discovering DRM device", .{});
    }
    const device = if (self.device_path) |path| try self.openDevice(path) else try self.discoverDevice();
    self.device = device;
    errdefer self.deactivate();
    self.device_number = try deviceNumber(device.fd);
    log.info("opened DRM device {s}", .{self.device_path.?});
    const selections = try DrmOutput.selectOutputs(
        self.allocator,
        device.fd,
        self.active_outputs.items,
    );
    defer self.allocator.free(selections);
    log.info("found {d} usable connected DRM output(s)", .{selections.len});
    if (!self.initialized and selections.len == 0) return error.NoConnectedOutput;

    // Existing connector objects remain stable across a VT switch.
    for (selections) |selection| {
        const existing = self.findOutput(selection.connector_id);
        if (existing) |output| {
            try output.activate(device.fd, selection, self.device_path.?);
        } else {
            const output = try self.newOutput(device.fd, selection);
            self.active_outputs.append(self.allocator, output) catch |err| {
                output.deactivate(device.fd);
                output.deinit();
                self.allocator.destroy(output);
                return err;
            };
            if (self.initialized) if (self.listener) |listener| listener.added(listener.context, output);
        }
    }
    var index = self.active_outputs.items.len;
    while (index > 0) {
        index -= 1;
        const output = self.active_outputs.items[index];
        var found = false;
        for (selections) |selection| if (selection.connector_id == output.connector_id) {
            found = true;
            break;
        };
        if (!found) self.removeAt(index, device.fd);
    }
    self.event_source = try self.event_loop.addFd(*Self, device.fd, .{ .readable = true }, handleDrmEvent, self);
}

fn deactivate(self: *Self) void {
    for (self.active_outputs.items) |output| output.notifyDeactivated();
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    const device = self.device orelse return;
    for (self.active_outputs.items) |output| output.deactivate(device.fd);
    self.session.closeDevice(device) catch |err| log.err("failed to close DRM device: {t}", .{err});
    self.device = null;
    self.device_number = null;
    self.destroyList(&self.retired_outputs);
}

fn removeAt(self: *Self, index: usize, fd: std.posix.fd_t) void {
    const output = self.active_outputs.items[index];
    if (self.listener) |listener| listener.removing(listener.context, output);
    output.deactivate(fd);
    output.retire();
    self.retired_outputs.append(self.allocator, output) catch return self.fail(error.OutOfMemory);
    _ = self.active_outputs.orderedRemove(index);
}

fn reconcile(self: *Self) !void {
    const device = self.device.?;
    const selections = try DrmOutput.selectOutputs(
        self.allocator,
        device.fd,
        self.active_outputs.items,
    );
    defer self.allocator.free(selections);
    var topology_changed = selections.len != self.active_outputs.items.len;
    for (selections) |selection| {
        const output = self.findOutput(selection.connector_id) orelse {
            topology_changed = true;
            continue;
        };
        if (!std.meta.eql(output.size, selection.size) or output.crtc_id != selection.crtc_id) {
            return error.OutputChanged;
        }
    }
    if (!topology_changed) return;
    log.info(
        "reconciling DRM hotplug: {d} active output(s), {d} usable connected output(s)",
        .{ self.active_outputs.items.len, selections.len },
    );
    for (selections) |selection| if (self.findOutput(selection.connector_id) == null) {
        const output = try self.newOutput(device.fd, selection);
        self.active_outputs.append(self.allocator, output) catch |err| {
            output.deactivate(device.fd);
            output.deinit();
            self.allocator.destroy(output);
            return err;
        };
        if (self.listener) |listener| listener.added(listener.context, output);
    };
    var index = self.active_outputs.items.len;
    while (index > 0) {
        index -= 1;
        const output = self.active_outputs.items[index];
        var found = false;
        for (selections) |selection| if (selection.connector_id == output.connector_id) {
            found = true;
            break;
        };
        if (!found) self.removeAt(index, device.fd);
    }
}

fn findOutput(self: *Self, connector_id: u32) ?*DrmOutput {
    for (self.active_outputs.items) |output| if (output.connector_id == connector_id) return output;
    return null;
}

fn destroyList(self: *Self, list: *std.ArrayList(*DrmOutput)) void {
    for (list.items) |output| {
        output.deinit();
        self.allocator.destroy(output);
    }
    list.clearRetainingCapacity();
}

fn openDevice(self: *Self, path: [:0]const u8) !Session.Device {
    const device = try self.session.openDevice(path);
    errdefer self.session.closeDevice(device) catch {};
    if (c.drmIsKMS(device.fd) != 1) return error.NotKmsDevice;
    return device;
}

fn discoverDevice(self: *Self) !Session.Device {
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
        const device = self.openDevice(path) catch continue;
        self.device_path = self.allocator.dupeSentinel(u8, path, 0) catch |err| {
            self.session.closeDevice(device) catch {};
            return err;
        };
        return device;
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
    errdefer {
        self.hotplug_source.?.remove();
        self.hotplug_source = null;
    }
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
    if (self.failed) return;
    self.failed = true;
    log.err("DRM device failed: {t}", .{err});
    self.deinitHotplugMonitor();
    self.deactivate();
    if (self.initialized) if (self.listener) |listener| listener.failed(listener.context);
}

fn handleSessionActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.failed) return;
    self.activate() catch |err| return self.fail(err);
    if (self.initialized) for (self.active_outputs.items) |output| output.notifyReady();
}

fn handleSessionDeactivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.deactivate();
}

fn handleSessionFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(error.SessionFailed);
}

fn handleDrmEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") self.fail(error.DeviceDisconnected) else if (mask.readable) if (self.device) |device| {
        if (self.active_outputs.items.len > 0) self.active_outputs.items[0].dispatchEvent(device.fd) catch |err| self.fail(err);
    };
    return 0;
}

fn handleHotplugEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail(error.UdevMonitorFailed);
        return 0;
    }
    if (!mask.readable) return 0;
    const device = c.udev_monitor_receive_device(self.udev_monitor.?) orelse return 0;
    defer _ = c.udev_device_unref(device);
    self.handleDeviceEvent(device) catch |err| self.fail(err);
    return 0;
}

fn handleDeviceEvent(self: *Self, device: *c.struct_udev_device) !void {
    const sysname = std.mem.span(c.udev_device_get_sysname(device) orelse return);
    if (!DrmOutput.isPrimaryNode(sysname)) return;
    const action = std.mem.span(c.udev_device_get_action(device) orelse return);
    const devnode = std.mem.span(c.udev_device_get_devnode(device) orelse return);
    const event_seat = if (c.udev_device_get_property_value(device, "ID_SEAT")) |value|
        std.mem.span(value)
    else
        "seat0";
    if (!std.mem.eql(u8, event_seat, self.session.name())) return;
    if (self.device_number == null or
        c.udev_device_get_devnum(device) != self.device_number.?) return;

    log.info(
        "DRM device event action={s} sysname={s} devnode={s} seat={s}",
        .{ action, sysname, devnode, event_seat },
    );
    if (std.mem.eql(u8, action, "change")) {
        if (self.device != null and self.session.isActive()) try self.reconcile();
    } else if (std.mem.eql(u8, action, "remove")) {
        return error.DeviceDisconnected;
    }
}

fn deviceNumber(fd: std.posix.fd_t) !c.dev_t {
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0) return error.StatDeviceFailed;
    return status.st_rdev;
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
