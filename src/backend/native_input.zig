//! Native keyboard, pointer, and touch input through libinput.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Session = @import("session.zig");
const NestedOutput = @import("nested_wayland.zig");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("libinput.h");
    @cInclude("libudev.h");
    @cInclude("stdlib.h");
    @cInclude("xkbcommon/xkbcommon.h");
});
const wl = wayland.server.wl;

const log = std.log.scoped(.native_input);

allocator: std.mem.Allocator,
io: std.Io,
session: *Session,
session_listener: Session.Listener,
event_source: ?*wl.EventSource,
context: *c.struct_libinput,
listener: Listener,
devices: std.AutoHashMapUnmanaged(std.posix.fd_t, Session.Device),
xkb_context: *c.struct_xkb_context,
xkb_keymap: *c.struct_xkb_keymap,
xkb_state: *c.struct_xkb_state,
size: render.Size,
pointer_x: f64,
pointer_y: f64,
keyboard_count: usize,
pointer_count: usize,
touch_count: usize,
modifiers: Modifiers,
suspended: bool,
initialized: bool,
failed: bool,

pub const Listener = NestedOutput.Listener;

const Modifiers = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
};

const libinput_interface: c.struct_libinput_interface = .{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    event_loop: *wl.EventLoop,
    session: *Session,
    size: render.Size,
    listener: Listener,
) !void {
    std.debug.assert(size.width > 0 and size.height > 0);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .session = session,
        .session_listener = .{
            .context = self,
            .activated = handleSessionActivated,
            .deactivated = handleSessionDeactivated,
            .failed = handleSessionFailed,
        },
        .event_source = null,
        .context = undefined,
        .listener = listener,
        .devices = .empty,
        .xkb_context = undefined,
        .xkb_keymap = undefined,
        .xkb_state = undefined,
        .size = size,
        .pointer_x = @as(f64, @floatFromInt(size.width)) / 2,
        .pointer_y = @as(f64, @floatFromInt(size.height)) / 2,
        .keyboard_count = 0,
        .pointer_count = 0,
        .touch_count = 0,
        .modifiers = .{},
        .suspended = false,
        .initialized = false,
        .failed = false,
    };
    errdefer self.devices.deinit(allocator);

    self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    errdefer c.xkb_context_unref(self.xkb_context);
    self.xkb_keymap = c.xkb_keymap_new_from_names2(
        self.xkb_context,
        null,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    errdefer c.xkb_keymap_unref(self.xkb_keymap);
    self.xkb_state = c.xkb_state_new(self.xkb_keymap) orelse return error.XkbStateFailed;
    errdefer c.xkb_state_unref(self.xkb_state);
    try self.installKeymap();
    listener.keyboard_repeat_info(listener.context, 25, 600);

    const udev = c.udev_new() orelse return error.UdevContextFailed;
    defer _ = c.udev_unref(udev);
    self.context = c.libinput_udev_create_context(
        &libinput_interface,
        self,
        udev,
    ) orelse return error.LibinputContextFailed;
    errdefer _ = c.libinput_unref(self.context);
    if (c.libinput_udev_assign_seat(self.context, session.name().ptr) != 0) {
        return error.AssignSeatFailed;
    }
    errdefer self.clearCapabilities();
    try self.dispatchEvents();

    const fd = c.libinput_get_fd(self.context);
    if (fd < 0) return error.GetLibinputFdFailed;
    self.event_source = try event_loop.addFd(
        *Self,
        fd,
        .{ .readable = true },
        handleEvent,
        self,
    );
    errdefer self.event_source.?.remove();
    try session.addListener(&self.session_listener);
    self.initialized = true;
}

pub fn deinit(self: *Self) void {
    self.initialized = false;
    self.session.removeListener(&self.session_listener);
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    self.clearCapabilities();
    _ = c.libinput_unref(self.context);
    std.debug.assert(self.devices.count() == 0);
    self.devices.deinit(self.allocator);
    c.xkb_state_unref(self.xkb_state);
    c.xkb_keymap_unref(self.xkb_keymap);
    c.xkb_context_unref(self.xkb_context);
    self.* = undefined;
}

fn installKeymap(self: *Self) !void {
    const text_pointer = c.xkb_keymap_get_as_string(
        self.xkb_keymap,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
    ) orelse return error.SerializeKeymapFailed;
    defer c.free(text_pointer);
    const text = std.mem.span(text_pointer);
    const size = std.math.add(usize, text.len, 1) catch return error.KeymapTooLarge;
    if (size > std.math.maxInt(u32)) return error.KeymapTooLarge;

    const fd = try std.posix.memfd_create("keywork-keymap", 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    errdefer file.close(self.io);
    try file.setLength(self.io, size);
    try file.writeStreamingAll(self.io, text.ptr[0..size]);
    self.listener.keyboard_keymap(
        self.listener.context,
        .xkb_v1,
        fd,
        @intCast(size),
    );
}

fn dispatchEvents(self: *Self) !void {
    if (c.libinput_dispatch(self.context) != 0) return error.LibinputDispatchFailed;
    while (c.libinput_get_event(self.context)) |event| {
        defer c.libinput_event_destroy(event);
        self.processEvent(event);
        if (self.failed) return error.InputFailed;
    }
}

fn processEvent(self: *Self, event: *c.struct_libinput_event) void {
    switch (c.libinput_event_get_type(event)) {
        c.LIBINPUT_EVENT_DEVICE_ADDED => self.deviceAdded(c.libinput_event_get_device(event).?),
        c.LIBINPUT_EVENT_DEVICE_REMOVED => self.deviceRemoved(c.libinput_event_get_device(event).?),
        c.LIBINPUT_EVENT_KEYBOARD_KEY => self.keyboardKey(
            c.libinput_event_get_keyboard_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_MOTION => self.pointerMotion(
            c.libinput_event_get_pointer_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE => self.pointerMotionAbsolute(
            c.libinput_event_get_pointer_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_BUTTON => self.pointerButton(
            c.libinput_event_get_pointer_event(event).?,
        ),
        c.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL => self.pointerScroll(
            c.libinput_event_get_pointer_event(event).?,
            .wheel,
        ),
        c.LIBINPUT_EVENT_POINTER_SCROLL_FINGER => self.pointerScroll(
            c.libinput_event_get_pointer_event(event).?,
            .finger,
        ),
        c.LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS => self.pointerScroll(
            c.libinput_event_get_pointer_event(event).?,
            .continuous,
        ),
        c.LIBINPUT_EVENT_TOUCH_DOWN => self.touchDown(c.libinput_event_get_touch_event(event).?),
        c.LIBINPUT_EVENT_TOUCH_UP => self.touchUp(c.libinput_event_get_touch_event(event).?),
        c.LIBINPUT_EVENT_TOUCH_MOTION => self.touchMotion(c.libinput_event_get_touch_event(event).?),
        c.LIBINPUT_EVENT_TOUCH_CANCEL => self.listener.touch_cancel(self.listener.context),
        c.LIBINPUT_EVENT_TOUCH_FRAME => self.listener.touch_frame(self.listener.context),
        else => {},
    }
}

fn deviceAdded(self: *Self, device: *c.struct_libinput_device) void {
    if (self.suspended) return;
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0) {
        self.keyboard_count += 1;
        if (self.keyboard_count == 1) {
            self.listener.keyboard_available(self.listener.context, true);
            self.listener.keyboard_enter(self.listener.context, &.{});
        }
    }
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_POINTER) != 0) {
        self.pointer_count += 1;
        if (self.pointer_count == 1) self.listener.pointer_available(self.listener.context, true);
    }
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TOUCH) != 0) {
        self.touch_count += 1;
        if (self.touch_count == 1) self.listener.touch_available(self.listener.context, true);
    }
}

fn deviceRemoved(self: *Self, device: *c.struct_libinput_device) void {
    if (self.suspended) return;
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0) {
        std.debug.assert(self.keyboard_count > 0);
        self.keyboard_count -= 1;
        if (self.keyboard_count == 0) {
            self.listener.keyboard_available(self.listener.context, false);
            self.resetKeyboardState() catch |err| self.fail(err);
        }
    }
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_POINTER) != 0) {
        std.debug.assert(self.pointer_count > 0);
        self.pointer_count -= 1;
        if (self.pointer_count == 0) self.listener.pointer_available(self.listener.context, false);
    }
    if (c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TOUCH) != 0) {
        std.debug.assert(self.touch_count > 0);
        self.touch_count -= 1;
        if (self.touch_count == 0) self.listener.touch_available(self.listener.context, false);
    }
}

fn keyboardKey(self: *Self, event: *c.struct_libinput_event_keyboard) void {
    const key = c.libinput_event_keyboard_get_key(event);
    const pressed = c.libinput_event_keyboard_get_key_state(event) == c.LIBINPUT_KEY_STATE_PRESSED;
    const seat_key_count = c.libinput_event_keyboard_get_seat_key_count(event);
    if ((pressed and seat_key_count != 1) or (!pressed and seat_key_count != 0)) return;
    self.listener.keyboard_key(
        self.listener.context,
        c.libinput_event_keyboard_get_time(event),
        key,
        if (pressed) .pressed else .released,
    );
    _ = c.xkb_state_update_key(
        self.xkb_state,
        key + 8,
        if (pressed) c.XKB_KEY_DOWN else c.XKB_KEY_UP,
    );
    self.sendModifiers();
}

fn sendModifiers(self: *Self) void {
    const modifiers: Modifiers = .{
        .depressed = c.xkb_state_serialize_mods(self.xkb_state, c.XKB_STATE_MODS_DEPRESSED),
        .latched = c.xkb_state_serialize_mods(self.xkb_state, c.XKB_STATE_MODS_LATCHED),
        .locked = c.xkb_state_serialize_mods(self.xkb_state, c.XKB_STATE_MODS_LOCKED),
        .group = c.xkb_state_serialize_layout(self.xkb_state, c.XKB_STATE_LAYOUT_EFFECTIVE),
    };
    if (std.meta.eql(self.modifiers, modifiers)) return;
    self.modifiers = modifiers;
    self.listener.keyboard_modifiers(
        self.listener.context,
        modifiers.depressed,
        modifiers.latched,
        modifiers.locked,
        modifiers.group,
    );
}

fn resetKeyboardState(self: *Self) !void {
    const state = c.xkb_state_new(self.xkb_keymap) orelse return error.XkbStateFailed;
    c.xkb_state_unref(self.xkb_state);
    self.xkb_state = state;
    self.modifiers = .{};
    self.listener.keyboard_modifiers(self.listener.context, 0, 0, 0, 0);
}

fn pointerMotion(self: *Self, event: *c.struct_libinput_event_pointer) void {
    self.pointer_x = clampCoordinate(
        self.pointer_x + c.libinput_event_pointer_get_dx(event),
        self.size.width,
    );
    self.pointer_y = clampCoordinate(
        self.pointer_y + c.libinput_event_pointer_get_dy(event),
        self.size.height,
    );
    self.listener.pointer_motion(
        self.listener.context,
        c.libinput_event_pointer_get_time(event),
        self.pointer_x,
        self.pointer_y,
    );
    self.listener.pointer_frame(self.listener.context);
}

fn pointerMotionAbsolute(self: *Self, event: *c.struct_libinput_event_pointer) void {
    self.pointer_x = c.libinput_event_pointer_get_absolute_x_transformed(event, self.size.width);
    self.pointer_y = c.libinput_event_pointer_get_absolute_y_transformed(event, self.size.height);
    self.listener.pointer_motion(
        self.listener.context,
        c.libinput_event_pointer_get_time(event),
        self.pointer_x,
        self.pointer_y,
    );
    self.listener.pointer_frame(self.listener.context);
}

fn pointerButton(self: *Self, event: *c.struct_libinput_event_pointer) void {
    const pressed = c.libinput_event_pointer_get_button_state(event) ==
        c.LIBINPUT_BUTTON_STATE_PRESSED;
    const seat_button_count = c.libinput_event_pointer_get_seat_button_count(event);
    if ((pressed and seat_button_count != 1) or (!pressed and seat_button_count != 0)) return;
    self.listener.pointer_button(
        self.listener.context,
        c.libinput_event_pointer_get_time(event),
        c.libinput_event_pointer_get_button(event),
        if (pressed) .pressed else .released,
    );
    self.listener.pointer_frame(self.listener.context);
}

fn pointerScroll(
    self: *Self,
    event: *c.struct_libinput_event_pointer,
    source: wl.Pointer.AxisSource,
) void {
    self.listener.pointer_axis_source(self.listener.context, source);
    self.pointerScrollAxis(event, source, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, .vertical_scroll);
    self.pointerScrollAxis(event, source, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL, .horizontal_scroll);
    self.listener.pointer_frame(self.listener.context);
}

fn pointerScrollAxis(
    self: *Self,
    event: *c.struct_libinput_event_pointer,
    source: wl.Pointer.AxisSource,
    libinput_axis: c.enum_libinput_pointer_axis,
    axis: wl.Pointer.Axis,
) void {
    if (c.libinput_event_pointer_has_axis(event, libinput_axis) == 0) return;
    const time = c.libinput_event_pointer_get_time(event);
    const value = c.libinput_event_pointer_get_scroll_value(event, libinput_axis);
    if (value == 0 and source != .wheel) {
        self.listener.pointer_axis_stop(self.listener.context, time, axis);
        return;
    }
    self.listener.pointer_axis(
        self.listener.context,
        time,
        axis,
        wl.Fixed.fromDouble(value),
    );
    if (source == .wheel) {
        const value_120 = c.libinput_event_pointer_get_scroll_value_v120(event, libinput_axis);
        const discrete: i32 = @intFromFloat(@round(value_120 / 120));
        self.listener.pointer_axis_value120(
            self.listener.context,
            axis,
            @intFromFloat(@round(value_120)),
        );
        if (discrete != 0) {
            self.listener.pointer_axis_discrete(self.listener.context, axis, discrete);
        }
    }
}

fn touchDown(self: *Self, event: *c.struct_libinput_event_touch) void {
    self.listener.touch_down(
        self.listener.context,
        c.libinput_event_touch_get_time(event),
        c.libinput_event_touch_get_seat_slot(event),
        c.libinput_event_touch_get_x_transformed(event, self.size.width),
        c.libinput_event_touch_get_y_transformed(event, self.size.height),
    );
}

fn touchUp(self: *Self, event: *c.struct_libinput_event_touch) void {
    self.listener.touch_up(
        self.listener.context,
        c.libinput_event_touch_get_time(event),
        c.libinput_event_touch_get_seat_slot(event),
    );
}

fn touchMotion(self: *Self, event: *c.struct_libinput_event_touch) void {
    self.listener.touch_motion(
        self.listener.context,
        c.libinput_event_touch_get_time(event),
        c.libinput_event_touch_get_seat_slot(event),
        c.libinput_event_touch_get_x_transformed(event, self.size.width),
        c.libinput_event_touch_get_y_transformed(event, self.size.height),
    );
}

fn clearCapabilities(self: *Self) void {
    if (self.keyboard_count != 0) self.listener.keyboard_available(self.listener.context, false);
    if (self.pointer_count != 0) self.listener.pointer_available(self.listener.context, false);
    if (self.touch_count != 0) self.listener.touch_available(self.listener.context, false);
    self.keyboard_count = 0;
    self.pointer_count = 0;
    self.touch_count = 0;
    self.resetKeyboardState() catch |err| self.fail(err);
}

fn discardEvents(self: *Self) void {
    if (c.libinput_dispatch(self.context) != 0) return self.fail(error.LibinputDispatchFailed);
    while (c.libinput_get_event(self.context)) |event| c.libinput_event_destroy(event);
}

fn fail(self: *Self, err: anyerror) void {
    if (self.failed) return;
    self.failed = true;
    log.err("native input failed: {t}", .{err});
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    if (self.initialized) self.listener.close(self.listener.context);
}

fn handleEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail(error.InputDisconnected);
    } else if (mask.readable) {
        self.dispatchEvents() catch |err| self.fail(err);
    }
    return 0;
}

fn handleSessionActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.failed or !self.suspended) return;
    if (c.libinput_resume(self.context) != 0) return self.fail(error.ResumeFailed);
    self.suspended = false;
    self.dispatchEvents() catch |err| self.fail(err);
}

fn handleSessionDeactivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.suspended) return;
    self.clearCapabilities();
    self.suspended = true;
    c.libinput_suspend(self.context);
    self.discardEvents();
}

fn handleSessionFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(error.SessionFailed);
}

fn openRestricted(path: [*c]const u8, _: c_int, data: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const device = self.session.openDevice(std.mem.span(path)) catch return -1;
    self.devices.put(self.allocator, device.fd, device) catch {
        self.session.closeDevice(device) catch {};
        return -1;
    };
    return device.fd;
}

fn closeRestricted(fd: c_int, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const entry = self.devices.fetchRemove(fd) orelse {
        log.err("libinput closed unknown device fd {d}", .{fd});
        return;
    };
    self.session.closeDevice(entry.value) catch |err| {
        log.err("failed to close input device: {t}", .{err});
    };
}

fn clampCoordinate(value: f64, dimension: u32) f64 {
    std.debug.assert(dimension > 0);
    return std.math.clamp(value, 0, @as(f64, @floatFromInt(dimension - 1)));
}

test "native pointer coordinates stay inside the output" {
    try std.testing.expectEqual(@as(f64, 0), clampCoordinate(-5, 100));
    try std.testing.expectEqual(@as(f64, 99), clampCoordinate(120, 100));
    try std.testing.expectEqual(@as(f64, 42.5), clampCoordinate(42.5, 100));
}
