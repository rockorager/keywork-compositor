//! Wayland-source to X11-target drag-and-drop interoperability.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DataDevice = @import("../wayland/data_device.zig");
const XSelection = @import("selection.zig");
const c = @import("xcb.zig").c;

const wl = wayland.server.wl;
const log = std.log.scoped(.xwayland_dnd);

const protocol_version: u32 = 5;

allocator: std.mem.Allocator,
connection: *c.xcb_connection_t,
data_device: *DataDevice,
selection: *XSelection,
atoms: Atoms,
target: ?Target,
last_unaware: ?c.xcb_window_t,
dropped: bool,

pub const Atoms = struct {
    aware: c.xcb_atom_t,
    enter: c.xcb_atom_t,
    position: c.xcb_atom_t,
    status: c.xcb_atom_t,
    leave: c.xcb_atom_t,
    drop: c.xcb_atom_t,
    finished: c.xcb_atom_t,
    proxy: c.xcb_atom_t,
    type_list: c.xcb_atom_t,
    action_copy: c.xcb_atom_t,
    action_move: c.xcb_atom_t,
    action_ask: c.xcb_atom_t,
    action_private: c.xcb_atom_t,
};

const Target = struct {
    surface_window: c.xcb_window_t,
    destination: c.xcb_window_t,
    version: u32,
    generation: u64,
    accepted: bool = false,
    action: wl.DataDeviceManager.DndAction = .{},
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    connection: *c.xcb_connection_t,
    data_device: *DataDevice,
    selection: *XSelection,
    atoms: Atoms,
) !void {
    self.* = .{
        .allocator = allocator,
        .connection = connection,
        .data_device = data_device,
        .selection = selection,
        .atoms = atoms,
        .target = null,
        .last_unaware = null,
        .dropped = false,
    };
    const version = protocol_version;
    try checkRequest(connection, c.xcb_change_property_checked(
        connection,
        c.XCB_PROP_MODE_REPLACE,
        selection.ownerWindow(),
        atoms.aware,
        c.XCB_ATOM_ATOM,
        32,
        1,
        &version,
    ));
}

pub fn deinit(self: *Self) void {
    if (self.target) |target| {
        if (self.dropped) {
            self.data_device.finishExternalDrag(target.generation, false);
        } else {
            self.sendLeave(target);
            self.data_device.externalDragStatus(target.generation, false, .{});
        }
    }
    self.* = undefined;
}

pub fn dragStarted(self: *Self) void {
    self.last_unaware = null;
    if (self.target) |target| {
        if (!self.dropped) self.sendLeave(target);
        self.target = null;
        self.dropped = false;
    }
}

pub fn dragMotion(
    self: *Self,
    window: c.xcb_window_t,
    time: u32,
    x: f64,
    y: f64,
) void {
    if (self.dropped) return;
    const source = self.data_device.dragSourceInfo() orelse {
        self.dragLeft();
        return;
    };
    if (self.last_unaware == window) return;
    if (self.target) |target| {
        if (target.surface_window == window and target.generation == source.generation) {
            self.sendPosition(target, source.actions, time, x, y);
            return;
        }
        self.dragLeft();
    }
    const destination, const version = self.resolveTarget(window) orelse {
        self.last_unaware = window;
        return;
    };
    const target: Target = .{
        .surface_window = window,
        .destination = destination,
        .version = version,
        .generation = source.generation,
    };
    if (!self.sendEnter(target, source.mime_types)) return;
    self.target = target;
    self.sendPosition(target, source.actions, time, x, y);
}

pub fn dragLeft(self: *Self) void {
    self.last_unaware = null;
    const target = self.target orelse return;
    if (self.dropped) return;
    self.sendLeave(target);
    self.data_device.externalDragStatus(target.generation, false, .{});
    self.target = null;
}

pub fn drop(self: *Self, time: u32) bool {
    const target = self.target orelse return false;
    if (self.dropped) return true;
    const accepted = target.accepted and actionBits(target.action) != 0;
    if (accepted) {
        self.dropped = true;
        self.sendDrop(target, time);
    } else {
        self.sendLeave(target);
        self.data_device.externalDragStatus(target.generation, false, .{});
        self.target = null;
    }
    if (!self.data_device.dropOnExternalTarget(target.generation, accepted)) {
        self.target = null;
        self.dropped = false;
    }
    return true;
}

pub fn physicalDragEnded(self: *Self) void {
    if (self.dropped) return;
    self.dragLeft();
}

pub fn sourceDestroyed(self: *Self, generation: u64) void {
    const target = self.target orelse return;
    if (target.generation != generation) return;
    self.target = null;
    self.dropped = false;
}

pub fn windowDestroyed(self: *Self, window: c.xcb_window_t) void {
    if (self.last_unaware == window) self.last_unaware = null;
    const target = self.target orelse return;
    if (target.surface_window != window and target.destination != window) return;
    if (self.dropped) {
        self.data_device.finishExternalDrag(target.generation, false);
    } else {
        self.data_device.externalDragStatus(target.generation, false, .{});
    }
    self.target = null;
    self.dropped = false;
}

pub fn handleClientMessage(self: *Self, event: *const c.xcb_client_message_event_t) bool {
    if (event.format != 32 or event.window != self.selection.ownerWindow()) return false;
    if (event.type == self.atoms.status) {
        self.handleStatus(event);
        return true;
    }
    if (event.type == self.atoms.finished) {
        self.handleFinished(event);
        return true;
    }
    return false;
}

fn handleStatus(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const target = if (self.target) |*value| value else return;
    if (self.dropped or !targetMatches(target.*, event.data.data32[0])) return;
    const requested_action = self.actionForAtom(event.data.data32[4]);
    const source = self.data_device.dragSourceInfo() orelse return;
    if (source.generation != target.generation) return;
    const accepted = event.data.data32[1] & 1 != 0 and
        actionBits(requested_action) & actionBits(source.actions) != 0;
    const selected: wl.DataDeviceManager.DndAction = if (accepted) requested_action else .{};
    if (target.accepted == accepted and actionBits(target.action) == actionBits(selected)) return;
    target.accepted = accepted;
    target.action = selected;
    self.data_device.externalDragStatus(target.generation, accepted, target.action);
}

fn handleFinished(self: *Self, event: *const c.xcb_client_message_event_t) void {
    const target = self.target orelse return;
    if (!self.dropped or !targetMatches(target, event.data.data32[0])) return;
    const performed = target.version < 5 or event.data.data32[1] & 1 != 0;
    self.data_device.finishExternalDrag(target.generation, performed);
    self.target = null;
    self.dropped = false;
}

fn resolveTarget(self: *Self, window: c.xcb_window_t) ?struct { c.xcb_window_t, u32 } {
    var destination = window;
    if (self.readWindowProperty(window, self.atoms.proxy)) |proxy| {
        if (proxy != c.XCB_WINDOW_NONE and
            self.readWindowProperty(proxy, self.atoms.proxy) == proxy)
        {
            destination = proxy;
        }
    }
    const advertised = self.readVersion(destination) orelse return null;
    if (advertised < 3) {
        log.warn("ignored Xdnd target {d} with unsupported version {d}", .{
            destination,
            advertised,
        });
        return null;
    }
    return .{ destination, @min(advertised, protocol_version) };
}

fn readWindowProperty(
    self: *Self,
    window: c.xcb_window_t,
    property: c.xcb_atom_t,
) ?c.xcb_window_t {
    return self.readScalarProperty(window, property, c.XCB_ATOM_WINDOW);
}

fn readVersion(self: *Self, window: c.xcb_window_t) ?u32 {
    return self.readScalarProperty(window, self.atoms.aware, c.XCB_ATOM_ATOM);
}

fn readScalarProperty(
    self: *Self,
    window: c.xcb_window_t,
    property: c.xcb_atom_t,
    property_type: c.xcb_atom_t,
) ?u32 {
    const reply = c.xcb_get_property_reply(
        self.connection,
        c.xcb_get_property(
            self.connection,
            0,
            window,
            property,
            property_type,
            0,
            1,
        ),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    if (reply.*.type != property_type or reply.*.format != 32 or
        reply.*.value_len != 1 or reply.*.bytes_after != 0) return null;
    const value = c.xcb_get_property_value(reply) orelse return null;
    return @as(*const u32, @ptrCast(@alignCast(value))).*;
}

fn sendEnter(
    self: *Self,
    target: Target,
    mime_types: []const [:0]const u8,
) bool {
    var target_atoms: std.ArrayList(c.xcb_atom_t) = .empty;
    defer target_atoms.deinit(self.allocator);
    for (mime_types) |mime_type| {
        const atom = self.selection.targetAtomForMime(mime_type) orelse continue;
        if (std.mem.indexOfScalar(c.xcb_atom_t, target_atoms.items, atom) != null) continue;
        target_atoms.append(self.allocator, atom) catch return false;
    }

    var data = [_]u32{ self.selection.ownerWindow(), target.version << 24, 0, 0, 0 };
    if (target_atoms.items.len > 3) {
        data[1] |= 1;
        _ = c.xcb_change_property(
            self.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.selection.ownerWindow(),
            self.atoms.type_list,
            c.XCB_ATOM_ATOM,
            32,
            @intCast(target_atoms.items.len),
            target_atoms.items.ptr,
        );
    } else {
        _ = c.xcb_delete_property(
            self.connection,
            self.selection.ownerWindow(),
            self.atoms.type_list,
        );
        for (target_atoms.items, 0..) |atom, index| data[index + 2] = atom;
    }
    self.sendEvent(target.destination, self.atoms.enter, data);
    return true;
}

fn sendPosition(
    self: *Self,
    target: Target,
    source_actions: wl.DataDeviceManager.DndAction,
    time: u32,
    x: f64,
    y: f64,
) void {
    const packed_position = @as(u32, packedCoordinate(x)) << 16 | packedCoordinate(y);
    self.sendEvent(target.destination, self.atoms.position, .{
        self.selection.ownerWindow(),
        0,
        packed_position,
        time,
        self.atomForActions(source_actions),
    });
}

fn sendLeave(self: *Self, target: Target) void {
    self.sendEvent(target.destination, self.atoms.leave, .{
        self.selection.ownerWindow(),
        0,
        0,
        0,
        0,
    });
}

fn sendDrop(self: *Self, target: Target, time: u32) void {
    self.sendEvent(target.destination, self.atoms.drop, .{
        self.selection.ownerWindow(),
        0,
        time,
        0,
        0,
    });
}

fn sendEvent(
    self: *Self,
    destination: c.xcb_window_t,
    message_type: c.xcb_atom_t,
    data: [5]u32,
) void {
    var event = std.mem.zeroes(c.xcb_client_message_event_t);
    event.response_type = c.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = destination;
    event.type = message_type;
    event.data.data32 = data;
    _ = c.xcb_send_event(
        self.connection,
        0,
        destination,
        c.XCB_EVENT_MASK_NO_EVENT,
        @ptrCast(&event),
    );
    _ = c.xcb_flush(self.connection);
}

fn atomForActions(
    self: *const Self,
    actions: wl.DataDeviceManager.DndAction,
) c.xcb_atom_t {
    if (actions.copy) return self.atoms.action_copy;
    if (actions.move) return self.atoms.action_move;
    if (actions.ask) return self.atoms.action_ask;
    return c.XCB_ATOM_NONE;
}

fn actionForAtom(
    self: *const Self,
    atom: c.xcb_atom_t,
) wl.DataDeviceManager.DndAction {
    var action: wl.DataDeviceManager.DndAction = .{};
    if (atom == self.atoms.action_copy or atom == self.atoms.action_private) {
        action.copy = true;
    } else if (atom == self.atoms.action_move) {
        action.move = true;
    } else if (atom == self.atoms.action_ask) {
        action.ask = true;
    }
    return action;
}

fn actionBits(actions: wl.DataDeviceManager.DndAction) u32 {
    return @bitCast(actions);
}

fn targetMatches(target: Target, window: c.xcb_window_t) bool {
    return window == target.destination or window == target.surface_window;
}

fn packedCoordinate(value: f64) u16 {
    const bounded = std.math.clamp(
        @floor(value),
        @as(f64, @floatFromInt(std.math.minInt(i16))),
        @as(f64, @floatFromInt(std.math.maxInt(i16))),
    );
    return @bitCast(@as(i16, @intFromFloat(bounded)));
}

fn checkRequest(connection: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t) !void {
    const x_error = c.xcb_request_check(connection, cookie) orelse return;
    defer std.c.free(x_error);
    return error.X11RequestFailed;
}
