//! Compositor-owned native input device registry.

const Self = @This();

const std = @import("std");
const NativeInput = @import("backend/native_input.zig");
const log = std.log.scoped(.input_manager);

allocator: std.mem.Allocator,
native_input: ?*NativeInput,
devices: std.ArrayList(*Device),
device_listeners: std.ArrayList(*DeviceListener),

pub const default_seat_name: [:0]const u8 = "default";

pub const Device = struct {
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    device_type: NativeInput.DeviceType,
    name: [:0]u8,
    seat_name: [:0]const u8 = default_seat_name,
};

pub const DeviceListener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, *Device) void,
    removed: *const fn (*anyopaque, *Device) void,
};

pub fn init(self: *Self, allocator: std.mem.Allocator, native_input: ?*NativeInput) !void {
    self.* = .{
        .allocator = allocator,
        .native_input = native_input,
        .devices = .empty,
        .device_listeners = .empty,
    };
    if (native_input) |input| {
        input.setDeviceListener(.{
            .context = self,
            .added = deviceAdded,
            .removed = deviceRemoved,
        });
    }
}

pub fn detachNativeInput(self: *Self) void {
    const native_input = self.native_input orelse return;
    native_input.clearDeviceListener();
    self.native_input = null;
    while (self.devices.items.len > 0) self.removeDevice(self.devices.items[0]);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.native_input == null);
    std.debug.assert(self.devices.items.len == 0);
    std.debug.assert(self.device_listeners.items.len == 0);
    self.devices.deinit(self.allocator);
    self.device_listeners.deinit(self.allocator);
    self.* = undefined;
}

pub fn findDevice(self: *Self, id: NativeInput.DeviceId) ?*Device {
    for (self.devices.items) |device| if (device.id == id) return device;
    return null;
}

pub const DeviceIterator = struct {
    devices: []const *Device,
    index: usize = 0,

    pub fn next(self: *DeviceIterator) ?*Device {
        if (self.index == self.devices.len) return null;
        defer self.index += 1;
        return self.devices[self.index];
    }
};

pub fn deviceIterator(self: *Self) DeviceIterator {
    return .{ .devices = self.devices.items };
}

pub fn addDeviceListener(self: *Self, listener: *DeviceListener) error{OutOfMemory}!void {
    for (self.device_listeners.items) |registered| std.debug.assert(registered != listener);
    try self.device_listeners.append(self.allocator, listener);
    var devices = self.deviceIterator();
    while (devices.next()) |device| listener.added(listener.context, device);
}

pub fn removeDeviceListener(self: *Self, listener: *DeviceListener) void {
    for (self.device_listeners.items, 0..) |registered, index| {
        if (registered != listener) continue;
        _ = self.device_listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

fn deviceAdded(context: *anyopaque, info: NativeInput.DeviceInfo) void {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(self.findDevice(info.id) == null);
    const name = self.allocator.dupeSentinel(u8, info.name, 0) catch return outOfMemory();
    const device = self.allocator.create(Device) catch {
        self.allocator.free(name);
        return outOfMemory();
    };
    device.* = .{
        .id = info.id,
        .physical_id = info.physical_id,
        .device_type = info.device_type,
        .name = name,
    };
    self.devices.append(self.allocator, device) catch {
        self.allocator.destroy(device);
        self.allocator.free(name);
        return outOfMemory();
    };
    for (self.device_listeners.items) |listener| listener.added(listener.context, device);
}

fn deviceRemoved(context: *anyopaque, id: NativeInput.DeviceId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const device = self.findDevice(id) orelse return;
    self.removeDevice(device);
}

fn removeDevice(self: *Self, device: *Device) void {
    for (self.device_listeners.items) |listener| listener.removed(listener.context, device);
    for (self.devices.items, 0..) |tracked, index| {
        if (tracked != device) continue;
        _ = self.devices.orderedRemove(index);
        self.allocator.free(device.name);
        self.allocator.destroy(device);
        return;
    }
    unreachable;
}

fn outOfMemory() void {
    log.err("failed to track native input device: out of memory", .{});
}
