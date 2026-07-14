//! Wayland seat global, input resources, and capability boundary.

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
keyboard_resources: std.ArrayList(KeyboardResource),
pointer_resources: std.ArrayList(PointerResource),
touch_resources: std.ArrayList(TouchResource),
next_touch_resource_generation: u64,
// Input objects created before a capability is re-added must remain inert.
keyboard_capability_generation: u64,
pointer_capability_generation: u64,
touch_capability_generation: u64,
keyboard_ever_available: bool,
pointer_ever_available: bool,
touch_ever_available: bool,
keyboard_available: bool,
pointer_available: bool,
touch_available: bool,
keymap: ?Keymap,
repeat_info: RepeatInfo,
repaint_listener: ?RepaintListener,
keyboard_focus_listeners: std.ArrayList(KeyboardFocusListener),
parent_focused: bool,
focus: ?Surface.Id,
pointer_focus: ?PointerFocus,
pointer_position: ?PointerPosition,
touch_points: std.ArrayList(TouchPoint),
touch_frame_resources: std.ArrayList(*wl.Touch),
latest_pointer_enter: ?UserAction,
active_cursor: ?ActiveCursor,
cursor_controller: ?CursorController,
cursor_surface_count: usize,
pressed_keys: std.ArrayList(u32),
modifiers: Modifiers,
last_user_action: ?UserAction,
recent_user_actions: [user_action_history_capacity]UserAction,
recent_user_action_count: usize,
next_user_action: usize,

const user_action_history_capacity = 32;

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

const TouchPoint = struct {
    id: i32,
    target: ?Target,

    const Target = struct {
        surface_id: Surface.Id,
        client: *wl.Client,
        offset_x: f64,
        offset_y: f64,
        max_resource_generation: u64,
    };
};

const TouchResource = struct {
    resource: *wl.Touch,
    generation: u64,
    capability_generation: u64,
};

const KeyboardResource = struct {
    resource: *wl.Keyboard,
    capability_generation: u64,
};

const PointerResource = struct {
    resource: *wl.Pointer,
    capability_generation: u64,
};

const ActiveCursor = struct {
    surface_id: Surface.Id,
    hotspot_x: i32,
    hotspot_y: i32,
};

const CursorController = struct {
    client: *wl.Client,
    cursor: ?ActiveCursor,
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

pub const KeyboardFocusListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, ?*wl.Client) void,
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
        .touch_resources = .empty,
        .next_touch_resource_generation = 0,
        .keyboard_capability_generation = 0,
        .pointer_capability_generation = 0,
        .touch_capability_generation = 0,
        .keyboard_ever_available = false,
        .pointer_ever_available = false,
        .touch_ever_available = false,
        .keyboard_available = false,
        .pointer_available = false,
        .touch_available = false,
        .keymap = null,
        .repeat_info = .{},
        .repaint_listener = null,
        .keyboard_focus_listeners = .empty,
        .parent_focused = false,
        .focus = null,
        .pointer_focus = null,
        .pointer_position = null,
        .touch_points = .empty,
        .touch_frame_resources = .empty,
        .latest_pointer_enter = null,
        .active_cursor = null,
        .cursor_controller = null,
        .cursor_surface_count = 0,
        .pressed_keys = .empty,
        .modifiers = .{},
        .last_user_action = null,
        .recent_user_actions = undefined,
        .recent_user_action_count = 0,
        .next_user_action = 0,
    };
    errdefer self.seat_resources.deinit(allocator);
    errdefer self.keyboard_resources.deinit(allocator);
    errdefer self.pointer_resources.deinit(allocator);
    errdefer self.touch_resources.deinit(allocator);
    errdefer self.touch_points.deinit(allocator);
    errdefer self.touch_frame_resources.deinit(allocator);
    errdefer self.pressed_keys.deinit(allocator);
    errdefer self.keyboard_focus_listeners.deinit(allocator);
    self.global = try wl.Global.create(display, wl.Seat, 10, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.seat_resources.items.len == 0);
    std.debug.assert(self.keyboard_resources.items.len == 0);
    std.debug.assert(self.pointer_resources.items.len == 0);
    std.debug.assert(self.touch_resources.items.len == 0);
    std.debug.assert(self.cursor_surface_count == 0);
    std.debug.assert(self.repaint_listener == null);
    std.debug.assert(self.keyboard_focus_listeners.items.len == 0);
    self.global.destroy();
    if (self.keymap) |keymap| keymap.file.close(self.io);
    self.keyboard_focus_listeners.deinit(self.allocator);
    self.pressed_keys.deinit(self.allocator);
    self.touch_frame_resources.deinit(self.allocator);
    self.touch_points.deinit(self.allocator);
    self.touch_resources.deinit(self.allocator);
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

pub fn addKeyboardFocusListener(
    self: *Self,
    listener: KeyboardFocusListener,
) error{OutOfMemory}!void {
    for (self.keyboard_focus_listeners.items) |existing| {
        std.debug.assert(existing.context != listener.context);
    }
    try self.keyboard_focus_listeners.append(self.allocator, listener);
}

pub fn removeKeyboardFocusListener(self: *Self, context: *anyopaque) void {
    for (self.keyboard_focus_listeners.items, 0..) |listener, index| {
        if (listener.context != context) continue;
        _ = self.keyboard_focus_listeners.orderedRemove(index);
        return;
    }
    unreachable;
}

pub fn acceptsUserActionSerial(
    self: *Self,
    resource: *wl.Seat,
    client: *wl.Client,
    serial: u32,
) bool {
    if (!self.ownsResource(resource)) return false;
    return self.acceptsClientUserActionSerial(client, serial);
}

pub fn acceptsSelectionSerial(self: *Self, client: *wl.Client, serial: u32) bool {
    for (self.recent_user_actions[0..self.recent_user_action_count]) |action| {
        if (action.client == client and action.serial == serial) return true;
    }
    return false;
}

pub fn acceptsActivationSerial(
    self: *Self,
    resource: *wl.Seat,
    client: *wl.Client,
    serial: u32,
) bool {
    if (!self.ownsResource(resource)) return false;
    if (self.acceptsSelectionSerial(client, serial)) return true;
    const pointer_enter = self.latest_pointer_enter orelse return false;
    return pointer_enter.client == client and pointer_enter.serial == serial;
}

pub fn activationSurfaceFocused(self: *const Self, surface_id: Surface.Id) bool {
    if (self.focus) |focus| {
        if (std.meta.eql(focus, surface_id)) return true;
    }
    if (self.pointer_focus) |focus| {
        if (std.meta.eql(focus.surface_id, surface_id)) return true;
    }
    for (self.touch_points.items) |point| {
        const target = point.target orelse continue;
        if (std.meta.eql(target.surface_id, surface_id)) return true;
    }
    return false;
}

pub fn acceptsClientUserActionSerial(self: *const Self, client: *wl.Client, serial: u32) bool {
    const action = self.last_user_action orelse return false;
    return action.client == client and action.serial == serial;
}

pub fn serialIsOlder(candidate: u32, current: u32) bool {
    return candidate -% current > std.math.maxInt(u32) / 2;
}

pub fn pointerFocusedSurface(self: *const Self) ?Surface.Id {
    const focus = self.pointer_focus orelse return null;
    return focus.surface_id;
}

pub fn pointerPosition(self: *const Self) ?struct { x: f64, y: f64 } {
    const position = self.pointer_position orelse return null;
    return .{ .x = position.x, .y = position.y };
}

pub fn effectiveModifiers(self: *const Self) u32 {
    return (self.modifiers.depressed | self.modifiers.latched) & 0xed;
}

/// Set the client allowed to own the cursor while pointer focus is absent.
/// This is also the generic ownership query point for cursor-shape protocols.
pub fn setUnfocusedCursorController(self: *Self, client: ?*wl.Client) void {
    if (client == null) {
        self.cursor_controller = null;
    } else if (self.cursor_controller == null or self.cursor_controller.?.client != client.?) {
        self.cursor_controller = .{ .client = client.?, .cursor = null };
    }
    if (self.pointer_focus == null) self.restoreControllerCursor();
}

pub fn isUnfocusedCursorController(self: *const Self, client: *wl.Client) bool {
    return if (self.cursor_controller) |controller| controller.client == client else false;
}

pub fn suppressPointerFocus(self: *Self, suppress: bool) void {
    if (suppress) self.updatePointerFocus(null, null);
}

pub fn restoreUnfocusedCursor(self: *Self) void {
    self.restoreControllerCursor();
}

pub fn keyboardFocusedClient(self: *Self) ?*wl.Client {
    if (!self.parent_focused or self.keymap == null) return null;
    const surface = self.focusedSurface() orelse return null;
    return surface.getClient();
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
    const new_capability = self.hasKeyboardCapability();
    if (!old_capability and new_capability) {
        beginCapabilityGeneration(
            &self.keyboard_capability_generation,
            &self.keyboard_ever_available,
        );
    }
    if (old_capability != new_capability) self.broadcastCapabilities();
}

pub fn setPointerAvailable(self: *Self, available: bool) void {
    if (self.pointer_available == available) return;
    if (!available) self.pointerLeave();
    self.pointer_available = available;
    if (available) {
        beginCapabilityGeneration(
            &self.pointer_capability_generation,
            &self.pointer_ever_available,
        );
    }
    self.broadcastCapabilities();
}

pub fn setTouchAvailable(self: *Self, available: bool) void {
    if (self.touch_available == available) return;
    if (!available) self.touchCancel();
    self.touch_available = available;
    if (available) {
        beginCapabilityGeneration(
            &self.touch_capability_generation,
            &self.touch_ever_available,
        );
    }
    self.broadcastCapabilities();
}

pub fn setKeymap(
    self: *Self,
    format: wl.Keyboard.KeymapFormat,
    fd: std.posix.fd_t,
    size: u32,
) void {
    const old_focus = self.keyboardFocusedClient();
    const old_capability = self.hasKeyboardCapability();
    if (self.keymap) |keymap| keymap.file.close(self.io);
    self.keymap = .{
        .format = format,
        .file = .{ .handle = fd, .flags = .{ .nonblocking = false } },
        .size = size,
    };
    const new_capability = self.hasKeyboardCapability();
    if (!old_capability and new_capability) {
        beginCapabilityGeneration(
            &self.keyboard_capability_generation,
            &self.keyboard_ever_available,
        );
    }
    if (old_capability != new_capability) self.broadcastCapabilities();
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        self.sendKeymap(entry.resource);
        self.sendRepeatInfo(entry.resource);
    }
    if (old_focus == null and self.keyboardFocusedClient() != null) {
        self.notifyKeyboardFocus();
        self.sendEnter();
    }
}

pub fn setRepeatInfo(self: *Self, rate: i32, delay: i32) void {
    std.debug.assert(rate >= 0 and delay >= 0);
    self.repeat_info = .{ .rate = rate, .delay = delay };
    for (self.keyboard_resources.items) |entry| {
        if (self.keyboardResourceActive(entry)) self.sendRepeatInfo(entry.resource);
    }
}

pub fn setKeyboardFocus(self: *Self, focus: ?Surface.Id) void {
    if (std.meta.eql(self.focus, focus)) return;
    if (self.parent_focused) self.sendLeave();
    self.focus = focus;
    if (self.parent_focused) {
        self.notifyKeyboardFocus();
        self.sendEnter();
    }
}

pub fn parentKeyboardEnter(self: *Self, pressed_keys: []const u32) error{OutOfMemory}!void {
    self.pressed_keys.clearRetainingCapacity();
    try self.pressed_keys.appendSlice(self.allocator, pressed_keys);
    if (self.parent_focused) return;
    self.parent_focused = true;
    self.notifyKeyboardFocus();
    self.sendEnter();
}

pub fn parentKeyboardLeave(self: *Self) void {
    if (self.parent_focused) self.sendLeave();
    self.parent_focused = false;
    self.notifyKeyboardFocus();
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
    if (state == .pressed) self.recordUserAction(surface.getClient(), serial);
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        const resource = entry.resource;
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
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        if (entry.resource.getClient() == surface.getClient()) {
            self.sendModifiers(entry.resource, serial);
        }
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
    if (state == .pressed) self.recordUserAction(surface.getClient(), serial);
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) {
            resource.sendButton(serial, time, button, state);
        }
    }
}

pub fn pointerAxis(self: *Self, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient()) resource.sendAxis(time, axis, value);
    }
}

pub fn pointerFrame(self: *Self) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.frame_since_version)
        {
            resource.sendFrame();
        }
    }
}

pub fn pointerAxisSource(self: *Self, source: wl.Pointer.AxisSource) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_source_since_version)
        {
            resource.sendAxisSource(source);
        }
    }
}

pub fn pointerAxisStop(self: *Self, time: u32, axis: wl.Pointer.Axis) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_stop_since_version)
        {
            resource.sendAxisStop(time, axis);
        }
    }
}

pub fn pointerAxisDiscrete(self: *Self, axis: wl.Pointer.Axis, discrete: i32) void {
    const surface = self.pointerSurface() orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
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
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
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
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
        if (resource.getClient() == surface.getClient() and
            resource.getVersion() >= wl.Pointer.axis_relative_direction_since_version)
        {
            resource.sendAxisRelativeDirection(axis, direction);
        }
    }
}

pub fn touchDown(
    self: *Self,
    time: u32,
    id: i32,
    x: f64,
    y: f64,
    focus: ?PointerFocus,
) error{OutOfMemory}!void {
    if (!self.touch_available or self.findTouchPoint(id) != null) return;
    try self.touch_points.ensureUnusedCapacity(self.allocator, 1);

    const target: ?TouchPoint.Target = if (focus) |candidate| target: {
        const surface = Surface.resourceFor(self.surface_store, candidate.surface_id) orelse
            break :target null;
        const max_resource_generation = self.latestTouchResourceGeneration(
            surface.getClient(),
        ) orelse break :target null;
        break :target .{
            .surface_id = candidate.surface_id,
            .client = surface.getClient(),
            .offset_x = x - candidate.x,
            .offset_y = y - candidate.y,
            .max_resource_generation = max_resource_generation,
        };
    } else null;
    self.touch_points.appendAssumeCapacity(.{ .id = id, .target = target });

    const destination = target orelse return;
    const surface = Surface.resourceFor(self.surface_store, destination.surface_id) orelse return;
    const serial = self.display.nextSerial();
    self.recordUserAction(destination.client, serial);
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, destination.max_resource_generation) and
            resource.getClient() == destination.client)
        {
            try self.markTouchFrame(resource);
            resource.sendDown(
                serial,
                time,
                surface,
                id,
                fixed(x - destination.offset_x),
                fixed(y - destination.offset_y),
            );
        }
    }
}

pub fn touchUp(self: *Self, time: u32, id: i32) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const index = self.findTouchPoint(id) orelse return;
    const point = self.touch_points.items[index];
    if (point.target) |target| {
        const serial = self.display.nextSerial();
        for (self.touch_resources.items) |entry| {
            if (!self.touchResourceActive(entry)) continue;
            const resource = entry.resource;
            if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
                resource.getClient() == target.client)
            {
                try self.markTouchFrame(resource);
                resource.sendUp(serial, time, id);
            }
        }
    }
    _ = self.touch_points.orderedRemove(index);
}

pub fn touchMotion(
    self: *Self,
    time: u32,
    id: i32,
    x: f64,
    y: f64,
) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const point = self.touchPoint(id) orelse return;
    const target = point.target orelse return;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
            resource.getClient() == target.client)
        {
            try self.markTouchFrame(resource);
            resource.sendMotion(
                time,
                id,
                fixed(x - target.offset_x),
                fixed(y - target.offset_y),
            );
        }
    }
}

pub fn touchFrame(self: *Self) void {
    for (self.touch_frame_resources.items) |resource| resource.sendFrame();
    self.touch_frame_resources.clearRetainingCapacity();
}

pub fn touchCancel(self: *Self) void {
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        for (self.touch_points.items) |point| {
            const target = point.target orelse continue;
            if (!touchResourceInSequence(entry.generation, target.max_resource_generation)) continue;
            if (entry.resource.getClient() != target.client) continue;
            entry.resource.sendCancel();
            break;
        }
    }
    self.touch_points.clearRetainingCapacity();
    self.touch_frame_resources.clearRetainingCapacity();
}

pub fn touchShape(self: *Self, id: i32, major: f64, minor: f64) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const point = self.touchPoint(id) orelse return;
    const target = point.target orelse return;
    if (!self.hasTouchResourceVersion(
        target.client,
        wl.Touch.shape_since_version,
        target.max_resource_generation,
    )) return;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
            resource.getClient() == target.client and
            resource.getVersion() >= wl.Touch.shape_since_version)
        {
            try self.markTouchFrame(resource);
            resource.sendShape(id, fixed(major), fixed(minor));
        }
    }
}

pub fn touchOrientation(self: *Self, id: i32, orientation: f64) error{OutOfMemory}!void {
    if (!self.touch_available) return;
    const point = self.touchPoint(id) orelse return;
    const target = point.target orelse return;
    if (!self.hasTouchResourceVersion(
        target.client,
        wl.Touch.orientation_since_version,
        target.max_resource_generation,
    )) return;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        const resource = entry.resource;
        if (touchResourceInSequence(entry.generation, target.max_resource_generation) and
            resource.getClient() == target.client and
            resource.getVersion() >= wl.Touch.orientation_since_version)
        {
            try self.markTouchFrame(resource);
            resource.sendOrientation(id, fixed(orientation));
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
        .get_keyboard => |get| if (self.keyboard_ever_available)
            self.createKeyboard(resource, get.id)
        else
            resource.postError(.missing_capability, "seat has never had a keyboard capability"),
        .get_pointer => |get| if (self.pointer_ever_available)
            self.createPointer(resource, get.id)
        else
            resource.postError(.missing_capability, "seat has never had a pointer capability"),
        .get_touch => |get| if (self.touch_ever_available)
            self.createTouch(resource, get.id)
        else
            resource.postError(.missing_capability, "seat has never had a touch capability"),
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
    const entry: KeyboardResource = .{
        .resource = resource,
        .capability_generation = self.keyboard_capability_generation,
    };
    self.keyboard_resources.append(self.allocator, entry) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handleKeyboardRequest, handleKeyboardDestroy, self);
    if (!self.keyboardResourceActive(entry)) return;
    if (self.keymap == null) return;
    self.sendKeymap(resource);
    self.sendRepeatInfo(resource);
    const surface = self.focusedSurface() orelse return;
    if (self.parent_focused and resource.getClient() == surface.getClient()) {
        const serial = self.display.nextSerial();
        self.recordSelectionSerial(surface.getClient(), serial);
        self.sendEnterTo(resource, surface, serial);
    }
}

fn createPointer(self: *Self, seat: *wl.Seat, id: u32) void {
    const resource = wl.Pointer.create(seat.getClient(), seat.getVersion(), id) catch {
        seat.postNoMemory();
        return;
    };
    const entry: PointerResource = .{
        .resource = resource,
        .capability_generation = self.pointer_capability_generation,
    };
    self.pointer_resources.append(self.allocator, entry) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handlePointerRequest, handlePointerDestroy, self);
    if (!self.pointerResourceActive(entry)) return;
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

fn createTouch(self: *Self, seat: *wl.Seat, id: u32) void {
    const resource = wl.Touch.create(seat.getClient(), seat.getVersion(), id) catch {
        seat.postNoMemory();
        return;
    };
    const generation = self.next_touch_resource_generation;
    self.touch_resources.append(self.allocator, .{
        .resource = resource,
        .generation = generation,
        .capability_generation = self.touch_capability_generation,
    }) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    self.next_touch_resource_generation = std.math.add(u64, generation, 1) catch unreachable;
    resource.setHandler(*Self, handleTouchRequest, handleTouchDestroy, self);
}

fn handleKeyboardRequest(resource: *wl.Keyboard, request: wl.Keyboard.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleKeyboardDestroy(resource: *wl.Keyboard, self: *Self) void {
    for (self.keyboard_resources.items, 0..) |candidate, index| {
        if (candidate.resource != resource) continue;
        _ = self.keyboard_resources.orderedRemove(index);
        return;
    }
    unreachable;
}

fn handlePointerRequest(resource: *wl.Pointer, request: wl.Pointer.Request, self: *Self) void {
    switch (request) {
        .set_cursor => |set| if (self.pointerResourceIsActive(resource)) self.setCursor(
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
        if (candidate.resource != resource) continue;
        _ = self.pointer_resources.orderedRemove(index);
        return;
    }
    unreachable;
}

fn handleTouchRequest(resource: *wl.Touch, request: wl.Touch.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleTouchDestroy(resource: *wl.Touch, self: *Self) void {
    const client = resource.getClient();
    for (self.touch_frame_resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.touch_frame_resources.orderedRemove(index);
        break;
    }
    for (self.touch_resources.items, 0..) |candidate, index| {
        if (candidate.resource != resource) continue;
        _ = self.touch_resources.orderedRemove(index);
        for (self.touch_resources.items) |remaining| {
            if (remaining.resource.getClient() == client) return;
        }
        for (self.touch_points.items) |*point| {
            const target = point.target orelse continue;
            if (target.client == client) point.target = null;
        }
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

fn keyboardResourceActive(self: *const Self, entry: KeyboardResource) bool {
    return capabilityResourceActive(
        self.hasKeyboardCapability(),
        self.keyboard_capability_generation,
        entry.capability_generation,
    );
}

fn pointerResourceActive(self: *const Self, entry: PointerResource) bool {
    return capabilityResourceActive(
        self.pointer_available,
        self.pointer_capability_generation,
        entry.capability_generation,
    );
}

fn pointerResourceIsActive(self: *const Self, resource: *wl.Pointer) bool {
    for (self.pointer_resources.items) |entry| {
        if (entry.resource == resource) return self.pointerResourceActive(entry);
    }
    return false;
}

fn touchResourceActive(self: *const Self, entry: TouchResource) bool {
    return capabilityResourceActive(
        self.touch_available,
        self.touch_capability_generation,
        entry.capability_generation,
    );
}

fn beginCapabilityGeneration(generation: *u64, ever_available: *bool) void {
    generation.* = std.math.add(u64, generation.*, 1) catch unreachable;
    ever_available.* = true;
}

fn capabilityResourceActive(available: bool, current: u64, resource: u64) bool {
    return available and resource == current;
}

fn findTouchPoint(self: *const Self, id: i32) ?usize {
    for (self.touch_points.items, 0..) |point, index| {
        if (point.id == id) return index;
    }
    return null;
}

fn touchPoint(self: *const Self, id: i32) ?*const TouchPoint {
    return &self.touch_points.items[self.findTouchPoint(id) orelse return null];
}

fn latestTouchResourceGeneration(self: *const Self, client: *wl.Client) ?u64 {
    var latest: ?u64 = null;
    for (self.touch_resources.items) |entry| {
        if (!self.touchResourceActive(entry)) continue;
        if (entry.resource.getClient() == client) latest = entry.generation;
    }
    return latest;
}

fn hasTouchResourceVersion(
    self: *const Self,
    client: *wl.Client,
    version: u32,
    max_generation: u64,
) bool {
    for (self.touch_resources.items) |entry| {
        if (self.touchResourceActive(entry) and
            touchResourceInSequence(entry.generation, max_generation) and
            entry.resource.getClient() == client and
            entry.resource.getVersion() >= version) return true;
    }
    return false;
}

fn markTouchFrame(self: *Self, resource: *wl.Touch) error{OutOfMemory}!void {
    for (self.touch_frame_resources.items) |pending| {
        if (pending == resource) return;
    }
    try self.touch_frame_resources.append(self.allocator, resource);
}

fn touchResourceInSequence(generation: u64, max_generation: u64) bool {
    return generation <= max_generation;
}

fn capabilities(self: *const Self) wl.Seat.Capability {
    return .{
        .keyboard = self.hasKeyboardCapability(),
        .pointer = self.pointer_available,
        .touch = self.touch_available,
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
    self.recordSelectionSerial(surface.getClient(), serial);
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        const resource = entry.resource;
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
    for (self.keyboard_resources.items) |entry| {
        if (!self.keyboardResourceActive(entry)) continue;
        const resource = entry.resource;
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
        if (focus == null) self.restoreControllerCursor();
        return;
    }
    self.pointer_focus = focus;
    const time = motion_time orelse return;
    const surface = self.pointerSurface() orelse return;
    const position = self.pointer_focus orelse return;
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
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
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
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
    for (self.pointer_resources.items) |entry| {
        if (!self.pointerResourceActive(entry)) continue;
        const resource = entry.resource;
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

    const controller = self.isUnfocusedCursorController(pointer.getClient());
    const enter = self.latest_pointer_enter;
    if (!controller and (enter == null or enter.?.client != pointer.getClient() or enter.?.serial != serial)) return;
    const focused_client = if (self.pointerSurface()) |surface|
        surface.getClient() == pointer.getClient()
    else
        false;
    const current_surface = if (self.active_cursor) |cursor|
        if (cursor_surface) |surface| std.meta.eql(cursor.surface_id, surface.handle()) else false
    else
        false;
    if (!controller and !focused_client and !current_surface) return;

    const requested: ?ActiveCursor = if (cursor_surface) |surface| .{
        .surface_id = surface.handle(),
        .hotspot_x = hotspot_x,
        .hotspot_y = hotspot_y,
    } else null;
    if (controller) {
        self.cursor_controller.?.cursor = requested;
        if (self.pointer_focus) |focus| {
            const focused_surface = self.surface_store.get(focus.surface_id);
            if (focused_surface == null or focused_surface.?.resource.getClient() != pointer.getClient()) return;
        }
    }
    self.active_cursor = requested;
    self.requestRepaint();
}

fn restoreControllerCursor(self: *Self) void {
    self.active_cursor = if (self.cursor_controller) |controller| controller.cursor else null;
    self.requestRepaint();
}

fn clearCursor(self: *Self) void {
    if (self.active_cursor == null) return;
    self.active_cursor = null;
    self.requestRepaint();
}

fn cursorSurfaceCommitted(self: *Self, id: Surface.Id, info: Surface.CommitInfo) void {
    var repaint = false;
    if (self.active_cursor) |*cursor| if (std.meta.eql(cursor.surface_id, id)) {
        cursor.hotspot_x -|= info.offset_x;
        cursor.hotspot_y -|= info.offset_y;
        repaint = true;
    };
    if (self.cursor_controller) |*controller| if (controller.cursor) |*remembered| {
        if (std.meta.eql(remembered.surface_id, id)) {
            remembered.hotspot_x -|= info.offset_x;
            remembered.hotspot_y -|= info.offset_y;
        }
    };
    if (repaint) self.requestRepaint();
}

fn cursorSurfaceDestroyed(self: *Self, id: Surface.Id) void {
    if (self.active_cursor) |cursor| {
        if (std.meta.eql(cursor.surface_id, id)) self.clearCursor();
    }
    if (self.cursor_controller) |*controller| if (controller.cursor) |cursor| {
        if (std.meta.eql(cursor.surface_id, id)) controller.cursor = null;
    };
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

fn recordUserAction(self: *Self, client: *wl.Client, serial: u32) void {
    const action: UserAction = .{ .client = client, .serial = serial };
    self.last_user_action = action;
    self.recordSelectionSerial(client, serial);
}

fn recordSelectionSerial(self: *Self, client: *wl.Client, serial: u32) void {
    const action: UserAction = .{ .client = client, .serial = serial };
    self.recent_user_actions[self.next_user_action] = action;
    self.next_user_action = (self.next_user_action + 1) % user_action_history_capacity;
    self.recent_user_action_count = @min(
        self.recent_user_action_count + 1,
        user_action_history_capacity,
    );
}

fn notifyKeyboardFocus(self: *Self) void {
    for (self.keyboard_focus_listeners.items) |listener| {
        listener.changed(listener.context, self.keyboardFocusedClient());
    }
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

test "protocol serial ordering handles wraparound" {
    try std.testing.expect(!serialIsOlder(10, 10));
    try std.testing.expect(!serialIsOlder(11, 10));
    try std.testing.expect(serialIsOlder(9, 10));
    try std.testing.expect(!serialIsOlder(1, std.math.maxInt(u32)));
    try std.testing.expect(serialIsOlder(std.math.maxInt(u32), 1));
}

test "seat capability generations invalidate existing input resources" {
    var generation: u64 = 0;
    var ever_available = false;

    beginCapabilityGeneration(&generation, &ever_available);
    try std.testing.expect(ever_available);
    try std.testing.expect(capabilityResourceActive(true, generation, generation));
    try std.testing.expect(!capabilityResourceActive(false, generation, generation));

    const previous = generation;
    beginCapabilityGeneration(&generation, &ever_available);
    try std.testing.expect(!capabilityResourceActive(true, generation, previous));
    try std.testing.expect(capabilityResourceActive(true, generation, generation));
}

test "touch resources bound after down do not join the contact sequence" {
    try std.testing.expect(touchResourceInSequence(4, 4));
    try std.testing.expect(!touchResourceInSequence(5, 4));
}
