//! Minimal, fixed key bindings for the built-in window manager.

const Self = @This();

const std = @import("std");
const NativeInput = @import("backend/native_input.zig");
const Command = @import("command.zig").Command;
const KeyboardShortcutsInhibit = @import("wayland/keyboard_shortcuts_inhibit.zig");
const InputManager = @import("input_manager.zig");
const WindowManager = @import("window_manager.zig");

allocator: std.mem.Allocator,
manager: *WindowManager,
input_manager: *InputManager,
shortcuts_inhibit: *KeyboardShortcutsInhibit,
native_input: ?*NativeInput,
device_listener: InputManager.DeviceListener,
held_keys: std.ArrayList(HeldKey) = .empty,

const super: u32 = 1 << 6; // xkb Mod4/Logo
const shift: u32 = 1 << 0;

const Binding = struct { modifiers: u32, keysym: u32, command: Command };

/// Built-in defaults: Super+j/k focus, Super+Shift+j/k move, and
/// Super+t/s select tiled/scrolling layout.
const bindings = [_]Binding{
    .{ .modifiers = super, .keysym = 'j', .command = .focus_next },
    .{ .modifiers = super, .keysym = 'k', .command = .focus_previous },
    .{ .modifiers = super | shift, .keysym = 'j', .command = .move_focused_next },
    .{ .modifiers = super | shift, .keysym = 'k', .command = .move_focused_previous },
    .{ .modifiers = super, .keysym = 't', .command = .layout_tiled },
    .{ .modifiers = super, .keysym = 's', .command = .layout_scrolling },
    .{ .modifiers = super, .keysym = '1', .command = .{ .switch_workspace = 1 } },
    .{ .modifiers = super, .keysym = '2', .command = .{ .switch_workspace = 2 } },
    .{ .modifiers = super, .keysym = '3', .command = .{ .switch_workspace = 3 } },
    .{ .modifiers = super, .keysym = '4', .command = .{ .switch_workspace = 4 } },
    .{ .modifiers = super, .keysym = '5', .command = .{ .switch_workspace = 5 } },
    .{ .modifiers = super, .keysym = '6', .command = .{ .switch_workspace = 6 } },
    .{ .modifiers = super, .keysym = '7', .command = .{ .switch_workspace = 7 } },
    .{ .modifiers = super, .keysym = '8', .command = .{ .switch_workspace = 8 } },
    .{ .modifiers = super, .keysym = '9', .command = .{ .switch_workspace = 9 } },
    .{ .modifiers = super, .keysym = '0', .command = .{ .switch_workspace = 10 } },
    .{ .modifiers = super | shift, .keysym = '1', .command = .{ .move_to_workspace = 1 } },
    .{ .modifiers = super | shift, .keysym = '2', .command = .{ .move_to_workspace = 2 } },
    .{ .modifiers = super | shift, .keysym = '3', .command = .{ .move_to_workspace = 3 } },
    .{ .modifiers = super | shift, .keysym = '4', .command = .{ .move_to_workspace = 4 } },
    .{ .modifiers = super | shift, .keysym = '5', .command = .{ .move_to_workspace = 5 } },
    .{ .modifiers = super | shift, .keysym = '6', .command = .{ .move_to_workspace = 6 } },
    .{ .modifiers = super | shift, .keysym = '7', .command = .{ .move_to_workspace = 7 } },
    .{ .modifiers = super | shift, .keysym = '8', .command = .{ .move_to_workspace = 8 } },
    .{ .modifiers = super | shift, .keysym = '9', .command = .{ .move_to_workspace = 9 } },
    .{ .modifiers = super | shift, .keysym = '0', .command = .{ .move_to_workspace = 10 } },
};

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
    else if (matchBinding(event.modifiers, event.keysyms)) |binding| blk: {
        self.manager.execute(binding.command);
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

fn matchBinding(modifiers: u32, keysyms: []const u32) ?Binding {
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

test "default bindings match every symbol and exact modifiers" {
    try std.testing.expectEqual(Command.focus_next, matchBinding(super, &.{ 0, 'j' }).?.command);
    try std.testing.expectEqual(Command.move_focused_previous, matchBinding(super | shift, &.{'k'}).?.command);
    try std.testing.expect(matchBinding(super | shift, &.{'t'}) == null);
    try std.testing.expect(matchBinding(0, &.{'j'}) == null);
    try std.testing.expectEqual(@as(u8, 4), matchBinding(super, &.{'4'}).?.command.switch_workspace);
    try std.testing.expectEqual(@as(u8, 7), matchBinding(super | shift, &.{'7'}).?.command.move_to_workspace);
    try std.testing.expectEqual(@as(u8, 10), matchBinding(super, &.{'0'}).?.command.switch_workspace);
    try std.testing.expectEqual(@as(u8, 10), matchBinding(super | shift, &.{'0'}).?.command.move_to_workspace);
}

test "held key records press disposition for release" {
    var held: std.ArrayList(HeldKey) = .empty;
    defer held.deinit(std.testing.allocator);
    try held.append(std.testing.allocator, .{ .device_id = 4, .key_code = 12, .disposition = .captured });
    const entry = held.orderedRemove(0);
    try std.testing.expectEqual(NativeInput.KeyboardEventDisposition.captured, entry.disposition);
}
