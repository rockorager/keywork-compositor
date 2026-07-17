//! Configured key bindings for compositor policy and application launching.

const Self = @This();

const std = @import("std");
const NativeInput = @import("backend/native_input.zig");
const Config = @import("config.zig");
const Launcher = @import("launcher.zig");
const KeyboardShortcutsInhibit = @import("wayland/keyboard_shortcuts_inhibit.zig");
const InputManager = @import("input_manager.zig");
const WindowManager = @import("window_manager.zig");

const log = std.log.scoped(.keybindings);

allocator: std.mem.Allocator,
manager: *WindowManager,
input_manager: *InputManager,
shortcuts_inhibit: *KeyboardShortcutsInhibit,
native_input: ?*NativeInput,
launcher: ?*Launcher = null,
bindings: []const Config.Binding = &.{},
device_listener: InputManager.DeviceListener,
held_keys: std.ArrayList(HeldKey) = .empty,

const HeldKey = struct {
    device_id: NativeInput.DeviceId,
    key_code: u32,
    disposition: NativeInput.KeyboardEventDisposition,
};

pub fn init(self: *Self, allocator: std.mem.Allocator, manager: *WindowManager, input_manager: *InputManager, shortcuts_inhibit: *KeyboardShortcutsInhibit, native_input: ?*NativeInput) !void {
    self.* = .{
        .allocator = allocator,
        .manager = manager,
        .input_manager = input_manager,
        .shortcuts_inhibit = shortcuts_inhibit,
        .native_input = native_input,
        .device_listener = .{ .context = self, .added = deviceAdded, .removed = deviceRemoved },
    };
    errdefer self.held_keys.deinit(allocator);
    try input_manager.addDeviceListener(&self.device_listener);
    errdefer input_manager.removeDeviceListener(&self.device_listener);
    if (native_input) |input| input.setKeyboardEventListener(.{ .context = self, .key = keyboardKey, .modifiers = modifiersChanged });
}

pub fn detachNativeInput(self: *Self) void {
    const input = self.native_input orelse return;
    input.clearKeyboardEventListener();
    self.native_input = null;
    self.held_keys.clearRetainingCapacity();
}

pub fn setLauncher(self: *Self, launcher: *Launcher) void {
    self.launcher = launcher;
}

pub fn setConfiguredBindings(self: *Self, bindings: []const Config.Binding) void {
    self.bindings = bindings;
}

pub fn deinit(self: *Self) void {
    self.detachNativeInput();
    self.input_manager.removeDeviceListener(&self.device_listener);
    self.held_keys.deinit(self.allocator);
    self.* = undefined;
}

fn keyboardKey(context: *anyopaque, event: NativeInput.KeyboardEvent) NativeInput.KeyboardEventDisposition {
    const self: *Self = @ptrCast(@alignCast(context));
    return switch (event.state) {
        .pressed => self.keyPressed(event),
        .released => self.keyReleased(event),
        else => .forwarded,
    };
}

fn keyPressed(self: *Self, event: NativeInput.KeyboardEvent) NativeInput.KeyboardEventDisposition {
    for (self.held_keys.items) |held| if (held.device_id == event.device_id and held.key_code == event.key_code) return held.disposition;
    const device = self.input_manager.findDevice(event.device_id) orelse return .forwarded;
    // libinput reports duplicate physical presses while the seat-level key is
    // already down. They inherit the first press's ownership without running
    // its command again.
    if (!event.seat_level) {
        for (self.held_keys.items) |held| {
            if (held.key_code != event.key_code) continue;
            const held_device = self.input_manager.findDevice(held.device_id) orelse continue;
            if (!std.mem.eql(u8, held_device.seat_name, device.seat_name)) continue;
            self.held_keys.append(self.allocator, .{
                .device_id = event.device_id,
                .key_code = event.key_code,
                .disposition = held.disposition,
            }) catch return .captured;
            return held.disposition;
        }
    }
    const disposition: NativeInput.KeyboardEventDisposition = if (self.shortcuts_inhibit.inhibitsSeatNamed(device.seat_name))
        .shortcuts_inhibited
    else if (matchBinding(self.bindings, event.modifiers, event.keysyms)) |binding| blk: {
        switch (binding.action) {
            .command => |command| self.manager.execute(command),
            .run => |argv| {
                const launcher = self.launcher orelse {
                    log.err("cannot launch {s}: launcher is unavailable", .{argv[0]});
                    break :blk .captured;
                };
                launcher.launch(argv) catch |err| {
                    log.err("failed to launch {s}: {t}", .{ argv[0], err });
                };
            },
        }
        break :blk .captured;
    } else .forwarded;
    self.held_keys.append(self.allocator, .{ .device_id = event.device_id, .key_code = event.key_code, .disposition = disposition }) catch return .captured;
    return disposition;
}

fn keyReleased(self: *Self, event: NativeInput.KeyboardEvent) NativeInput.KeyboardEventDisposition {
    for (self.held_keys.items, 0..) |held, index| {
        if (held.device_id != event.device_id or held.key_code != event.key_code) continue;
        _ = self.held_keys.orderedRemove(index);
        return held.disposition;
    }
    return .forwarded;
}

fn matchBinding(bindings: []const Config.Binding, modifiers: u32, keysyms: []const u32) ?Config.Binding {
    for (bindings) |binding| {
        if (binding.modifiers != modifiers) continue;
        for (keysyms) |keysym| if (keysym == binding.keysym) return binding;
    }
    return null;
}

fn deviceAdded(_: *anyopaque, _: *InputManager.Device) void {}
fn deviceRemoved(context: *anyopaque, device: *InputManager.Device) void {
    if (device.device_type == .keyboard) releaseDevice(@ptrCast(@alignCast(context)), device.id);
}
fn releaseDevice(self: *Self, id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.held_keys.items.len) {
        if (self.held_keys.items[index].device_id == id) _ = self.held_keys.orderedRemove(index) else index += 1;
    }
}
fn modifiersChanged(_: *anyopaque, _: ?NativeInput.DeviceId, _: u32, _: u32) void {}

test "binding matching checks every symbol and exact modifiers" {
    const test_bindings = [_]Config.Binding{
        .{ .modifiers = Config.super, .keysym = 'j', .action = .{ .command = .{ .focus_direction = .down } } },
    };
    try std.testing.expectEqual(.down, matchBinding(&test_bindings, Config.super, &.{ 0, 'j' }).?.action.command.focus_direction);
    try std.testing.expect(matchBinding(&test_bindings, Config.super | Config.shift, &.{'j'}) == null);
    try std.testing.expect(matchBinding(&test_bindings, 0, &.{'j'}) == null);
}

test "held key records press disposition for release" {
    var held: std.ArrayList(HeldKey) = .empty;
    defer held.deinit(std.testing.allocator);
    try held.append(std.testing.allocator, .{ .device_id = 4, .key_code = 12, .disposition = .captured });
    const entry = held.orderedRemove(0);
    try std.testing.expectEqual(NativeInput.KeyboardEventDisposition.captured, entry.disposition);
}
