//! River xkbcommon key bindings protocol.

const Self = @This();
const std = @import("std");
const wayland = @import("wayland");
const NativeInput = @import("../backend/native_input.zig");
const SecurityContext = @import("../wayland/security_context.zig");
const Seat = @import("../wayland/seat.zig");
const InputManager = @import("input_manager.zig");
const WindowManager = @import("window_manager.zig");
const wl = wayland.server.wl;
const river = wayland.server.river;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
window_manager: *WindowManager,
input_manager: *InputManager,
native_input: ?*NativeInput,
device_listener: InputManager.DeviceListener,
bindings: std.ArrayList(*Binding),
seats: std.ArrayList(*BindingsSeat),
held_keys: std.ArrayList(HeldKey),

const Binding = struct {
    owner: *Self,
    resource: *river.XkbBindingV1,
    generation: ?u64,
    seat: ?*Seat,
    keysym: u32,
    modifiers: u32,
    layout_override: ?u32 = null,
    enabled: bool = false,

    fn active(self: *const Binding) bool {
        const generation = self.generation orelse return false;
        const seat = self.seat orelse return false;
        return self.owner.window_manager.seatActive(seat) and
            self.owner.window_manager.bindingSessionActive(generation, self.resource.getClient());
    }
};

const BindingsSeat = struct {
    owner: *Self,
    resource: *river.XkbBindingsSeatV1,
    generation: ?u64,
    seat: ?*Seat,
    seat_id: u32,
    ensure_next_key_eaten: bool = false,
    watched_modifiers: u32 = 0,
    modifiers: u32 = 0,

    fn active(self: *const BindingsSeat) bool {
        const generation = self.generation orelse return false;
        const seat = self.seat orelse return false;
        return self.owner.window_manager.seatActive(seat) and
            self.owner.window_manager.bindingSessionActive(generation, self.resource.getClient());
    }
};

const HeldKey = struct {
    device_id: NativeInput.DeviceId,
    key_code: u32,
    binding: ?*Binding,
    captured: bool,
    stop_repeat_sent: bool = false,
};

const EventSession = struct {
    generation: u64,
    client: *wl.Client,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    window_manager: *WindowManager,
    input_manager: *InputManager,
    native_input: *NativeInput,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .window_manager = window_manager,
        .input_manager = input_manager,
        .native_input = native_input,
        .device_listener = .{
            .context = self,
            .added = deviceAdded,
            .removed = deviceRemoved,
            .seat_changed = deviceSeatChanged,
        },
        .bindings = .empty,
        .seats = .empty,
        .held_keys = .empty,
    };
    errdefer self.deinitStorage();
    self.global = try wl.Global.create(display, river.XkbBindingsV1, 3, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    try input_manager.addDeviceListener(&self.device_listener);
    errdefer input_manager.removeDeviceListener(&self.device_listener);
    native_input.setKeyboardEventListener(.{
        .context = self,
        .key = keyboardKey,
        .modifiers = modifiersChanged,
    });
}

pub fn detachNativeInput(self: *Self) void {
    const native_input = self.native_input orelse return;
    native_input.clearKeyboardEventListener();
    self.native_input = null;
    self.held_keys.clearRetainingCapacity();
}

pub fn deinit(self: *Self) void {
    self.detachNativeInput();
    self.input_manager.removeDeviceListener(&self.device_listener);
    std.debug.assert(self.bindings.items.len == 0);
    std.debug.assert(self.seats.items.len == 0);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.deinitStorage();
    self.* = undefined;
}

fn deinitStorage(self: *Self) void {
    self.held_keys.deinit(self.allocator);
    for (self.seats.items) |seat| self.allocator.destroy(seat);
    self.seats.deinit(self.allocator);
    for (self.bindings.items) |binding| self.allocator.destroy(binding);
    self.bindings.deinit(self.allocator);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = river.XkbBindingsV1.create(client, version, id) catch
        return client.postNoMemory();
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(resource: *river.XkbBindingsV1, request: river.XkbBindingsV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_xkb_binding => |get| self.createBinding(
            resource,
            get.seat,
            get.id,
            get.keysym,
            @bitCast(get.modifiers),
        ) catch resource.postNoMemory(),
        .get_seat => |get| self.createSeat(resource, get.seat, get.id),
    }
}

fn createBinding(
    self: *Self,
    parent: *river.XkbBindingsV1,
    seat: *river.SeatV1,
    id: u32,
    keysym: u32,
    modifiers: u32,
) !void {
    const resource = try river.XkbBindingV1.create(
        parent.getClient(),
        @min(parent.getVersion(), river.XkbBindingV1.generated_version),
        id,
    );
    errdefer resource.destroy();
    const binding = try self.allocator.create(Binding);
    errdefer self.allocator.destroy(binding);
    binding.* = .{
        .owner = self,
        .resource = resource,
        .generation = self.window_manager.bindingSession(seat),
        .seat = self.window_manager.bindingSeat(seat),
        .keysym = keysym,
        .modifiers = modifiers & 0xed,
    };
    try self.bindings.append(self.allocator, binding);
    resource.setHandler(*Binding, bindingRequest, bindingDestroyed, binding);
}

fn bindingRequest(resource: *river.XkbBindingV1, request: river.XkbBindingV1.Request, binding: *Binding) void {
    if (request == .destroy) return resource.destroy();
    const generation = binding.generation orelse return;
    if (!binding.owner.window_manager.requireBindingManage(generation, resource.getClient())) return;
    switch (request) {
        .destroy => unreachable,
        .set_layout_override => |set| binding.layout_override = set.layout,
        .enable => binding.enabled = true,
        .disable => binding.enabled = false,
    }
}

fn bindingDestroyed(_: *river.XkbBindingV1, binding: *Binding) void {
    const owner = binding.owner;
    for (owner.held_keys.items) |*held| {
        if (held.binding == binding) held.binding = null;
    }
    for (owner.bindings.items, 0..) |candidate, index| {
        if (candidate != binding) continue;
        _ = owner.bindings.orderedRemove(index);
        owner.allocator.destroy(binding);
        return;
    }
    unreachable;
}

fn createSeat(self: *Self, parent: *river.XkbBindingsV1, seat: *river.SeatV1, id: u32) void {
    const generation = self.window_manager.bindingSession(seat);
    const seat_id = seat.getId();
    if (generation) |active_generation| {
        for (self.seats.items) |candidate| {
            if (candidate.generation == active_generation and
                candidate.resource.getClient() == parent.getClient() and
                candidate.seat_id == seat_id)
            {
                return parent.postError(.object_already_created, "xkb bindings seat already created");
            }
        }
    }
    const resource = river.XkbBindingsSeatV1.create(
        parent.getClient(),
        @min(parent.getVersion(), river.XkbBindingsSeatV1.generated_version),
        id,
    ) catch return parent.postNoMemory();
    const adapter = self.allocator.create(BindingsSeat) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    adapter.* = .{
        .owner = self,
        .resource = resource,
        .generation = generation,
        .seat = self.window_manager.bindingSeat(seat),
        .seat_id = seat_id,
    };
    self.seats.append(self.allocator, adapter) catch {
        self.allocator.destroy(adapter);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*BindingsSeat, seatRequest, seatDestroyed, adapter);
}

fn seatRequest(resource: *river.XkbBindingsSeatV1, request: river.XkbBindingsSeatV1.Request, seat: *BindingsSeat) void {
    if (request == .destroy) return resource.destroy();
    const generation = seat.generation orelse return;
    if (!seat.owner.window_manager.requireBindingManage(generation, resource.getClient())) return;
    switch (request) {
        .destroy => unreachable,
        .ensure_next_key_eaten => seat.ensure_next_key_eaten = true,
        .cancel_ensure_next_key_eaten => seat.ensure_next_key_eaten = false,
        .modifiers_watch => |watch| seat.watched_modifiers = @as(u32, @bitCast(watch.modifiers)) & 0xed,
    }
}

fn seatDestroyed(_: *river.XkbBindingsSeatV1, seat: *BindingsSeat) void {
    const owner = seat.owner;
    for (owner.seats.items, 0..) |candidate, index| {
        if (candidate != seat) continue;
        _ = owner.seats.orderedRemove(index);
        owner.allocator.destroy(seat);
        return;
    }
    unreachable;
}

fn keyboardKey(context: *anyopaque, event: NativeInput.KeyboardEvent) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return switch (event.state) {
        .pressed => self.keyPressed(event),
        .released => self.keyReleased(event),
        else => false,
    };
}

fn keyPressed(self: *Self, event: NativeInput.KeyboardEvent) bool {
    for (self.held_keys.items) |held| {
        if (held.device_id == event.device_id and held.key_code == event.key_code) return held.captured;
    }
    const event_device = self.input_manager.findDevice(event.device_id) orelse return false;
    if (!event.seat_level) {
        for (self.held_keys.items) |held| {
            if (held.key_code != event.key_code) continue;
            const held_device = self.input_manager.findDevice(held.device_id) orelse continue;
            if (!std.mem.eql(u8, held_device.seat_name, event_device.seat_name)) continue;
            self.held_keys.append(self.allocator, .{
                .device_id = event.device_id,
                .key_code = event.key_code,
                .binding = null,
                .captured = held.captured,
            }) catch return true;
            return held.captured;
        }
    }

    var session: ?EventSession = null;
    for (self.held_keys.items) |*held| {
        const binding = held.binding orelse continue;
        if (held.stop_repeat_sent or !binding.active() or !seatMatchesDevice(binding.seat.?, event_device) or
            binding.resource.getVersion() < river.XkbBindingV1.stop_repeat_since_version) continue;
        binding.resource.sendStopRepeat();
        held.stop_repeat_sent = true;
        session = bindingSession(binding);
    }

    var matched: ?*Binding = null;
    for (self.bindings.items) |binding| {
        if (!binding.active() or !seatMatchesDevice(binding.seat.?, event_device) or
            !binding.enabled or binding.modifiers != event.modifiers) continue;
        const keysym_matches = if (binding.layout_override) |layout|
            self.native_input.?.keyboardMatchesKeysym(
                event.device_id,
                event.key_code,
                layout,
                binding.keysym,
            )
        else
            containsKeysym(event.keysyms, binding.keysym);
        if (!keysym_matches) continue;
        matched = binding;
        break;
    }

    var eaten_by: ?*BindingsSeat = null;
    if (matched == null and !event.is_modifier) {
        for (self.seats.items) |seat| {
            if (!seat.active() or !seatMatchesDevice(seat.seat.?, event_device) or
                !seat.ensure_next_key_eaten) continue;
            seat.ensure_next_key_eaten = false;
            eaten_by = seat;
            break;
        }
    }
    const captured = matched != null or eaten_by != null;
    self.held_keys.append(self.allocator, .{
        .device_id = event.device_id,
        .key_code = event.key_code,
        .binding = matched,
        .captured = captured,
    }) catch {
        if (matched) |binding| binding.resource.postNoMemory() else if (eaten_by) |seat| seat.resource.postNoMemory();
        return true;
    };
    if (matched) |binding| {
        binding.resource.sendPressed();
        session = bindingSession(binding);
    } else if (eaten_by) |seat| {
        seat.resource.sendAteUnboundKey();
        session = seatSession(seat);
    }
    if (session) |event_session| self.requestManage(event_session);
    return captured;
}

fn keyReleased(self: *Self, event: NativeInput.KeyboardEvent) bool {
    for (self.held_keys.items, 0..) |held, index| {
        if (held.device_id != event.device_id or held.key_code != event.key_code) continue;
        _ = self.held_keys.orderedRemove(index);
        if (held.binding) |binding| if (binding.active()) {
            binding.resource.sendReleased();
            self.requestManage(bindingSession(binding));
        };
        return held.captured;
    }
    return false;
}

fn deviceAdded(_: *anyopaque, _: *InputManager.Device) void {}

fn deviceRemoved(context: *anyopaque, device: *InputManager.Device) void {
    if (device.device_type != .keyboard) return;
    const self: *Self = @ptrCast(@alignCast(context));
    self.releaseDevice(device);
    self.syncSeatModifiers(device.seat_name);
}

fn deviceSeatChanged(context: *anyopaque, device: *InputManager.Device, previous_name: [:0]const u8) void {
    if (device.device_type != .keyboard) return;
    const self: *Self = @ptrCast(@alignCast(context));
    self.releaseDevice(device);
    self.syncSeatModifiers(previous_name);
    self.syncSeatModifiers(device.seat_name);
}

fn releaseDevice(self: *Self, device: *InputManager.Device) void {
    var session: ?EventSession = null;
    var index: usize = 0;
    while (index < self.held_keys.items.len) {
        const held = self.held_keys.items[index];
        if (held.device_id != device.id) {
            index += 1;
            continue;
        }
        _ = self.held_keys.orderedRemove(index);
        if (held.binding) |binding| if (binding.active()) {
            binding.resource.sendReleased();
            session = bindingSession(binding);
        };
    }
    if (session) |event_session| self.requestManage(event_session);
}

fn syncSeatModifiers(self: *Self, name: []const u8) void {
    var modifiers: u32 = 0;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        if (device.device_type != .keyboard or !std.mem.eql(u8, device.seat_name, name)) continue;
        modifiers = if (self.native_input) |native_input|
            native_input.deviceEffectiveModifiers(device.id) orelse 0
        else
            0;
        break;
    }
    var session: ?EventSession = null;
    for (self.seats.items) |seat| {
        if (!seat.active() or !std.mem.eql(u8, seat.seat.?.name(), name)) continue;
        const old = seat.modifiers;
        seat.modifiers = modifiers;
        if ((seat.watched_modifiers & (old ^ modifiers)) == 0) continue;
        seat.resource.sendModifiersUpdate(@bitCast(old & 0xed), @bitCast(modifiers & 0xed));
        session = seatSession(seat);
    }
    if (session) |event_session| self.requestManage(event_session);
}

fn modifiersChanged(context: *anyopaque, source: ?NativeInput.DeviceId, _: u32, new: u32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const device = if (source) |id| self.input_manager.findDevice(id) else null;
    var session: ?EventSession = null;
    for (self.seats.items) |seat| {
        if (!seat.active() or (device != null and !seatMatchesDevice(seat.seat.?, device.?))) continue;
        const old = seat.modifiers;
        seat.modifiers = new;
        if ((seat.watched_modifiers & (old ^ new)) == 0) continue;
        seat.resource.sendModifiersUpdate(@bitCast(old & 0xed), @bitCast(new & 0xed));
        session = seatSession(seat);
    }
    if (session) |event_session| self.requestManage(event_session);
}

fn seatMatchesDevice(seat: *const Seat, device: *const InputManager.Device) bool {
    return std.mem.eql(u8, seat.name(), device.seat_name);
}

fn bindingSession(binding: *Binding) EventSession {
    return .{ .generation = binding.generation.?, .client = binding.resource.getClient() };
}

fn seatSession(seat: *BindingsSeat) EventSession {
    return .{ .generation = seat.generation.?, .client = seat.resource.getClient() };
}

fn requestManage(self: *Self, session: EventSession) void {
    self.window_manager.requestBindingManage(session.generation, session.client);
}

fn containsKeysym(keysyms: []const u32, expected: u32) bool {
    for (keysyms) |keysym| if (keysym == expected) return true;
    return false;
}

test "keysym matching checks every symbol" {
    try std.testing.expect(containsKeysym(&.{ 1, 2, 3 }, 2));
    try std.testing.expect(!containsKeysym(&.{ 1, 2, 3 }, 4));
}

test {
    std.testing.refAllDecls(Self);
}
