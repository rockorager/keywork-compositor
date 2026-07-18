//! Built-in, protocol-neutral workspace policy for XDG and Xwayland toplevels.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("slot_map.zig");
const Scene = @import("scene.zig");
const OutputLayout = @import("wayland/output_layout.zig");
const Surface = @import("wayland/surface.zig");
const Seat = @import("wayland/seat.zig");
const XdgShell = @import("wayland/xdg_shell.zig");
const LayerShell = @import("wayland/layer_shell.zig");
const WorkspaceProtocol = @import("wayland/workspace.zig");
const Xwm = @import("xwayland/xwm.zig");
const XwaylandController = @import("window_manager/backend.zig").XwaylandController;
const types = @import("window_manager/types.zig");
const layout_mod = @import("window_manager/layout.zig");
const workspace_mod = @import("window_manager/workspace.zig");
const command_mod = @import("command.zig");
const Command = command_mod.Command;
const Direction = command_mod.Direction;

const wl = wayland.server.wl;
const workspace_count = 10;

allocator: std.mem.Allocator,
outputs: *OutputLayout,
default_output: OutputLayout.Id,
scene: *Scene,
xdg_shell: *XdgShell,
xwayland: XwaylandController,
layer_shell: *LayerShell,
workspace_protocol: *WorkspaceProtocol,
windows: WindowStore = .{},
known_xwayland: std.AutoHashMapUnmanaged(Xwm.WindowId, KnownXwaylandWindow) = .empty,
workspaces: std.ArrayList(OutputWorkspace) = .empty,
transaction: Transaction = .{},
configure_timer: *wl.EventSource,
layer_focus: LayerShell.FocusClass = .none,
window_effects: Scene.Effects = Scene.default_effects,

const WindowStore = slot_map.SlotMap(Window, enum { builtin_window });
pub const WindowId = WindowStore.Id;

const KnownXwaylandWindow = struct {
    scene_id: Scene.Id,
    surface_id: Surface.Id,
};

const Window = struct {
    backend: Backend,
    scene_id: Scene.Id,
    surface_id: Surface.Id,
    workspace: usize,
    tags: workspace_mod.TagSet = .{},
    serial: ?u32 = null,
    placement: ?types.LayoutPlan = null,
    mapped: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    fullscreen_output: ?OutputLayout.Id = null,

    const Backend = union(enum) {
        xdg: XdgShell.WindowId,
        xwayland: Xwm.WindowId,
    };
};

const OutputWorkspace = struct {
    output: OutputLayout.Id,
    number: u8,
    active: bool,
    workspace: workspace_mod.Workspace = .{},
};

/// Pure transaction barrier. Removing an expected participant is equivalent to
/// it committing, which prevents an unmap from stranding a render transaction.
pub const Transaction = struct {
    state: State = .idle,
    remaining: u32 = 0,
    dirty: bool = false,

    pub const State = enum { idle, inflight, timed_out };

    pub fn begin(self: *Transaction, count: u32) void {
        std.debug.assert(self.state == .idle);
        self.remaining = count;
        self.state = if (count == 0) .idle else .inflight;
    }

    pub fn change(self: *Transaction) bool {
        if (self.state == .inflight) {
            self.dirty = true;
            return false;
        }
        return true;
    }

    pub fn configured(self: *Transaction) bool {
        if (self.state != .inflight) return false;
        std.debug.assert(self.remaining > 0);
        self.remaining -= 1;
        if (self.remaining != 0) return false;
        self.state = .idle;
        return true;
    }

    pub fn removed(self: *Transaction, was_pending: bool) bool {
        return if (was_pending) self.configured() else false;
    }

    pub fn timeout(self: *Transaction) bool {
        if (self.state != .inflight) return false;
        self.state = .timed_out;
        self.remaining = 0;
        return true;
    }

    pub fn consumeDirty(self: *Transaction) bool {
        const value = self.dirty;
        self.dirty = false;
        if (self.state == .timed_out) self.state = .idle;
        return value;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
    default_output: OutputLayout.Id,
    scene: *Scene,
    xdg_shell: *XdgShell,
    xwayland: XwaylandController,
    layer_shell: *LayerShell,
    workspace_protocol: *WorkspaceProtocol,
) !void {
    self.* = .{
        .allocator = allocator,
        .outputs = outputs,
        .default_output = default_output,
        .scene = scene,
        .xdg_shell = xdg_shell,
        .xwayland = xwayland,
        .layer_shell = layer_shell,
        .workspace_protocol = workspace_protocol,
        .configure_timer = undefined,
    };
    var output_iterator = outputs.iterator();
    while (output_iterator.next()) |entry| {
        self.appendOutputWorkspaces(entry.id) catch |err| {
            for (self.workspaces.items) |*workspace| workspace.workspace.deinit(allocator);
            self.workspaces.deinit(allocator);
            return err;
        };
    }
    std.debug.assert(self.workspaceFor(default_output) != null);
    errdefer {
        for (self.workspaces.items) |*entry| entry.workspace.deinit(allocator);
        self.workspaces.deinit(allocator);
    }
    self.configure_timer = try display.getEventLoop().addTimer(*Self, configureTimeout, self);
    errdefer self.configure_timer.remove();
    xdg_shell.setWindowListener(.{
        .context = self,
        .ready = windowReady,
        .committed = windowCommitted,
        .unmapped = windowUnmapped,
        .destroyed = windowDestroyed,
        .metadata_changed = windowMetadataChanged,
        .request = windowRequest,
    });
    layer_shell.setPolicyListener(.{ .context = self, .supported = layerSupported, .changed = layerChanged });
}

pub fn deinit(self: *Self) void {
    self.layer_shell.clearPolicyListener();
    self.xdg_shell.clearWindowListener();
    self.configure_timer.remove();
    var windows = self.windows.iterator();
    while (windows.next()) |entry| entry.value.tags.deinit(self.allocator);
    while (self.windows.len() != 0) {
        var it = self.windows.iterator();
        _ = self.windows.remove(it.next().?.id);
    }
    self.windows.deinit(self.allocator);
    self.known_xwayland.deinit(self.allocator);
    for (self.workspaces.items) |*entry| entry.workspace.deinit(self.allocator);
    self.workspaces.deinit(self.allocator);
    self.* = undefined;
}

fn neutral(id: WindowId) types.WindowId {
    return .{ .index = id.index, .generation = id.generation };
}

fn internal(id: types.WindowId) WindowId {
    return .{ .index = id.index, .generation = id.generation };
}

fn findXdg(self: *Self, xdg_id: XdgShell.WindowId) ?WindowId {
    var it = self.windows.iterator();
    while (it.next()) |entry| switch (entry.value.backend) {
        .xdg => |candidate| if (std.meta.eql(candidate, xdg_id)) return entry.id,
        .xwayland => {},
    };
    return null;
}

fn findXwayland(self: *Self, xwayland_id: Xwm.WindowId) ?WindowId {
    var it = self.windows.iterator();
    while (it.next()) |entry| switch (entry.value.backend) {
        .xdg => {},
        .xwayland => |candidate| if (std.meta.eql(candidate, xwayland_id)) return entry.id,
    };
    return null;
}

fn addXdg(self: *Self, xdg_id: XdgShell.WindowId) !WindowId {
    if (self.findXdg(xdg_id)) |id| return id;
    const info = self.xdg_shell.windowInfo(xdg_id) orelse return error.OutOfMemory;
    const surface_id = self.xdg_shell.windowSurface(xdg_id) orelse return error.OutOfMemory;
    const workspace = self.workspaceFor(self.default_output) orelse 0;
    const id = try self.windows.insert(self.allocator, .{ .backend = .{ .xdg = xdg_id }, .scene_id = info.scene_id, .surface_id = surface_id, .workspace = workspace });
    errdefer _ = self.windows.remove(id);
    _ = try self.workspaces.items[workspace].workspace.insert(self.allocator, neutral(id));
    _ = self.workspaces.items[workspace].workspace.focus(neutral(id));
    self.reportWorkspaceOccupancy(workspace);
    return id;
}

fn removeId(self: *Self, id: WindowId) void {
    const pending = self.windows.get(id).?.serial != null;
    var window = self.windows.remove(id).?;
    _ = self.workspaces.items[window.workspace].workspace.remove(neutral(id));
    self.reportWorkspaceOccupancy(window.workspace);
    window.tags.deinit(self.allocator);
    if (self.transaction.removed(pending)) self.publish();
    self.relayout();
}

fn removeXdg(self: *Self, xdg_id: XdgShell.WindowId) void {
    self.removeId(self.findXdg(xdg_id) orelse return);
}

fn addXwayland(self: *Self, xwayland_id: Xwm.WindowId) !?WindowId {
    if (self.findXwayland(xwayland_id)) |id| return id;
    const known = self.known_xwayland.get(xwayland_id) orelse return null;
    const info = self.xwayland.window_info(self.xwayland.context, xwayland_id) orelse return null;
    if (!info.participatesInWindowManagement()) return null;
    const workspace = self.workspaceFor(self.default_output) orelse return null;
    const id = try self.windows.insert(self.allocator, .{
        .backend = .{ .xwayland = xwayland_id },
        .scene_id = known.scene_id,
        .surface_id = known.surface_id,
        .workspace = workspace,
        .mapped = info.mapped,
        .minimized = info.minimized,
        .maximized = info.maximized,
        .fullscreen_output = if (info.fullscreen) self.workspaces.items[workspace].output else null,
    });
    errdefer _ = self.windows.remove(id);
    _ = try self.workspaces.items[workspace].workspace.insert(self.allocator, neutral(id));
    _ = self.workspaces.items[workspace].workspace.focus(neutral(id));
    self.reportWorkspaceOccupancy(workspace);
    return id;
}

fn reportWorkspaceOccupancy(self: *Self, index: usize) void {
    const entry = &self.workspaces.items[index];
    self.workspace_protocol.setOccupied(entry.output, entry.number, entry.workspace.members.items.len != 0);
}

fn workspaceFor(self: *Self, output: OutputLayout.Id) ?usize {
    for (self.workspaces.items, 0..) |entry, i| {
        if (entry.active and std.meta.eql(entry.output, output)) return i;
    }
    return null;
}

fn workspaceNumber(self: *Self, output: OutputLayout.Id, number: u8) ?usize {
    if (number == 0 or number > workspace_count) return null;
    for (self.workspaces.items, 0..) |entry, i| {
        if (entry.number == number and std.meta.eql(entry.output, output)) return i;
    }
    return null;
}

fn appendOutputWorkspaces(self: *Self, output: OutputLayout.Id) !void {
    const original_len = self.workspaces.items.len;
    errdefer {
        for (self.workspaces.items[original_len..]) |*entry| entry.workspace.deinit(self.allocator);
        self.workspaces.items.len = original_len;
    }
    for (1..workspace_count + 1) |number| {
        try self.workspaces.append(self.allocator, .{
            .output = output,
            .number = @intCast(number),
            .active = number == 1,
        });
    }
}

pub fn outputAdded(self: *Self, output: OutputLayout.Id) !void {
    if (self.workspaceFor(output) == null) try self.appendOutputWorkspaces(output);
    self.relayout();
}

pub fn outputRemoved(self: *Self, output: OutputLayout.Id) error{OutOfMemory}!void {
    _ = self.workspaceFor(output) orelse return;
    var replacement: ?usize = null;
    for (self.workspaces.items, 0..) |entry, index| {
        if (!entry.active or std.meta.eql(entry.output, output)) continue;
        replacement = index;
        break;
    }
    var replacement_index = replacement orelse return;
    const replacement_output = self.workspaces.items[replacement_index].output;
    var migration_count: usize = 0;
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        if (std.meta.eql(self.workspaces.items[entry.value.workspace].output, output)) {
            migration_count += 1;
        }
    }
    try self.workspaces.items[replacement_index].workspace.ensureInsertCapacity(
        self.allocator,
        migration_count,
    );
    it = self.windows.iterator();
    while (it.next()) |entry| {
        const source_index = entry.value.workspace;
        if (!std.meta.eql(self.workspaces.items[source_index].output, output)) continue;
        const moved = try workspace_mod.Workspace.moveWindow(
            self.allocator,
            &self.workspaces.items[source_index].workspace,
            &self.workspaces.items[replacement_index].workspace,
            neutral(entry.id),
        );
        std.debug.assert(moved);
        entry.value.workspace = replacement_index;
        self.reportWorkspaceOccupancy(source_index);
        self.reportWorkspaceOccupancy(replacement_index);
        if (entry.value.fullscreen_output) |fullscreen_output| {
            if (std.meta.eql(fullscreen_output, output)) {
                entry.value.fullscreen_output = replacement_output;
            }
        }
    }
    var index = self.workspaces.items.len;
    while (index > 0) {
        index -= 1;
        if (!std.meta.eql(self.workspaces.items[index].output, output)) continue;
        self.workspaces.items[index].workspace.deinit(self.allocator);
        _ = self.workspaces.orderedRemove(index);
        if (replacement_index > index) replacement_index -= 1;
        it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value.workspace > index) entry.value.workspace -= 1;
        }
    }
    if (std.meta.eql(self.default_output, output)) self.default_output = replacement_output;
    self.relayout();
}

pub fn outputStateChanged(
    self: *Self,
    _: OutputLayout.Id,
    position_changed: bool,
    dimensions_changed: bool,
) void {
    if (position_changed or dimensions_changed) self.relayout();
}

pub fn setDefaultOutput(self: *Self, output: OutputLayout.Id) void {
    std.debug.assert(self.workspaceFor(output) != null);
    self.default_output = output;
}

pub fn setWindowEffects(self: *Self, effects: Scene.Effects) void {
    if (std.meta.eql(self.window_effects, effects)) return;
    self.window_effects = effects;
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        self.scene.setEffects(entry.value.scene_id, if (entry.value.fullscreen_output != null) .{} else effects);
    }
}

pub fn focusedSurface(self: *Self) ?Surface.Id {
    const workspace_index = self.workspaceFor(self.default_output) orelse return null;
    const focused = self.workspaces.items[workspace_index].workspace.focused orelse return null;
    const window = self.windows.get(internal(focused)) orelse return null;
    if (window.minimized or !window.mapped) return null;
    return window.surface_id;
}

pub fn pointerButton(self: *Self, root: ?Surface.Id, state: wl.Pointer.ButtonState) void {
    if (state != .pressed or self.layer_focus == .exclusive) return;
    const surface_id = root orelse return;
    var candidate: ?WindowId = null;
    var it = self.windows.iterator();
    while (it.next()) |entry| if (std.meta.eql(entry.value.surface_id, surface_id)) {
        candidate = entry.id;
        break;
    };
    const id = candidate orelse (if (self.xdg_shell.surfaceRootWindow(surface_id)) |xdg_id| self.findXdg(xdg_id) else null) orelse return;
    const window = self.windows.get(id) orelse return;
    const workspace = &self.workspaces.items[window.workspace];
    if (!workspace.active) return;
    self.default_output = workspace.output;
    _ = self.layer_shell.relinquishNonExclusiveFocus();
    _ = workspace.workspace.focus(neutral(id));
    self.relayout();
}

fn currentDimensions(self: *Self, window: *const Window) XdgShell.Dimensions {
    return switch (window.backend) {
        .xdg => |id| if (self.xdg_shell.windowInfo(id)) |info| info.dimensions orelse .{ .width = 640, .height = 480 } else .{ .width = 640, .height = 480 },
        .xwayland => |id| if (self.xwayland.window_info(self.xwayland.context, id)) |info| .{ .width = info.geometry.width, .height = info.geometry.height } else .{ .width = 640, .height = 480 },
    };
}

fn needsXdgConfigure(
    current_dimensions: ?XdgShell.Dimensions,
    current_configuration: XdgShell.ToplevelConfigure,
    decoration_configure_requested: bool,
    dimensions: XdgShell.Dimensions,
    configuration: XdgShell.ToplevelConfigure,
) bool {
    return decoration_configure_requested or current_dimensions == null or
        !std.meta.eql(current_dimensions.?, dimensions) or
        !std.meta.eql(current_configuration, configuration);
}

pub fn execute(self: *Self, command: Command) void {
    switch (command) {
        .focus_next => self.focusNext(),
        .focus_previous => self.focusPrevious(),
        .focus_direction => |direction| self.focusDirection(direction),
        .move_focused_next => self.moveFocusedNext(),
        .move_focused_previous => self.moveFocusedPrevious(),
        .move_focused_direction => |direction| self.moveFocusedDirection(direction),
        .close => |target| switch (target) {
            .focused => self.closeFocused(),
        },
        .layout_master_stack => self.switchLayout(.master_stack),
        .layout_dwindle => self.switchLayout(.dwindle),
        .layout_scrolling => self.switchLayout(.scrolling),
        .switch_workspace => |number| self.switchWorkspace(number),
        .move_to_workspace => |number| self.moveFocusedToWorkspace(number),
    }
}

pub fn focusNext(self: *Self) void {
    self.cycleFocus(false);
}
pub fn focusPrevious(self: *Self) void {
    self.cycleFocus(true);
}
pub fn focusDirection(self: *Self, direction: Direction) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const workspace = &self.workspaces.items[index].workspace;
    const candidate = self.directionalNeighbor(workspace, direction) orelse return;
    const changed = workspace.focus(candidate);
    std.debug.assert(changed);
    self.relayout();
}
pub fn moveFocusedNext(self: *Self) void {
    self.moveFocused(false);
}
pub fn moveFocusedPrevious(self: *Self) void {
    self.moveFocused(true);
}
pub fn moveFocusedDirection(self: *Self, direction: Direction) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const workspace = &self.workspaces.items[index].workspace;
    const focused = workspace.focused orelse return;
    const candidate = self.directionalNeighbor(workspace, direction) orelse return;
    const changed = workspace.swapWindows(focused, candidate);
    std.debug.assert(changed);
    self.relayout();
}
pub fn closeFocused(self: *Self) void {
    const window = self.focusedWindow() orelse return;
    if (!window.mapped or window.minimized) return;
    switch (window.backend) {
        .xdg => |id| self.xdg_shell.closeWindow(id),
        .xwayland => |id| self.xwayland.close(self.xwayland.context, id),
    }
}
pub fn switchLayout(self: *Self, kind: layout_mod.Kind) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const entry = &self.workspaces.items[index];
    var usable: ?types.Rect = null;
    if (self.layer_shell.usableAreaFor(entry.output)) |area| {
        if (area.width > 0 and area.height > 0) usable = .{
            .x = area.x,
            .y = area.y,
            .size = types.Size.init(@intCast(area.width), @intCast(area.height)),
        };
    }
    entry.workspace.setLayout(self.allocator, kind, usable) catch return;
    self.relayout();
}

pub fn switchWorkspace(self: *Self, number: u8) void {
    _ = self.activateWorkspace(self.default_output, number, true);
}

pub fn activateWorkspaceFromProtocol(self: *Self, output: OutputLayout.Id, number: u8) bool {
    return self.activateWorkspace(output, number, false);
}

fn activateWorkspace(self: *Self, output: OutputLayout.Id, number: u8, notify_protocol: bool) bool {
    const current = self.workspaceFor(output) orelse return false;
    const target = self.workspaceNumber(output, number) orelse return false;
    const output_changed = !std.meta.eql(self.default_output, output);
    self.default_output = output;
    if (current == target) {
        if (output_changed) self.relayout();
        return true;
    }
    self.workspaces.items[current].active = false;
    self.workspaces.items[target].active = true;
    if (notify_protocol) self.workspace_protocol.setActive(output, number);
    self.relayout();
    return true;
}

pub fn moveFocusedToWorkspace(self: *Self, number: u8) void {
    const source = self.workspaceFor(self.default_output) orelse return;
    const target = self.workspaceNumber(self.default_output, number) orelse return;
    if (source == target) return;
    const id = self.workspaces.items[source].workspace.focused orelse return;
    const moved = workspace_mod.Workspace.moveWindow(
        self.allocator,
        &self.workspaces.items[source].workspace,
        &self.workspaces.items[target].workspace,
        id,
    ) catch return;
    std.debug.assert(moved);
    self.windows.get(internal(id)).?.workspace = target;
    self.reportWorkspaceOccupancy(source);
    self.reportWorkspaceOccupancy(target);
    self.relayout();
}
pub fn addTagToFocused(self: *Self, tag: types.TagId) !void {
    if (self.focusedWindow()) |window| _ = try window.tags.add(self.allocator, tag);
}
pub fn removeTagFromFocused(self: *Self, tag: types.TagId) void {
    if (self.focusedWindow()) |window| _ = window.tags.remove(tag);
}

fn focusedWindow(self: *Self) ?*Window {
    const index = self.workspaceFor(self.default_output) orelse return null;
    return self.windows.get(internal(self.workspaces.items[index].workspace.focused orelse return null));
}
fn cycleFocus(self: *Self, reverse: bool) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const ws = &self.workspaces.items[index].workspace;
    if (ws.members.items.len == 0) return;
    var candidate = ws.focused orelse ws.members.items[0];
    for (0..ws.members.items.len) |_| {
        candidate = ws.nextWindow(candidate, reverse) orelse return;
        const window = self.windows.get(internal(candidate)) orelse continue;
        if (window.minimized) continue;
        ws.focused = candidate;
        break;
    }
    self.relayout();
}
fn moveFocused(self: *Self, reverse: bool) void {
    const index = self.workspaceFor(self.default_output) orelse return;
    const ws = &self.workspaces.items[index].workspace;
    const focused = ws.focused orelse return;
    const other = ws.nextWindow(focused, reverse) orelse return;
    _ = ws.swapWindows(focused, other);
    self.relayout();
}

fn directionalNeighbor(
    self: *Self,
    workspace: *const workspace_mod.Workspace,
    direction: Direction,
) ?types.WindowId {
    const focused = workspace.focused orelse return null;
    const focused_window = self.windows.get(internal(focused)) orelse return null;
    const origin = if (focused_window.placement) |plan| plan.rect else return null;
    var best_id: ?types.WindowId = null;
    var best_score: ?DirectionalScore = null;
    for (workspace.members.items) |id| {
        if (id.eql(focused)) continue;
        const window = self.windows.get(internal(id)) orelse continue;
        if (window.minimized) continue;
        const candidate = if (window.placement) |plan| plan.rect else continue;
        const score = directionalScore(origin, candidate, direction) orelse continue;
        if (best_score == null or score.lessThan(best_score.?)) {
            best_id = id;
            best_score = score;
        }
    }
    return best_id;
}

fn relayout(self: *Self) void {
    if (!self.transaction.change()) return;
    var planned: std.ArrayList(types.LayoutPlan) = .empty;
    defer planned.deinit(self.allocator);
    for (self.workspaces.items) |*entry| {
        if (!entry.active) continue;
        const area = self.layer_shell.usableAreaFor(entry.output) orelse continue;
        if (area.width <= 0 or area.height <= 0) continue;
        var inputs: std.ArrayList(types.WindowInput) = .empty;
        defer inputs.deinit(self.allocator);
        for (entry.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            if (window.minimized or window.fullscreen_output != null) continue;
            const current = self.currentDimensions(window);
            inputs.append(self.allocator, .{ .id = member, .current = types.Size.init(@intCast(@max(1, current.width)), @intCast(@max(1, current.height))) }) catch return;
        }
        var plans = entry.workspace.layout.arrange(self.allocator, inputs.items, .{ .x = area.x, .y = area.y, .size = types.Size.init(@intCast(area.width), @intCast(area.height)) }, entry.workspace.focused) catch return;
        defer plans.deinit(self.allocator);
        planned.appendSlice(self.allocator, plans.items) catch return;
    }

    var pending: u32 = 0;
    var windows = self.windows.iterator();
    while (windows.next()) |entry| {
        entry.value.placement = null;
        entry.value.serial = null;
    }
    for (planned.items) |plan| {
        const window = self.windows.get(internal(plan.id)) orelse continue;
        window.placement = plan;
    }
    for (self.workspaces.items) |*entry| {
        if (!entry.active) continue;
        self.normalizeFocus(entry);
        for (entry.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            const output = self.outputs.get(entry.output) orelse continue;
            if (window.fullscreen_output != null) {
                const fullscreen_output = self.outputs.get(window.fullscreen_output.?) orelse output;
                const position = fullscreen_output.logicalPosition();
                const size = fullscreen_output.logicalSize();
                window.placement = .{
                    .id = member,
                    .rect = .{
                        .x = position.x,
                        .y = position.y,
                        .size = types.Size.init(size.width, size.height),
                    },
                    .visible = true,
                };
            }
            const plan = window.placement;
            const current_dimensions = self.currentDimensions(window);
            const dimensions: XdgShell.Dimensions = if (plan) |placement| .{
                .width = @intCast(placement.rect.size.width),
                .height = @intCast(placement.rect.size.height),
            } else .{
                .width = @max(1, current_dimensions.width),
                .height = @max(1, current_dimensions.height),
            };
            if (!window.mapped) switch (window.backend) {
                .xdg => |id| self.xdg_shell.setWindowVisible(id, false),
                .xwayland => {},
            };
            const tiled: XdgShell.TiledEdges = if (plan) |placement| .{
                .top = placement.tiled_edges.top,
                .right = placement.tiled_edges.right,
                .bottom = placement.tiled_edges.bottom,
                .left = placement.tiled_edges.left,
            } else .{};
            window.serial = switch (window.backend) {
                .xwayland => |id| serial: {
                    const current = self.currentDimensions(window);
                    if (!std.meta.eql(current, dimensions)) {
                        _ = self.xwayland.resize(
                            self.xwayland.context,
                            id,
                            @intCast(@min(dimensions.width, std.math.maxInt(u16))),
                            @intCast(@min(dimensions.height, std.math.maxInt(u16))),
                        );
                    }
                    break :serial null;
                },
                .xdg => |id| configure: {
                    const info = self.xdg_shell.windowInfo(id) orelse break :configure null;
                    const configuration: XdgShell.ToplevelConfigure = .{
                        .activated = !window.minimized and entry.workspace.focused != null and
                            member.eql(entry.workspace.focused.?),
                        .maximized = window.maximized,
                        .fullscreen = window.fullscreen_output != null,
                        .tiled = tiled,
                        .decoration_mode = if (info.decoration_preference == .only_csd)
                            .client_side
                        else
                            .server_side,
                        .bounds = .{
                            .width = @intCast(output.logicalSize().width),
                            .height = @intCast(output.logicalSize().height),
                        },
                        .suspended = window.minimized,
                    };
                    if (!needsXdgConfigure(
                        info.dimensions,
                        info.configuration,
                        info.decoration_configure_requested,
                        dimensions,
                        configuration,
                    )) break :configure null;
                    break :configure self.xdg_shell.configureWindowState(
                        id,
                        dimensions,
                        configuration,
                    ) catch null;
                },
            };
            if (window.serial != null) pending += 1;
        }
    }
    self.transaction.begin(pending);
    if (pending == 0) {
        self.publish();
    } else {
        self.configure_timer.timerUpdate(100) catch self.handleOutOfMemory();
    }
}

fn normalizeFocus(self: *Self, entry: *OutputWorkspace) void {
    const workspace = &entry.workspace;
    if (workspace.members.items.len == 0) {
        workspace.focused = null;
        return;
    }
    var candidate = workspace.focused orelse workspace.members.items[0];
    for (0..workspace.members.items.len) |_| {
        if (self.windows.get(internal(candidate))) |window| {
            if (!window.minimized) {
                workspace.focused = candidate;
                return;
            }
        }
        candidate = workspace.nextWindow(candidate, false) orelse break;
    }
    workspace.focused = null;
}

fn publish(self: *Self) void {
    var it = self.windows.iterator();
    while (it.next()) |entry| {
        const window = entry.value;
        const plan = window.placement;
        if (plan) |placement| switch (window.backend) {
            .xdg => |id| self.xdg_shell.setWindowPosition(id, .{ .x = placement.rect.x, .y = placement.rect.y }),
            .xwayland => |id| _ = self.xwayland.move(self.xwayland.context, id, clampI16(placement.rect.x), clampI16(placement.rect.y)),
        };
        const focused = !window.minimized and
            self.workspaces.items[window.workspace].workspace.focused != null and
            neutral(entry.id).eql(self.workspaces.items[window.workspace].workspace.focused.?);
        self.scene.setFocused(window.scene_id, focused);
        self.scene.setFullscreen(window.scene_id, window.fullscreen_output != null);
        switch (window.backend) {
            .xdg => |id| {
                self.xdg_shell.setWindowFocused(id, focused);
                self.xdg_shell.setWindowFullscreen(id, window.fullscreen_output != null);
            },
            .xwayland => |id| {
                self.xwayland.set_fullscreen(self.xwayland.context, id, window.fullscreen_output != null);
                self.xwayland.set_maximized(self.xwayland.context, id, window.maximized);
                self.xwayland.set_minimized(self.xwayland.context, id, window.minimized);
            },
        }
        self.scene.setEffects(window.scene_id, if (window.fullscreen_output != null) .{} else self.window_effects);
        const clip_box: ?Scene.ClipBox = if (plan) |placement|
            if (placement.clip) |clip| .{
                .x = clip.x -| placement.rect.x,
                .y = clip.y -| placement.rect.y,
                .width = clip.size.width,
                .height = clip.size.height,
            } else null
        else
            null;
        const shadow_clip_box: ?Scene.ClipBox = if (plan) |placement|
            if (placement.shadow_clip) |clip| .{
                .x = clip.x -| placement.rect.x,
                .y = clip.y -| placement.rect.y,
                .width = clip.size.width,
                .height = clip.size.height,
            } else null
        else
            null;
        self.scene.setShadowClipBox(window.scene_id, shadow_clip_box);
        switch (window.backend) {
            .xdg => |id| {
                self.xdg_shell.setWindowClipBox(id, clip_box);
                self.xdg_shell.setWindowContentClipBox(id, null);
                self.xdg_shell.setWindowVisible(id, displayed(window.mapped, window.minimized, self.workspaces.items[window.workspace].active, plan));
            },
            .xwayland => |id| self.xwayland.refresh_scene(self.xwayland.context, id),
        }
        if (window.backend == .xwayland) {
            self.scene.setClipBox(window.scene_id, clip_box);
            self.scene.setContentClipBox(window.scene_id, null);
        }
    }
    for (self.workspaces.items) |workspace| {
        if (!workspace.active) continue;
        for (workspace.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            if (window.placement != null) self.scene.placeTop(window.scene_id);
        }
        for (workspace.workspace.members.items) |member| {
            const window = self.windows.get(internal(member)) orelse continue;
            if (window.placement != null and window.fullscreen_output != null) {
                self.scene.placeTop(window.scene_id);
            }
        }
    }
    self.xwayland.stacking_changed(self.xwayland.context);
    if (self.transaction.consumeDirty()) self.relayout();
}

fn clampI16(value: i32) i16 {
    return @intCast(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16)));
}

const DirectionalScore = struct {
    off_axis: bool,
    primary: u64,
    secondary: u64,

    fn lessThan(self: DirectionalScore, other: DirectionalScore) bool {
        if (self.off_axis != other.off_axis) return !self.off_axis;
        if (self.primary != other.primary) return self.primary < other.primary;
        return self.secondary < other.secondary;
    }
};

fn directionalScore(origin: types.Rect, candidate: types.Rect, direction: Direction) ?DirectionalScore {
    const origin_x = doubledCenter(origin.x, origin.size.width);
    const origin_y = doubledCenter(origin.y, origin.size.height);
    const candidate_x = doubledCenter(candidate.x, candidate.size.width);
    const candidate_y = doubledCenter(candidate.y, candidate.size.height);
    const primary_delta: i64 = switch (direction) {
        .left => origin_x - candidate_x,
        .right => candidate_x - origin_x,
        .up => origin_y - candidate_y,
        .down => candidate_y - origin_y,
    };
    if (primary_delta <= 0) return null;
    const horizontal = direction == .left or direction == .right;
    const secondary_delta = if (horizontal)
        absoluteDifference(origin_y, candidate_y)
    else
        absoluteDifference(origin_x, candidate_x);
    const overlap = if (horizontal)
        rangesOverlap(origin.y, origin.size.height, candidate.y, candidate.size.height)
    else
        rangesOverlap(origin.x, origin.size.width, candidate.x, candidate.size.width);
    return .{
        .off_axis = !overlap,
        .primary = @intCast(primary_delta),
        .secondary = secondary_delta,
    };
}

fn doubledCenter(start: i32, length: u32) i64 {
    return 2 * @as(i64, start) + length;
}

fn absoluteDifference(first: i64, second: i64) u64 {
    return @intCast(if (first >= second) first - second else second - first);
}

fn rangesOverlap(first_start: i32, first_length: u32, second_start: i32, second_length: u32) bool {
    const first_end = @as(i64, first_start) + first_length;
    const second_end = @as(i64, second_start) + second_length;
    return @as(i64, first_start) < second_end and @as(i64, second_start) < first_end;
}

fn displayed(mapped: bool, minimized: bool, active: bool, plan: ?types.LayoutPlan) bool {
    return mapped and !minimized and active and plan != null and plan.?.visible;
}

fn configureTimeout(self: *Self) c_int {
    if (!self.transaction.timeout()) return 0;
    self.publish();
    return 0;
}

fn handleOutOfMemory(self: *Self) void {
    // A timer allocation failure must not freeze every managed window.
    _ = self.transaction.timeout();
    self.publish();
}

fn windowReady(context: *anyopaque, id: XdgShell.WindowId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    _ = self.addXdg(id) catch return false;
    self.xdg_shell.setWindowVisible(id, false);
    self.relayout();
    return true;
}
fn windowCommitted(context: *anyopaque, id: XdgShell.WindowId, serial: ?u32) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const window = self.windows.get(self.findXdg(id) orelse return false) orelse return false;
    window.mapped = true;
    if (serial != null and window.serial == serial) {
        window.serial = null;
        if (self.transaction.configured()) self.publish();
    }
    return true;
}
fn windowUnmapped(context: *anyopaque, id: XdgShell.WindowId) void {
    removeXdg(@ptrCast(@alignCast(context)), id);
}
fn windowDestroyed(context: *anyopaque, id: XdgShell.WindowId) void {
    removeXdg(@ptrCast(@alignCast(context)), id);
}
fn windowMetadataChanged(context: *anyopaque, _: XdgShell.WindowId) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    self.relayout();
    return true;
}
fn windowRequest(context: *anyopaque, id: XdgShell.WindowId, request: XdgShell.WindowRequest) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const window = self.windows.get(self.findXdg(id) orelse return) orelse return;
    switch (request) {
        .activate => {
            if (self.layer_focus == .exclusive) return;
            window.minimized = false;
            _ = self.layer_shell.relinquishNonExclusiveFocus();
            _ = self.workspaces.items[window.workspace].workspace.focus(neutral(self.findXdg(id).?));
        },
        .unminimize => {
            window.minimized = false;
            _ = self.workspaces.items[window.workspace].workspace.focus(neutral(self.findXdg(id).?));
        },
        .minimize => window.minimized = true,
        .maximize => window.maximized = true,
        .unmaximize => window.maximized = false,
        .fullscreen => |fullscreen| window.fullscreen_output = if (fullscreen) |resource|
            if (self.outputs.findResource(resource)) |entry| entry.id else self.workspaces.items[window.workspace].output
        else
            self.workspaces.items[window.workspace].output,
        .exit_fullscreen => window.fullscreen_output = null,
        else => {},
    }
    self.relayout();
}
fn layerSupported(_: *anyopaque) bool {
    return true;
}
fn layerChanged(context: *anyopaque, _: LayerShell.Rect, focus: LayerShell.FocusClass) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.layer_focus = focus;
    self.relayout();
}

pub fn xwaylandWindowAssociated(self: *Self, id: Xwm.WindowId, scene_id: Scene.Id, surface_id: Surface.Id) error{OutOfMemory}!void {
    std.debug.assert(!self.known_xwayland.contains(id));
    try self.known_xwayland.put(self.allocator, id, .{
        .scene_id = scene_id,
        .surface_id = surface_id,
    });
    errdefer _ = self.known_xwayland.remove(id);
    const info = self.xwayland.window_info(self.xwayland.context, id) orelse return;
    if (info.mapped and try self.addXwayland(id) != null) self.relayout();
}

pub fn xwaylandWindowDissociated(self: *Self, id: Xwm.WindowId) void {
    if (self.findXwayland(id)) |managed| self.removeId(managed);
    _ = self.known_xwayland.remove(id);
}

pub fn xwaylandWindowMapped(self: *Self, id: Xwm.WindowId, mapped: bool) void {
    if (!mapped) {
        if (self.findXwayland(id)) |managed| self.removeId(managed);
        return;
    }
    const managed = self.addXwayland(id) catch return orelse return;
    self.windows.get(managed).?.mapped = true;
    self.relayout();
}

pub fn xwaylandWindowConfigured(self: *Self, id: Xwm.WindowId, _: Xwm.Geometry, override_redirect: bool) void {
    if (override_redirect) if (self.findXwayland(id)) |managed| self.removeId(managed);
}

pub fn xwaylandWindowMetadataChanged(self: *Self, id: Xwm.WindowId) void {
    const info = self.xwayland.window_info(self.xwayland.context, id) orelse return;
    if (!info.participatesInWindowManagement()) {
        if (self.findXwayland(id)) |managed| self.removeId(managed);
        return;
    }
    if (info.mapped and self.findXwayland(id) == null) self.xwaylandWindowMapped(id, true);
}

pub fn xwaylandWindowFullscreenRequested(self: *Self, id: Xwm.WindowId, fullscreen: bool, output: ?OutputLayout.Id) void {
    const window = self.windows.get(self.findXwayland(id) orelse return) orelse return;
    window.fullscreen_output = if (fullscreen) output orelse self.workspaces.items[window.workspace].output else null;
    self.relayout();
}

pub fn xwaylandWindowMaximizeRequested(self: *Self, id: Xwm.WindowId, maximized: bool) void {
    const window = self.windows.get(self.findXwayland(id) orelse return) orelse return;
    window.maximized = maximized;
    self.relayout();
}

pub fn xwaylandWindowMinimizeRequested(self: *Self, id: Xwm.WindowId, minimized: bool) void {
    const window = self.windows.get(self.findXwayland(id) orelse return) orelse return;
    window.minimized = minimized;
    self.relayout();
}

pub fn xwaylandWindowActivationRequested(self: *Self, id: Xwm.WindowId, _: *Seat) void {
    if (self.layer_focus == .exclusive) return;
    const managed = self.findXwayland(id) orelse return;
    const window = self.windows.get(managed).?;
    window.minimized = false;
    _ = self.layer_shell.relinquishNonExclusiveFocus();
    _ = self.workspaces.items[window.workspace].workspace.focus(neutral(managed));
    self.relayout();
}

pub fn xwaylandWindowMoveResizeRequested(_: *Self, _: Xwm.WindowId, _: Xwm.MoveResizeRequest) void {}

pub fn xwaylandWindowDisplayed(self: *Self, id: Xwm.WindowId) bool {
    const window = self.windows.get(self.findXwayland(id) orelse return true) orelse return true;
    return displayed(window.mapped, window.minimized, self.workspaces.items[window.workspace].active, window.placement);
}

test "transaction coalesces, completes, times out, and tolerates removal" {
    var transaction: Transaction = .{};
    transaction.begin(2);
    try std.testing.expect(!transaction.change());
    try std.testing.expect(!transaction.configured());
    try std.testing.expect(transaction.removed(true));
    try std.testing.expect(transaction.consumeDirty());
    transaction.begin(1);
    try std.testing.expect(transaction.timeout());
    try std.testing.expectEqual(Transaction.State.timed_out, transaction.state);
    _ = transaction.consumeDirty();
    try std.testing.expectEqual(Transaction.State.idle, transaction.state);
}

test "each output owns ten numbered workspaces" {
    var manager: Self = undefined;
    manager.allocator = std.testing.allocator;
    manager.workspaces = .empty;
    defer {
        for (manager.workspaces.items) |*entry| entry.workspace.deinit(std.testing.allocator);
        manager.workspaces.deinit(std.testing.allocator);
    }

    const first: OutputLayout.Id = .{ .index = 1, .generation = 1 };
    const second: OutputLayout.Id = .{ .index = 2, .generation = 1 };
    try manager.appendOutputWorkspaces(first);
    try manager.appendOutputWorkspaces(second);

    try std.testing.expectEqual(@as(usize, 20), manager.workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 0), manager.workspaceFor(first).?);
    try std.testing.expectEqual(@as(usize, 10), manager.workspaceFor(second).?);
    try std.testing.expectEqual(@as(usize, 9), manager.workspaceNumber(first, 10).?);
    try std.testing.expectEqual(@as(usize, 19), manager.workspaceNumber(second, 10).?);
}

test "Xwayland does not enter configure barrier and hidden workspaces are invisible" {
    var transaction: Transaction = .{};
    transaction.begin(0);
    try std.testing.expectEqual(Transaction.State.idle, transaction.state);
    const plan: types.LayoutPlan = .{ .id = types.id(1), .rect = .{ .x = 0, .y = 0, .size = types.Size.init(1, 1) }, .visible = true };
    try std.testing.expect(!displayed(true, false, false, plan));
    try std.testing.expect(displayed(true, false, true, plan));
}

test "XDG configure is sent only for initial or changed state" {
    const dimensions: XdgShell.Dimensions = .{ .width = 640, .height = 480 };
    const configuration: XdgShell.ToplevelConfigure = .{
        .activated = true,
        .tiled = .{ .top = true, .bottom = true },
    };

    try std.testing.expect(needsXdgConfigure(null, configuration, false, dimensions, configuration));
    try std.testing.expect(needsXdgConfigure(dimensions, configuration, true, dimensions, configuration));
    try std.testing.expect(needsXdgConfigure(
        dimensions,
        configuration,
        false,
        .{ .width = 800, .height = 600 },
        configuration,
    ));
    try std.testing.expect(needsXdgConfigure(
        dimensions,
        configuration,
        false,
        dimensions,
        .{ .activated = false },
    ));
    try std.testing.expect(!needsXdgConfigure(
        dimensions,
        configuration,
        false,
        dimensions,
        configuration,
    ));
}

test "directional navigation prefers aligned neighbors then distance" {
    const origin: types.Rect = .{ .x = 40, .y = 40, .size = types.Size.init(20, 20) };
    const aligned_left: types.Rect = .{ .x = 0, .y = 45, .size = types.Size.init(20, 10) };
    const closer_aligned_left: types.Rect = .{ .x = 20, .y = 45, .size = types.Size.init(10, 10) };
    const diagonal_left: types.Rect = .{ .x = 30, .y = 0, .size = types.Size.init(10, 10) };
    const right: types.Rect = .{ .x = 70, .y = 40, .size = types.Size.init(20, 20) };

    const aligned_score = directionalScore(origin, aligned_left, .left).?;
    const closer_aligned_score = directionalScore(origin, closer_aligned_left, .left).?;
    const diagonal_score = directionalScore(origin, diagonal_left, .left).?;
    try std.testing.expect(aligned_score.lessThan(diagonal_score));
    try std.testing.expect(closer_aligned_score.lessThan(aligned_score));
    try std.testing.expect(directionalScore(origin, right, .left) == null);
    try std.testing.expect(directionalScore(origin, right, .right) != null);
}
