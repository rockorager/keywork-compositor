//! River per-keyboard xkbcommon configuration protocol.

const Self = @This();
const std = @import("std");
const wayland = @import("wayland");
const NativeInput = @import("../backend/native_input.zig");
const InputManager = @import("input_manager.zig");
const SecurityContext = @import("../wayland/security_context.zig");
const wl = wayland.server.wl;
const river = wayland.server.river;

const maximum_keymap_size = 16 * 1024 * 1024;

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
security_context: *SecurityContext,
input_manager: *InputManager,
native_input: ?*NativeInput,
keymap_compiler: NativeInput.KeymapCompiler,
managers: std.ArrayList(*Manager),
keymaps: std.ArrayList(*Keymap),
keyboards: std.ArrayList(*Keyboard),
device_listener: InputManager.DeviceListener,
resource_listener: InputManager.ResourceListener,

const Manager = struct {
    owner: *Self,
    resource: ?*river.XkbConfigV1,
    stopped: bool = false,
};

const Keymap = struct {
    owner: *Self,
    manager: *Manager,
    resource: ?*river.XkbKeymapV1,
    keymap: ?*NativeInput.Keymap = null,
};

const KeyboardState = struct {
    keymap: *const NativeInput.Keymap,
    layout_index: u32,
    capslock_enabled: bool,
    numlock_enabled: bool,
};

const Keyboard = struct {
    owner: *Self,
    manager: *Manager,
    device: *InputManager.Device,
    resource: ?*river.XkbKeyboardV1,
    state: KeyboardState,
    removed: bool = false,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    security_context: *SecurityContext,
    input_manager: *InputManager,
    native_input: ?*NativeInput,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = undefined,
        .security_context = security_context,
        .input_manager = input_manager,
        .native_input = native_input,
        .keymap_compiler = undefined,
        .managers = .empty,
        .keymaps = .empty,
        .keyboards = .empty,
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
    try self.keymap_compiler.init(allocator, io);
    errdefer self.keymap_compiler.deinit();
    self.global = try wl.Global.create(display, river.XkbConfigV1, 2, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    try input_manager.addResourceListener(&self.resource_listener);
    errdefer input_manager.removeResourceListener(&self.resource_listener);
    try input_manager.addDeviceListener(&self.device_listener);
    errdefer input_manager.removeDeviceListener(&self.device_listener);
    if (native_input) |input| {
        input.setKeyboardStateListener(.{
            .context = self,
            .changed = keyboardStateChanged,
        });
    }
}

pub fn detachNativeInput(self: *Self) void {
    const native_input = self.native_input orelse return;
    native_input.clearKeyboardStateListener();
    self.native_input = null;
}

pub fn deinit(self: *Self) void {
    self.detachNativeInput();
    self.input_manager.removeDeviceListener(&self.device_listener);
    self.input_manager.removeResourceListener(&self.resource_listener);
    for (self.managers.items) |manager| std.debug.assert(manager.resource == null);
    for (self.keymaps.items) |keymap| std.debug.assert(keymap.resource == null);
    for (self.keyboards.items) |keyboard| std.debug.assert(keyboard.resource == null);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.deinitStorage();
    self.keymap_compiler.deinit();
    self.* = undefined;
}

fn deinitStorage(self: *Self) void {
    for (self.keyboards.items) |keyboard| {
        InputManager.releaseDevice(keyboard.device);
        self.allocator.destroy(keyboard);
    }
    self.keyboards.deinit(self.allocator);
    for (self.keymaps.items) |keymap| {
        if (keymap.keymap) |compiled| compiled.unref();
        self.allocator.destroy(keymap);
    }
    self.keymaps.deinit(self.allocator);
    for (self.managers.items) |manager| self.allocator.destroy(manager);
    self.managers.deinit(self.allocator);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = river.XkbConfigV1.create(client, version, id) catch
        return client.postNoMemory();
    const manager = self.allocator.create(Manager) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    manager.* = .{ .owner = self, .resource = resource };
    self.managers.append(self.allocator, manager) catch {
        self.allocator.destroy(manager);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Manager, managerRequest, managerDestroyed, manager);
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        const input_resource = self.input_manager.inputResource(client, device) orelse continue;
        self.createKeyboard(manager, device, input_resource) catch resource.postNoMemory();
    }
}

fn managerRequest(resource: *river.XkbConfigV1, request: river.XkbConfigV1.Request, manager: *Manager) void {
    switch (request) {
        .stop => {
            if (manager.stopped) return;
            manager.stopped = true;
            resource.sendFinished();
        },
        .destroy => if (!manager.stopped)
            resource.postError(.invalid_destroy, "xkb manager must be stopped before destruction")
        else
            resource.destroy(),
        .create_keymap => |keymap| manager.owner.createKeymap(
            manager,
            resource,
            keymap.id,
            keymap.fd,
            protocolEnumRaw(keymap.format),
        ),
    }
}

fn managerDestroyed(_: *river.XkbConfigV1, manager: *Manager) void {
    manager.resource = null;
    manager.stopped = true;
    manager.owner.maybeDestroyManager(manager);
}

fn maybeDestroyManager(self: *Self, manager: *Manager) void {
    if (manager.resource != null) return;
    for (self.keyboards.items) |keyboard| if (keyboard.manager == manager) return;
    for (self.keymaps.items) |keymap| if (keymap.manager == manager) return;
    for (self.managers.items, 0..) |candidate, index| {
        if (candidate != manager) continue;
        _ = self.managers.orderedRemove(index);
        self.allocator.destroy(manager);
        return;
    }
    unreachable;
}

fn createKeymap(
    self: *Self,
    manager: *Manager,
    parent: *river.XkbConfigV1,
    id: u32,
    fd: std.posix.fd_t,
    raw_format: u32,
) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(self.io);
    const format = enumValue(NativeInput.KeymapFormat, raw_format) orelse
        return parent.postError(.invalid_format, "invalid xkb keymap format");
    const resource = river.XkbKeymapV1.create(
        parent.getClient(),
        @min(parent.getVersion(), river.XkbKeymapV1.generated_version),
        id,
    ) catch return parent.postNoMemory();
    const keymap = self.allocator.create(Keymap) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    keymap.* = .{ .owner = self, .manager = manager, .resource = resource };
    self.keymaps.append(self.allocator, keymap) catch {
        self.allocator.destroy(keymap);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Keymap, keymapRequest, keymapDestroyed, keymap);

    const stat = file.stat(self.io) catch return resource.sendFailure("failed to stat keymap fd");
    if (stat.kind != .file or stat.size == 0 or stat.size > maximum_keymap_size) {
        return resource.sendFailure("keymap fd must contain a regular file up to 16 MiB");
    }
    const mapping = std.posix.mmap(
        null,
        @intCast(stat.size),
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => return resource.postNoMemory(),
        else => return resource.sendFailure("failed to map keymap fd"),
    };
    defer std.posix.munmap(mapping);
    keymap.keymap = self.keymap_compiler.compile(format, mapping) catch |err| switch (err) {
        error.OutOfMemory => return resource.postNoMemory(),
        else => return resource.sendFailure("failed to store compiled keymap"),
    };
    if (keymap.keymap == null) return resource.sendFailure("failed to compile keymap");
    resource.sendSuccess();
}

fn keymapRequest(resource: *river.XkbKeymapV1, request: river.XkbKeymapV1.Request, _: *Keymap) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn keymapDestroyed(_: *river.XkbKeymapV1, keymap: *Keymap) void {
    const owner = keymap.owner;
    const manager = keymap.manager;
    keymap.resource = null;
    if (keymap.keymap) |compiled| compiled.unref();
    for (owner.keymaps.items, 0..) |candidate, index| {
        if (candidate != keymap) continue;
        _ = owner.keymaps.orderedRemove(index);
        owner.allocator.destroy(keymap);
        owner.maybeDestroyManager(manager);
        return;
    }
    unreachable;
}

fn deviceAdded(_: *anyopaque, _: *InputManager.Device) void {}

fn deviceRemoved(context: *anyopaque, device: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.keyboards.items) |keyboard| {
        if (keyboard.device != device or keyboard.removed) continue;
        if (keyboard.resource) |resource| resource.sendRemoved();
        keyboard.removed = true;
    }
}

fn inputResourceCreated(context: *anyopaque, device: *InputManager.Device, input_resource: *river.InputDeviceV1) void {
    if (device.device_type != .keyboard) return;
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.managers.items) |manager| {
        const resource = manager.resource orelse continue;
        if (manager.stopped or resource.getClient() != input_resource.getClient()) continue;
        self.createKeyboard(manager, device, input_resource) catch resource.postNoMemory();
    }
}

fn createKeyboard(
    self: *Self,
    manager: *Manager,
    device: *InputManager.Device,
    input_resource: *river.InputDeviceV1,
) !void {
    if (device.device_type != .keyboard) return;
    for (self.keyboards.items) |keyboard| {
        if (keyboard.manager == manager and keyboard.device == device and keyboard.resource != null) return;
    }
    const native_input = self.native_input orelse return;
    const native_state = native_input.keyboardState(device.id) orelse return;
    const resource = try river.XkbKeyboardV1.create(
        manager.resource.?.getClient(),
        @min(manager.resource.?.getVersion(), river.XkbKeyboardV1.generated_version),
        0,
    );
    errdefer resource.destroy();
    const keyboard = try self.allocator.create(Keyboard);
    errdefer self.allocator.destroy(keyboard);
    keyboard.* = .{
        .owner = self,
        .manager = manager,
        .device = device,
        .resource = resource,
        .state = stateKey(native_state),
    };
    try self.keyboards.append(self.allocator, keyboard);
    InputManager.retainDevice(device);
    resource.setHandler(*Keyboard, keyboardRequest, keyboardDestroyed, keyboard);
    manager.resource.?.sendXkbKeyboard(resource);
    resource.sendInputDevice(input_resource);
    sendAllState(resource, native_state);
}

fn keyboardRequest(resource: *river.XkbKeyboardV1, request: river.XkbKeyboardV1.Request, keyboard: *Keyboard) void {
    if (request == .destroy) return resource.destroy();
    if (keyboard.removed or !keyboard.device.connected) return;
    const native_input = keyboard.owner.native_input orelse return;
    switch (request) {
        .destroy => unreachable,
        .set_keymap => |set| {
            const data = set.keymap.getUserData() orelse
                return resource.postError(.invalid_keymap, "invalid xkb keymap object");
            const keymap: *Keymap = @ptrCast(@alignCast(data));
            if (keymap.resource != set.keymap or
                set.keymap.getClient() != resource.getClient() or
                keymap.keymap == null)
            {
                return resource.postError(.invalid_keymap, "xkb keymap creation did not succeed");
            }
            _ = native_input.setKeyboardKeymap(keyboard.device.id, keymap.keymap.?) catch
                return resource.postNoMemory();
        },
        .set_layout_by_index => |set| _ = native_input.setKeyboardLayoutIndex(
            keyboard.device.id,
            set.index,
        ),
        .set_layout_by_name => |set| _ = native_input.setKeyboardLayoutName(
            keyboard.device.id,
            set.name,
        ),
        .capslock_enable => _ = native_input.setKeyboardCapslock(keyboard.device.id, true),
        .capslock_disable => _ = native_input.setKeyboardCapslock(keyboard.device.id, false),
        .numlock_enable => _ = native_input.setKeyboardNumlock(keyboard.device.id, true),
        .numlock_disable => _ = native_input.setKeyboardNumlock(keyboard.device.id, false),
    }
}

fn keyboardDestroyed(_: *river.XkbKeyboardV1, keyboard: *Keyboard) void {
    const owner = keyboard.owner;
    const manager = keyboard.manager;
    keyboard.resource = null;
    InputManager.releaseDevice(keyboard.device);
    for (owner.keyboards.items, 0..) |candidate, index| {
        if (candidate != keyboard) continue;
        _ = owner.keyboards.orderedRemove(index);
        owner.allocator.destroy(keyboard);
        owner.maybeDestroyManager(manager);
        return;
    }
    unreachable;
}

fn keyboardStateChanged(context: *anyopaque, id: NativeInput.DeviceId, state: NativeInput.KeyboardState) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.keyboards.items) |keyboard| {
        if (keyboard.device.id != id or keyboard.resource == null or keyboard.removed) continue;
        sendChangedState(keyboard, state);
    }
}

fn sendAllState(resource: *river.XkbKeyboardV1, state: NativeInput.KeyboardState) void {
    resource.sendLayout(state.layout_index, state.layout_name);
    if (state.capslock_enabled) resource.sendCapslockEnabled() else resource.sendCapslockDisabled();
    if (state.numlock_enabled) resource.sendNumlockEnabled() else resource.sendNumlockDisabled();
    if (resource.getVersion() >= river.XkbKeyboardV1.done_since_version) resource.sendDone();
}

fn sendChangedState(keyboard: *Keyboard, state: NativeInput.KeyboardState) void {
    const resource = keyboard.resource.?;
    const current = stateKey(state);
    const keymap_changed = keyboard.state.keymap != current.keymap;
    var changed = false;
    if (keymap_changed or keyboard.state.layout_index != current.layout_index) {
        resource.sendLayout(state.layout_index, state.layout_name);
        changed = true;
    }
    if (keymap_changed or keyboard.state.capslock_enabled != current.capslock_enabled) {
        if (state.capslock_enabled) resource.sendCapslockEnabled() else resource.sendCapslockDisabled();
        changed = true;
    }
    if (keymap_changed or keyboard.state.numlock_enabled != current.numlock_enabled) {
        if (state.numlock_enabled) resource.sendNumlockEnabled() else resource.sendNumlockDisabled();
        changed = true;
    }
    keyboard.state = current;
    if (changed and resource.getVersion() >= river.XkbKeyboardV1.done_since_version) resource.sendDone();
}

fn stateKey(state: NativeInput.KeyboardState) KeyboardState {
    return .{
        .keymap = state.keymap,
        .layout_index = state.layout_index,
        .capslock_enabled = state.capslock_enabled,
        .numlock_enabled = state.numlock_enabled,
    };
}

fn protocolEnumRaw(value: anytype) u32 {
    return @bitCast(@as(i32, @intFromEnum(value)));
}

fn enumValue(comptime T: type, raw: u32) ?T {
    inline for (std.meta.fields(T)) |field| if (raw == field.value) return @enumFromInt(raw);
    return null;
}

test "unknown keymap formats are rejected" {
    try std.testing.expectEqual(NativeInput.KeymapFormat.text_v2, enumValue(NativeInput.KeymapFormat, 2).?);
    try std.testing.expect(enumValue(NativeInput.KeymapFormat, 3) == null);
}

test {
    std.testing.refAllDecls(Self);
}
