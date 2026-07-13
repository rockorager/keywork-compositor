//! Wayland seat global and capability boundary.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
io: std.Io,
display: *wl.Server,
global: *wl.Global,
surface_store: *Surface.Store,
seat_resources: std.ArrayList(*wl.Seat),
keyboard_resources: std.ArrayList(*wl.Keyboard),
pointer_resources: std.ArrayList(*wl.Pointer),
keyboard_available: bool,
pointer_available: bool,
keymap: ?Keymap,
repeat_info: RepeatInfo,
repaint_listener: ?RepaintListener,
parent_focused: bool,
focus: ?Surface.Id,
pointer_focus: ?PointerFocus,
pointer_position: ?PointerPosition,
latest_pointer_enter: ?UserAction,
active_cursor: ?ActiveCursor,
cursor_surface_count: usize,
pressed_keys: std.ArrayList(u32),
modifiers: Modifiers,
last_user_action: ?UserAction,

const Keymap = struct {
    format: wl.Keyboard.KeymapFormat,
    file: std.Io.File,
    size: u32,
};

const RepeatInfo = struct {
    rate: i32 = 0,
    delay: i32 = 0,
};

const Modifiers = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
};

const UserAction = struct {
    client: *wl.Client,
    serial: u32,
};

const PointerPosition = struct {
    x: f64,
    y: f64,
};

const ActiveCursor = struct {
    surface_id: Surface.Id,
    hotspot_x: i32,
    hotspot_y: i32,
};

pub const PointerFocus = struct {
    surface_id: Surface.Id,
    x: f64,
    y: f64,
};

pub const CursorInfo = struct {
    surface_id: Surface.Id,
    x: i32,
    y: i32,
};

pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    surface_store: *Surface.Store,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .display = display,
        .global = undefined,
        .surface_store = surface_store,
        .seat_resources = .empty,
        .keyboard_resources = .empty,
        .pointer_resources = .empty,
        .keyboard_available = false,
        .pointer_available = false,
        .keymap = null,
        .repeat_info = .{},
        .repaint_listener = null,
        .parent_focused = false,
        .focus = null,
        .pointer_focus = null,
        .pointer_position = null,
        .latest_pointer_enter = null,
        .active_cursor = null,
        .cursor_surface_count = 0,
        .pressed_keys = .empty,
        .modifiers = .{},
        .last_user_action = null,
    };
    errdefer self.seat_resources.deinit(allocator);
    errdefer self.keyboard_resources.deinit(allocator);
    errdefer self.pointer_resources.deinit(allocator);
    errdefer self.pressed_keys.deinit(allocator);
    self.global = try wl.Global.create(display, wl.Seat, 10, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.seat_resources.items.len == 0);
    std.debug.assert(self.keyboard_resources.items.len == 0);
    std.debug.assert(self.pointer_resources.items.len == 0);
    std.debug.assert(self.cursor_surface_count == 0);
    std.debug.assert(self.repaint_listener == null);
    self.global.destroy();
    if (self.keymap) |keymap| keymap.file.close(self.io);
    self.pressed_keys.deinit(self.allocator);
    self.pointer_resources.deinit(self.allocator);
    self.keyboard_resources.deinit(self.allocator);
    self.seat_resources.deinit(self.allocator);
    self.* = undefined;
}

pub fn globalName(self: *const Self, client: *const wl.Client) u32 {
    return self.global.getName(client);
}

pub fn ownsResource(self: *Self, resource: *wl.Seat) bool {
    return resource.getUserData() == @as(?*anyopaque, @ptrCast(self));
}

pub fn setRepaintListener(self: *Self, listener: RepaintListener) void {
    std.debug.assert(self.repaint_listener == null);
    self.repaint_listener = listener;
}

pub fn clearRepaintListener(self: *Self) void {
    std.debug.assert(self.repaint_listener != null);
    self.repaint_listener = null;
}

pub fn acceptsUserActionSerial(
    self: *Self,
    resource: *wl.Seat,
    client: *wl.Client,
    serial: u32,
) bool {
    if (!self.ownsResource(resource)) return false;
    const action = self.last_user_action orelse return false;
    return action.client == client and action.serial == serial;
}

pub fn pointerFocusedSurface(self: *const Self) ?Surface.Id {
    const focus = self.pointer_focus orelse return null;
    return focus.surface_id;
}

pub fn cursorInfo(self: *const Self) ?CursorInfo {
    const cursor = self.active_cursor orelse return null;
    const position = self.pointer_position orelse return null;
    return .{
        .surface_id = cursor.surface_id,
        .x = cursorCoordinate(position.x, cursor.hotspot_x),
        .y = cursorCoordinate(position.y, cursor.hotspot_y),
    };
}

pub fn setKeyboardAvailable(self: *Self, available: bool) void {
    if (self.keyboard_available == available) return;
    const old_capability = self.hasKeyboardCapability();
    if (!available) self.parentKeyboardLeave();
    self.keyboard_available = available;
    if (old_capability != self.hasKeyboardCapability()) self.broadcastCapabilities();
}

pub fn setPointerAvailable(self: *Self, available: bool) void {
    if (self.pointer_available == available) return;
    if (!available) self.pointerLeave();
    self.pointer_available = available;
    self.broadcastCapabilities();
}

pub fn setKeymap(
    self: *Self,
    format: wl.Keyboard.KeymapFormat,
    fd: std.posix.fd_t,
    size: u32,
) void {
    const old_capability = self.hasKeyboardCapability();
    if (self.keymap) |keymap| keymap.file.close(self.io);
    self.keymap = .{
        .format = format,
        .file = .{ .handle = fd, .flags = .{ .nonblocking = false } },
        .size = size,
    };
    if (old_capability != self.hasKeyboardCapability()) self.broadcastCapabilities();
    for (self.keyboard_resources.items) |resource| {
        self.sendKeymap(resource);
        self.sendRepeatInfo(resource);
    }
}

pub fn setRepeatInfo(self: *Self, rate: i32, delay: i32) void {
    std.debug.assert(rate >= 0 and delay >= 0);
    self.repeat_info = .{ .rate = rate, .delay = delay };
    for (self.keyboard_resources.items) |resource| self.sendRepeatInfo(resource);
}

pub fn setKeyboardFocus(self: *Self, focus: ?Surface.Id) void {
    if (std.meta.eql(self.focus, focus)) return;
    if (self.parent_focused) self.sendLeave();
    self.focus = focus;
    if (self.parent_focused) self.sendEnter();
}

pub fn parentKeyboardEnter(self: *Self, pressed_keys: []const u32) error{OutOfMemory}!void {
    self.pressed_keys.clearRetainingCapacity();
    try self.pressed_keys.appendSlice(self.allocator, pressed_keys);
    if (self.parent_focused) return;
    self.parent_focused = true;
    self.sendEnter();
}

pub fn parentKeyboardLeave(self: *Self) void {
    if (self.parent_focused) self.sendLeave();
    self.parent_focused = false;
    self.pressed_keys.clearRetainingCapacity();
}

pub fn key(
    self: *Self,
    time: u32,
    key_code: u32,
    state: wl.Keyboard.KeyState,
) error{OutOfMemory}!void {
    switch (state) {
        .pressed => {
            for (self.pressed_keys.items) |pressed| {
                if (pressed == key_code) return;
            }
            try self.pressed_keys.append(self.allocator, key_code);
        },
        .released => {
            for (self.pressed_keys.items, 0..) |pressed, index| {
                if (pressed != key_code) continue;
                _ = self.pressed_keys.orderedRemove(index);
                break;
            } else return;
        },
        .repeated => {},
        else => return,
    }

    const surface = self.focusedSurface() orelse return;
    if (!self.parent_focused or self.keymap == null) return;
    const serial = self.display.nextSerial();
    if (state == .pressed) self.last_user_action = .{
        .client = surface.getClient(),
        .serial = serial,
    };
    for (self.keyboard_resources.items) |resource| {
        if (resource.getClient() != surface.getClient()) continue;
        if (state == .repeated and resource.getVersion() < 10) continue;
        resource.sendKey(serial, time, key_code, state);
    }
}

pub fn setModifiers(
    self: *Self,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) void {
    self.modifiers = .{
        .depressed = depressed,
        .latched = latched,
        .locked = locked,
        .group = group,
    };
    const surface = self.focusedSurface() orelse return;
    if (!self.parent_focused or self.keymap == null) return;
    const serial = self.display.nextSerial();
    for (self.keyboard_resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) self.sendModifiers(resource, serial);
    }
}

pub fn pointerEnter(self: *Self, x: f64, y: f64, focus: ?PointerFocus) void {
    self.setPointerPosition(x, y);
    self.updatePointerFocus(focus, null);
}

pub fn pointerMotion(self: *Self, time: u32, x: f64, y: f64, focus: ?PointerFocus) void {
    self.setPointerPosition(x, y);
    self.updatePointerFocus(focus, time);
}

pub fn pointerLeave(self: *Self) void {
    self.clearCursor();
    self.sendPointerLeave();
    self.pointer_focus = null;
    self.pointer_position = null;
    self.latest_pointer_enter = null;
}

pub fn pointerButton(
    self: *Self,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    const surface = self.pointerSurface() orelse return;
    const serial = self.display.nextSerial();
    if (state == .pressed) self.last_user_action = .{
        .client = surface.getClient(),
        .serial = serial,
    };
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) {
            resource.sendButton(serial, time, button, state);
        }
    }
}

pub fn pointerAxis(self: *Self, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) resource.sendAxis(time, axis, value);
    }
}

pub fn pointerFrame(self: *Self) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.frame_since_version)
        {
            resource.sendFrame();
        }
    }
}

pub fn pointerAxisSource(self: *Self, source: wl.Pointer.AxisSource) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_source_since_version)
        {
            resource.sendAxisSource(source);
        }
    }
}

pub fn pointerAxisStop(self: *Self, time: u32, axis: wl.Pointer.Axis) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_stop_since_version)
        {
            resource.sendAxisStop(time, axis);
        }
    }
}

pub fn pointerAxisDiscrete(self: *Self, axis: wl.Pointer.Axis, discrete: i32) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_discrete_since_version and
            resource.getVersion() < wl.Pointer.axis_value120_since_version)
        {
            resource.sendAxisDiscrete(axis, discrete);
        }
    }
}

pub fn pointerAxisValue120(self: *Self, axis: wl.Pointer.Axis, value120: i32) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_value120_since_version)
        {
            resource.sendAxisValue120(axis, value120);
        }
    }
}

pub fn pointerAxisRelativeDirection(
    self: *Self,
    axis: wl.Pointer.Axis,
    direction: wl.Pointer.AxisRelativeDirection,
) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_relative_direction_since_version)
        {
            resource.sendAxisRelativeDirection(axis, direction);
        }
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Seat.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    self.seat_resources.append(self.allocator, resource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handleRequest, handleSeatDestroy, self);
    if (version >= wl.Seat.name_since_version) resource.sendName("seat0");
    resource.sendCapabilities(self.capabilities());
}

fn handleRequest(resource: *wl.Seat, request: wl.Seat.Request, self: *Self) void {
    switch (request) {
        .release => resource.destroy(),
        .get_keyboard => |get| self.createKeyboard(resource, get.id),
        .get_pointer => |get| self.createPointer(resource, get.id),
        .get_touch => resource.postError(
            .missing_capability,
            "seat does not currently provide this input capability",
        ),
    }
}

fn handleSeatDestroy(resource: *wl.Seat, self: *Self) void {
    for (self.seat_resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.seat_resources.orderedRemove(index);
        return;
    }
    unreachable;
}

fn createKeyboard(self: *Self, seat: *wl.Seat, id: u32) void {
    const resource = wl.Keyboard.create(seat.getClient(), seat.getVersion(), id) catch {
        seat.postNoMemory();
        return;
    };
    self.keyboard_resources.append(self.allocator, resource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handleKeyboardRequest, handleKeyboardDestroy, self);
    if (self.keymap == null) return;
    self.sendKeymap(resource);
    self.sendRepeatInfo(resource);
    const surface = self.focusedSurface() orelse return;
    if (self.parent_focused and resource.getClient() == surface.getClient()) {
        const serial = self.display.nextSerial();
        self.sendEnterTo(resource, surface, serial);
    }
}

fn createPointer(self: *Self, seat: *wl.Seat, id: u32) void {
    const resource = wl.Pointer.create(seat.getClient(), seat.getVersion(), id) catch {
        seat.postNoMemory();
        return;
    };
    self.pointer_resources.append(self.allocator, resource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handlePointerRequest, handlePointerDestroy, self);
    const surface = self.pointerSurface() orelse return;
    if (resource.getClient() == surface.getClient()) {
        const serial = self.display.nextSerial();
        self.latest_pointer_enter = .{
            .client = surface.getClient(),
            .serial = serial,
        };
        self.sendPointerEnterTo(resource, surface, serial);
        if (resource.getVersion() >= wl.Pointer.frame_since_version) resource.sendFrame();
    }
}

fn handleKeyboardRequest(resource: *wl.Keyboard, request: wl.Keyboard.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleKeyboardDestroy(resource: *wl.Keyboard, self: *Self) void {
    for (self.keyboard_resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.keyboard_resources.orderedRemove(index);
        return;
    }
    unreachable;
}

fn handlePointerRequest(resource: *wl.Pointer, request: wl.Pointer.Request, self: *Self) void {
    switch (request) {
        .set_cursor => |set| self.setCursor(
            resource,
            set.serial,
            set.surface,
            set.hotspot_x,
            set.hotspot_y,
        ),
        .release => resource.destroy(),
    }
}

fn handlePointerDestroy(resource: *wl.Pointer, self: *Self) void {
    for (self.pointer_resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.pointer_resources.orderedRemove(index);
        return;
    }
    unreachable;
}

fn focusedSurface(self: *Self) ?*wl.Surface {
    return Surface.resourceFor(self.surface_store, self.focus orelse return null);
}

fn hasKeyboardCapability(self: *const Self) bool {
    return self.keyboard_available and self.keymap != null;
}

fn capabilities(self: *const Self) wl.Seat.Capability {
    return .{
        .keyboard = self.hasKeyboardCapability(),
        .pointer = self.pointer_available,
    };
}

fn broadcastCapabilities(self: *Self) void {
    for (self.seat_resources.items) |resource| resource.sendCapabilities(self.capabilities());
}

fn sendKeymap(self: *Self, resource: *wl.Keyboard) void {
    const keymap = self.keymap orelse return;
    resource.sendKeymap(keymap.format, keymap.file.handle, keymap.size);
}

fn sendRepeatInfo(self: *const Self, resource: *wl.Keyboard) void {
    if (resource.getVersion() >= wl.Keyboard.repeat_info_since_version) {
        resource.sendRepeatInfo(self.repeat_info.rate, self.repeat_info.delay);
    }
}

fn sendEnter(self: *Self) void {
    if (self.keymap == null) return;
    const surface = self.focusedSurface() orelse return;
    const serial = self.display.nextSerial();
    for (self.keyboard_resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) {
            self.sendEnterTo(resource, surface, serial);
        }
    }
}

fn sendEnterTo(self: *Self, resource: *wl.Keyboard, surface: *wl.Surface, serial: u32) void {
    var keys = wl.Array.fromArrayList(u32, self.pressed_keys);
    resource.sendEnter(serial, surface, &keys);
    self.sendModifiers(resource, serial);
}

fn sendLeave(self: *Self) void {
    const surface = self.focusedSurface() orelse return;
    const serial = self.display.nextSerial();
    for (self.keyboard_resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) resource.sendLeave(serial, surface);
    }
}

fn sendModifiers(self: *const Self, resource: *wl.Keyboard, serial: u32) void {
    resource.sendModifiers(
        serial,
        self.modifiers.depressed,
        self.modifiers.latched,
        self.modifiers.locked,
        self.modifiers.group,
    );
}

fn updatePointerFocus(self: *Self, focus: ?PointerFocus, motion_time: ?u32) void {
    const changed = if (self.pointer_focus) |current|
        if (focus) |next| !std.meta.eql(current.surface_id, next.surface_id) else true
    else
        focus != null;
    if (changed) {
        self.clearCursor();
        self.sendPointerLeave();
        self.pointer_focus = focus;
        self.latest_pointer_enter = null;
        self.sendPointerEnter();
        return;
    }
    self.pointer_focus = focus;
    const time = motion_time orelse return;
    const surface = self.pointerSurface() orelse return;
    const position = self.pointer_focus orelse return;
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) {
            resource.sendMotion(time, fixed(position.x), fixed(position.y));
        }
    }
}

fn pointerSurface(self: *Self) ?*wl.Surface {
    const focus = self.pointer_focus orelse return null;
    return Surface.resourceFor(self.surface_store, focus.surface_id);
}

fn sendPointerEnter(self: *Self) void {
    const surface = self.pointerSurface() orelse return;
    const serial = self.display.nextSerial();
    self.latest_pointer_enter = .{
        .client = surface.getClient(),
        .serial = serial,
    };
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) {
            self.sendPointerEnterTo(resource, surface, serial);
        }
    }
}

fn sendPointerEnterTo(
    self: *const Self,
    resource: *wl.Pointer,
    surface: *wl.Surface,
    serial: u32,
) void {
    const position = self.pointer_focus orelse return;
    resource.sendEnter(serial, surface, fixed(position.x), fixed(position.y));
}

fn sendPointerLeave(self: *Self) void {
    const surface = self.pointerSurface() orelse return;
    const serial = self.display.nextSerial();
    for (self.pointer_resources.items) |resource| {
        if (resource.getClient() != surface.getClient()) continue;
        resource.sendLeave(serial, surface);
        if (resource.getVersion() >= wl.Pointer.frame_since_version) resource.sendFrame();
    }
}

fn setPointerPosition(self: *Self, x: f64, y: f64) void {
    std.debug.assert(std.math.isFinite(x) and std.math.isFinite(y));
    self.pointer_position = .{ .x = x, .y = y };
    if (self.active_cursor != null) self.requestRepaint();
}

fn setCursor(
    self: *Self,
    pointer: *wl.Pointer,
    serial: u32,
    surface_resource: ?*wl.Surface,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    const cursor_surface = if (surface_resource) |resource| cursor: {
        const surface = Surface.fromResource(resource);
        if (surface.assignedRole()) |role| {
            if (role != .cursor) {
                pointer.postError(.role, "wl_surface already has another role");
                return;
            }
        } else {
            CursorSurface.create(self, surface) catch |err| switch (err) {
                error.OutOfMemory => {
                    pointer.postNoMemory();
                    return;
                },
                error.RoleUnavailable => {
                    pointer.postError(.role, "wl_surface is unavailable for the cursor role");
                    return;
                },
            };
        }
        break :cursor surface;
    } else null;

    const enter = self.latest_pointer_enter orelse return;
    if (enter.client != pointer.getClient() or enter.serial != serial) return;
    const focused_client = if (self.pointerSurface()) |surface|
        surface.getClient() == pointer.getClient()
    else
        false;
    const current_surface = if (self.active_cursor) |cursor|
        if (cursor_surface) |surface| std.meta.eql(cursor.surface_id, surface.handle()) else false
    else
        false;
    if (!focused_client and !current_surface) return;

    self.active_cursor = if (cursor_surface) |surface| .{
        .surface_id = surface.handle(),
        .hotspot_x = hotspot_x,
        .hotspot_y = hotspot_y,
    } else null;
    self.requestRepaint();
}

fn clearCursor(self: *Self) void {
    if (self.active_cursor == null) return;
    self.active_cursor = null;
    self.requestRepaint();
}

fn cursorSurfaceCommitted(self: *Self, id: Surface.Id, info: Surface.CommitInfo) void {
    const cursor = if (self.active_cursor) |*cursor|
        if (std.meta.eql(cursor.surface_id, id)) cursor else return
    else
        return;
    cursor.hotspot_x -|= info.offset_x;
    cursor.hotspot_y -|= info.offset_y;
    self.requestRepaint();
}

fn cursorSurfaceDestroyed(self: *Self, id: Surface.Id) void {
    if (self.active_cursor) |cursor| {
        if (std.meta.eql(cursor.surface_id, id)) self.clearCursor();
    }
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

const CursorSurface = struct {
    seat: *Self,
    surface_id: Surface.Id,

    fn create(seat: *Self, surface: *Surface) error{ OutOfMemory, RoleUnavailable }!void {
        const self = seat.allocator.create(CursorSurface) catch return error.OutOfMemory;
        errdefer seat.allocator.destroy(self);
        self.* = .{
            .seat = seat,
            .surface_id = surface.handle(),
        };
        surface.reserveRole(.cursor, .{
            .context = self,
            .before_commit = beforeCommit,
            .after_commit = afterCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch return error.RoleUnavailable;
        errdefer surface.releaseRole(self);
        surface.assignReservedRole(.cursor, self) catch return error.RoleUnavailable;
        seat.cursor_surface_count += 1;
    }

    fn beforeCommit(_: *anyopaque, _: Surface.CommitInfo) Surface.CommitAction {
        return .apply;
    }

    fn afterCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *CursorSurface = @ptrCast(@alignCast(context));
        self.seat.cursorSurfaceCommitted(self.surface_id, info);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *CursorSurface = @ptrCast(@alignCast(context));
        const seat = self.seat;
        seat.cursorSurfaceDestroyed(self.surface_id);
        std.debug.assert(seat.cursor_surface_count > 0);
        seat.cursor_surface_count -= 1;
        seat.allocator.destroy(self);
    }
};

fn cursorCoordinate(value: f64, hotspot: i32) i32 {
    const coordinate: i64 = @intFromFloat(@floor(value));
    return @intCast(std.math.clamp(
        coordinate - @as(i64, hotspot),
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn fixed(value: f64) wl.Fixed {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return wl.Fixed.fromDouble(std.math.clamp(value, minimum, maximum));
}

test "cursor position accounts for hotspot and fractional motion" {
    try std.testing.expectEqual(@as(i32, 8), cursorCoordinate(12.75, 4));
    try std.testing.expectEqual(@as(i32, -5), cursorCoordinate(0.25, 5));
    try std.testing.expectEqual(
        std.math.minInt(i32),
        cursorCoordinate(-0.25, std.math.maxInt(i32)),
    );
}
