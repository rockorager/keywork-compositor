//! River libinput device configuration protocol.

const Self = @This();
const std = @import("std");
const wayland = @import("wayland");
const NativeInput = @import("../backend/native_input.zig");
const InputManager = @import("input_manager.zig");
const SecurityContext = @import("../wayland/security_context.zig");
const wl = wayland.server.wl;
const river = wayland.server.river;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
input_manager: *InputManager,
native_input: ?*NativeInput,
managers: std.ArrayList(*Manager),
devices: std.ArrayList(*Device),
accels: std.ArrayList(*Accel),
device_listener: InputManager.DeviceListener,
resource_listener: InputManager.ResourceListener,

const Manager = struct {
    owner: *Self,
    resource: ?*river.LibinputConfigV1,
    stopped: bool = false,
};

const Device = struct {
    owner: *Self,
    manager: *Manager,
    device: *InputManager.Device,
    resource: ?*river.LibinputDeviceV1,
    removed: bool = false,
};

const Accel = struct {
    owner: *Self,
    resource: ?*river.LibinputAccelConfigV1,
    config: NativeInput.AccelConfig,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    input_manager: *InputManager,
    native_input: ?*NativeInput,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .input_manager = input_manager,
        .native_input = native_input,
        .managers = .empty,
        .devices = .empty,
        .accels = .empty,
        .device_listener = .{
            .context = self,
            .added = deviceAdded,
            .removed = deviceRemoved,
        },
        .resource_listener = .{
            .context = self,
            .created = inputResourceCreated,
        },
    };
    errdefer self.deinitStorage();
    self.global = try wl.Global.create(display, river.LibinputConfigV1, 2, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    try input_manager.addResourceListener(&self.resource_listener);
    errdefer input_manager.removeResourceListener(&self.resource_listener);
    try input_manager.addDeviceListener(&self.device_listener);
}

pub fn detachNativeInput(self: *Self) void {
    self.native_input = null;
}

pub fn deinit(self: *Self) void {
    self.detachNativeInput();
    self.input_manager.removeDeviceListener(&self.device_listener);
    self.input_manager.removeResourceListener(&self.resource_listener);
    for (self.managers.items) |m| std.debug.assert(m.resource == null);
    for (self.devices.items) |d| std.debug.assert(d.resource == null);
    for (self.accels.items) |a| std.debug.assert(a.resource == null);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.deinitStorage();
    self.* = undefined;
}
fn deinitStorage(self: *Self) void {
    for (self.accels.items) |a| {
        a.config.deinit();
        self.allocator.destroy(a);
    }
    self.accels.deinit(self.allocator);
    for (self.devices.items) |d| self.allocator.destroy(d);
    self.devices.deinit(self.allocator);
    for (self.managers.items) |m| self.allocator.destroy(m);
    self.managers.deinit(self.allocator);
}
fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const r = river.LibinputConfigV1.create(client, version, id) catch return client.postNoMemory();
    const m = self.allocator.create(Manager) catch {
        r.postNoMemory();
        r.destroy();
        return;
    };
    m.* = .{ .owner = self, .resource = r };
    self.managers.append(self.allocator, m) catch {
        self.allocator.destroy(m);
        r.postNoMemory();
        r.destroy();
        return;
    };
    r.setHandler(*Manager, managerRequest, managerDestroyed, m);
    var it = self.input_manager.deviceIterator();
    while (it.next()) |d| if (self.input_manager.inputResource(client, d)) |ir| self.createDevice(m, d, ir) catch r.postNoMemory();
}
fn managerRequest(r: *river.LibinputConfigV1, req: river.LibinputConfigV1.Request, m: *Manager) void {
    switch (req) {
        .stop => {
            if (m.stopped) return;
            m.stopped = true;
            r.sendFinished();
        },
        .destroy => if (!m.stopped) r.postError(.invalid_destroy, "libinput manager must be stopped before destruction") else r.destroy(),
        .create_accel_config => |v| m.owner.createAccel(r, v.id, protocolEnumRaw(v.profile)),
    }
}
fn managerDestroyed(_: *river.LibinputConfigV1, m: *Manager) void {
    m.resource = null;
    m.stopped = true;
    m.owner.maybeDestroyManager(m);
}

fn maybeDestroyManager(self: *Self, manager: *Manager) void {
    if (manager.resource != null) return;
    for (self.devices.items) |device| if (device.manager == manager) return;
    for (self.managers.items, 0..) |candidate, index| {
        if (candidate != manager) continue;
        _ = self.managers.orderedRemove(index);
        self.allocator.destroy(manager);
        return;
    }
    unreachable;
}
fn createAccel(self: *Self, parent: *river.LibinputConfigV1, id: u32, raw: u32) void {
    const profile = enumValue(NativeInput.AccelProfile, raw) orelse return parent.postError(.invalid_arg, "invalid acceleration profile");
    if (profile == .none) return parent.postError(.invalid_arg, "none is not an acceleration config profile");
    var config = NativeInput.createAccelConfig(profile) orelse return parent.postNoMemory();
    const r = river.LibinputAccelConfigV1.create(
        parent.getClient(),
        @min(parent.getVersion(), river.LibinputAccelConfigV1.generated_version),
        id,
    ) catch {
        config.deinit();
        return parent.postNoMemory();
    };
    const a = self.allocator.create(Accel) catch {
        config.deinit();
        r.postNoMemory();
        r.destroy();
        return;
    };
    a.* = .{ .owner = self, .resource = r, .config = config };
    self.accels.append(self.allocator, a) catch {
        self.allocator.destroy(a);
        config.deinit();
        r.postNoMemory();
        r.destroy();
        return;
    };
    r.setHandler(*Accel, accelRequest, accelDestroyed, a);
}
fn accelRequest(r: *river.LibinputAccelConfigV1, req: river.LibinputAccelConfigV1.Request, a: *Accel) void {
    switch (req) {
        .destroy => r.destroy(),
        .set_points => |v| {
            const typ = enumValue(NativeInput.AccelType, protocolEnumRaw(v.type)) orelse
                return r.postError(.invalid_arg, "invalid acceleration type");
            const step = parseOne(f64, v.step) orelse
                return r.postError(.invalid_arg, "acceleration step must contain one double");
            const points = parseDoubles(v.points, a.owner.allocator) catch |err| switch (err) {
                error.Invalid => return r.postError(
                    .invalid_arg,
                    "acceleration points must contain one or more doubles",
                ),
                error.OutOfMemory => return r.postNoMemory(),
            };
            defer a.owner.allocator.free(points);
            const result = createResult(r.getClient(), r.getVersion(), v.result) orelse
                return r.postNoMemory();
            finish(result, a.config.setPoints(typ, step, points));
        },
    }
}
fn accelDestroyed(_: *river.LibinputAccelConfigV1, a: *Accel) void {
    a.resource = null;
    for (a.owner.accels.items, 0..) |candidate, index| {
        if (candidate != a) continue;
        _ = a.owner.accels.orderedRemove(index);
        a.config.deinit();
        a.owner.allocator.destroy(a);
        return;
    }
    unreachable;
}
fn deviceAdded(_: *anyopaque, _: *InputManager.Device) void {}
fn deviceRemoved(ctx: *anyopaque, d: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    for (self.devices.items) |x| if (x.device == d and !x.removed) {
        if (x.resource) |r| r.sendRemoved();
        x.removed = true;
    };
}
fn inputResourceCreated(ctx: *anyopaque, d: *InputManager.Device, ir: *river.InputDeviceV1) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    for (self.managers.items) |m| if (m.resource != null and !m.stopped and m.resource.?.getClient() == ir.getClient()) self.createDevice(m, d, ir) catch m.resource.?.postNoMemory();
}
fn createDevice(self: *Self, m: *Manager, d: *InputManager.Device, ir: *river.InputDeviceV1) !void {
    for (self.devices.items) |x| if (x.manager == m and x.device == d and x.resource != null) return;
    const native_input = self.native_input orelse return;
    const cfg = native_input.deviceConfig(d.id) orelse return;
    const r = try river.LibinputDeviceV1.create(m.resource.?.getClient(), @min(m.resource.?.getVersion(), 2), 0);
    errdefer r.destroy();
    const x = try self.allocator.create(Device);
    errdefer self.allocator.destroy(x);
    x.* = .{ .owner = self, .manager = m, .device = d, .resource = r };
    try self.devices.append(self.allocator, x);
    InputManager.retainDevice(d);
    r.setHandler(*Device, deviceRequest, deviceDestroyed, x);
    m.resource.?.sendLibinputDevice(r);
    r.sendInputDevice(ir);
    sendInitial(r, cfg);
}
fn deviceDestroyed(_: *river.LibinputDeviceV1, d: *Device) void {
    const owner = d.owner;
    const manager = d.manager;
    d.resource = null;
    InputManager.releaseDevice(d.device);
    for (owner.devices.items, 0..) |candidate, index| {
        if (candidate != d) continue;
        _ = owner.devices.orderedRemove(index);
        owner.allocator.destroy(d);
        owner.maybeDestroyManager(manager);
        return;
    }
    unreachable;
}
fn createResult(client: *wl.Client, version: u32, id: u32) ?*river.LibinputResultV1 {
    return river.LibinputResultV1.create(
        client,
        @min(version, river.LibinputResultV1.generated_version),
        id,
    ) catch null;
}
fn finish(r: *river.LibinputResultV1, status: NativeInput.Status) void {
    switch (status) {
        .success => r.destroySendSuccess(),
        .unsupported => r.destroySendUnsupported(),
        .invalid => r.destroySendInvalid(),
    }
}
fn apply(d: *Device, result_id: u32, status: ?NativeInput.Status) void {
    const resource = d.resource.?;
    const result = createResult(resource.getClient(), resource.getVersion(), result_id) orelse
        return resource.postNoMemory();
    const s = status orelse return finish(result, .invalid);
    finish(result, s);
    if (s == .success) d.owner.broadcast(d.device.physical_id);
}
fn deviceRequest(r: *river.LibinputDeviceV1, req: river.LibinputDeviceV1.Request, d: *Device) void {
    if (req == .destroy) return r.destroy();
    if (d.removed or !d.device.connected) return;
    const n = d.owner.native_input orelse return;
    const id = d.device.id;
    switch (req) {
        .destroy => unreachable,
        .set_send_events => |v| {
            const raw: u32 = @bitCast(v.mode);
            if (raw & ~@as(u32, 3) != 0) {
                return r.postError(.invalid_arg, "invalid send-events mode");
            }
            apply(d, v.result, n.setSendEvents(id, @bitCast(raw)));
        },
        .set_tap => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setTap),
        .set_tap_button_map => |v| setEnum(d, r, v.result, NativeInput.TapButtonMap, protocolEnumRaw(v.button_map), NativeInput.setTapButtonMap),
        .set_drag => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setDrag),
        .set_drag_lock => |v| setEnum(d, r, v.result, NativeInput.DragLock, protocolEnumRaw(v.state), NativeInput.setDragLock),
        .set_three_finger_drag => |v| setEnum(d, r, v.result, NativeInput.ThreeFingerDrag, protocolEnumRaw(v.state), NativeInput.setThreeFingerDrag),
        .set_calibration_matrix => |v| {
            const x = parseFixed(NativeInput.CalibrationMatrix, v.matrix) orelse
                return r.postError(.invalid_arg, "calibration matrix must contain six floats");
            apply(d, v.result, n.setCalibrationMatrix(id, x));
        },
        .set_accel_profile => |v| setEnum(d, r, v.result, NativeInput.AccelProfile, protocolEnumRaw(v.profile), NativeInput.setAccelProfile),
        .set_accel_speed => |v| {
            const x = parseOne(f64, v.speed) orelse
                return r.postError(.invalid_arg, "acceleration speed must contain one double");
            apply(d, v.result, n.setAccelSpeed(id, x));
        },
        .apply_accel_config => |v| {
            const p = v.config.getUserData() orelse
                return r.postError(.invalid_arg, "invalid acceleration config");
            const a: *Accel = @ptrCast(@alignCast(p));
            if (a.resource != v.config or v.config.getClient() != r.getClient()) {
                return r.postError(.invalid_arg, "invalid acceleration config");
            }
            apply(d, v.result, n.applyAccelConfig(id, &a.config));
        },
        .set_natural_scroll => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setNaturalScroll),
        .set_left_handed => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setLeftHanded),
        .set_click_method => |v| setEnum(d, r, v.result, NativeInput.ClickMethod, protocolEnumRaw(v.method), NativeInput.setClickMethod),
        .set_clickfinger_button_map => |v| setEnum(d, r, v.result, NativeInput.ClickfingerButtonMap, protocolEnumRaw(v.button_map), NativeInput.setClickfingerButtonMap),
        .set_middle_emulation => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setMiddleEmulation),
        .set_scroll_method => |v| setEnum(d, r, v.result, NativeInput.ScrollMethod, protocolEnumRaw(v.method), NativeInput.setScrollMethod),
        .set_scroll_button => |v| apply(d, v.result, n.setScrollButton(id, v.button)),
        .set_scroll_button_lock => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setScrollButtonLock),
        .set_dwt => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setDwt),
        .set_dwtp => |v| setEnum(d, r, v.result, NativeInput.Toggle, protocolEnumRaw(v.state), NativeInput.setDwtp),
        .set_rotation => |v| apply(d, v.result, n.setRotation(id, v.angle)),
    }
}
fn setEnum(d: *Device, r: *river.LibinputDeviceV1, result: u32, comptime T: type, raw: u32, setter: anytype) void {
    const value = enumValue(T, raw) orelse
        return r.postError(.invalid_arg, "invalid libinput configuration value");
    const native_input = d.owner.native_input orelse return;
    apply(d, result, setter(native_input, d.device.id, value));
}
fn broadcast(self: *Self, physical_id: NativeInput.PhysicalDeviceId) void {
    const native_input = self.native_input orelse return;
    for (self.devices.items) |d| {
        if (d.resource == null or d.removed or d.device.physical_id != physical_id) continue;
        const cfg = native_input.deviceConfig(d.device.id) orelse continue;
        sendCurrents(d.resource.?, cfg);
        if (d.resource.?.getVersion() >= 2) d.resource.?.sendDone();
    }
}
fn proto(comptime T: type, value: anytype) T {
    return @enumFromInt(@as(c_int, @intCast(@intFromEnum(value))));
}

fn protocolEnumRaw(value: anytype) u32 {
    return @bitCast(@as(i32, @intFromEnum(value)));
}

fn array(value: anytype) wl.Array {
    const pointer = @typeInfo(@TypeOf(value)).pointer;
    return .{
        .size = @sizeOf(pointer.child),
        .alloc = @sizeOf(pointer.child),
        .data = @ptrCast(@constCast(value)),
    };
}
fn sendInitial(r: *river.LibinputDeviceV1, c: NativeInput.DeviceConfig) void {
    r.sendSendEventsSupport(@bitCast(c.send_events.supported));
    r.sendSendEventsDefault(@bitCast(c.send_events.default));
    r.sendSendEventsCurrent(@bitCast(c.send_events.current));
    r.sendTapSupport(@intCast(c.tap_finger_count));
    if (c.tap) |x| {
        r.sendTapDefault(proto(river.LibinputDeviceV1.TapState, x.default));
        r.sendTapCurrent(proto(river.LibinputDeviceV1.TapState, x.current));
    }
    if (c.tap_button_map) |x| {
        r.sendTapButtonMapDefault(proto(river.LibinputDeviceV1.TapButtonMap, x.default));
        r.sendTapButtonMapCurrent(proto(river.LibinputDeviceV1.TapButtonMap, x.current));
    }
    if (c.drag) |x| {
        r.sendDragDefault(proto(river.LibinputDeviceV1.DragState, x.default));
        r.sendDragCurrent(proto(river.LibinputDeviceV1.DragState, x.current));
    }
    if (c.drag_lock) |x| {
        r.sendDragLockDefault(proto(river.LibinputDeviceV1.DragLockState, x.default));
        r.sendDragLockCurrent(proto(river.LibinputDeviceV1.DragLockState, x.current));
    }
    r.sendThreeFingerDragSupport(@intCast(c.three_finger_drag_count));
    if (c.three_finger_drag) |x| {
        r.sendThreeFingerDragDefault(proto(river.LibinputDeviceV1.ThreeFingerDragState, x.default));
        r.sendThreeFingerDragCurrent(proto(river.LibinputDeviceV1.ThreeFingerDragState, x.current));
    }
    r.sendCalibrationMatrixSupport(@intFromBool(c.calibration_matrix != null));
    if (c.calibration_matrix) |x| {
        var a = array(&x.default);
        r.sendCalibrationMatrixDefault(&a);
        a = array(&x.current);
        r.sendCalibrationMatrixCurrent(&a);
    }
    r.sendAccelProfilesSupport(if (c.accel_profiles) |x| @bitCast(x.supported) else .{});
    if (c.accel_profiles) |x| {
        r.sendAccelProfileDefault(proto(river.LibinputDeviceV1.AccelProfile, x.default));
        r.sendAccelProfileCurrent(proto(river.LibinputDeviceV1.AccelProfile, x.current));
        var a = array(&x.speed.default);
        r.sendAccelSpeedDefault(&a);
        a = array(&x.speed.current);
        r.sendAccelSpeedCurrent(&a);
    }
    sendOptional(r, c.natural_scroll, river.LibinputDeviceV1.sendNaturalScrollSupport, river.LibinputDeviceV1.sendNaturalScrollDefault, river.LibinputDeviceV1.sendNaturalScrollCurrent, river.LibinputDeviceV1.NaturalScrollState);
    sendOptional(r, c.left_handed, river.LibinputDeviceV1.sendLeftHandedSupport, river.LibinputDeviceV1.sendLeftHandedDefault, river.LibinputDeviceV1.sendLeftHandedCurrent, river.LibinputDeviceV1.LeftHandedState);
    r.sendClickMethodSupport(if (c.click_method) |x| @bitCast(x.supported) else .{});
    if (c.click_method) |x| {
        r.sendClickMethodDefault(proto(river.LibinputDeviceV1.ClickMethod, x.default));
        r.sendClickMethodCurrent(proto(river.LibinputDeviceV1.ClickMethod, x.current));
    }
    if (c.clickfinger_button_map) |x| {
        r.sendClickfingerButtonMapDefault(proto(river.LibinputDeviceV1.ClickfingerButtonMap, x.default));
        r.sendClickfingerButtonMapCurrent(proto(river.LibinputDeviceV1.ClickfingerButtonMap, x.current));
    }
    sendOptional(r, c.middle_emulation, river.LibinputDeviceV1.sendMiddleEmulationSupport, river.LibinputDeviceV1.sendMiddleEmulationDefault, river.LibinputDeviceV1.sendMiddleEmulationCurrent, river.LibinputDeviceV1.MiddleEmulationState);
    r.sendScrollMethodSupport(if (c.scroll_method) |x| @bitCast(x.supported) else .{});
    if (c.scroll_method) |x| {
        r.sendScrollMethodDefault(proto(river.LibinputDeviceV1.ScrollMethod, x.default));
        r.sendScrollMethodCurrent(proto(river.LibinputDeviceV1.ScrollMethod, x.current));
    }
    if (c.scroll_button) |x| {
        r.sendScrollButtonDefault(x.default);
        r.sendScrollButtonCurrent(x.current);
    }
    if (c.scroll_button_lock) |x| {
        r.sendScrollButtonLockDefault(proto(river.LibinputDeviceV1.ScrollButtonLockState, x.default));
        r.sendScrollButtonLockCurrent(proto(river.LibinputDeviceV1.ScrollButtonLockState, x.current));
    }
    sendOptional(r, c.dwt, river.LibinputDeviceV1.sendDwtSupport, river.LibinputDeviceV1.sendDwtDefault, river.LibinputDeviceV1.sendDwtCurrent, river.LibinputDeviceV1.DwtState);
    sendOptional(r, c.dwtp, river.LibinputDeviceV1.sendDwtpSupport, river.LibinputDeviceV1.sendDwtpDefault, river.LibinputDeviceV1.sendDwtpCurrent, river.LibinputDeviceV1.DwtpState);
    r.sendRotationSupport(@intFromBool(c.rotation != null));
    if (c.rotation) |x| {
        r.sendRotationDefault(x.default);
        r.sendRotationCurrent(x.current);
    }
    if (r.getVersion() >= 2) r.sendDone();
}
fn sendOptional(r: anytype, x: anytype, support: anytype, def: anytype, current: anytype, comptime P: type) void {
    support(r, @intFromBool(x != null));
    if (x) |v| {
        def(r, proto(P, v.default));
        current(r, proto(P, v.current));
    }
}
fn sendCurrents(r: *river.LibinputDeviceV1, c: NativeInput.DeviceConfig) void {
    r.sendSendEventsCurrent(@bitCast(c.send_events.current));
    if (c.tap) |x| r.sendTapCurrent(proto(river.LibinputDeviceV1.TapState, x.current));
    if (c.tap_button_map) |x| r.sendTapButtonMapCurrent(proto(river.LibinputDeviceV1.TapButtonMap, x.current));
    if (c.drag) |x| r.sendDragCurrent(proto(river.LibinputDeviceV1.DragState, x.current));
    if (c.drag_lock) |x| r.sendDragLockCurrent(proto(river.LibinputDeviceV1.DragLockState, x.current));
    if (c.three_finger_drag) |x| r.sendThreeFingerDragCurrent(proto(river.LibinputDeviceV1.ThreeFingerDragState, x.current));
    if (c.calibration_matrix) |x| {
        var a = array(&x.current);
        r.sendCalibrationMatrixCurrent(&a);
    }
    if (c.accel_profiles) |x| {
        r.sendAccelProfileCurrent(proto(river.LibinputDeviceV1.AccelProfile, x.current));
        var a = array(&x.speed.current);
        r.sendAccelSpeedCurrent(&a);
    }
    if (c.natural_scroll) |x| r.sendNaturalScrollCurrent(proto(river.LibinputDeviceV1.NaturalScrollState, x.current));
    if (c.left_handed) |x| r.sendLeftHandedCurrent(proto(river.LibinputDeviceV1.LeftHandedState, x.current));
    if (c.click_method) |x| r.sendClickMethodCurrent(proto(river.LibinputDeviceV1.ClickMethod, x.current));
    if (c.clickfinger_button_map) |x| r.sendClickfingerButtonMapCurrent(proto(river.LibinputDeviceV1.ClickfingerButtonMap, x.current));
    if (c.middle_emulation) |x| r.sendMiddleEmulationCurrent(proto(river.LibinputDeviceV1.MiddleEmulationState, x.current));
    if (c.scroll_method) |x| r.sendScrollMethodCurrent(proto(river.LibinputDeviceV1.ScrollMethod, x.current));
    if (c.scroll_button) |x| r.sendScrollButtonCurrent(x.current);
    if (c.scroll_button_lock) |x| r.sendScrollButtonLockCurrent(proto(river.LibinputDeviceV1.ScrollButtonLockState, x.current));
    if (c.dwt) |x| r.sendDwtCurrent(proto(river.LibinputDeviceV1.DwtState, x.current));
    if (c.dwtp) |x| r.sendDwtpCurrent(proto(river.LibinputDeviceV1.DwtpState, x.current));
    if (c.rotation) |x| r.sendRotationCurrent(x.current);
}
fn enumValue(comptime T: type, raw: u32) ?T {
    inline for (std.meta.fields(T)) |f| if (raw == f.value) return @enumFromInt(raw);
    return null;
}
fn parseFixed(comptime T: type, a: *const wl.Array) ?T {
    if (a.size != @sizeOf(T)) return null;
    const p = a.data orelse return null;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), @as([*]const u8, @ptrCast(p))[0..@sizeOf(T)]);
    return value;
}
fn parseOne(comptime T: type, a: *const wl.Array) ?T {
    return parseFixed(T, a);
}
fn parseDoubles(a: *const wl.Array, allocator: std.mem.Allocator) error{ Invalid, OutOfMemory }![]f64 {
    if (a.size == 0 or a.size % @sizeOf(f64) != 0 or a.data == null) return error.Invalid;
    const out = try allocator.alloc(f64, a.size / @sizeOf(f64));
    const bytes: [*]const u8 = @ptrCast(a.data.?);
    for (out, 0..) |*v, i| @memcpy(std.mem.asBytes(v), bytes[i * @sizeOf(f64) ..][0..@sizeOf(f64)]);
    return out;
}
fn testArray(bytes: []const u8) wl.Array {
    return .{ .size = bytes.len, .alloc = bytes.len, .data = if (bytes.len == 0) null else @ptrCast(@constCast(bytes.ptr)) };
}
test "array parsing copies unaligned floating point values" {
    var bytes: [9]u8 = undefined;
    const x: f64 = 0.25;
    @memcpy(bytes[1..], std.mem.asBytes(&x));
    var a = testArray(bytes[1..]);
    try std.testing.expectEqual(x, parseOne(f64, &a).?);
}
test "fixed arrays reject incorrect lengths" {
    var bytes: [23]u8 = undefined;
    var a = testArray(&bytes);
    try std.testing.expect(parseFixed(NativeInput.CalibrationMatrix, &a) == null);
}
test "enum conversion rejects unknown values" {
    try std.testing.expectEqual(NativeInput.Toggle.enabled, enumValue(NativeInput.Toggle, 1).?);
    try std.testing.expect(enumValue(NativeInput.Toggle, 2) == null);
}

test {
    std.testing.refAllDecls(Self);
}
