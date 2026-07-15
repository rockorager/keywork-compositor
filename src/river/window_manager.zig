//! river-window-management-v1 lifecycle and transaction boundary.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("../wayland/output.zig");
const OutputLayout = @import("../wayland/output_layout.zig");
const Scene = @import("../scene.zig");
const SecurityContext = @import("../wayland/security_context.zig");
const Seat = @import("../wayland/seat.zig");
const slot_map = @import("../slot_map.zig");
const Surface = @import("../wayland/surface.zig");
const XdgShell = @import("../wayland/xdg_shell.zig");
const LayerShell = @import("../wayland/layer_shell.zig");

const wl = wayland.server.wl;
const river = wayland.server.river;

const protocol_version = 5;

allocator: std.mem.Allocator,
display: *wl.Server,
global: *wl.Global,
layer_global: *wl.Global,
security_context: *SecurityContext,
outputs: *OutputLayout,
output_id: OutputLayout.Id,
seat_states: std.ArrayList(*SeatState),
default_seat_state: *SeatState,
scene: *Scene,
xdg_shell: *XdgShell,
layer_shell: *LayerShell,
active: ?*river.WindowManagerV1,
output_resources: std.ArrayList(*OutputResource),
session_generation: u64,
sequence: Sequence,
windows: WindowStore,
decorations: DecorationStore,
shell_surfaces: ShellSurfaceStore,
window_requests: std.ArrayList(PendingWindowRequest),
stack_operations: std.ArrayList(StackOperation),
configure_timer: *wl.EventSource,
layer_bindings: std.ArrayList(*LayerBinding),
layer_area: LayerShell.Rect,
layer_focus: LayerShell.FocusClass,
layer_focus_sent: LayerShell.FocusClass,
next_window_identifier: u64,
presentation_mode: river.OutputV1.PresentationMode,
pending_presentation_mode: ?river.OutputV1.PresentationMode,
pointer_bindings: std.ArrayList(*PointerBinding),
router: PointerRouter,

const WindowStore = slot_map.SlotMap(ManagedWindow, enum { managed_window });
const WindowId = WindowStore.Id;
const DecorationStore = slot_map.SlotMap(ManagedDecoration, enum { managed_decoration });
const DecorationId = DecorationStore.Id;
const ShellSurfaceStore = slot_map.SlotMap(ManagedShellSurface, enum { managed_shell_surface });
const ShellSurfaceId = ShellSurfaceStore.Id;

const SeatState = struct {
    seat: *Seat,
    removed: bool,
    seat_resource: ?*SeatResource,
    focused: ?WindowId,
    pending_focus: PendingFocus,
    held_buttons: std.ArrayList(HeldButton),
    last_pointer_position: ?Point,
    operation: ?PointerOperation,
    pending_operation: PendingOperation,
    pending_warp: ?Point,
    focused_shell_surface: ?ShellSurfaceId,
    desired_hovered: ?WindowId,
    sent_hovered: ?WindowId,
    pending_interaction: ?Interaction,
    ignore_until_release: bool,

    fn create(allocator: std.mem.Allocator, seat: *Seat) !*SeatState {
        const self = try allocator.create(SeatState);
        self.* = .{
            .seat = seat,
            .removed = false,
            .seat_resource = null,
            .focused = null,
            .pending_focus = .unchanged,
            .held_buttons = .empty,
            .last_pointer_position = null,
            .operation = null,
            .pending_operation = .unchanged,
            .pending_warp = null,
            .focused_shell_surface = null,
            .desired_hovered = null,
            .sent_hovered = null,
            .pending_interaction = null,
            .ignore_until_release = false,
        };
        return self;
    }

    fn destroy(self: *SeatState, allocator: std.mem.Allocator) void {
        self.held_buttons.deinit(allocator);
        allocator.destroy(self);
    }
};

const ManagedNodeId = union(enum) {
    window: WindowId,
    shell_surface: ShellSurfaceId,
};

const ManagedWindow = struct {
    xdg_id: XdgShell.WindowId,
    identifier: u64,
    resource: ?*river.WindowV1 = null,
    node_resource: ?*river.NodeV1 = null,
    node_created: bool = false,
    metadata_dirty: bool = true,
    sent_presentation_hint: bool = false,
    proposed_dimensions: ?XdgShell.Dimensions = null,
    requested_dimensions: XdgShell.Dimensions = .{ .width = 0, .height = 0 },
    requested_configuration: XdgShell.ToplevelConfigure = .{},
    sent_configuration: XdgShell.ToplevelConfigure = .{},
    fullscreen_output: ?OutputLayout.Id = null,
    fullscreen_dimensions_pending: bool = false,
    configure: ConfigureState = .idle,
    dimensions_pending: bool = false,
    last_dimensions: ?XdgShell.Dimensions = null,
    display_ready: bool = false,
    requested_visible: bool = true,
    pending_position: ?Scene.Position = null,
    pending_borders: PendingBorders = .unchanged,
    pending_clip_box: PendingClipBox = .unchanged,
    pending_content_clip_box: PendingClipBox = .unchanged,
    borders: ?Scene.Borders = null,
    clip_box: ?Scene.ClipBox = null,
    content_clip_box: ?Scene.ClipBox = null,
};

const ManagedDecoration = struct {
    window_id: WindowId,
    scene_id: ?Scene.DecorationId,
    adapter: *DecorationResource,
    pending_offset: ?Scene.Position = null,
};

const ManagedShellSurface = struct {
    scene_id: ?Scene.ShellSurfaceId,
    adapter: *ShellSurfaceResource,
    node_resource: ?*river.NodeV1 = null,
    node_created: bool = false,
    pending_position: ?Scene.Position = null,
};

const StackOperation = union(enum) {
    top: ManagedNodeId,
    bottom: ManagedNodeId,
    above: struct { id: ManagedNodeId, other: ManagedNodeId },
    below: struct { id: ManagedNodeId, other: ManagedNodeId },
};

const PendingWindowRequest = struct {
    id: WindowId,
    request: Request,

    const Request = union(enum) {
        pointer_move,
        pointer_resize: river.WindowV1.Edges,
        show_window_menu: struct { x: i32, y: i32 },
        maximize,
        unmaximize,
        fullscreen: ?OutputLayout.Id,
        exit_fullscreen,
        minimize,
    };
};

const ConfigureState = union(enum) {
    idle,
    inflight: PendingConfigure,
    timed_out: PendingConfigure,
};

const PendingConfigure = struct {
    serial: u32,
    report_dimensions: bool,
};

const PendingFocus = union(enum) {
    unchanged,
    clear,
    window: WindowId,
    shell_surface: ShellSurfaceId,
};

const Point = struct { x: i32, y: i32 };
const PointerOperation = struct { start: Point, current: Point, release_pending: bool = false, release_sent: bool = false };
const PendingOperation = enum { unchanged, start, end };
const HeldButton = struct { button: u32, binding: ?*PointerBinding, captured: bool };
const Interaction = union(enum) { window: WindowId, shell_surface: ShellSurfaceId };
pub const PointerRoute = struct { focus: ?Seat.PointerFocus, root: ?Surface.Id };
pub const PointerRouter = struct {
    context: *anyopaque,
    route: *const fn (*anyopaque, f64, f64) PointerRoute,
};

fn operationDelta(operation: PointerOperation) Point {
    return .{
        .x = @intCast(std.math.clamp(@as(i64, operation.current.x) - operation.start.x, std.math.minInt(i32), std.math.maxInt(i32))),
        .y = @intCast(std.math.clamp(@as(i64, operation.current.y) - operation.start.y, std.math.minInt(i32), std.math.maxInt(i32))),
    };
}

fn pointerCoordinate(value: f64) i32 {
    return @intFromFloat(std.math.clamp(value, @as(f64, std.math.minInt(i32)), @as(f64, std.math.maxInt(i32))));
}

fn clampPoint(point: Point, width: u32, height: u32) Point {
    std.debug.assert(width > 0 and height > 0);
    return .{
        .x = std.math.clamp(point.x, 0, @as(i32, @intCast(width - 1))),
        .y = std.math.clamp(point.y, 0, @as(i32, @intCast(height - 1))),
    };
}

fn hasCapturedButton(buttons: []const HeldButton) bool {
    for (buttons) |held| if (held.captured) return true;
    return false;
}

const PendingBorders = union(enum) {
    unchanged,
    set: ?Scene.Borders,
};

const PendingClipBox = union(enum) {
    unchanged,
    set: ?Scene.ClipBox,
};

fn protocolColorComponent(value: u32) u8 {
    const maximum = std.math.maxInt(u32);
    return @intCast((@as(u64, value) * 255 + maximum / 2) / maximum);
}

const Sequence = struct {
    state: State = .idle,
    dirty: bool = false,

    const State = union(enum) {
        idle,
        manage,
        inflight_configures: u32,
        render,
    };

    fn reset(self: *Sequence) void {
        self.* = .{};
    }

    fn requestManage(self: *Sequence) bool {
        self.dirty = true;
        if (self.state != .idle) return false;
        self.dirty = false;
        self.state = .manage;
        return true;
    }

    fn finishManage(self: *Sequence, configure_count: u32) bool {
        if (self.state != .manage) return false;
        self.state = if (configure_count == 0)
            .render
        else
            .{ .inflight_configures = configure_count };
        return true;
    }

    fn configureFinished(self: *Sequence) bool {
        switch (self.state) {
            .inflight_configures => |count| {
                std.debug.assert(count > 0);
                if (count == 1) {
                    self.state = .render;
                    return true;
                }
                self.state = .{ .inflight_configures = count - 1 };
                return false;
            },
            else => return false,
        }
    }

    fn configureTimeout(self: *Sequence) bool {
        if (self.state != .inflight_configures) return false;
        self.state = .render;
        return true;
    }

    fn finishRender(self: *Sequence) enum { invalid, idle, manage } {
        if (self.state != .render) return .invalid;
        if (self.dirty) {
            self.dirty = false;
            self.state = .manage;
            return .manage;
        }
        self.state = .idle;
        return .idle;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    outputs: *OutputLayout,
    output_id: OutputLayout.Id,
    seat: *Seat,
    scene: *Scene,
    xdg_shell: *XdgShell,
    layer_shell: *LayerShell,
    router: PointerRouter,
) !void {
    const seat_state = try SeatState.create(allocator, seat);
    errdefer seat_state.destroy(allocator);

    self.* = .{
        .allocator = allocator,
        .display = display,
        .global = undefined,
        .layer_global = undefined,
        .security_context = security_context,
        .outputs = outputs,
        .output_id = output_id,
        .seat_states = .empty,
        .default_seat_state = seat_state,
        .scene = scene,
        .xdg_shell = xdg_shell,
        .layer_shell = layer_shell,
        .active = null,
        .output_resources = .empty,
        .session_generation = 0,
        .sequence = .{},
        .windows = .{},
        .decorations = .{},
        .shell_surfaces = .{},
        .window_requests = .empty,
        .stack_operations = .empty,
        .configure_timer = undefined,
        .layer_bindings = .empty,
        .layer_area = layer_shell.usableArea(),
        .layer_focus = .none,
        .layer_focus_sent = .none,
        .next_window_identifier = 1,
        .presentation_mode = .vsync,
        .pending_presentation_mode = null,
        .pointer_bindings = .empty,
        .router = router,
    };
    try self.seat_states.append(allocator, seat_state);
    errdefer self.seat_states.deinit(allocator);
    errdefer self.windows.deinit(allocator);
    errdefer self.decorations.deinit(allocator);
    errdefer self.shell_surfaces.deinit(allocator);
    errdefer self.window_requests.deinit(allocator);
    errdefer self.stack_operations.deinit(allocator);
    errdefer self.output_resources.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        river.WindowManagerV1,
        protocol_version,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    self.layer_global = try wl.Global.create(display, river.LayerShellV1, 1, *Self, self, bindLayerShell);
    errdefer self.layer_global.destroy();
    try security_context.restrictGlobal(self.layer_global);
    errdefer security_context.unrestrictGlobal(self.layer_global);
    self.configure_timer = try display.getEventLoop().addTimer(*Self, handleConfigureTimeout, self);
    xdg_shell.setWindowListener(.{
        .context = self,
        .ready = windowReady,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .request = windowRequest,
    });
    layer_shell.setPolicyListener(.{
        .context = self,
        .supported = layerSupported,
        .changed = layerChanged,
    });
}

fn resolveOutput(self: *Self) *Output {
    return self.outputs.get(self.output_id) orelse unreachable;
}

pub fn setDefaultOutput(self: *Self, output_id: OutputLayout.Id) void {
    std.debug.assert(self.outputs.get(output_id) != null);
    self.output_id = output_id;
    self.layer_area = self.layer_shell.usableArea();
}

pub fn outputStateChanged(
    self: *Self,
    output_id: OutputLayout.Id,
    position_changed: bool,
    dimensions_changed: bool,
) void {
    const resource = (self.outputResource(output_id) orelse return).resource;
    const output = self.outputs.get(output_id) orelse return;
    if (position_changed) {
        const position = output.logicalPosition();
        resource.sendPosition(position.x, position.y);
    }
    if (dimensions_changed) {
        const size = output.logicalSize();
        resource.sendDimensions(@intCast(size.width), @intCast(size.height));
    }
    if (position_changed or dimensions_changed) self.requestManage();
}

pub fn outputAdded(self: *Self, output_id: OutputLayout.Id) !void {
    const output = self.outputs.get(output_id) orelse unreachable;
    const manager = self.active orelse return;
    try self.createOutput(manager, output_id, output);
    self.requestManage();
}

pub fn outputRemoved(self: *Self, output_id: OutputLayout.Id) void {
    std.debug.assert(self.outputs.get(output_id) != null);
    if (std.meta.eql(self.output_id, output_id)) {
        var outputs = self.outputs.iterator();
        while (outputs.next()) |entry| std.debug.assert(std.meta.eql(entry.id, output_id));
    }

    if (self.outputResource(output_id)) |output_resource| {
        output_resource.removed = true;
        output_resource.resource.sendRemoved();
    }

    const replacement = if (std.meta.eql(self.output_id, output_id)) null else self.output_id;
    var windows = self.windows.iterator();
    while (windows.next()) |entry| {
        if (!std.meta.eql(entry.value.fullscreen_output, output_id)) continue;
        entry.value.fullscreen_output = replacement;
        entry.value.fullscreen_dimensions_pending = replacement != null;
    }
    self.requestManage();
}

fn outputResource(self: *Self, output_id: OutputLayout.Id) ?*OutputResource {
    for (self.output_resources.items) |output_resource| {
        if (output_resource.owner_generation != self.session_generation) continue;
        if (output_resource.removed) continue;
        if (std.meta.eql(output_resource.output_id, output_id)) return output_resource;
    }
    return null;
}

fn fullscreenOutput(self: *Self, window: *const ManagedWindow) ?*Output {
    return self.outputs.get(window.fullscreen_output orelse return null);
}

pub fn deinit(self: *Self) void {
    self.layer_shell.clearPolicyListener();
    self.xdg_shell.clearWindowListener();
    self.configure_timer.remove();
    self.releaseWindows();
    self.releaseShellSurfaces();
    self.windows.deinit(self.allocator);
    self.decorations.deinit(self.allocator);
    self.shell_surfaces.deinit(self.allocator);
    self.window_requests.deinit(self.allocator);
    self.stack_operations.deinit(self.allocator);
    std.debug.assert(self.output_resources.items.len == 0);
    self.output_resources.deinit(self.allocator);
    std.debug.assert(self.pointer_bindings.items.len == 0);
    self.pointer_bindings.deinit(self.allocator);
    for (self.seat_states.items) |seat_state| {
        std.debug.assert(seat_state.seat_resource == null);
        seat_state.destroy(self.allocator);
    }
    self.seat_states.deinit(self.allocator);
    std.debug.assert(self.layer_bindings.items.len == 0);
    self.layer_bindings.deinit(self.allocator);
    self.security_context.unrestrictGlobal(self.layer_global);
    self.layer_global.destroy();
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    self.* = undefined;
}

pub fn hasActiveManager(self: *const Self) bool {
    return self.active != null;
}

fn seatState(self: *const Self, seat: *Seat) ?*SeatState {
    for (self.seat_states.items) |state| {
        if (!state.removed and state.seat == seat) return state;
    }
    return null;
}

pub fn seatAdded(self: *Self, seat: *Seat) error{OutOfMemory}!void {
    std.debug.assert(self.seatState(seat) == null);
    const state = try SeatState.create(self.allocator, seat);
    errdefer state.destroy(self.allocator);
    try self.seat_states.append(self.allocator, state);
    errdefer _ = self.seat_states.pop();
    if (self.active) |manager| {
        try self.createSeat(manager, state);
        if (manager.getVersion() >= 4) seat.setUnfocusedCursorController(manager.getClient());
        self.requestManage();
    }
}

pub fn seatRemoved(self: *Self, seat: *Seat) void {
    const state = self.seatState(seat) orelse return;
    std.debug.assert(state != self.default_seat_state);
    if (state.removed) return;
    state.removed = true;
    state.focused = null;
    state.pending_focus = .unchanged;
    state.held_buttons.clearRetainingCapacity();
    state.operation = null;
    state.pending_operation = .unchanged;
    state.pending_warp = null;
    state.focused_shell_surface = null;
    state.desired_hovered = null;
    state.sent_hovered = null;
    state.pending_interaction = null;
    state.ignore_until_release = false;
    state.last_pointer_position = null;
    state.seat.setUnfocusedCursorController(null);
    for (self.pointer_bindings.items) |binding| if (binding.seat_state == state) {
        binding.pending.clearRetainingCapacity();
    };
    if (state.seat_resource) |adapter| adapter.resource.sendRemoved();
    self.requestManage();
}

pub fn focusedShellSurface(self: *Self) ?Surface.Id {
    return self.focusedShellSurfaceForSeat(self.default_seat_state.seat);
}

pub fn focusedShellSurfaceForSeat(self: *Self, seat: *Seat) ?Surface.Id {
    const state = self.seatState(seat) orelse return null;
    if (state.removed) return null;
    const id = state.focused_shell_surface orelse return null;
    const managed = self.shell_surfaces.get(id) orelse return null;
    return if (managed.adapter.surface) |surface| surface.handle() else null;
}

pub fn pointerGrabbed(self: *const Self) bool {
    return self.pointerGrabbedForSeat(self.default_seat_state.seat);
}

pub fn pointerGrabbedForSeat(self: *const Self, seat: *Seat) bool {
    const state = self.seatState(seat) orelse return false;
    return pointerGrabbedState(state);
}

fn pointerGrabbedState(state: *const SeatState) bool {
    if (state.removed or state.operation != null or state.ignore_until_release) return !state.removed;
    return hasCapturedButton(state.held_buttons.items);
}

fn reroutePointer(self: *Self, state: *SeatState) bool {
    if (state.removed) return false;
    const position = state.seat.pointerPosition() orelse return false;
    const route = self.router.route(self.router.context, position.x, position.y);
    state.seat.pointerEnter(position.x, position.y, if (pointerGrabbedState(state)) null else route.focus);
    return self.updateDesiredHover(state, if (pointerGrabbedState(state)) null else route.root);
}

fn windowForSurface(self: *Self, root: ?Surface.Id) ?WindowId {
    const surface_id = root orelse return null;
    if (self.xdg_shell.surfaceRootWindow(surface_id)) |xdg_id| return self.findWindow(xdg_id);
    var decorations = self.decorations.iterator();
    while (decorations.next()) |entry| if (entry.value.adapter.surface) |surface| {
        if (std.meta.eql(surface.handle(), surface_id)) return entry.value.window_id;
    };
    return null;
}

fn shellForSurface(self: *Self, root: ?Surface.Id) ?ShellSurfaceId {
    const surface_id = root orelse return null;
    var iterator = self.shell_surfaces.iterator();
    while (iterator.next()) |entry| {
        const surface = entry.value.adapter.surface orelse continue;
        if (std.meta.eql(surface.handle(), surface_id)) return entry.id;
    }
    return null;
}

pub fn pointerMoved(self: *Self, root: ?Surface.Id) void {
    self.pointerMovedForSeat(self.default_seat_state.seat, root);
}

pub fn pointerMovedForSeat(self: *Self, seat: *Seat, root: ?Surface.Id) void {
    const state = self.seatState(seat) orelse return;
    if (state.removed) return;
    var changed = false;
    if (state.operation) |*operation| if (state.seat.pointerPosition()) |position| {
        const current: Point = .{ .x = pointerCoordinate(position.x), .y = pointerCoordinate(position.y) };
        if (!std.meta.eql(current, operation.current)) {
            operation.current = current;
            changed = true;
        }
    };
    changed = self.updateDesiredHover(state, if (pointerGrabbedState(state)) null else root) or changed;
    if (changed) self.requestManage();
}

pub fn bindingSession(self: *Self, resource: *river.SeatV1) ?u64 {
    const data = resource.getUserData() orelse return null;
    const seat_resource: *SeatResource = @ptrCast(@alignCast(data));
    if (seat_resource.manager != self or seat_resource.seat_state.removed or seat_resource.seat_state.seat_resource != seat_resource or
        seat_resource.resource != resource or self.active == null) return null;
    if (seat_resource.owner_generation != self.session_generation or
        resource.getClient() != self.active.?.getClient()) return null;
    return self.session_generation;
}

pub fn bindingSeat(self: *Self, resource: *river.SeatV1) ?*Seat {
    _ = self.bindingSession(resource) orelse return null;
    const adapter: *SeatResource = @ptrCast(@alignCast(resource.getUserData().?));
    return adapter.seat_state.seat;
}

pub fn bindingSessionActive(self: *Self, generation: u64, client: *wl.Client) bool {
    return self.active != null and self.session_generation == generation and
        self.active.?.getClient() == client;
}

pub fn requireBindingManage(self: *Self, generation: u64, client: *wl.Client) bool {
    if (!self.bindingSessionActive(generation, client)) return false;
    if (self.sequence.state == .manage) return true;
    self.active.?.postError(.sequence_order, "binding request outside a manage sequence");
    return false;
}

pub fn requestBindingManage(self: *Self, generation: u64, client: *wl.Client) void {
    if (self.bindingSessionActive(generation, client)) self.requestManage();
}

fn updateDesiredHover(self: *Self, state: *SeatState, root: ?Surface.Id) bool {
    const next = self.windowForSurface(root);
    if (std.meta.eql(state.desired_hovered, next)) return false;
    state.desired_hovered = next;
    return true;
}

/// Returns true when the physical event is intercepted by River.
pub fn pointerButton(self: *Self, button: u32, state: wl.Pointer.ButtonState, root: ?Surface.Id) bool {
    return self.pointerButtonForSeat(self.default_seat_state.seat, button, state, root);
}

pub fn pointerButtonForSeat(self: *Self, seat: *Seat, button: u32, button_state: wl.Pointer.ButtonState, root: ?Surface.Id) bool {
    const seat_state = self.seatState(seat) orelse return false;
    if (seat_state.removed) return false;
    if (button_state == .pressed) {
        var matched: ?*PointerBinding = null;
        for (self.pointer_bindings.items) |binding| {
            if (binding.seat_state == seat_state and binding.active() and binding.enabled and binding.button == button and
                binding.modifiers == seat_state.seat.effectiveModifiers())
            {
                matched = binding;
                break;
            }
        }
        const captured = matched != null or pointerGrabbedState(seat_state);
        seat_state.held_buttons.append(self.allocator, .{ .button = button, .binding = matched, .captured = captured }) catch {
            if (captured) if (self.active) |manager| manager.postNoMemory();
            return captured;
        };
        if (matched) |binding| {
            binding.pending.append(self.allocator, .pressed) catch {
                if (self.active) |manager| manager.postNoMemory();
                return true;
            };
            _ = self.updateDesiredHover(seat_state, null);
            self.requestManage();
            return true;
        }
        if (!captured and self.active != null) {
            seat_state.pending_interaction = if (self.windowForSurface(root)) |id|
                .{ .window = id }
            else if (self.shellForSurface(root)) |id|
                .{ .shell_surface = id }
            else
                null;
            if (seat_state.pending_interaction != null) self.requestManage();
        }
        return captured;
    }
    for (seat_state.held_buttons.items, 0..) |held, index| {
        if (held.button != button) continue;
        const was_grabbed = pointerGrabbedState(seat_state);
        _ = seat_state.held_buttons.orderedRemove(index);
        var needs_manage = false;
        if (held.binding) |binding| if (binding.active()) binding.pending.append(self.allocator, .released) catch {
            if (self.active) |manager| manager.postNoMemory();
        };
        if (held.binding != null) needs_manage = true;
        if (seat_state.operation) |*operation| if (seat_state.held_buttons.items.len == 0 and !operation.release_pending and !operation.release_sent) {
            operation.release_pending = true;
            needs_manage = true;
        };
        const swallowed = held.captured or was_grabbed;
        if (seat_state.held_buttons.items.len == 0 and seat_state.ignore_until_release) {
            seat_state.ignore_until_release = false;
        }
        if (was_grabbed and !pointerGrabbedState(seat_state)) {
            needs_manage = self.reroutePointer(seat_state) or needs_manage;
        }
        if (needs_manage) self.requestManage();
        return swallowed;
    }
    return pointerGrabbedState(seat_state);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = river.WindowManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, handleDestroy, self);

    if (self.active != null) {
        resource.sendUnavailable();
        return;
    }

    self.active = resource;
    self.session_generation +%= 1;
    if (resource.getVersion() >= 4) for (self.seat_states.items) |state| if (!state.removed) state.seat.setUnfocusedCursorController(resource.getClient());
    for (self.layer_bindings.items) |binding| binding.beginSession(if (binding.resource.getClient() == resource.getClient()) self.session_generation else null);
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| self.createOutput(resource, entry.id, entry.output) catch {
        resource.postNoMemory();
        return;
    };
    for (self.seat_states.items) |seat_state| if (!seat_state.removed) self.createSeat(resource, seat_state) catch {
        resource.postNoMemory();
        return;
    };
    var windows = self.xdg_shell.windowIterator();
    while (windows.next()) |xdg_id| {
        const info = self.xdg_shell.windowInfo(xdg_id) orelse continue;
        if (!info.ready) continue;
        _ = self.ensureWindow(xdg_id) catch {
            resource.postNoMemory();
            return;
        };
        self.xdg_shell.setWindowVisible(xdg_id, false);
    }
    _ = self.reroutePointer(self.default_seat_state);
    self.requestManage();
}

fn handleRequest(
    resource: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    self: *Self,
) void {
    if (self.active != resource) {
        if (request == .destroy) resource.destroy();
        return;
    }

    switch (request) {
        .stop => {
            resource.sendFinished();
            self.releaseManager();
        },
        .destroy => resource.postError(.sequence_order, "stop the window manager before destroying it"),
        .manage_finish => {
            self.finishManage(resource);
        },
        .manage_dirty => self.requestManage(),
        .render_finish => self.finishRender(resource),
        .get_shell_surface => |get| ShellSurfaceResource.create(
            self,
            resource,
            Surface.fromResource(get.surface),
            get.id,
        ) catch resource.postNoMemory(),
        .exit_session => self.display.terminate(),
    }
}

fn handleDestroy(resource: *river.WindowManagerV1, self: *Self) void {
    if (self.active == resource) self.releaseManager();
}

fn ensureWindow(self: *Self, xdg_id: XdgShell.WindowId) error{OutOfMemory}!WindowId {
    if (self.findWindow(xdg_id)) |id| return id;
    const identifier = self.next_window_identifier;
    self.next_window_identifier = std.math.add(u64, identifier, 1) catch unreachable;
    return self.windows.insert(self.allocator, .{
        .xdg_id = xdg_id,
        .identifier = identifier,
    });
}

fn findWindow(self: *Self, xdg_id: XdgShell.WindowId) ?WindowId {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.xdg_id, xdg_id)) return entry.id;
    }
    return null;
}

fn requestManage(self: *Self) void {
    const manager = self.active orelse return;
    if (!self.sequence.requestManage()) return;
    self.sendPendingState(manager) catch {
        manager.postNoMemory();
        return;
    };
    manager.sendManageStart();
}

fn sendPendingState(self: *Self, manager: *river.WindowManagerV1) !void {
    self.layer_focus_sent = self.layer_focus;
    for (self.layer_bindings.items) |binding| if (binding.active()) {
        if (binding.output) |output| if (output.sent_area == null or !std.meta.eql(output.sent_area.?, self.layer_area)) {
            const area = self.layer_area;
            output.resource.sendNonExclusiveArea(area.x, area.y, area.width, area.height);
            output.sent_area = area;
        };
        if (binding.seat) |seat| if (seat.sent_focus == null or seat.sent_focus.? != self.layer_focus) {
            switch (self.layer_focus) {
                .exclusive => seat.resource.sendFocusExclusive(),
                .non_exclusive => seat.resource.sendFocusNonExclusive(),
                .none => seat.resource.sendFocusNone(),
            }
            seat.sent_focus = self.layer_focus;
        };
    };
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.resource == null) try self.createWindowResource(manager, entry.id);
    }

    iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        const window = entry.value;
        if (!window.metadata_dirty) continue;
        const resource = window.resource orelse continue;
        const info = self.xdg_shell.windowInfo(window.xdg_id) orelse continue;
        resource.sendDimensionsHint(
            info.min_size.width,
            info.min_size.height,
            info.max_size.width,
            info.max_size.height,
        );
        resource.sendAppId(if (info.app_id) |app_id| app_id.ptr else null);
        resource.sendTitle(if (info.title) |title| title.ptr else null);
        const parent_resource = if (info.parent) |parent_id| parent: {
            const managed_parent_id = self.findWindow(parent_id) orelse break :parent null;
            const managed_parent = self.windows.get(managed_parent_id) orelse break :parent null;
            break :parent managed_parent.resource;
        } else null;
        resource.sendParent(parent_resource);
        resource.sendDecorationHint(switch (info.decoration_preference) {
            .only_csd => .only_supports_csd,
            .prefers_csd => .prefers_csd,
            .prefers_ssd => .prefers_ssd,
            .no_preference => .no_preference,
        });
        window.metadata_dirty = false;
    }

    for (self.seat_states.items) |state| {
        if (state.removed) continue;
        if (state.seat_resource) |seat_adapter| {
            const seat_resource = seat_adapter.resource;
            if (!std.meta.eql(state.sent_hovered, state.desired_hovered)) {
                if (state.sent_hovered != null) seat_resource.sendPointerLeave();
                state.sent_hovered = null;
                if (state.desired_hovered) |id| if (self.windows.get(id)) |window| if (window.resource) |resource| {
                    seat_resource.sendPointerEnter(resource);
                    state.sent_hovered = id;
                };
            }
            if (state.pending_interaction) |interaction| switch (interaction) {
                .window => |id| if (self.windows.get(id)) |window| if (window.resource) |resource| seat_resource.sendWindowInteraction(resource),
                .shell_surface => |id| if (self.shell_surfaces.get(id)) |shell| seat_resource.sendShellSurfaceInteraction(shell.adapter.resource),
            };
            state.pending_interaction = null;
            if (state.operation) |*operation| {
                const delta = operationDelta(operation.*);
                seat_resource.sendOpDelta(delta.x, delta.y);
                if (operation.release_pending and !operation.release_sent) {
                    seat_resource.sendOpRelease();
                    operation.release_pending = false;
                    operation.release_sent = true;
                }
            }
        }
    }
    for (self.pointer_bindings.items) |binding| {
        for (binding.pending.items) |event| switch (event) {
            .pressed => binding.resource.sendPressed(),
            .released => binding.resource.sendReleased(),
        };
        binding.pending.clearRetainingCapacity();
    }

    for (self.window_requests.items) |pending| {
        const window = self.windows.get(pending.id) orelse continue;
        const resource = window.resource orelse continue;
        switch (pending.request) {
            .pointer_move => if (self.default_seat_state.seat_resource) |seat| {
                resource.sendPointerMoveRequested(seat.resource);
            },
            .pointer_resize => |edges| if (self.default_seat_state.seat_resource) |seat| {
                resource.sendPointerResizeRequested(seat.resource, edges);
            },
            .show_window_menu => |menu| {
                resource.sendShowWindowMenuRequested(menu.x, menu.y);
            },
            .maximize => resource.sendMaximizeRequested(),
            .unmaximize => resource.sendUnmaximizeRequested(),
            .fullscreen => |preferred_output| resource.sendFullscreenRequested(if (preferred_output) |id|
                if (self.outputResource(id)) |output| output.resource else null
            else
                null),
            .exit_fullscreen => resource.sendExitFullscreenRequested(),
            .minimize => resource.sendMinimizeRequested(),
        }
    }
    self.window_requests.clearRetainingCapacity();
    for (self.seat_states.items) |state| {
        if (state.removed) continue;
        if (state.seat_resource) |seat_adapter| if (seat_adapter.resource.getVersion() >= 2) {
            const seat_resource = seat_adapter.resource;
            if (state.seat.pointerPosition()) |position| {
                const point: Point = .{ .x = pointerCoordinate(position.x), .y = pointerCoordinate(position.y) };
                if (state.last_pointer_position == null or !std.meta.eql(state.last_pointer_position.?, point)) {
                    seat_resource.sendPointerPosition(point.x, point.y);
                    state.last_pointer_position = point;
                }
            }
        };
    }
}

fn createWindowResource(
    self: *Self,
    manager: *river.WindowManagerV1,
    id: WindowId,
) !void {
    const resource = try river.WindowV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(WindowResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .id = id,
        .owner_generation = self.session_generation,
    };
    resource.setHandler(*WindowResource, WindowResource.handleRequest, WindowResource.handleDestroy, adapter);

    const window = self.windows.get(id) orelse unreachable;
    window.resource = resource;
    manager.sendWindow(resource);
    if (resource.getVersion() >= river.WindowV1.unreliable_pid_since_version) {
        const info = self.xdg_shell.windowInfo(window.xdg_id) orelse unreachable;
        resource.sendUnreliablePid(info.unreliable_pid);
    }
    if (resource.getVersion() >= river.WindowV1.identifier_since_version) {
        var identifier_buffer: [20]u8 = undefined;
        const identifier = std.fmt.bufPrintSentinel(
            &identifier_buffer,
            "kw-{x:0>16}",
            .{window.identifier},
            0,
        ) catch unreachable;
        resource.sendIdentifier(identifier.ptr);
    }
    if (resource.getVersion() >= river.WindowV1.capture_sessions_since_version) {
        resource.sendCaptureSessions(0);
    }
}

fn finishManage(self: *Self, manager: *river.WindowManagerV1) void {
    if (self.sequence.state != .manage) {
        manager.postError(.sequence_order, "manage_finish outside a manage sequence");
        return;
    }

    for (self.seat_states.items) |state| if (!state.removed) self.finishSeatManage(state);

    var configure_count: u32 = 0;
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        const activated = self.windowFocusedByAnySeat(entry.id);
        entry.value.requested_configuration.activated = activated;
        const report_dimensions = entry.value.proposed_dimensions != null or
            entry.value.fullscreen_dimensions_pending;
        const info = self.xdg_shell.windowInfo(entry.value.xdg_id) orelse continue;
        if (info.decoration_preference == .only_csd) {
            entry.value.requested_configuration.decoration_mode = .client_side;
        }
        const configuration_changed = !std.meta.eql(
            entry.value.requested_configuration,
            entry.value.sent_configuration,
        );
        if (!report_dimensions and !configuration_changed and
            !info.decoration_configure_requested) continue;
        const proposed_dimensions = entry.value.proposed_dimensions;
        const dimensions = if (self.fullscreenOutput(entry.value)) |output| fullscreen: {
            const size = output.logicalSize();
            break :fullscreen XdgShell.Dimensions{
                .width = @intCast(size.width),
                .height = @intCast(size.height),
            };
        } else proposed_dimensions orelse info.dimensions orelse entry.value.requested_dimensions;
        const serial = self.xdg_shell.configureWindowState(
            entry.value.xdg_id,
            dimensions,
            entry.value.requested_configuration,
        ) catch |err| {
            switch (err) {
                error.OutOfMemory => manager.postNoMemory(),
                error.InvalidWindow => {},
            }
            continue;
        };
        if (report_dimensions) {
            entry.value.proposed_dimensions = null;
            entry.value.fullscreen_dimensions_pending = false;
            if (entry.value.fullscreen_output == null and proposed_dimensions != null) {
                entry.value.requested_dimensions = dimensions;
            }
        }
        entry.value.sent_configuration = entry.value.requested_configuration;
        entry.value.configure = .{ .inflight = .{
            .serial = serial,
            .report_dimensions = report_dimensions,
        } };
        configure_count += 1;
    }

    std.debug.assert(self.sequence.finishManage(configure_count));
    if (configure_count == 0) {
        self.startRender(manager);
    } else {
        self.configure_timer.timerUpdate(100) catch manager.postNoMemory();
    }
}

fn finishSeatManage(self: *Self, state: *SeatState) void {
    const focused = switch (state.pending_focus) {
        .unchanged => state.focused,
        .clear => null,
        .window => |id| if (self.windows.get(id) != null) id else null,
        .shell_surface => null,
    };
    const focused_shell_surface = switch (state.pending_focus) {
        .unchanged => state.focused_shell_surface,
        .shell_surface => |id| if (self.shell_surfaces.get(id) != null) id else null,
        else => null,
    };
    state.pending_focus = .unchanged;
    switch (state.pending_operation) {
        .unchanged => {},
        .start => if (state.operation == null) if (state.seat.pointerPosition()) |position| {
            const point: Point = .{ .x = pointerCoordinate(position.x), .y = pointerCoordinate(position.y) };
            state.operation = .{ .start = point, .current = point };
            state.desired_hovered = null;
            state.seat.suppressPointerFocus(true);
            state.seat.restoreUnfocusedCursor();
            self.requestManage();
        },
        .end => if (state.operation != null) {
            state.operation = null;
            state.ignore_until_release = state.held_buttons.items.len != 0;
            if (!state.ignore_until_release and self.reroutePointer(state)) self.requestManage();
        },
    }
    state.pending_operation = .unchanged;
    if (state.pending_warp) |requested| {
        const size = self.resolveOutput().logicalSize();
        const point = clampPoint(requested, size.width, size.height);
        const route = self.router.route(self.router.context, @floatFromInt(point.x), @floatFromInt(point.y));
        state.seat.pointerEnter(@floatFromInt(point.x), @floatFromInt(point.y), if (pointerGrabbedState(state)) null else route.focus);
        self.pointerMovedForSeat(state.seat, if (pointerGrabbedState(state)) null else route.root);
        state.pending_warp = null;
    }
    state.seat.suppressPointerFocus(pointerGrabbedState(state));
    state.focused_shell_surface = focused_shell_surface;
    state.focused = focused;
}

fn windowFocusedByAnySeat(self: *const Self, id: WindowId) bool {
    for (self.seat_states.items) |state| {
        if (state.removed) continue;
        if (state.focused) |focused| if (std.meta.eql(focused, id)) return true;
    }
    return false;
}

fn startRender(self: *Self, manager: *river.WindowManagerV1) void {
    std.debug.assert(self.sequence.state == .render);
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value.sent_presentation_hint) {
            if (entry.value.resource) |resource| {
                if (resource.getVersion() >= river.WindowV1.presentation_hint_since_version) {
                    resource.sendPresentationHint(.vsync);
                }
                entry.value.sent_presentation_hint = true;
            }
        }
        if (!entry.value.dimensions_pending) continue;
        const dimensions = (self.xdg_shell.windowInfo(entry.value.xdg_id) orelse continue).dimensions orelse
            continue;
        if (dimensions.width <= 0 or dimensions.height <= 0) continue;
        if (entry.value.resource) |resource| {
            resource.sendDimensions(dimensions.width, dimensions.height);
            entry.value.dimensions_pending = false;
            entry.value.last_dimensions = dimensions;
            entry.value.display_ready = true;
        }
    }
    manager.sendRenderStart();
}

fn finishRender(self: *Self, manager: *river.WindowManagerV1) void {
    if (self.sequence.state != .render) {
        manager.postError(.sequence_order, "render_finish outside a render sequence");
        return;
    }
    if (!self.validateSynchronizedCommits()) return;
    self.applyDecorationState();
    self.applyShellSurfaceState();
    if (self.pending_presentation_mode) |mode| {
        self.presentation_mode = mode;
        self.pending_presentation_mode = null;
    }

    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.pending_position) |position| {
            if (entry.value.fullscreen_output == null) {
                self.xdg_shell.setWindowPosition(entry.value.xdg_id, position);
            }
            entry.value.pending_position = null;
        }
        if (self.fullscreenOutput(entry.value)) |output| {
            const position = output.logicalPosition();
            self.xdg_shell.setWindowPosition(entry.value.xdg_id, .{
                .x = position.x,
                .y = position.y,
            });
        }
        self.xdg_shell.setWindowFocused(
            entry.value.xdg_id,
            self.windowFocusedByAnySeat(entry.id),
        );
        self.xdg_shell.setWindowFullscreen(entry.value.xdg_id, entry.value.fullscreen_output != null);
        switch (entry.value.pending_borders) {
            .unchanged => {},
            .set => |borders| {
                entry.value.borders = borders;
                entry.value.pending_borders = .unchanged;
            },
        }
        switch (entry.value.pending_clip_box) {
            .unchanged => {},
            .set => |clip_box| {
                entry.value.clip_box = clip_box;
                entry.value.pending_clip_box = .unchanged;
            },
        }
        switch (entry.value.pending_content_clip_box) {
            .unchanged => {},
            .set => |clip_box| {
                entry.value.content_clip_box = clip_box;
                entry.value.pending_content_clip_box = .unchanged;
            },
        }
        if (self.fullscreenOutput(entry.value)) |output| {
            const size = output.logicalSize();
            self.xdg_shell.setWindowBorders(entry.value.xdg_id, null);
            self.xdg_shell.setWindowClipBox(entry.value.xdg_id, .{
                .x = 0,
                .y = 0,
                .width = size.width,
                .height = size.height,
            });
            self.xdg_shell.setWindowContentClipBox(entry.value.xdg_id, null);
        } else {
            self.xdg_shell.setWindowBorders(entry.value.xdg_id, entry.value.borders);
            self.xdg_shell.setWindowClipBox(entry.value.xdg_id, entry.value.clip_box);
            self.xdg_shell.setWindowContentClipBox(
                entry.value.xdg_id,
                entry.value.content_clip_box,
            );
        }
        self.xdg_shell.setWindowVisible(
            entry.value.xdg_id,
            entry.value.display_ready and entry.value.requested_visible,
        );
    }
    for (self.stack_operations.items) |operation| switch (operation) {
        .top => |id| {
            const scene_id = self.sceneNodeId(id) orelse continue;
            self.scene.placeNodeTop(scene_id);
        },
        .bottom => |id| {
            const scene_id = self.sceneNodeId(id) orelse continue;
            self.scene.placeNodeBottom(scene_id);
        },
        .above => |placement| {
            const scene_id = self.sceneNodeId(placement.id) orelse continue;
            const other_scene_id = self.sceneNodeId(placement.other) orelse continue;
            self.scene.placeNodeAbove(scene_id, other_scene_id);
        },
        .below => |placement| {
            const scene_id = self.sceneNodeId(placement.id) orelse continue;
            const other_scene_id = self.sceneNodeId(placement.other) orelse continue;
            self.scene.placeNodeBelow(scene_id, other_scene_id);
        },
    };
    self.stack_operations.clearRetainingCapacity();
    for (self.seat_states.items) |state| if (self.reroutePointer(state)) self.requestManage();
    switch (self.sequence.finishRender()) {
        .invalid => unreachable,
        .idle => {},
        .manage => {
            self.sendPendingState(manager) catch {
                manager.postNoMemory();
                return;
            };
            manager.sendManageStart();
        },
    }
}

fn validateSynchronizedCommits(self: *Self) bool {
    var iterator = self.decorations.iterator();
    while (iterator.next()) |entry| {
        const adapter = entry.value.adapter;
        if (adapter.owner_generation != self.session_generation) continue;
        if (!adapter.synchronized_commit_requested) continue;
        adapter.resource.postError(
            .no_commit,
            "sync_next_commit was not followed by wl_surface.commit",
        );
        return false;
    }
    var shell_surfaces = self.shell_surfaces.iterator();
    while (shell_surfaces.next()) |entry| {
        const adapter = entry.value.adapter;
        if (adapter.owner_generation != self.session_generation) continue;
        if (!adapter.synchronized_commit_requested) continue;
        adapter.resource.postError(
            .no_commit,
            "sync_next_commit was not followed by wl_surface.commit",
        );
        return false;
    }
    return true;
}

fn applyDecorationState(self: *Self) void {
    var iterator = self.decorations.iterator();
    while (iterator.next()) |entry| {
        const adapter = entry.value.adapter;
        if (adapter.owner_generation != self.session_generation) continue;
        if (entry.value.pending_offset) |offset| {
            if (entry.value.scene_id) |scene_id| {
                self.xdg_shell.setWindowDecorationOffset(scene_id, offset);
            }
            entry.value.pending_offset = null;
        }
        if (adapter.synchronized_commit_cached) {
            if (adapter.surface) |surface| {
                surface.applyCachedCommit();
                if (surface.hasCachedCommit()) surface.discardCachedCommit();
            }
            adapter.synchronized_commit_cached = false;
        }
    }
}

fn applyShellSurfaceState(self: *Self) void {
    var iterator = self.shell_surfaces.iterator();
    while (iterator.next()) |entry| {
        const adapter = entry.value.adapter;
        if (adapter.owner_generation != self.session_generation) continue;
        if (entry.value.pending_position) |position| {
            if (entry.value.scene_id) |scene_id| {
                self.scene.setShellSurfacePosition(scene_id, position);
            }
            entry.value.pending_position = null;
        }
        if (adapter.synchronized_commit_cached) {
            if (adapter.surface) |surface| {
                surface.applyCachedCommit();
                if (surface.hasCachedCommit()) surface.discardCachedCommit();
            }
            adapter.synchronized_commit_cached = false;
        }
    }
}

fn sceneNodeId(self: *Self, id: ManagedNodeId) ?Scene.NodeId {
    return switch (id) {
        .window => |window_id| {
            const window = self.windows.get(window_id) orelse return null;
            const info = self.xdg_shell.windowInfo(window.xdg_id) orelse return null;
            return .{ .window = info.scene_id };
        },
        .shell_surface => |shell_id| {
            const shell_surface = self.shell_surfaces.get(shell_id) orelse return null;
            const scene_id = shell_surface.scene_id orelse return null;
            return .{ .shell_surface = scene_id };
        },
    };
}

fn bindLayerShell(client: *wl.Client, manager: *Self, version: u32, id: u32) void {
    const resource = river.LayerShellV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    const binding = manager.allocator.create(LayerBinding) catch {
        resource.destroy();
        client.postNoMemory();
        return;
    };
    binding.* = .{ .manager = manager, .resource = resource };
    manager.layer_bindings.append(manager.allocator, binding) catch {
        manager.allocator.destroy(binding);
        resource.destroy();
        client.postNoMemory();
        return;
    };
    if (manager.active) |active| {
        if (active.getClient() == client) binding.owner_generation = manager.session_generation;
    }
    resource.setHandler(*LayerBinding, LayerBinding.handleRequest, LayerBinding.handleDestroy, binding);
}

fn activeLayerBinding(self: *Self) ?*LayerBinding {
    for (self.layer_bindings.items) |binding| {
        if (binding.owner_generation == self.session_generation and self.active != null and
            binding.resource.getClient() == self.active.?.getClient()) return binding;
    }
    return null;
}

fn layerSupported(context: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.activeLayerBinding() != null;
}

fn layerChanged(context: *anyopaque, area: LayerShell.Rect, focus: LayerShell.FocusClass) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (std.meta.eql(self.layer_area, area) and self.layer_focus == focus) return;
    self.layer_area = area;
    self.layer_focus = focus;
    self.requestManage();
}

fn hasLayerOutput(self: *Self) bool {
    for (self.layer_bindings.items) |binding| {
        if (binding.active() and binding.output != null) return true;
    }
    return false;
}

fn hasLayerSeat(self: *Self) bool {
    for (self.layer_bindings.items) |binding| {
        if (binding.active() and binding.seat != null) return true;
    }
    return false;
}

const LayerBinding = struct {
    manager: *Self,
    resource: *river.LayerShellV1,
    owner_generation: ?u64 = null,
    output: ?*LayerOutput = null,
    seat: ?*LayerSeat = null,

    fn active(self: *LayerBinding) bool {
        return self.owner_generation == self.manager.session_generation and
            self.manager.active != null and self.resource.getClient() == self.manager.active.?.getClient();
    }

    fn beginSession(self: *LayerBinding, generation: ?u64) void {
        if (self.output) |child| child.binding = null;
        if (self.seat) |child| child.binding = null;
        self.output = null;
        self.seat = null;
        self.owner_generation = generation;
    }

    fn handleRequest(resource: *river.LayerShellV1, request: river.LayerShellV1.Request, self: *LayerBinding) void {
        switch (request) {
            .destroy => resource.destroy(),
            .get_output => |get| {
                if (self.output != null or (self.active() and self.manager.hasLayerOutput())) {
                    resource.postError(.object_already_created, "layer shell output already created");
                    return;
                }
                const child = LayerOutput.create(self, get.id) catch {
                    resource.postNoMemory();
                    return;
                };
                if (!self.active() or !validOutput(self, get.output)) {
                    child.binding = null;
                    return;
                }
                self.output = child;
                child.attached = true;
                self.manager.requestManage();
            },
            .get_seat => |get| {
                if (self.seat != null or (self.active() and self.manager.hasLayerSeat())) {
                    resource.postError(.object_already_created, "layer shell seat already created");
                    return;
                }
                const child = LayerSeat.create(self, get.id) catch {
                    resource.postNoMemory();
                    return;
                };
                if (!self.active() or !validSeat(self, get.seat)) {
                    child.binding = null;
                    return;
                }
                self.seat = child;
                child.attached = true;
                self.manager.requestManage();
            },
        }
    }

    fn validOutput(self: *LayerBinding, resource: *river.OutputV1) bool {
        const data = resource.getUserData() orelse return false;
        const output: *OutputResource = @ptrCast(@alignCast(data));
        return output.manager == self.manager and output.owner_generation == self.owner_generation.? and
            resource.getClient() == self.resource.getClient();
    }

    fn validSeat(self: *LayerBinding, resource: *river.SeatV1) bool {
        const data = resource.getUserData() orelse return false;
        const seat: *SeatResource = @ptrCast(@alignCast(data));
        return seat.manager == self.manager and seat.owner_generation == self.owner_generation.? and
            seat.seat_state == self.manager.default_seat_state and seat.seat_state.seat_resource == seat and
            resource.getClient() == self.resource.getClient();
    }

    fn handleDestroy(_: *river.LayerShellV1, self: *LayerBinding) void {
        if (self.output) |child| child.binding = null;
        if (self.seat) |child| child.binding = null;
        for (self.manager.layer_bindings.items, 0..) |candidate, i| if (candidate == self) {
            _ = self.manager.layer_bindings.swapRemove(i);
            break;
        };
        self.manager.allocator.destroy(self);
    }
};

const LayerOutput = struct {
    allocator: std.mem.Allocator,
    binding: ?*LayerBinding,
    resource: *river.LayerShellOutputV1,
    attached: bool = false,
    sent_area: ?LayerShell.Rect = null,

    fn create(binding: *LayerBinding, id: u32) !*LayerOutput {
        const resource = try river.LayerShellOutputV1.create(binding.resource.getClient(), 1, id);
        errdefer resource.destroy();
        const self = try binding.manager.allocator.create(LayerOutput);
        self.* = .{ .allocator = binding.manager.allocator, .binding = binding, .resource = resource };
        resource.setHandler(*LayerOutput, LayerOutput.handleRequest, LayerOutput.handleDestroy, self);
        return self;
    }
    fn handleRequest(resource: *river.LayerShellOutputV1, request: river.LayerShellOutputV1.Request, self: *LayerOutput) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_default => if (self.binding) |binding| if (binding.active() and binding.manager.sequence.state != .manage)
                binding.manager.active.?.postError(.sequence_order, "set_default outside a manage sequence"),
        }
    }
    fn handleDestroy(_: *river.LayerShellOutputV1, self: *LayerOutput) void {
        if (self.binding) |binding| {
            if (self.attached and binding.output == self) binding.output = null;
        }
        self.allocator.destroy(self);
    }
};

const LayerSeat = struct {
    allocator: std.mem.Allocator,
    binding: ?*LayerBinding,
    resource: *river.LayerShellSeatV1,
    attached: bool = false,
    sent_focus: ?LayerShell.FocusClass = null,
    fn create(binding: *LayerBinding, id: u32) !*LayerSeat {
        const resource = try river.LayerShellSeatV1.create(binding.resource.getClient(), 1, id);
        errdefer resource.destroy();
        const self = try binding.manager.allocator.create(LayerSeat);
        self.* = .{ .allocator = binding.manager.allocator, .binding = binding, .resource = resource };
        resource.setHandler(*LayerSeat, LayerSeat.handleRequest, LayerSeat.handleDestroy, self);
        return self;
    }
    fn handleRequest(resource: *river.LayerShellSeatV1, request: river.LayerShellSeatV1.Request, _: *LayerSeat) void {
        if (request == .destroy) resource.destroy();
    }
    fn handleDestroy(_: *river.LayerShellSeatV1, self: *LayerSeat) void {
        if (self.binding) |binding| {
            if (self.attached and binding.seat == self) binding.seat = null;
        }
        self.allocator.destroy(self);
    }
};

fn releaseManager(self: *Self) void {
    for (self.layer_bindings.items) |binding| binding.beginSession(null);
    for (self.pointer_bindings.items) |binding| binding.pending.clearRetainingCapacity();
    for (self.seat_states.items) |seat_state| {
        var held_index: usize = 0;
        while (held_index < seat_state.held_buttons.items.len) {
            const held = &seat_state.held_buttons.items[held_index];
            if (held.captured) {
                held.binding = null;
                held_index += 1;
            } else {
                _ = seat_state.held_buttons.orderedRemove(held_index);
            }
        }
        seat_state.seat_resource = null;
        seat_state.focused = null;
        seat_state.pending_focus = .unchanged;
        if (!seat_state.removed) seat_state.seat.setUnfocusedCursorController(null);
        seat_state.operation = null;
        seat_state.pending_operation = .unchanged;
        seat_state.pending_warp = null;
        seat_state.focused_shell_surface = null;
        seat_state.desired_hovered = null;
        seat_state.sent_hovered = null;
        seat_state.pending_interaction = null;
        seat_state.ignore_until_release = seat_state.held_buttons.items.len != 0;
        seat_state.last_pointer_position = null;
    }
    self.active = null;
    self.sequence.reset();
    self.window_requests.clearRetainingCapacity();
    self.stack_operations.clearRetainingCapacity();
    self.presentation_mode = .vsync;
    self.pending_presentation_mode = null;
    self.releaseWindows();
    self.releaseShellSurfaces();
    for (self.seat_states.items) |state| {
        if (!state.removed) _ = self.reroutePointer(state);
    }
}

fn releaseWindows(self: *Self) void {
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        self.detachDecorations(entry.id);
        self.xdg_shell.setWindowFocused(entry.value.xdg_id, false);
        self.xdg_shell.setWindowFullscreen(entry.value.xdg_id, false);
        self.xdg_shell.setWindowBorders(entry.value.xdg_id, null);
        self.xdg_shell.setWindowClipBox(entry.value.xdg_id, null);
        self.xdg_shell.setWindowContentClipBox(entry.value.xdg_id, null);
        self.xdg_shell.restoreStandaloneWindow(
            entry.value.xdg_id,
            entry.value.sent_configuration.activated or
                entry.value.sent_configuration.decoration_mode == .server_side or
                entry.value.sent_configuration.suspended or
                entry.value.sent_configuration.bounds.width != 0 or
                entry.value.sent_configuration.bounds.height != 0,
            entry.value.requested_dimensions,
        );
        _ = self.windows.remove(entry.id);
    }
}

fn detachDecorations(self: *Self, window_id: WindowId) void {
    var iterator = self.decorations.iterator();
    while (iterator.next()) |entry| {
        if (!std.meta.eql(entry.value.window_id, window_id)) continue;
        entry.value.adapter.detach();
    }
}

fn releaseShellSurfaces(self: *Self) void {
    var iterator = self.shell_surfaces.iterator();
    while (iterator.next()) |entry| entry.value.adapter.detach();
}

fn handleConfigureTimeout(self: *Self) c_int {
    if (!self.sequence.configureTimeout()) return 0;
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| switch (entry.value.configure) {
        .inflight => |configure| entry.value.configure = .{ .timed_out = configure },
        else => {},
    };
    if (self.active) |manager| self.startRender(manager);
    return 0;
}

fn windowReady(context: *anyopaque, xdg_id: XdgShell.WindowId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const manager = self.active orelse return false;
    _ = self.ensureWindow(xdg_id) catch {
        manager.postNoMemory();
        return true;
    };
    var windows = self.windows.iterator();
    while (windows.next()) |entry| entry.value.metadata_dirty = true;
    self.xdg_shell.setWindowVisible(xdg_id, false);
    self.requestManage();
    return true;
}

fn windowCommitted(
    context: *anyopaque,
    xdg_id: XdgShell.WindowId,
    configure_serial: ?u32,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const manager = self.active orelse return false;
    const id = self.findWindow(xdg_id) orelse return false;
    const window = self.windows.get(id) orelse return false;
    const serial = configure_serial orelse {
        const dimensions = (self.xdg_shell.windowInfo(xdg_id) orelse return true).dimensions orelse
            return true;
        if (window.display_ready and
            (window.last_dimensions == null or !std.meta.eql(window.last_dimensions.?, dimensions)))
        {
            window.dimensions_pending = true;
            self.requestManage();
        }
        return true;
    };

    switch (window.configure) {
        .inflight => |configure| {
            if (serial != configure.serial) return true;
            window.configure = .idle;
            if (configure.report_dimensions) window.dimensions_pending = true;
            if (self.sequence.configureFinished()) self.startRender(manager);
        },
        .timed_out => |configure| {
            if (serial != configure.serial) return true;
            window.configure = .idle;
            if (configure.report_dimensions) {
                window.dimensions_pending = true;
                self.requestManage();
            }
        },
        .idle => {
            if (!window.display_ready) return true;
            window.dimensions_pending = true;
            self.requestManage();
        },
    }
    return true;
}

fn windowUnmapped(context: *anyopaque, xdg_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeWindow(xdg_id);
}

fn windowDestroyed(context: *anyopaque, xdg_id: XdgShell.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.removeWindow(xdg_id);
}

fn windowMetadataChanged(context: *anyopaque, xdg_id: XdgShell.WindowId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.active == null) return false;
    const id = self.findWindow(xdg_id) orelse return false;
    const window = self.windows.get(id) orelse return false;
    window.metadata_dirty = true;
    self.requestManage();
    return true;
}

fn windowRequest(
    context: *anyopaque,
    xdg_id: XdgShell.WindowId,
    request: XdgShell.WindowRequest,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const manager = self.active orelse return;
    const id = self.ensureWindow(xdg_id) catch {
        manager.postNoMemory();
        return;
    };
    const pending: PendingWindowRequest.Request = switch (request) {
        .pointer_move => .pointer_move,
        .pointer_resize => |edges| .{ .pointer_resize = .{
            .top = edges.top,
            .bottom = edges.bottom,
            .left = edges.left,
            .right = edges.right,
        } },
        .show_window_menu => |menu| .{ .show_window_menu = .{ .x = menu.x, .y = menu.y } },
        .maximize => .maximize,
        .unmaximize => .unmaximize,
        .fullscreen => |output| .{ .fullscreen = if (output) |resource|
            if (self.outputs.findResource(resource)) |entry| entry.id else null
        else
            null },
        .exit_fullscreen => .exit_fullscreen,
        .minimize => .minimize,
    };
    self.window_requests.append(self.allocator, .{ .id = id, .request = pending }) catch {
        manager.postNoMemory();
        return;
    };
    self.requestManage();
}

fn removeWindow(self: *Self, xdg_id: XdgShell.WindowId) void {
    const id = self.findWindow(xdg_id) orelse return;
    const window = self.windows.get(id) orelse return;
    if (window.resource) |resource| resource.sendClosed();
    for (self.seat_states.items) |state| {
        if (state.desired_hovered) |hovered| {
            if (std.meta.eql(hovered, id)) state.desired_hovered = null;
        }
        if (state.sent_hovered) |hovered| {
            if (std.meta.eql(hovered, id)) state.sent_hovered = null;
        }
        if (state.focused) |focused| {
            if (std.meta.eql(focused, id)) state.focused = null;
        }
        switch (state.pending_focus) {
            .window => |pending| if (std.meta.eql(pending, id)) {
                state.pending_focus = .clear;
            },
            else => {},
        }
    }
    const finish_configure = switch (window.configure) {
        .inflight => true,
        else => false,
    };
    self.detachDecorations(id);
    self.xdg_shell.setWindowFocused(window.xdg_id, false);
    self.xdg_shell.setWindowFullscreen(window.xdg_id, false);
    self.xdg_shell.setWindowBorders(window.xdg_id, null);
    self.xdg_shell.setWindowClipBox(window.xdg_id, null);
    self.xdg_shell.setWindowContentClipBox(window.xdg_id, null);
    _ = self.windows.remove(id);
    if (finish_configure and self.sequence.configureFinished()) {
        if (self.active) |manager| self.startRender(manager);
    }
    self.requestManage();
}

const WindowResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: WindowId,
    owner_generation: u64,

    fn handleRequest(
        resource: *river.WindowV1,
        request: river.WindowV1.Request,
        self: *WindowResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const manager_resource = self.activeManager() orelse return;
        const window = self.manager.windows.get(self.id) orelse return;

        switch (request) {
            .destroy => unreachable,
            .close => {
                if (!self.requireManage(manager_resource)) return;
                self.manager.xdg_shell.closeWindow(window.xdg_id);
            },
            .propose_dimensions => |dimensions| {
                if (!self.requireManage(manager_resource)) return;
                if (dimensions.width < 0 or dimensions.height < 0) {
                    resource.postError(.invalid_dimensions, "proposed dimensions must not be negative");
                    return;
                }
                window.proposed_dimensions = .{
                    .width = dimensions.width,
                    .height = dimensions.height,
                };
            },
            .hide => {
                if (!self.requireRendering(manager_resource)) return;
                window.requested_visible = false;
                window.requested_configuration.suspended = true;
                self.manager.requestManage();
            },
            .show => {
                if (!self.requireRendering(manager_resource)) return;
                window.requested_visible = true;
                window.requested_configuration.suspended = false;
                self.manager.requestManage();
            },
            .use_csd => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.decoration_mode = .client_side;
            },
            .use_ssd => {
                if (!self.requireManage(manager_resource)) return;
                const info = self.manager.xdg_shell.windowInfo(window.xdg_id) orelse return;
                if (info.decoration_preference != .only_csd) {
                    window.requested_configuration.decoration_mode = .server_side;
                }
            },
            .set_tiled => |tiled| {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.tiled = .{
                    .top = tiled.edges.top,
                    .bottom = tiled.edges.bottom,
                    .left = tiled.edges.left,
                    .right = tiled.edges.right,
                };
            },
            .inform_resize_start => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.resizing = true;
            },
            .inform_resize_end => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.resizing = false;
            },
            .set_capabilities => |capabilities| {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.capabilities = .{
                    .window_menu = capabilities.caps.window_menu,
                    .maximize = capabilities.caps.maximize,
                    .fullscreen = capabilities.caps.fullscreen,
                    .minimize = capabilities.caps.minimize,
                };
            },
            .inform_maximized => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.maximized = true;
            },
            .inform_unmaximized => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.maximized = false;
            },
            .inform_fullscreen => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.fullscreen = true;
            },
            .inform_not_fullscreen => {
                if (!self.requireManage(manager_resource)) return;
                window.requested_configuration.fullscreen = false;
            },
            .fullscreen => |fullscreen| {
                if (!self.requireManage(manager_resource)) return;
                window.fullscreen_output = self.resolveOutput(fullscreen.output) orelse return;
                window.fullscreen_dimensions_pending = true;
            },
            .exit_fullscreen => {
                if (!self.requireManage(manager_resource)) return;
                window.fullscreen_output = null;
            },
            .get_node => |get| NodeResource.createWindow(
                self.manager,
                self.id,
                resource,
                get.id,
            ) catch resource.postNoMemory(),
            .set_borders => |borders| {
                if (!self.requireRendering(manager_resource)) return;
                const edges: u32 = @bitCast(borders.edges);
                if (borders.width < 0 or edges & ~@as(u32, 0xf) != 0) {
                    resource.postError(.invalid_border, "invalid window border");
                    return;
                }
                window.pending_borders = .{ .set = if (borders.width == 0 or edges == 0)
                    null
                else
                    .{
                        .edges = .{
                            .top = borders.edges.top,
                            .bottom = borders.edges.bottom,
                            .left = borders.edges.left,
                            .right = borders.edges.right,
                        },
                        .width = @intCast(borders.width),
                        .color = .{
                            .red = protocolColorComponent(borders.r),
                            .green = protocolColorComponent(borders.g),
                            .blue = protocolColorComponent(borders.b),
                            .alpha = protocolColorComponent(borders.a),
                        },
                    } };
            },
            .set_clip_box => |box| {
                if (!self.requireRendering(manager_resource)) return;
                if (box.width < 0 or box.height < 0) {
                    resource.postError(.invalid_clip_box, "invalid window clip box");
                    return;
                }
                window.pending_clip_box = .{ .set = protocolClipBox(
                    box.x,
                    box.y,
                    box.width,
                    box.height,
                ) };
            },
            .set_content_clip_box => |box| {
                if (!self.requireRendering(manager_resource)) return;
                if (box.width < 0 or box.height < 0) {
                    resource.postError(.invalid_clip_box, "invalid window content clip box");
                    return;
                }
                window.pending_content_clip_box = .{ .set = protocolClipBox(
                    box.x,
                    box.y,
                    box.width,
                    box.height,
                ) };
            },
            .get_decoration_above => |get| DecorationResource.create(
                self.manager,
                self.id,
                manager_resource,
                resource,
                Surface.fromResource(get.surface),
                .above,
                get.id,
            ) catch resource.postNoMemory(),
            .get_decoration_below => |get| DecorationResource.create(
                self.manager,
                self.id,
                manager_resource,
                resource,
                Surface.fromResource(get.surface),
                .below,
                get.id,
            ) catch resource.postNoMemory(),
            .set_dimension_bounds => |bounds| {
                if (!self.requireManage(manager_resource)) return;
                if (bounds.max_width < 0 or bounds.max_height < 0) {
                    resource.postError(
                        .invalid_dimensions,
                        "dimension bounds must not be negative",
                    );
                    return;
                }
                window.requested_configuration.bounds = .{
                    .width = bounds.max_width,
                    .height = bounds.max_height,
                };
            },
        }
    }

    fn activeManager(self: *WindowResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn resolveOutput(self: *WindowResource, resource: *river.OutputV1) ?OutputLayout.Id {
        const data = resource.getUserData() orelse return null;
        const output: *OutputResource = @ptrCast(@alignCast(data));
        if (output.manager != self.manager or
            output.owner_generation != self.owner_generation) return null;
        if (output.removed) return null;
        if (self.manager.outputs.get(output.output_id) == null) return null;
        return output.output_id;
    }

    fn requireManage(self: *WindowResource, manager: *river.WindowManagerV1) bool {
        if (self.manager.sequence.state == .manage) return true;
        manager.postError(.sequence_order, "window request outside a manage sequence");
        return false;
    }

    fn protocolClipBox(x: i32, y: i32, width: i32, height: i32) ?Scene.ClipBox {
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        if (width == 0 or height == 0) return null;
        return .{
            .x = x,
            .y = y,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    fn requireRendering(self: *WindowResource, manager: *river.WindowManagerV1) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "window request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(_: *river.WindowV1, self: *WindowResource) void {
        if (self.manager.session_generation == self.owner_generation) {
            if (self.manager.windows.get(self.id)) |window| window.resource = null;
        }
        self.allocator.destroy(self);
    }
};

const DecorationResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: DecorationId,
    resource: *river.DecorationV1,
    surface: ?*Surface,
    owner_generation: u64,
    synchronized_commit_requested: bool,
    synchronized_commit_cached: bool,

    fn create(
        manager: *Self,
        window_id: WindowId,
        manager_resource: *river.WindowManagerV1,
        window_resource: *river.WindowV1,
        surface: *Surface,
        layer: Scene.DecorationLayer,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const window = manager.windows.get(window_id) orelse
            return error.ResourceCreateFailed;
        const resource = try river.DecorationV1.create(
            window_resource.getClient(),
            window_resource.getVersion(),
            protocol_id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(DecorationResource) catch
            return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = undefined,
            .resource = resource,
            .surface = surface,
            .owner_generation = manager.session_generation,
            .synchronized_commit_requested = false,
            .synchronized_commit_cached = false,
        };

        if (surface.assignedRole() != null or surface.hasBufferAttachedOrCommitted()) {
            manager_resource.postError(
                .role,
                "decoration wl_surface already has a role or buffer",
            );
            manager.allocator.destroy(self);
            resource.destroy();
            return;
        }
        surface.reserveRole(.river_decoration, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch {
            manager_resource.postError(.role, "wl_surface is unavailable for decoration role");
            manager.allocator.destroy(self);
            resource.destroy();
            return;
        };
        errdefer surface.releaseRole(self);

        const scene_id = manager.xdg_shell.addWindowDecoration(
            window.xdg_id,
            surface.handle(),
            layer,
        ) catch |err| switch (err) {
            error.InvalidWindow => return error.ResourceCreateFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer manager.xdg_shell.removeWindowDecoration(scene_id);
        const id = manager.decorations.insert(manager.allocator, .{
            .window_id = window_id,
            .scene_id = scene_id,
            .adapter = self,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.decorations.remove(id);
        self.id = id;

        surface.assignReservedRole(.river_decoration, self) catch unreachable;
        resource.setHandler(
            *DecorationResource,
            DecorationResource.handleRequest,
            DecorationResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *river.DecorationV1,
        request: river.DecorationV1.Request,
        self: *DecorationResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const manager_resource = self.activeManager() orelse return;
        const decoration = self.manager.decorations.get(self.id) orelse return;
        if (!self.requireRendering(manager_resource)) return;

        switch (request) {
            .destroy => unreachable,
            .set_offset => |offset| decoration.pending_offset = .{
                .x = offset.x,
                .y = offset.y,
            },
            .sync_next_commit => self.synchronized_commit_requested = true,
        }
    }

    fn beforeSurfaceCommit(
        context: *anyopaque,
        _: Surface.CommitInfo,
    ) Surface.CommitAction {
        const self: *DecorationResource = @ptrCast(@alignCast(context));
        if (self.synchronized_commit_requested) {
            self.synchronized_commit_requested = false;
            self.synchronized_commit_cached = true;
            return .cache;
        }
        if (self.synchronized_commit_cached) return .cache;
        return .apply;
    }

    fn afterSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *DecorationResource = @ptrCast(@alignCast(context));
        const decoration = self.manager.decorations.get(self.id) orelse return;
        const scene_id = decoration.scene_id orelse return;
        self.manager.xdg_shell.setWindowDecorationMapped(scene_id, info.has_buffer);
        self.manager.xdg_shell.windowDecorationCommitted(scene_id);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *DecorationResource = @ptrCast(@alignCast(context));
        self.surface = null;
        self.synchronized_commit_requested = false;
        self.synchronized_commit_cached = false;
        const decoration = self.manager.decorations.get(self.id) orelse return;
        if (decoration.scene_id) |scene_id| {
            self.manager.xdg_shell.removeWindowDecoration(scene_id);
            decoration.scene_id = null;
        }
    }

    fn detach(self: *DecorationResource) void {
        const decoration = self.manager.decorations.get(self.id) orelse return;
        if (decoration.scene_id) |scene_id| {
            self.manager.xdg_shell.removeWindowDecoration(scene_id);
            decoration.scene_id = null;
        }
        decoration.pending_offset = null;
        if (self.surface) |surface| surface.discardCachedCommit();
        self.synchronized_commit_requested = false;
        self.synchronized_commit_cached = false;
    }

    fn activeManager(self: *DecorationResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn requireRendering(
        self: *DecorationResource,
        manager: *river.WindowManagerV1,
    ) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "decoration request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(_: *river.DecorationV1, self: *DecorationResource) void {
        self.detach();
        if (self.surface) |surface| surface.releaseRole(self);
        _ = self.manager.decorations.remove(self.id);
        self.allocator.destroy(self);
    }
};

const ShellSurfaceResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: ShellSurfaceId,
    resource: *river.ShellSurfaceV1,
    surface: ?*Surface,
    owner_generation: u64,
    synchronized_commit_requested: bool,
    synchronized_commit_cached: bool,

    fn create(
        manager: *Self,
        manager_resource: *river.WindowManagerV1,
        surface: *Surface,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try river.ShellSurfaceV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            protocol_id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(ShellSurfaceResource) catch
            return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = undefined,
            .resource = resource,
            .surface = surface,
            .owner_generation = manager.session_generation,
            .synchronized_commit_requested = false,
            .synchronized_commit_cached = false,
        };

        if (surface.assignedRole() != null or surface.hasBufferAttachedOrCommitted()) {
            manager_resource.postError(
                .role,
                "shell wl_surface already has a role or buffer",
            );
            manager.allocator.destroy(self);
            resource.destroy();
            return;
        }
        surface.reserveRole(.river_shell_surface, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch {
            manager_resource.postError(.role, "wl_surface is unavailable for shell role");
            manager.allocator.destroy(self);
            resource.destroy();
            return;
        };
        errdefer surface.releaseRole(self);

        const scene_id = try manager.scene.addShellSurface(surface.handle());
        errdefer manager.scene.removeShellSurface(scene_id);
        const id = manager.shell_surfaces.insert(manager.allocator, .{
            .scene_id = scene_id,
            .adapter = self,
        }) catch return error.OutOfMemory;
        errdefer _ = manager.shell_surfaces.remove(id);
        self.id = id;

        surface.assignReservedRole(.river_shell_surface, self) catch unreachable;
        resource.setHandler(
            *ShellSurfaceResource,
            ShellSurfaceResource.handleRequest,
            ShellSurfaceResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *river.ShellSurfaceV1,
        request: river.ShellSurfaceV1.Request,
        self: *ShellSurfaceResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const manager_resource = self.activeManager() orelse return;
        if (self.manager.shell_surfaces.get(self.id) == null) return;

        switch (request) {
            .destroy => unreachable,
            .get_node => |get| NodeResource.createShellSurface(
                self.manager,
                self.id,
                resource,
                get.id,
            ) catch resource.postNoMemory(),
            .sync_next_commit => {
                if (!self.requireRendering(manager_resource)) return;
                self.synchronized_commit_requested = true;
            },
        }
    }

    fn beforeSurfaceCommit(
        context: *anyopaque,
        _: Surface.CommitInfo,
    ) Surface.CommitAction {
        const self: *ShellSurfaceResource = @ptrCast(@alignCast(context));
        if (self.synchronized_commit_requested) {
            self.synchronized_commit_requested = false;
            self.synchronized_commit_cached = true;
            return .cache;
        }
        if (self.synchronized_commit_cached) return .cache;
        return .apply;
    }

    fn afterSurfaceCommit(context: *anyopaque, info: Surface.CommitInfo) void {
        const self: *ShellSurfaceResource = @ptrCast(@alignCast(context));
        const shell_surface = self.manager.shell_surfaces.get(self.id) orelse return;
        const scene_id = shell_surface.scene_id orelse return;
        self.manager.scene.setShellSurfaceMapped(scene_id, info.has_buffer);
        self.manager.scene.shellSurfaceCommitted(scene_id);
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *ShellSurfaceResource = @ptrCast(@alignCast(context));
        self.clearFocus();
        self.surface = null;
        self.synchronized_commit_requested = false;
        self.synchronized_commit_cached = false;
        const shell_surface = self.manager.shell_surfaces.get(self.id) orelse return;
        if (shell_surface.scene_id) |scene_id| {
            self.manager.scene.removeShellSurface(scene_id);
            shell_surface.scene_id = null;
        }
    }

    fn detach(self: *ShellSurfaceResource) void {
        const shell_surface = self.manager.shell_surfaces.get(self.id) orelse return;
        if (shell_surface.scene_id) |scene_id| {
            self.manager.scene.removeShellSurface(scene_id);
            shell_surface.scene_id = null;
        }
        shell_surface.pending_position = null;
        if (self.surface) |surface| surface.discardCachedCommit();
        self.synchronized_commit_requested = false;
        self.synchronized_commit_cached = false;
    }

    fn activeManager(self: *ShellSurfaceResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn requireRendering(
        self: *ShellSurfaceResource,
        manager: *river.WindowManagerV1,
    ) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "shell request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(_: *river.ShellSurfaceV1, self: *ShellSurfaceResource) void {
        self.clearFocus();
        self.detach();
        if (self.surface) |surface| surface.releaseRole(self);
        _ = self.manager.shell_surfaces.remove(self.id);
        self.allocator.destroy(self);
    }

    fn clearFocus(self: *ShellSurfaceResource) void {
        var changed = false;
        for (self.manager.seat_states.items) |state| {
            if (state.focused_shell_surface) |id| if (std.meta.eql(id, self.id)) {
                state.focused_shell_surface = null;
                changed = true;
            };
            switch (state.pending_focus) {
                .shell_surface => |id| if (std.meta.eql(id, self.id)) {
                    state.pending_focus = .clear;
                    changed = true;
                },
                else => {},
            }
        }
        if (changed) self.manager.requestManage();
    }
};

const NodeResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    id: ManagedNodeId,
    owner_generation: u64,

    fn createWindow(
        manager: *Self,
        id: WindowId,
        window_resource: *river.WindowV1,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const window = manager.windows.get(id) orelse return error.ResourceCreateFailed;
        if (window.node_created) {
            window_resource.postError(.node_exists, "window already has a render node");
            return;
        }
        const resource = try create(
            manager,
            .{ .window = id },
            window_resource.getClient(),
            window_resource.getVersion(),
            protocol_id,
        );
        window.node_created = true;
        window.node_resource = resource;
    }

    fn createShellSurface(
        manager: *Self,
        id: ShellSurfaceId,
        shell_resource: *river.ShellSurfaceV1,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const shell_surface = manager.shell_surfaces.get(id) orelse
            return error.ResourceCreateFailed;
        if (shell_surface.node_created) {
            shell_resource.postError(.node_exists, "shell surface already has a render node");
            return;
        }
        const resource = try create(
            manager,
            .{ .shell_surface = id },
            shell_resource.getClient(),
            shell_resource.getVersion(),
            protocol_id,
        );
        shell_surface.node_created = true;
        shell_surface.node_resource = resource;
    }

    fn create(
        manager: *Self,
        id: ManagedNodeId,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!*river.NodeV1 {
        const resource = try river.NodeV1.create(
            client,
            version,
            protocol_id,
        );
        errdefer resource.destroy();
        const self = manager.allocator.create(NodeResource) catch return error.OutOfMemory;
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .allocator = manager.allocator,
            .manager = manager,
            .id = id,
            .owner_generation = manager.session_generation,
        };
        resource.setHandler(*NodeResource, NodeResource.handleRequest, NodeResource.handleDestroy, self);
        return resource;
    }

    fn handleRequest(
        resource: *river.NodeV1,
        request: river.NodeV1.Request,
        self: *NodeResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        const manager_resource = self.activeManager() orelse return;
        if (!self.exists()) return;
        if (!self.requireRendering(manager_resource)) return;

        switch (request) {
            .destroy => unreachable,
            .set_position => |position| switch (self.id) {
                .window => |id| {
                    const window = self.manager.windows.get(id) orelse return;
                    window.pending_position = .{ .x = position.x, .y = position.y };
                },
                .shell_surface => |id| {
                    const shell_surface = self.manager.shell_surfaces.get(id) orelse return;
                    shell_surface.pending_position = .{ .x = position.x, .y = position.y };
                },
            },
            .place_top => self.appendOperation(resource, .{ .top = self.id }),
            .place_bottom => self.appendOperation(resource, .{ .bottom = self.id }),
            .place_above => |placement| {
                const other = self.resolveOther(placement.other) orelse return;
                self.appendOperation(resource, .{ .above = .{ .id = self.id, .other = other } });
            },
            .place_below => |placement| {
                const other = self.resolveOther(placement.other) orelse return;
                self.appendOperation(resource, .{ .below = .{ .id = self.id, .other = other } });
            },
        }
    }

    fn appendOperation(
        self: *NodeResource,
        resource: *river.NodeV1,
        operation: StackOperation,
    ) void {
        self.manager.stack_operations.append(self.manager.allocator, operation) catch
            resource.postNoMemory();
    }

    fn resolveOther(self: *NodeResource, resource: *river.NodeV1) ?ManagedNodeId {
        const data = resource.getUserData() orelse return null;
        const other: *NodeResource = @ptrCast(@alignCast(data));
        if (other.manager != self.manager or
            other.owner_generation != self.owner_generation) return null;
        if (!other.exists()) return null;
        return other.id;
    }

    fn exists(self: *NodeResource) bool {
        return switch (self.id) {
            .window => |id| self.manager.windows.get(id) != null,
            .shell_surface => |id| self.manager.shell_surfaces.get(id) != null,
        };
    }

    fn activeManager(self: *NodeResource) ?*river.WindowManagerV1 {
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn requireRendering(self: *NodeResource, manager: *river.WindowManagerV1) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "node request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(resource: *river.NodeV1, self: *NodeResource) void {
        if (self.manager.session_generation == self.owner_generation) {
            switch (self.id) {
                .window => |id| if (self.manager.windows.get(id)) |window| {
                    if (window.node_resource == resource) window.node_resource = null;
                },
                .shell_surface => |id| if (self.manager.shell_surfaces.get(id)) |shell_surface| {
                    if (shell_surface.node_resource == resource) shell_surface.node_resource = null;
                },
            }
        }
        self.allocator.destroy(self);
    }
};

fn createOutput(
    self: *Self,
    manager: *river.WindowManagerV1,
    output_id: OutputLayout.Id,
    output: *Output,
) !void {
    const resource = try river.OutputV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(OutputResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .owner_generation = self.session_generation,
        .output_id = output_id,
        .resource = resource,
        .removed = false,
    };
    try self.output_resources.append(self.allocator, adapter);
    resource.setHandler(*OutputResource, OutputResource.handleRequest, OutputResource.handleDestroy, adapter);

    manager.sendOutput(resource);
    resource.sendWlOutput(output.globalName(manager.getClient()));
    const position = output.logicalPosition();
    resource.sendPosition(position.x, position.y);
    const size = output.logicalSize();
    resource.sendDimensions(@intCast(size.width), @intCast(size.height));
    if (resource.getVersion() >= river.OutputV1.capture_sessions_since_version) {
        resource.sendCaptureSessions(0);
    }
}

fn createSeat(self: *Self, manager: *river.WindowManagerV1, seat_state: *SeatState) !void {
    std.debug.assert(!seat_state.removed);
    std.debug.assert(seat_state.seat_resource == null);
    const resource = try river.SeatV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(SeatResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .resource = resource,
        .seat_state = seat_state,
        .owner_generation = self.session_generation,
    };
    resource.setHandler(*SeatResource, SeatResource.handleRequest, SeatResource.handleDestroy, adapter);

    seat_state.seat_resource = adapter;
    manager.sendSeat(resource);
    resource.sendWlSeat(seat_state.seat.globalName(manager.getClient()));
}

const OutputResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    owner_generation: u64,
    output_id: OutputLayout.Id,
    resource: *river.OutputV1,
    removed: bool,

    fn handleRequest(
        resource: *river.OutputV1,
        request: river.OutputV1.Request,
        self: *OutputResource,
    ) void {
        if (self.removed) {
            if (request == .destroy) resource.destroy();
            return;
        }
        switch (request) {
            .destroy => resource.destroy(),
            .set_presentation_mode => |set| {
                const manager_resource = self.activeManager() orelse return;
                if (!self.requireRendering(manager_resource)) return;
                switch (set.mode) {
                    .vsync, .async => self.manager.pending_presentation_mode = set.mode,
                    else => resource.postError(
                        .invalid_presentation_mode,
                        "unknown output presentation mode",
                    ),
                }
            },
        }
    }

    fn activeManager(self: *OutputResource) ?*river.WindowManagerV1 {
        if (self.removed) return null;
        if (self.manager.session_generation != self.owner_generation) return null;
        return self.manager.active;
    }

    fn requireRendering(
        self: *OutputResource,
        manager: *river.WindowManagerV1,
    ) bool {
        switch (self.manager.sequence.state) {
            .manage, .inflight_configures, .render => return true,
            .idle => {
                manager.postError(.sequence_order, "output request outside a render sequence");
                return false;
            },
        }
    }

    fn handleDestroy(resource: *river.OutputV1, self: *OutputResource) void {
        std.debug.assert(self.resource == resource);
        for (self.manager.output_resources.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = self.manager.output_resources.orderedRemove(index);
            break;
        }
        self.allocator.destroy(self);
    }
};

const SeatResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    resource: *river.SeatV1,
    seat_state: *SeatState,
    owner_generation: u64,

    fn handleRequest(
        resource: *river.SeatV1,
        request: river.SeatV1.Request,
        self: *SeatResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        if (self.seat_state.removed or self.seat_state.seat_resource != self or
            self.manager.active == null or
            self.manager.session_generation != self.owner_generation) return;
        const manager_resource = self.manager.active.?;

        switch (request) {
            .destroy => unreachable,
            .focus_window => |focus| {
                if (!self.requireManage(manager_resource)) return;
                if (self.manager.layer_focus_sent == .exclusive) return;
                const id = self.resolveWindow(focus.window) orelse return;
                _ = self.manager.layer_shell.relinquishNonExclusiveFocus();
                self.seat_state.pending_focus = .{ .window = id };
            },
            .clear_focus => {
                if (!self.requireManage(manager_resource)) return;
                if (self.manager.layer_focus_sent == .exclusive) return;
                _ = self.manager.layer_shell.relinquishNonExclusiveFocus();
                self.seat_state.pending_focus = .clear;
            },
            .focus_shell_surface => |focus| {
                if (!self.requireManage(manager_resource)) return;
                if (self.manager.layer_focus_sent == .exclusive) return;
                const id = self.resolveShellSurface(focus.shell_surface) orelse return;
                _ = self.manager.layer_shell.relinquishNonExclusiveFocus();
                self.seat_state.pending_focus = .{ .shell_surface = id };
            },
            .op_start_pointer => {
                if (self.requireManage(manager_resource) and self.seat_state.operation == null and
                    self.seat_state.pending_operation != .end) self.seat_state.pending_operation = .start;
            },
            .op_end => {
                if (self.requireManage(manager_resource)) self.seat_state.pending_operation = .end;
            },
            .get_pointer_binding => |get| PointerBinding.create(
                self.manager,
                self.seat_state,
                get.id,
                get.button,
                @bitCast(get.modifiers),
            ) catch resource.postNoMemory(),
            .set_xcursor_theme => {},
            .pointer_warp => |warp| if (self.requireManage(manager_resource)) {
                self.seat_state.pending_warp = .{ .x = warp.x, .y = warp.y };
            },
        }
    }

    fn resolveWindow(self: *SeatResource, resource: *river.WindowV1) ?WindowId {
        const data = resource.getUserData() orelse return null;
        const window: *WindowResource = @ptrCast(@alignCast(data));
        if (window.manager != self.manager or
            window.owner_generation != self.owner_generation) return null;
        if (self.manager.windows.get(window.id) == null) return null;
        return window.id;
    }

    fn resolveShellSurface(
        self: *SeatResource,
        resource: *river.ShellSurfaceV1,
    ) ?ShellSurfaceId {
        const data = resource.getUserData() orelse return null;
        const shell_surface: *ShellSurfaceResource = @ptrCast(@alignCast(data));
        if (shell_surface.manager != self.manager or
            shell_surface.owner_generation != self.owner_generation) return null;
        if (self.manager.shell_surfaces.get(shell_surface.id) == null) return null;
        return shell_surface.id;
    }

    fn requireManage(self: *SeatResource, manager: *river.WindowManagerV1) bool {
        if (self.manager.sequence.state == .manage) return true;
        manager.postError(.sequence_order, "seat request outside a manage sequence");
        return false;
    }

    fn handleDestroy(resource: *river.SeatV1, self: *SeatResource) void {
        std.debug.assert(self.resource == resource);
        if (self.seat_state.seat_resource == self) self.seat_state.seat_resource = null;
        self.allocator.destroy(self);
    }
};

const PointerBinding = struct {
    manager: *Self,
    seat_state: *SeatState,
    resource: *river.PointerBindingV1,
    owner_generation: u64,
    button: u32,
    modifiers: u32,
    enabled: bool = false,
    pending: std.ArrayList(enum { pressed, released }) = .empty,

    fn create(manager: *Self, seat_state: *SeatState, id: u32, button: u32, modifiers: u32) !void {
        const resource = try river.PointerBindingV1.create(manager.active.?.getClient(), manager.active.?.getVersion(), id);
        errdefer resource.destroy();
        const self = try manager.allocator.create(PointerBinding);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .seat_state = seat_state,
            .resource = resource,
            .owner_generation = manager.session_generation,
            .button = button,
            .modifiers = modifiers & 0xed,
        };
        try manager.pointer_bindings.append(manager.allocator, self);
        resource.setHandler(*PointerBinding, PointerBinding.handleRequest, PointerBinding.handleDestroy, self);
    }

    fn active(self: *PointerBinding) bool {
        return !self.seat_state.removed and self.manager.active != null and
            self.manager.session_generation == self.owner_generation;
    }

    fn handleRequest(resource: *river.PointerBindingV1, request: river.PointerBindingV1.Request, self: *PointerBinding) void {
        switch (request) {
            .destroy => resource.destroy(),
            .enable, .disable => {
                if (!self.active()) return;
                if (self.manager.sequence.state != .manage) {
                    self.manager.active.?.postError(.sequence_order, "pointer binding request outside a manage sequence");
                    return;
                }
                self.enabled = request == .enable;
            },
        }
    }

    fn handleDestroy(_: *river.PointerBindingV1, self: *PointerBinding) void {
        for (self.seat_state.held_buttons.items) |*held| {
            if (held.binding == self) held.binding = null;
        }
        for (self.manager.pointer_bindings.items, 0..) |binding, index| if (binding == self) {
            _ = self.manager.pointer_bindings.orderedRemove(index);
            break;
        };
        self.pending.deinit(self.manager.allocator);
        self.manager.allocator.destroy(self);
    }
};

test "removed River outputs stay inert until the client destroys them" {
    const display = try wl.Server.create();
    defer display.destroy();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;
    defer client.destroy();

    var manager: Self = undefined;
    manager.allocator = std.testing.allocator;
    manager.output_resources = .empty;
    defer manager.output_resources.deinit(std.testing.allocator);

    const resource = try river.OutputV1.create(client, protocol_version, 0);
    const adapter = try std.testing.allocator.create(OutputResource);
    adapter.* = .{
        .allocator = std.testing.allocator,
        .manager = &manager,
        .owner_generation = 1,
        .output_id = .{ .index = 0, .generation = 1 },
        .resource = resource,
        .removed = true,
    };
    try manager.output_resources.append(std.testing.allocator, adapter);
    resource.setHandler(*OutputResource, OutputResource.handleRequest, OutputResource.handleDestroy, adapter);
    const resource_id = resource.getId();

    OutputResource.handleRequest(resource, .{ .set_presentation_mode = .{ .mode = .async } }, adapter);
    try std.testing.expect(client.getObject(resource_id) != null);
    try std.testing.expectEqual(@as(usize, 1), manager.output_resources.items.len);

    OutputResource.handleRequest(resource, .destroy, adapter);
    try std.testing.expect(client.getObject(resource_id) == null);
    try std.testing.expectEqual(@as(usize, 0), manager.output_resources.items.len);
}

test "window management sequence preserves dirty work across render" {
    var sequence: Sequence = .{};

    try std.testing.expect(sequence.requestManage());
    try std.testing.expect(!sequence.requestManage());
    try std.testing.expect(sequence.finishManage(0));
    try std.testing.expectEqual(.manage, sequence.finishRender());
    try std.testing.expect(sequence.finishManage(0));
    try std.testing.expectEqual(.idle, sequence.finishRender());
}

test "window management sequence rejects out-of-order finishes" {
    var sequence: Sequence = .{};

    try std.testing.expect(!sequence.finishManage(0));
    try std.testing.expectEqual(.invalid, sequence.finishRender());
    try std.testing.expect(sequence.requestManage());
    try std.testing.expectEqual(.invalid, sequence.finishRender());
}

test "window management waits for every configured window" {
    var sequence: Sequence = .{};

    try std.testing.expect(sequence.requestManage());
    try std.testing.expect(sequence.finishManage(2));
    try std.testing.expect(!sequence.configureFinished());
    try std.testing.expect(sequence.configureFinished());
    try std.testing.expectEqual(.idle, sequence.finishRender());
}

test "window management configure timeout advances to render" {
    var sequence: Sequence = .{};

    try std.testing.expect(sequence.requestManage());
    try std.testing.expect(sequence.finishManage(1));
    try std.testing.expect(sequence.configureTimeout());
    try std.testing.expectEqual(.idle, sequence.finishRender());
    try std.testing.expect(!sequence.configureTimeout());
}

test "river color components retain full-range endpoints" {
    try std.testing.expectEqual(@as(u8, 0), protocolColorComponent(0));
    try std.testing.expectEqual(@as(u8, 128), protocolColorComponent(0x80808080));
    try std.testing.expectEqual(@as(u8, 255), protocolColorComponent(std.math.maxInt(u32)));
}

test "pointer coordinates clamp to output pixels" {
    try std.testing.expectEqual(Point{ .x = 0, .y = 9 }, clampPoint(.{ .x = -4, .y = 20 }, 10, 10));
    try std.testing.expectEqual(@as(i32, -2), pointerCoordinate(-2.9));
}

test "pointer operation delta clamps cumulative subtraction" {
    try std.testing.expectEqual(Point{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) }, operationDelta(.{
        .start = .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) },
        .current = .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) },
    }));
}

test "ordinary held buttons do not create a River pointer grab" {
    const buttons = [_]HeldButton{
        .{ .button = 0x110, .binding = null, .captured = false },
        .{ .button = 0x111, .binding = null, .captured = false },
    };
    try std.testing.expect(!hasCapturedButton(&buttons));
    try std.testing.expect(hasCapturedButton(&.{
        .{ .button = 0x110, .binding = null, .captured = true },
    }));
}
