//! Privileged virtual keyboard input for input methods and automation clients.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

const maximum_keymap_size = 16 * 1024 * 1024;

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
security_context: *SecurityContext,
seat: *Seat,
devices: std.ArrayList(*Device),
inhibited: bool,
deferred_keymap: ?DeferredKeymap,

const DeferredKeymap = struct {
    fd: std.posix.fd_t,
    size: u32,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    security_context: *SecurityContext,
    seat: *Seat,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = try wl.Global.create(
            display,
            zwp.VirtualKeyboardManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .security_context = security_context,
        .seat = seat,
        .devices = .empty,
        .inhibited = false,
        .deferred_keymap = null,
    };
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.devices.items.len == 0);
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    if (self.deferred_keymap) |keymap| {
        const file: std.Io.File = .{ .handle = keymap.fd, .flags = .{ .nonblocking = false } };
        file.close(self.io);
    }
    self.devices.deinit(self.allocator);
    self.* = undefined;
}

pub fn setInhibited(self: *Self, inhibited: bool) void {
    if (self.inhibited == inhibited) return;
    self.inhibited = inhibited;
    if (!inhibited) {
        if (self.deferred_keymap) |keymap| {
            self.deferred_keymap = null;
            self.seat.setKeymap(.xkb_v1, keymap.fd, keymap.size);
        }
        return;
    }
    for (self.devices.items) |device| {
        while (device.pressed_keys.pop()) |key_code| {
            self.seat.virtualKey(0, key_code, .released) catch unreachable;
        }
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.VirtualKeyboardManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.VirtualKeyboardManagerV1,
    request: zwp.VirtualKeyboardManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .create_virtual_keyboard => |create| {
            if (!self.seat.ownsResource(create.seat)) {
                resource.getClient().postImplementationError("unknown wl_seat resource");
                return;
            }
            Device.create(self, resource, create.id) catch resource.postNoMemory();
        },
    }
}

const Device = struct {
    manager: *Self,
    resource: *zwp.VirtualKeyboardV1,
    has_keymap: bool,
    registered: bool,
    pressed_keys: std.ArrayList(u32),

    fn create(
        manager: *Self,
        manager_resource: *zwp.VirtualKeyboardManagerV1,
        id: u32,
    ) !void {
        const resource = try zwp.VirtualKeyboardV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Device);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .has_keymap = false,
            .registered = false,
            .pressed_keys = .empty,
        };
        errdefer self.pressed_keys.deinit(manager.allocator);
        try manager.devices.append(manager.allocator, self);
        resource.setHandler(*Device, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.VirtualKeyboardV1,
        request: zwp.VirtualKeyboardV1.Request,
        self: *Device,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .keymap => |keymap| self.setKeymap(resource, keymap.format, keymap.fd, keymap.size),
            .key => |key| self.sendKey(resource, key.time, key.key, key.state),
            .modifiers => |modifiers| {
                if (!self.requireKeymap(resource)) return;
                if (self.manager.inhibited) return;
                self.manager.seat.setVirtualModifiers(
                    modifiers.mods_depressed,
                    modifiers.mods_latched,
                    modifiers.mods_locked,
                    modifiers.group,
                );
            },
        }
    }

    fn setKeymap(
        self: *Device,
        resource: *zwp.VirtualKeyboardV1,
        format_value: u32,
        fd: std.posix.fd_t,
        size: u32,
    ) void {
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        if (format_value != @intFromEnum(wl.Keyboard.KeymapFormat.xkb_v1) or
            !validKeymap(self.manager.io, file, size))
        {
            file.close(self.manager.io);
            resource.getClient().postImplementationError("invalid virtual keyboard keymap");
            return;
        }
        if (self.manager.inhibited) {
            if (self.manager.deferred_keymap) |old| {
                const old_file: std.Io.File = .{
                    .handle = old.fd,
                    .flags = .{ .nonblocking = false },
                };
                old_file.close(self.manager.io);
            }
            self.manager.deferred_keymap = .{ .fd = fd, .size = size };
        } else {
            self.manager.seat.setKeymap(.xkb_v1, fd, size);
        }
        self.has_keymap = true;
        if (!self.registered) {
            self.registered = true;
            self.manager.seat.addVirtualKeyboard();
        }
    }

    fn sendKey(
        self: *Device,
        resource: *zwp.VirtualKeyboardV1,
        time: u32,
        key_code: u32,
        state_value: u32,
    ) void {
        if (!self.requireKeymap(resource)) return;
        if (self.manager.inhibited) return;
        const state: wl.Keyboard.KeyState = switch (state_value) {
            @intFromEnum(wl.Keyboard.KeyState.released) => .released,
            @intFromEnum(wl.Keyboard.KeyState.pressed) => .pressed,
            else => {
                resource.getClient().postImplementationError("invalid virtual keyboard key state");
                return;
            },
        };
        switch (state) {
            .pressed => {
                for (self.pressed_keys.items) |pressed| if (pressed == key_code) return;
                self.pressed_keys.append(self.manager.allocator, key_code) catch {
                    resource.postNoMemory();
                    return;
                };
                self.manager.seat.virtualKey(time, key_code, state) catch {
                    _ = self.pressed_keys.pop();
                    resource.postNoMemory();
                };
            },
            .released => {
                for (self.pressed_keys.items, 0..) |pressed, index| {
                    if (pressed != key_code) continue;
                    _ = self.pressed_keys.orderedRemove(index);
                    self.manager.seat.virtualKey(time, key_code, state) catch unreachable;
                    return;
                }
            },
            else => unreachable,
        }
    }

    fn requireKeymap(self: *const Device, resource: *zwp.VirtualKeyboardV1) bool {
        if (self.has_keymap) return true;
        resource.postError(.no_keymap, "virtual keyboard has no keymap");
        return false;
    }

    fn handleDestroy(_: *zwp.VirtualKeyboardV1, self: *Device) void {
        while (self.pressed_keys.pop()) |key_code| {
            self.manager.seat.virtualKey(0, key_code, .released) catch unreachable;
        }
        if (self.registered) self.manager.seat.removeVirtualKeyboard();
        for (self.manager.devices.items, 0..) |device, index| {
            if (device != self) continue;
            _ = self.manager.devices.orderedRemove(index);
            self.pressed_keys.deinit(self.manager.allocator);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

fn validKeymap(io: std.Io, file: std.Io.File, size: u32) bool {
    if (size == 0 or size > maximum_keymap_size) return false;
    const stat = file.stat(io) catch return false;
    if (stat.size < size) return false;
    var terminator: [1]u8 = undefined;
    const read = file.readPositionalAll(io, &terminator, size - 1) catch return false;
    return read == 1 and terminator[0] == 0;
}
