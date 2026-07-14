//! River physical input-device discovery and configuration.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const NativeInput = @import("../backend/native_input.zig");
const OutputLayout = @import("../wayland/output_layout.zig");
const SecurityContext = @import("../wayland/security_context.zig");

const wl = wayland.server.wl;
const river = wayland.server.river;
const log = std.log.scoped(.river_input_manager);

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
native_input: ?*NativeInput,
outputs: *OutputLayout,
target_output: OutputLayout.Id,
managers: std.ArrayList(*ManagerResource),
devices: std.ArrayList(*Device),
device_resources: std.ArrayList(*DeviceResource),
device_listeners: std.ArrayList(*DeviceListener),
seats: std.ArrayList([:0]u8),

const ManagerResource = struct {
    manager: *Self,
    resource: ?*river.InputManagerV1,
    stopped: bool,
};

pub const Device = struct {
    manager: *Self,
    id: NativeInput.DeviceId,
    physical_id: NativeInput.PhysicalDeviceId,
    device_type: NativeInput.DeviceType,
    name: [:0]u8,
    connected: bool = true,
    seat_name: [:0]const u8 = default_seat,
    output: ?OutputLayout.Id = null,
    rectangle: ?NativeInput.DeviceMap = null,
    references: usize = 0,
};

pub const DeviceListener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, *Device) void,
    removed: *const fn (*anyopaque, *Device) void,
};

const DeviceResource = struct {
    device: *Device,
    resource: ?*river.InputDeviceV1,
    removed: bool,
};

const default_seat: [:0]const u8 = "default";

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    native_input: *NativeInput,
    outputs: *OutputLayout,
    target_output: OutputLayout.Id,
) !void {
    std.debug.assert(outputs.get(target_output) != null);
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .native_input = native_input,
        .outputs = outputs,
        .target_output = target_output,
        .managers = .empty,
        .devices = .empty,
        .device_resources = .empty,
        .device_listeners = .empty,
        .seats = .empty,
    };
    errdefer self.deinitStorage();
    self.global = try wl.Global.create(display, river.InputManagerV1, 2, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    native_input.setDeviceListener(.{
        .context = self,
        .added = deviceAdded,
        .removed = deviceRemoved,
    });
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.native_input == null);
    std.debug.assert(self.device_listeners.items.len == 0);
    for (self.managers.items) |manager| std.debug.assert(manager.resource == null);
    for (self.device_resources.items) |resource| std.debug.assert(resource.resource == null);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.deinitStorage();
    self.* = undefined;
}

fn deinitStorage(self: *Self) void {
    self.device_listeners.deinit(self.allocator);
    for (self.device_resources.items) |resource| self.allocator.destroy(resource);
    self.device_resources.deinit(self.allocator);
    for (self.managers.items) |manager| self.allocator.destroy(manager);
    self.managers.deinit(self.allocator);
    for (self.devices.items) |device| {
        std.debug.assert(device.references == 0);
        self.allocator.free(device.name);
        self.allocator.destroy(device);
    }
    self.devices.deinit(self.allocator);
    for (self.seats.items) |name| self.allocator.free(name);
    self.seats.deinit(self.allocator);
}

pub fn detachNativeInput(self: *Self) void {
    const native_input = self.native_input orelse return;
    native_input.clearDeviceListener();
    self.native_input = null;
    while (self.firstConnectedDevice()) |device| self.removeDevice(device);
}

pub fn targetOutputChanged(self: *Self, target_output: OutputLayout.Id) void {
    std.debug.assert(self.outputs.get(target_output) != null);
    self.target_output = target_output;
    for (self.devices.items) |device| if (device.connected) self.applyDeviceMap(device);
}

pub fn outputRemoved(self: *Self, output_id: OutputLayout.Id) void {
    for (self.devices.items) |device| {
        if (device.output == null or !std.meta.eql(device.output.?, output_id)) continue;
        device.output = null;
        if (device.connected) self.applyDeviceMap(device);
    }
}

pub fn findDevice(self: *Self, id: NativeInput.DeviceId) ?*Device {
    for (self.devices.items) |device| if (device.id == id and device.connected) return device;
    return null;
}

pub const DeviceIterator = struct {
    devices: []const *Device,
    index: usize = 0,

    pub fn next(self: *DeviceIterator) ?*Device {
        while (self.index < self.devices.len) {
            defer self.index += 1;
            const device = self.devices[self.index];
            if (device.connected) return device;
        }
        return null;
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

pub fn retainDevice(device: *Device) void {
    device.references = std.math.add(usize, device.references, 1) catch unreachable;
}

pub fn releaseDevice(device: *Device) void {
    std.debug.assert(device.references > 0);
    device.references -= 1;
    device.manager.maybeDestroyDevice(device);
}

fn firstConnectedDevice(self: *Self) ?*Device {
    for (self.devices.items) |device| if (device.connected) return device;
    return null;
}

pub fn inputResource(self: *Self, client: *wl.Client, device: *Device) ?*river.InputDeviceV1 {
    for (self.device_resources.items) |adapter| {
        const resource = adapter.resource orelse continue;
        if (!adapter.removed and adapter.device == device and resource.getClient() == client) return resource;
    }
    return null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = river.InputManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const manager = self.allocator.create(ManagerResource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    manager.* = .{ .manager = self, .resource = resource, .stopped = false };
    self.managers.append(self.allocator, manager) catch {
        self.allocator.destroy(manager);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*ManagerResource, managerRequest, managerDestroyed, manager);
    for (self.devices.items) |device| {
        if (!device.connected) continue;
        self.createDeviceResource(manager, device) catch {
            resource.postNoMemory();
            return;
        };
    }
}

fn managerRequest(
    resource: *river.InputManagerV1,
    request: river.InputManagerV1.Request,
    adapter: *ManagerResource,
) void {
    if (adapter.stopped and request != .destroy) return;
    switch (request) {
        .stop => {
            if (adapter.stopped) return;
            adapter.stopped = true;
            resource.sendFinished();
        },
        .destroy => {
            if (!adapter.stopped) {
                resource.postError(.invalid_destroy, "input manager must be stopped before destruction");
                return;
            }
            resource.destroy();
        },
        .create_seat => |create| adapter.manager.createSeat(resource, std.mem.span(create.name)),
        .destroy_seat => |destroy| adapter.manager.destroySeat(std.mem.span(destroy.name)),
    }
}

fn managerDestroyed(_: *river.InputManagerV1, adapter: *ManagerResource) void {
    adapter.resource = null;
    adapter.stopped = true;
}

fn createSeat(self: *Self, resource: *river.InputManagerV1, name: []const u8) void {
    if (std.mem.eql(u8, name, default_seat) or self.hasSeat(name)) return;
    log.warn("tracking seat {s}, but multi-seat input routing is not implemented yet", .{name});
    const copy = self.allocator.dupeSentinel(u8, name, 0) catch {
        resource.postNoMemory();
        return;
    };
    self.seats.append(self.allocator, copy) catch {
        self.allocator.free(copy);
        resource.postNoMemory();
    };
}

fn destroySeat(self: *Self, name: []const u8) void {
    if (std.mem.eql(u8, name, default_seat)) return;
    for (self.seats.items, 0..) |seat_name, index| {
        if (!std.mem.eql(u8, seat_name, name)) continue;
        for (self.devices.items) |device| {
            if (std.mem.eql(u8, device.seat_name, seat_name)) device.seat_name = default_seat;
        }
        const removed = self.seats.orderedRemove(index);
        self.allocator.free(removed);
        return;
    }
}

fn hasSeat(self: *const Self, name: []const u8) bool {
    if (std.mem.eql(u8, name, default_seat)) return true;
    for (self.seats.items) |seat_name| if (std.mem.eql(u8, seat_name, name)) return true;
    return false;
}

fn createDeviceResource(self: *Self, manager: *ManagerResource, device: *Device) !void {
    const manager_resource = manager.resource.?;
    const resource = try river.InputDeviceV1.create(
        manager_resource.getClient(),
        @min(manager_resource.getVersion(), river.InputDeviceV1.generated_version),
        0,
    );
    errdefer resource.destroy();
    const adapter = try self.allocator.create(DeviceResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{ .device = device, .resource = resource, .removed = false };
    try self.device_resources.append(self.allocator, adapter);
    retainDevice(device);
    resource.setHandler(*DeviceResource, deviceRequest, deviceResourceDestroyed, adapter);
    manager_resource.sendInputDevice(resource);
    resource.sendType(switch (device.device_type) {
        .keyboard => .keyboard,
        .pointer => .pointer,
        .touch => .touch,
        .tablet => .tablet,
    });
    resource.sendName(device.name);
    if (resource.getVersion() >= river.InputDeviceV1.done_since_version) resource.sendDone();
}

fn deviceRequest(
    resource: *river.InputDeviceV1,
    request: river.InputDeviceV1.Request,
    adapter: *DeviceResource,
) void {
    if (request == .destroy) {
        resource.destroy();
        return;
    }
    if (adapter.removed or !adapter.device.connected) return;
    const device = adapter.device;
    const self = device.manager;
    switch (request) {
        .destroy => unreachable,
        .assign_to_seat => |assign| {
            const name = std.mem.span(assign.name);
            if (!self.hasSeat(name)) return;
            device.seat_name = self.seatName(name).?;
            if (!std.mem.eql(u8, name, default_seat)) {
                log.warn("device {d} remains routed through the default seat", .{device.id});
            }
        },
        .set_repeat_info => |repeat| {
            if (repeat.rate < 0 or repeat.delay < 0) {
                resource.postError(.invalid_repeat_info, "repeat rate and delay must not be negative");
                return;
            }
            if (device.device_type == .keyboard) {
                const native_input = self.native_input orelse return;
                native_input.setDeviceRepeatInfo(device.id, repeat.rate, repeat.delay);
            }
        },
        .set_scroll_factor => |scroll| {
            const factor = scroll.factor.toDouble();
            if (!std.math.isFinite(factor) or factor < 0) {
                resource.postError(.invalid_scroll_factor, "scroll factor must be finite and non-negative");
                return;
            }
            if (device.device_type == .pointer) {
                const native_input = self.native_input orelse return;
                native_input.setDeviceScrollFactor(device.id, factor);
            }
        },
        .map_to_output => |map| {
            if (device.device_type == .keyboard) return;
            device.output = if (map.output) |output|
                if (self.outputs.findResource(output)) |entry| entry.id else return
            else
                null;
            self.applyDeviceMap(device);
        },
        .map_to_rectangle => |map| {
            if (map.width < 0 or map.height < 0) {
                resource.postError(.invalid_map_to_rectangle, "mapped width and height must not be negative");
                return;
            }
            if (device.device_type == .keyboard) return;
            device.rectangle = if (map.width == 0 or map.height == 0) null else .{
                .x = map.x,
                .y = map.y,
                .width = @intCast(map.width),
                .height = @intCast(map.height),
            };
            self.applyDeviceMap(device);
        },
    }
}

fn deviceResourceDestroyed(_: *river.InputDeviceV1, adapter: *DeviceResource) void {
    adapter.resource = null;
    releaseDevice(adapter.device);
}

fn seatName(self: *const Self, name: []const u8) ?[:0]const u8 {
    if (std.mem.eql(u8, name, default_seat)) return default_seat;
    for (self.seats.items) |seat_name| if (std.mem.eql(u8, seat_name, name)) return seat_name;
    return null;
}

fn applyDeviceMap(self: *Self, device: *Device) void {
    const native_input = self.native_input orelse return;
    const global_map = device.rectangle orelse if (device.output) |output_id| blk: {
        const output = self.outputs.get(output_id) orelse {
            device.output = null;
            break :blk null;
        };
        const rectangle = output.logicalRect();
        break :blk NativeInput.DeviceMap{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        };
    } else null;
    const map = if (global_map) |rectangle| blk: {
        const target_position = self.outputs.get(self.target_output).?.logicalPosition();
        break :blk relativeMap(rectangle, target_position.x, target_position.y);
    } else null;
    native_input.setDeviceMap(device.id, map);
}

fn relativeMap(map: NativeInput.DeviceMap, target_x: i32, target_y: i32) NativeInput.DeviceMap {
    return .{
        .x = map.x -| target_x,
        .y = map.y -| target_y,
        .width = map.width,
        .height = map.height,
    };
}

fn deviceAdded(context: *anyopaque, info: NativeInput.DeviceInfo) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const name = self.allocator.dupeSentinel(u8, info.name, 0) catch return self.outOfMemory();
    const device = self.allocator.create(Device) catch {
        self.allocator.free(name);
        return self.outOfMemory();
    };
    device.* = .{
        .manager = self,
        .id = info.id,
        .physical_id = info.physical_id,
        .device_type = info.device_type,
        .name = name,
    };
    self.devices.append(self.allocator, device) catch {
        self.allocator.destroy(device);
        self.allocator.free(name);
        return self.outOfMemory();
    };
    for (self.managers.items) |manager| {
        if (manager.resource == null or manager.stopped) continue;
        self.createDeviceResource(manager, device) catch manager.resource.?.postNoMemory();
    }
    for (self.device_listeners.items) |listener| listener.added(listener.context, device);
}

fn deviceRemoved(context: *anyopaque, id: NativeInput.DeviceId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const device = self.findDevice(id) orelse return;
    self.removeDevice(device);
}

fn removeDevice(self: *Self, device: *Device) void {
    std.debug.assert(device.connected);
    device.connected = false;
    for (self.device_listeners.items) |listener| listener.removed(listener.context, device);
    for (self.device_resources.items) |adapter| {
        if (adapter.device != device or adapter.resource == null or adapter.removed) continue;
        adapter.resource.?.sendRemoved();
        adapter.removed = true;
    }
    self.maybeDestroyDevice(device);
}

fn maybeDestroyDevice(self: *Self, device: *Device) void {
    if (device.connected or device.references != 0) return;
    for (self.devices.items, 0..) |candidate, index| {
        if (candidate != device) continue;
        _ = self.devices.orderedRemove(index);
        self.allocator.free(device.name);
        self.allocator.destroy(device);
        return;
    }
    unreachable;
}

fn outOfMemory(self: *Self) void {
    log.err("failed to track native input device: out of memory", .{});
    for (self.managers.items) |manager| if (manager.resource) |resource| resource.postNoMemory();
}

test "device maps are relative to the native input target" {
    try std.testing.expectEqual(
        NativeInput.DeviceMap{ .x = -1280, .y = 200, .width = 1920, .height = 1080 },
        relativeMap(.{ .x = 0, .y = 200, .width = 1920, .height = 1080 }, 1280, 0),
    );
}
