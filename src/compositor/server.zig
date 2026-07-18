//! Wayland display and compositor-global lifetime.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("slot_map.zig");
const presentation = @import("presentation.zig");
const Compositor = @import("wayland/compositor.zig");
const Subcompositor = @import("wayland/subcompositor.zig");
const XdgOutput = @import("wayland/xdg_output.zig");
const XdgShell = @import("wayland/xdg_shell.zig");
const GtkShell = @import("wayland/gtk_shell.zig");
const XdgForeign = @import("wayland/xdg_foreign.zig");
const LayerShell = @import("wayland/layer_shell.zig");
const SinglePixelBuffer = @import("wayland/single_pixel_buffer.zig");
const ContentType = @import("wayland/content_type.zig");
const ColorManagement = @import("wayland/color_management.zig");
const ColorRepresentation = @import("wayland/color_representation.zig");
const AlphaModifier = @import("wayland/alpha_modifier.zig");
const BackgroundEffect = @import("wayland/background_effect.zig");
const SecurityContext = @import("wayland/security_context.zig");
const SessionLock = @import("wayland/session_lock.zig");
const CursorShape = @import("wayland/cursor_shape.zig");
const Tablet = @import("wayland/tablet.zig");
const RelativePointer = @import("wayland/relative_pointer.zig");
const PointerGestures = @import("wayland/pointer_gestures.zig");
const PointerConstraints = @import("wayland/pointer_constraints.zig");
const PointerWarp = @import("wayland/pointer_warp.zig");
const IdleInhibit = @import("wayland/idle_inhibit.zig");
const KeyboardShortcutsInhibit = @import("wayland/keyboard_shortcuts_inhibit.zig");
const IdleNotify = @import("wayland/idle_notify.zig");
const Seat = @import("wayland/seat.zig");
const DataDevice = @import("wayland/data_device.zig");
const XdgToplevelDrag = @import("wayland/xdg_toplevel_drag.zig");
const XdgToplevelIcon = @import("wayland/xdg_toplevel_icon.zig");
const XdgDialog = @import("wayland/xdg_dialog.zig");
const XdgSystemBell = @import("wayland/xdg_system_bell.zig");
const XdgToplevelTag = @import("wayland/xdg_toplevel_tag.zig");
const XdgSessionManagement = @import("wayland/xdg_session_management.zig");
const TransientSeat = @import("wayland/transient_seat.zig");
const PrimarySelection = @import("wayland/primary_selection.zig");
const DataControl = @import("wayland/data_control.zig");
const ForeignToplevelList = @import("wayland/foreign_toplevel_list.zig");
const ImageCaptureSource = @import("wayland/image_capture_source.zig");
const ImageCopyCapture = @import("wayland/image_copy_capture.zig");
const Screencopy = @import("wayland/screencopy.zig");
const XwaylandKeyboardGrab = @import("wayland/xwayland_keyboard_grab.zig");
const XwaylandShell = @import("wayland/xwayland_shell.zig");
const XwaylandServer = @import("xwayland/server.zig");
const Xwm = @import("xwayland/xwm.zig");
const Workspace = @import("wayland/workspace.zig");
const TextInput = @import("wayland/text_input.zig");
const InputMethod = @import("wayland/input_method.zig");
const VirtualKeyboard = @import("wayland/virtual_keyboard.zig");
const VirtualPointer = @import("wayland/virtual_pointer.zig");
const PresentationProtocol = @import("wayland/presentation.zig");
const FractionalScale = @import("wayland/fractional_scale.zig");
const Fixes = @import("wayland/fixes.zig");
const LinuxDmabuf = @import("wayland/linux_dmabuf.zig");
const LinuxDrmSyncobj = @import("wayland/linux_drm_syncobj.zig");
const TearingControl = @import("wayland/tearing_control.zig");
const Fifo = @import("wayland/fifo.zig");
const CommitTiming = @import("wayland/commit_timing.zig");
const XdgActivation = @import("wayland/xdg_activation.zig");
const Output = @import("wayland/output.zig");
const OutputLayout = @import("wayland/output_layout.zig");
const OutputManagement = @import("wayland/output_management.zig");
const OutputPower = @import("wayland/output_power.zig");
const GammaControl = @import("wayland/gamma_control.zig");
const DrmLease = @import("wayland/drm_lease.zig");
const OutputBackend = @import("backend/output.zig");
const DrmDevice = @import("backend/drm_device.zig");
const DrmOutput = @import("backend/drm.zig");
const NativeInput = @import("backend/native_input.zig");
const Session = @import("backend/session.zig");
const renderer_types = @import("render/renderer.zig");
const render = @import("render/types.zig");
const Region = @import("region.zig");
const Scene = @import("scene.zig");
const Surface = @import("wayland/surface.zig");
const Viewporter = @import("wayland/viewporter.zig");
const InputManager = @import("input_manager.zig");
const BuiltinKeybindings = @import("builtin_keybindings.zig");
const Command = @import("command.zig").Command;
const Config = @import("config.zig");
const Launcher = @import("launcher.zig");
const Control = @import("control.zig");
const ControlProtocol = @import("keywork-control");
const WindowManager = @import("window_manager.zig");

const wl = wayland.server.wl;
const log = std.log.scoped(.server);
const linux_button_left = 0x110;

allocator: std.mem.Allocator,
io: std.Io,
display: *wl.Server,
control: Control,
control_initialized: bool,
configuration: ?Config.Store,
layer_shell_effects: Scene.Effects,
session: Session,
session_initialized: bool,
drm_device: DrmDevice,
drm_device_initialized: bool,
native_input: NativeInput,
native_input_initialized: bool,
input_manager: InputManager,
input_manager_initialized: bool,
builtin_keybindings: BuiltinKeybindings,
builtin_keybindings_initialized: bool,
render_outputs: RenderOutputStore,
primary_render_output: RenderOutputId,
outputs: OutputLayout,
xdg_output: XdgOutput,
xdg_output_initialized: bool,
output_management: OutputManagement,
output_management_initialized: bool,
output_power: OutputPower,
output_power_initialized: bool,
gamma_control: GammaControl,
gamma_control_initialized: bool,
drm_lease: DrmLease,
drm_lease_initialized: bool,
single_pixel_buffer: SinglePixelBuffer,
content_type: ContentType,
color_management: ColorManagement,
color_representation: ColorRepresentation,
alpha_modifier: AlphaModifier,
background_effect: BackgroundEffect,
security_context: SecurityContext,
session_lock: SessionLock,
session_lock_initialized: bool,
cursor_shape: CursorShape,
tablet: Tablet,
relative_pointer: RelativePointer,
pointer_gestures: PointerGestures,
pointer_constraints: PointerConstraints,
pointer_warp: PointerWarp,
idle_inhibit: IdleInhibit,
keyboard_shortcuts_inhibit: KeyboardShortcutsInhibit,
idle_notify: IdleNotify,
idle_notify_initialized: bool,
compositor: Compositor,
subcompositor: Subcompositor,
scene: Scene,
xdg_shell: XdgShell,
gtk_shell: GtkShell,
xdg_foreign: XdgForeign,
layer_shell: LayerShell,
seat: Seat,
transient_seat: TransientSeat,
input_device_listener: InputManager.DeviceListener,
routed_keys: std.ArrayList(RoutedKey),
routed_buttons: std.ArrayList(RoutedButton),
routed_gestures: std.ArrayList(RoutedGesture),
routed_touches: std.ArrayList(RoutedTouch),
next_touch_id: u31,
data_device: DataDevice,
xdg_toplevel_drag: XdgToplevelDrag,
xdg_toplevel_icon: XdgToplevelIcon,
xdg_dialog: XdgDialog,
xdg_system_bell: XdgSystemBell,
xdg_toplevel_tag: XdgToplevelTag,
xdg_session_management: XdgSessionManagement,
primary_selection: PrimarySelection,
data_control: DataControl,
foreign_toplevel_list: ForeignToplevelList,
foreign_toplevel_list_initialized: bool,
image_capture_source: ImageCaptureSource,
image_capture_source_initialized: bool,
image_copy_capture: ImageCopyCapture,
image_copy_capture_initialized: bool,
screencopy: Screencopy,
screencopy_initialized: bool,
xwayland_keyboard_grab: XwaylandKeyboardGrab,
xwayland_keyboard_grab_initialized: bool,
xwayland_shell: XwaylandShell,
xwayland_shell_initialized: bool,
xwayland_server: XwaylandServer,
xwayland_server_initialized: bool,
xwm: Xwm,
xwm_initialized: bool,
xwayland_windows: std.AutoHashMapUnmanaged(Xwm.WindowId, XwaylandWindow),
xwayland_client_stack: std.ArrayList(Xwm.WindowId),
xwayland_override_redirect_focus: ?Surface.Id,
workspace: Workspace,
workspace_initialized: bool,
text_input: TextInput,
input_method: InputMethod,
virtual_keyboard: VirtualKeyboard,
virtual_pointer: VirtualPointer,
presentation_protocol: PresentationProtocol,
fractional_scale: FractionalScale,
fixes: Fixes,
linux_dmabuf: LinuxDmabuf,
linux_drm_syncobj: LinuxDrmSyncobj,
tearing_control: TearingControl,
fifo: Fifo,
commit_timing: CommitTiming,
xdg_activation: XdgActivation,
viewporter: Viewporter,
window_manager: WindowManager,
window_manager_initialized: bool,
renderer: renderer_types.Renderer,
socket_buffer: [11]u8,
listening: bool,
xwayland_display_listener: ?XwaylandDisplayListener,

pub const XwaylandDisplayListener = struct {
    context: *anyopaque,
    available: *const fn (*anyopaque, []const u8) void,
    unavailable: *const fn (*anyopaque) void,
};

const RenderOutput = struct {
    server: *Self,
    backend: OutputBackend,
    protocol_id: OutputLayout.Id,
    timer: ?*wl.EventSource,
    repaint_idle: ?*wl.EventSource,
    damage: Region,
    damage_rectangles: std.ArrayList(render.Rect),
    repaint_needed: bool,
    render_scheduled: bool,
    lock_frame_pending: bool,
    frame_statistics: FrameStatistics,
    request_started_nanoseconds: ?i96,
    pending_frame: ?PendingFrame,

    const Point = struct { x: f64, y: f64 };

    fn requestFrame(self: *RenderOutput) void {
        if (self.repaint_needed) return;
        self.request_started_nanoseconds = nowNanoseconds(self.server.io);
        increment(&self.frame_statistics.frames_requested);
        self.repaint_needed = true;
    }

    fn beginFrame(self: *RenderOutput) void {
        std.debug.assert(self.pending_frame == null);
        const now = nowNanoseconds(self.server.io);
        self.pending_frame = .{
            .request_nanoseconds = self.request_started_nanoseconds orelse now,
            .render_nanoseconds = now,
        };
        self.request_started_nanoseconds = null;
        increment(&self.frame_statistics.frames_started);
    }

    fn commitFrame(self: *RenderOutput, path: FramePath) void {
        const pending = if (self.pending_frame) |*frame| frame else unreachable;
        std.debug.assert(pending.commit_nanoseconds == null);
        pending.commit_nanoseconds = nowNanoseconds(self.server.io);
        switch (path) {
            .composited => increment(&self.frame_statistics.composited_frames),
            .direct_scanout => increment(&self.frame_statistics.direct_scanout_frames),
        }
    }

    fn presentFrame(self: *RenderOutput, info: presentation.Info) void {
        const pending = self.pending_frame orelse return;
        self.pending_frame = null;
        const dispatched_nanoseconds = nowNanoseconds(self.server.io);
        const presented_nanoseconds = if (self.backend.presentationClockId() ==
            presentation.monotonic_clock_id)
            info.timestamp.toNanoseconds()
        else
            dispatched_nanoseconds;
        self.frame_statistics.recordPresentation(
            pending,
            presented_nanoseconds,
            presentationRefreshNanoseconds(info, self.backend.refreshMillihertz()),
        );
    }

    fn discardFrame(self: *RenderOutput) void {
        if (self.pending_frame == null) return;
        self.pending_frame = null;
        increment(&self.frame_statistics.frames_discarded);
    }

    fn globalPoint(self: *RenderOutput, x: f64, y: f64) Point {
        const position = self.server.outputs.get(self.protocol_id).?.logicalPosition();
        return .{
            .x = x + @as(f64, @floatFromInt(position.x)),
            .y = y + @as(f64, @floatFromInt(position.y)),
        };
    }
};

const frame_latency_capacity = 1024;
const frame_budget_tolerance_nanoseconds = std.time.ns_per_ms;

const FramePath = enum { composited, direct_scanout };

const PendingFrame = struct {
    request_nanoseconds: i96,
    render_nanoseconds: i96,
    commit_nanoseconds: ?i96 = null,
};

const FrameLatency = struct {
    request_to_presentation_microseconds: u64,
    request_to_render_microseconds: u64,
    render_to_commit_microseconds: u64,
    commit_to_presentation_microseconds: u64,
};

const LatencyKind = enum {
    request_to_presentation,
    request_to_render,
    render_to_commit,
    commit_to_presentation,
};

const FrameStatistics = struct {
    frames_requested: u64 = 0,
    frames_started: u64 = 0,
    frames_presented: u64 = 0,
    frames_discarded: u64 = 0,
    acquire_retries: u64 = 0,
    composited_frames: u64 = 0,
    direct_scanout_candidates: u64 = 0,
    direct_scanout_frames: u64 = 0,
    frames_over_budget: u64 = 0,
    latency_samples: [frame_latency_capacity]FrameLatency = undefined,
    latency_count: usize = 0,
    latency_next: usize = 0,
    gpu_execution_samples: [frame_latency_capacity]u64 = undefined,
    gpu_execution_count: usize = 0,
    gpu_execution_next: usize = 0,

    fn recordPresentation(
        self: *FrameStatistics,
        pending: PendingFrame,
        presented_nanoseconds: i96,
        refresh_nanoseconds: u64,
    ) void {
        const commit_nanoseconds = pending.commit_nanoseconds orelse unreachable;
        const request_to_presentation = elapsedNanoseconds(
            pending.request_nanoseconds,
            presented_nanoseconds,
        );
        self.addLatency(.{
            .request_to_presentation_microseconds = nanosecondsToMicroseconds(request_to_presentation),
            .request_to_render_microseconds = nanosecondsToMicroseconds(elapsedNanoseconds(
                pending.request_nanoseconds,
                pending.render_nanoseconds,
            )),
            .render_to_commit_microseconds = nanosecondsToMicroseconds(elapsedNanoseconds(
                pending.render_nanoseconds,
                commit_nanoseconds,
            )),
            .commit_to_presentation_microseconds = nanosecondsToMicroseconds(elapsedNanoseconds(
                commit_nanoseconds,
                presented_nanoseconds,
            )),
        });
        increment(&self.frames_presented);
        if (request_to_presentation > refresh_nanoseconds +| frame_budget_tolerance_nanoseconds) {
            increment(&self.frames_over_budget);
        }
    }

    fn addLatency(self: *FrameStatistics, latency: FrameLatency) void {
        self.latency_samples[self.latency_next] = latency;
        self.latency_next = (self.latency_next + 1) % frame_latency_capacity;
        self.latency_count = @min(self.latency_count + 1, frame_latency_capacity);
    }

    fn addGpuExecution(self: *FrameStatistics, nanoseconds: u64) void {
        self.gpu_execution_samples[self.gpu_execution_next] = nanosecondsToMicroseconds(nanoseconds);
        self.gpu_execution_next = (self.gpu_execution_next + 1) % frame_latency_capacity;
        self.gpu_execution_count = @min(self.gpu_execution_count + 1, frame_latency_capacity);
    }

    fn snapshot(
        self: *const FrameStatistics,
        name: []const u8,
        size: render.Size,
        refresh_millihertz: i32,
    ) ControlProtocol.OutputStatistics {
        return .{
            .name = name,
            .width = @intCast(size.width),
            .height = @intCast(size.height),
            .refresh_millihertz = refresh_millihertz,
            .frames_requested = wireInteger(self.frames_requested),
            .frames_started = wireInteger(self.frames_started),
            .frames_presented = wireInteger(self.frames_presented),
            .frames_discarded = wireInteger(self.frames_discarded),
            .acquire_retries = wireInteger(self.acquire_retries),
            .composited_frames = wireInteger(self.composited_frames),
            .direct_scanout_candidates = wireInteger(self.direct_scanout_candidates),
            .direct_scanout_frames = wireInteger(self.direct_scanout_frames),
            .frames_over_budget = wireInteger(self.frames_over_budget),
            .gpu_execution = self.gpuExecutionSummary(),
            .request_to_presentation = self.latencySummary(.request_to_presentation),
            .request_to_render = self.latencySummary(.request_to_render),
            .render_to_commit = self.latencySummary(.render_to_commit),
            .commit_to_presentation = self.latencySummary(.commit_to_presentation),
        };
    }

    fn latencySummary(
        self: *const FrameStatistics,
        comptime kind: LatencyKind,
    ) ControlProtocol.LatencyStatistics {
        if (self.latency_count == 0) return .{
            .samples = 0,
            .p50_microseconds = 0,
            .p95_microseconds = 0,
            .p99_microseconds = 0,
            .maximum_microseconds = 0,
        };
        var values: [frame_latency_capacity]u64 = undefined;
        for (self.latency_samples[0..self.latency_count], 0..) |sample, index| {
            values[index] = switch (kind) {
                .request_to_presentation => sample.request_to_presentation_microseconds,
                .request_to_render => sample.request_to_render_microseconds,
                .render_to_commit => sample.render_to_commit_microseconds,
                .commit_to_presentation => sample.commit_to_presentation_microseconds,
            };
        }
        const sorted = values[0..self.latency_count];
        std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
        return .{
            .samples = @intCast(sorted.len),
            .p50_microseconds = wireInteger(percentile(sorted, 50)),
            .p95_microseconds = wireInteger(percentile(sorted, 95)),
            .p99_microseconds = wireInteger(percentile(sorted, 99)),
            .maximum_microseconds = wireInteger(sorted[sorted.len - 1]),
        };
    }

    fn gpuExecutionSummary(self: *const FrameStatistics) ControlProtocol.LatencyStatistics {
        if (self.gpu_execution_count == 0) return .{
            .samples = 0,
            .p50_microseconds = 0,
            .p95_microseconds = 0,
            .p99_microseconds = 0,
            .maximum_microseconds = 0,
        };
        var values: [frame_latency_capacity]u64 = undefined;
        @memcpy(
            values[0..self.gpu_execution_count],
            self.gpu_execution_samples[0..self.gpu_execution_count],
        );
        const sorted = values[0..self.gpu_execution_count];
        std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
        return .{
            .samples = @intCast(sorted.len),
            .p50_microseconds = wireInteger(percentile(sorted, 50)),
            .p95_microseconds = wireInteger(percentile(sorted, 95)),
            .p99_microseconds = wireInteger(percentile(sorted, 99)),
            .maximum_microseconds = wireInteger(sorted[sorted.len - 1]),
        };
    }

    fn reset(self: *FrameStatistics) void {
        self.* = .{};
    }
};

fn nowNanoseconds(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn elapsedNanoseconds(start: i96, end: i96) u64 {
    if (end <= start) return 0;
    return @intCast(end - start);
}

fn nanosecondsToMicroseconds(nanoseconds: u64) u64 {
    return nanoseconds / std.time.ns_per_us;
}

fn presentationRefreshNanoseconds(info: presentation.Info, refresh_millihertz: i32) u64 {
    if (info.refresh_nanoseconds != 0) return info.refresh_nanoseconds;
    if (refresh_millihertz <= 0) return presentation.nominal_refresh_nanoseconds;
    const frequency: u64 = @intCast(refresh_millihertz);
    return (std.time.ns_per_s * 1000 + frequency / 2) / frequency;
}

fn percentile(sorted: []const u64, percentage: u8) u64 {
    std.debug.assert(sorted.len > 0 and percentage > 0 and percentage <= 100);
    const rank = (sorted.len * @as(usize, percentage) + 99) / 100;
    return sorted[rank - 1];
}

fn wireInteger(value: u64) i64 {
    return @intCast(@min(value, @as(u64, std.math.maxInt(i64))));
}

fn increment(value: *u64) void {
    value.* +|= 1;
}

test "frame statistics summarize rolling latency and classify over-budget frames" {
    var statistics: FrameStatistics = .{};
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 100,
        .request_to_render_microseconds = 5,
        .render_to_commit_microseconds = 10,
        .commit_to_presentation_microseconds = 90,
    });
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 200,
        .request_to_render_microseconds = 10,
        .render_to_commit_microseconds = 20,
        .commit_to_presentation_microseconds = 180,
    });
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 300,
        .request_to_render_microseconds = 15,
        .render_to_commit_microseconds = 30,
        .commit_to_presentation_microseconds = 270,
    });
    statistics.addLatency(.{
        .request_to_presentation_microseconds = 400,
        .request_to_render_microseconds = 20,
        .render_to_commit_microseconds = 40,
        .commit_to_presentation_microseconds = 360,
    });
    const summary = statistics.latencySummary(.request_to_presentation);
    try std.testing.expectEqual(@as(i64, 4), summary.samples);
    try std.testing.expectEqual(@as(i64, 200), summary.p50_microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.p95_microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.p99_microseconds);
    try std.testing.expectEqual(@as(i64, 400), summary.maximum_microseconds);

    statistics.addGpuExecution(1_100 * std.time.ns_per_us);
    statistics.addGpuExecution(2_200 * std.time.ns_per_us);
    statistics.addGpuExecution(3_300 * std.time.ns_per_us);
    const gpu_summary = statistics.gpuExecutionSummary();
    try std.testing.expectEqual(@as(i64, 3), gpu_summary.samples);
    try std.testing.expectEqual(@as(i64, 2_200), gpu_summary.p50_microseconds);
    try std.testing.expectEqual(@as(i64, 3_300), gpu_summary.p95_microseconds);
    try std.testing.expectEqual(@as(i64, 3_300), gpu_summary.maximum_microseconds);

    statistics.recordPresentation(.{
        .request_nanoseconds = 0,
        .render_nanoseconds = std.time.ns_per_ms,
        .commit_nanoseconds = 2 * std.time.ns_per_ms,
    }, 20 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1), statistics.frames_presented);
    try std.testing.expectEqual(@as(u64, 1), statistics.frames_over_budget);

    statistics.reset();
    try std.testing.expectEqual(@as(usize, 0), statistics.latency_count);
    try std.testing.expectEqual(@as(usize, 0), statistics.gpu_execution_count);
    try std.testing.expectEqual(@as(u64, 0), statistics.frames_presented);

    for (0..frame_latency_capacity + 1) |value| statistics.addLatency(.{
        .request_to_presentation_microseconds = value,
        .request_to_render_microseconds = value,
        .render_to_commit_microseconds = value,
        .commit_to_presentation_microseconds = value,
    });
    const rolling = statistics.latencySummary(.request_to_presentation);
    try std.testing.expectEqual(@as(i64, frame_latency_capacity), rolling.samples);
    try std.testing.expectEqual(@as(i64, frame_latency_capacity), rolling.maximum_microseconds);
}

const RoutedKey = struct {
    device_id: NativeInput.DeviceId,
    seat: *Seat,
    key: u32,
};

const RoutedButton = struct {
    source: PointerButtonSource,
    seat: *Seat,
    button: u32,
};

const PointerButtonSource = union(enum) {
    native: NativeInput.DeviceId,
    virtual: u64,
};

const GestureKind = enum { swipe, pinch, hold };

const RoutedGesture = struct {
    device_id: NativeInput.DeviceId,
    seat: *Seat,
    kind: GestureKind,
};

const RoutedTouch = struct {
    device_id: NativeInput.DeviceId,
    native_id: i32,
    seat: *Seat,
    protocol_id: i32,
};

const PointerRoute = struct {
    focus: ?Seat.PointerFocus,
    root: ?Surface.Id,
};

const RenderOutputStore = slot_map.SlotMap(*RenderOutput, enum { render_output });
const RenderOutputId = RenderOutputStore.Id;

const XwaylandWindow = struct {
    scene_id: Scene.Id,
    surface_id: Surface.Id,
};

const RenderOutputConfig = struct {
    kind: OutputBackend.Kind,
    size: render.Size,
    scale: render.Scale = .{},
    position: Output.Position = .{},
    name: []const u8,
    description: []const u8,
    make: []const u8 = "keywork",
    model: []const u8,
    drm_output: ?*DrmOutput = null,
};

const EffectiveOutputSettings = struct {
    enabled: bool,
    mode_index: usize,
    requested_mode: ?Config.OutputMode = null,
    x: i32,
    y: i32,
    scale: render.Scale,
};

pub const VirtualOutputConfig = struct {
    size: render.Size = .{ .width = 1280, .height = 720 },
    scale: render.Scale = .{},
};

const OutputFrame = struct {
    render_output: *RenderOutput,
    output: *Output,
    visible_rect: render.Rect,
    track_visibility: bool,
    presentation_damage: ?*const Region = null,
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    renderer_kind: renderer_types.Renderer.Kind,
    output_kind: OutputBackend.Kind,
    drm_device_path: ?[]const u8,
) !*Self {
    return createWithVirtualOutput(
        allocator,
        io,
        renderer_kind,
        output_kind,
        drm_device_path,
        .{},
    );
}

pub fn createWithVirtualOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    renderer_kind: renderer_types.Renderer.Kind,
    output_kind: OutputBackend.Kind,
    drm_device_path: ?[]const u8,
    virtual_output: VirtualOutputConfig,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const display = try wl.Server.create();
    errdefer display.destroy();
    try display.initShm();

    self.* = .{
        .allocator = allocator,
        .io = io,
        .display = display,
        .control = undefined,
        .control_initialized = false,
        .configuration = null,
        .layer_shell_effects = Scene.default_effects,
        .session = undefined,
        .session_initialized = false,
        .drm_device = undefined,
        .drm_device_initialized = false,
        .native_input = undefined,
        .native_input_initialized = false,
        .input_manager = undefined,
        .input_manager_initialized = false,
        .builtin_keybindings = undefined,
        .builtin_keybindings_initialized = false,
        .render_outputs = .{},
        .primary_render_output = undefined,
        .outputs = undefined,
        .xdg_output = undefined,
        .xdg_output_initialized = false,
        .output_management = undefined,
        .output_management_initialized = false,
        .output_power = undefined,
        .output_power_initialized = false,
        .gamma_control = undefined,
        .gamma_control_initialized = false,
        .drm_lease = undefined,
        .drm_lease_initialized = false,
        .single_pixel_buffer = undefined,
        .content_type = undefined,
        .color_management = undefined,
        .color_representation = undefined,
        .alpha_modifier = undefined,
        .background_effect = undefined,
        .security_context = undefined,
        .session_lock = undefined,
        .session_lock_initialized = false,
        .cursor_shape = undefined,
        .tablet = undefined,
        .relative_pointer = undefined,
        .pointer_gestures = undefined,
        .pointer_constraints = undefined,
        .pointer_warp = undefined,
        .idle_inhibit = undefined,
        .keyboard_shortcuts_inhibit = undefined,
        .idle_notify = undefined,
        .idle_notify_initialized = false,
        .compositor = undefined,
        .subcompositor = undefined,
        .scene = undefined,
        .xdg_shell = undefined,
        .gtk_shell = undefined,
        .xdg_foreign = undefined,
        .layer_shell = undefined,
        .seat = undefined,
        .transient_seat = undefined,
        .input_device_listener = .{
            .context = self,
            .added = inputDeviceAdded,
            .removed = inputDeviceRemoved,
        },
        .routed_keys = .empty,
        .routed_buttons = .empty,
        .routed_gestures = .empty,
        .routed_touches = .empty,
        .next_touch_id = 0,
        .data_device = undefined,
        .xdg_toplevel_drag = undefined,
        .xdg_toplevel_icon = undefined,
        .xdg_dialog = undefined,
        .xdg_system_bell = undefined,
        .xdg_toplevel_tag = undefined,
        .xdg_session_management = undefined,
        .primary_selection = undefined,
        .data_control = undefined,
        .foreign_toplevel_list = undefined,
        .foreign_toplevel_list_initialized = false,
        .image_capture_source = undefined,
        .image_capture_source_initialized = false,
        .image_copy_capture = undefined,
        .image_copy_capture_initialized = false,
        .screencopy = undefined,
        .screencopy_initialized = false,
        .xwayland_keyboard_grab = undefined,
        .xwayland_keyboard_grab_initialized = false,
        .xwayland_shell = undefined,
        .xwayland_shell_initialized = false,
        .xwayland_server = undefined,
        .xwayland_server_initialized = false,
        .xwm = undefined,
        .xwm_initialized = false,
        .xwayland_windows = .empty,
        .xwayland_client_stack = .empty,
        .xwayland_override_redirect_focus = null,
        .workspace = undefined,
        .workspace_initialized = false,
        .text_input = undefined,
        .input_method = undefined,
        .virtual_keyboard = undefined,
        .virtual_pointer = undefined,
        .presentation_protocol = undefined,
        .fractional_scale = undefined,
        .fixes = undefined,
        .linux_dmabuf = undefined,
        .linux_drm_syncobj = undefined,
        .tearing_control = undefined,
        .fifo = undefined,
        .commit_timing = undefined,
        .xdg_activation = undefined,
        .viewporter = undefined,
        .window_manager = undefined,
        .window_manager_initialized = false,
        .renderer = undefined,
        .socket_buffer = undefined,
        .listening = false,
        .xwayland_display_listener = null,
    };
    errdefer self.routed_touches.deinit(allocator);
    errdefer self.routed_gestures.deinit(allocator);
    errdefer self.routed_buttons.deinit(allocator);
    errdefer self.routed_keys.deinit(allocator);
    errdefer self.render_outputs.deinit(allocator);
    errdefer self.xwayland_windows.deinit(allocator);
    errdefer self.xwayland_client_stack.deinit(allocator);
    if (output_kind == .drm) {
        try self.session.init(allocator, display.getEventLoop());
        self.session_initialized = true;
        errdefer self.session.deinit();
        try self.drm_device.init(
            allocator,
            io,
            display.getEventLoop(),
            &self.session,
            drm_device_path,
        );
        self.drm_device_initialized = true;
    }
    self.renderer = renderer_types.Renderer.initForDevice(
        allocator,
        renderer_kind,
        if (output_kind == .drm) self.drm_device.deviceId() else null,
    ) catch |err| {
        if (output_kind == .drm) {
            self.drm_device.deinit();
            self.session.deinit();
        }
        return err;
    };
    errdefer if (output_kind == .drm) self.session.deinit();
    errdefer self.renderer.deinit();
    errdefer if (output_kind == .drm) self.drm_device.deinit();
    try self.compositor.init(allocator, display);
    errdefer self.compositor.deinit();
    try self.security_context.init(allocator, display);
    errdefer self.security_context.deinit();
    self.outputs.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.outputs.deinit();
    try self.color_management.init(allocator, display, &self.outputs);
    errdefer self.color_management.deinit();
    try self.color_representation.init(allocator, display);
    errdefer self.color_representation.deinit();
    try self.alpha_modifier.init(allocator, display);
    errdefer self.alpha_modifier.deinit();
    try self.seat.init(allocator, io, display, "default", self.compositor.surfaceStore());
    errdefer self.seat.deinit();
    try self.transient_seat.init(
        allocator,
        io,
        display,
        self.compositor.surfaceStore(),
        &self.security_context,
    );
    errdefer self.transient_seat.deinit();
    var render_output_id: RenderOutputId = undefined;
    errdefer {
        var it = self.render_outputs.iterator();
        while (it.next()) |entry| std.debug.assert(self.removeRenderOutput(entry.id));
    }
    if (output_kind == .drm) {
        const drm_outputs = self.drm_device.outputs();
        if (drm_outputs.len == 0) return error.NoConnectedOutput;
        var x: i32 = 0;
        for (drm_outputs, 0..) |drm_output, index| {
            std.debug.assert(drm_output.enabled);
            drm_output.logical_x = x;
            drm_output.logical_y = 0;
            const id = try self.addRenderOutput(io, .{ .kind = .drm, .size = drm_output.size, .position = .{ .x = x }, .name = "DRM", .description = "Keywork DRM output", .model = "drm-kms", .drm_output = drm_output });
            if (index == 0) render_output_id = id;
            x += @intCast(drm_output.logicalSize().width);
        }
    } else render_output_id = try self.addRenderOutput(io, .{
        .kind = output_kind,
        .size = virtual_output.size,
        .scale = virtual_output.scale,
        .name = if (output_kind == .headless) "HEADLESS-1" else "NESTED-1",
        .description = if (output_kind == .headless) "Keywork headless output" else "Keywork nested output",
        .model = if (output_kind == .headless) "headless" else "nested-wayland",
    });
    self.primary_render_output = render_output_id;
    const render_output = self.render_outputs.get(render_output_id).?.*;
    try self.xdg_output.init(allocator, display, &self.outputs);
    self.xdg_output_initialized = true;
    errdefer {
        self.xdg_output.deinit();
        self.xdg_output_initialized = false;
    }
    if (output_kind == .drm) {
        try self.output_management.init(
            allocator,
            display,
            self.drm_device.outputs(),
            &self.security_context,
            .{ .context = self, .apply = applyOutputConfiguration },
        );
        self.output_management_initialized = true;
        errdefer {
            self.output_management.deinit();
            self.output_management_initialized = false;
        }
        try self.output_power.init(
            allocator,
            display,
            &self.outputs,
            &self.security_context,
            .{
                .context = self,
                .powered = outputPowerState,
                .set_powered = setOutputPowerState,
            },
        );
        self.output_power_initialized = true;
        errdefer {
            self.output_power.deinit();
            self.output_power_initialized = false;
        }
        try self.gamma_control.init(
            allocator,
            display,
            &self.outputs,
            &self.security_context,
            .{
                .context = self,
                .gamma_size = outputGammaSize,
                .set_gamma = setOutputGamma,
                .reset_gamma = resetOutputGamma,
            },
        );
        self.gamma_control_initialized = true;
        errdefer {
            self.gamma_control.deinit();
            self.gamma_control_initialized = false;
        }
        try self.drm_lease.init(
            allocator,
            display,
            &self.security_context,
            self.drm_device.outputs(),
            .{
                .context = self,
                .open_fd = openDrmLeaseDevice,
                .grant = grantDrmLease,
                .revoke = revokeDrmLease,
            },
        );
        self.drm_lease_initialized = true;
        errdefer {
            self.drm_lease.deinit();
            self.drm_lease_initialized = false;
        }
    }
    try self.single_pixel_buffer.init(allocator, display);
    errdefer self.single_pixel_buffer.deinit();
    try self.content_type.init(allocator, display);
    errdefer self.content_type.deinit();
    try self.background_effect.init(allocator, display);
    errdefer self.background_effect.deinit();
    try self.session_lock.init(
        allocator,
        display,
        &self.outputs,
        self.compositor.surfaceStore(),
        &self.security_context,
        .{
            .context = self,
            .state_changed = sessionLockStateChanged,
            .output_secure_without_frame = outputSecureWithoutFrame,
            .repaint = requestRepaint,
        },
    );
    self.session_lock_initialized = true;
    errdefer {
        self.session_lock.deinit();
        self.session_lock_initialized = false;
    }
    try self.tablet.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        .{
            .context = self,
            .surface_coordinates = tabletSurfaceCoordinates,
            .repaint = requestRepaint,
        },
    );
    errdefer self.tablet.deinit();
    try self.cursor_shape.init(allocator, display, &self.tablet, .{
        .context = self,
        .clear_shapes = clearCursorShapes,
    });
    errdefer self.cursor_shape.deinit();
    self.seat.setDefaultCursor(self.cursor_shape.defaultCursor());
    try self.relative_pointer.init(allocator, display, &self.seat);
    errdefer self.relative_pointer.deinit();
    try self.pointer_gestures.init(allocator, display);
    errdefer self.pointer_gestures.deinit();
    try self.pointer_constraints.init(
        allocator,
        display,
        &self.seat,
        self.compositor.surfaceStore(),
    );
    errdefer self.pointer_constraints.deinit();
    try self.pointer_warp.init(
        display,
        &self.seat,
        self.compositor.surfaceStore(),
        .{ .context = self, .warp = pointerWarp },
    );
    errdefer self.pointer_warp.deinit();
    try self.idle_inhibit.init(allocator, display, .{
        .context = self,
        .changed = idleInhibitorsChanged,
    });
    errdefer self.idle_inhibit.deinit();
    try self.keyboard_shortcuts_inhibit.init(allocator, display);
    errdefer self.keyboard_shortcuts_inhibit.deinit();
    try self.presentation_protocol.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        render_output.backend.presentationClockId(),
    );
    errdefer self.presentation_protocol.deinit();
    try self.viewporter.init(allocator, display);
    errdefer self.viewporter.deinit();
    try self.fractional_scale.init(
        allocator,
        display,
        &self.outputs,
        render_output.protocol_id,
    );
    errdefer self.fractional_scale.deinit();
    try self.fixes.init(display);
    errdefer self.fixes.deinit();
    try self.linux_dmabuf.init(
        allocator,
        io,
        display,
        self.renderer.dmabufDeviceId(),
        if (output_kind == .drm) self.drm_device.deviceId() else null,
    );
    errdefer self.linux_dmabuf.deinit();
    try self.linux_drm_syncobj.init(
        allocator,
        io,
        display,
        self.renderer.dmabufDeviceId(),
    );
    errdefer self.linux_drm_syncobj.deinit();
    try self.tearing_control.init(allocator, display);
    errdefer self.tearing_control.deinit();
    try self.fifo.init(allocator, display);
    errdefer self.fifo.deinit();
    try self.commit_timing.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        render_output.backend.presentationClockId(),
        .{ .context = self, .failed = commitTimingFailed },
    );
    errdefer self.commit_timing.deinit();
    try self.subcompositor.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.subcompositor.deinit();
    self.scene.init(allocator);
    errdefer self.scene.deinit();
    try self.idle_notify.init(allocator, io, display, .{
        .context = self,
        .failed = idleNotifyFailed,
    });
    self.idle_notify_initialized = true;
    errdefer {
        self.idle_notify.deinit();
        self.idle_notify_initialized = false;
    }
    try self.gtk_shell.init(allocator, display, &self.seat);
    errdefer self.gtk_shell.deinit();
    try self.xdg_shell.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        &self.subcompositor,
        &self.scene,
        &self.seat,
        &self.outputs,
        render_output.protocol_id,
        &self.gtk_shell,
    );
    errdefer self.xdg_shell.deinit();
    try self.xdg_foreign.init(allocator, io, display, &self.xdg_shell);
    errdefer self.xdg_foreign.deinit();
    try self.layer_shell.init(
        allocator,
        display,
        &self.outputs,
        render_output.protocol_id,
        &self.scene,
        &self.seat,
        &self.xdg_shell,
        self.compositor.surfaceStore(),
    );
    errdefer self.layer_shell.deinit();
    try self.xdg_activation.init(allocator, io, display, &self.seat);
    errdefer self.xdg_activation.deinit();
    try self.data_device.init(
        allocator,
        display,
        &self.seat,
        self.compositor.surfaceStore(),
        .{
            .context = self,
            .started = dragStarted,
            .ended = dragEnded,
            .external_source_destroyed = dragExternalSourceDestroyed,
            .repaint = requestRepaint,
        },
    );
    errdefer self.data_device.deinit();
    try self.primary_selection.init(allocator, display, &self.seat);
    errdefer self.primary_selection.deinit();
    try self.data_control.init(
        allocator,
        display,
        &self.security_context,
        &self.seat,
        &self.data_device,
        &self.primary_selection,
    );
    errdefer self.data_control.deinit();
    try self.text_input.init(
        allocator,
        display,
        &self.seat,
        self.compositor.surfaceStore(),
    );
    errdefer self.text_input.deinit();
    try self.input_method.init(
        allocator,
        display,
        &self.security_context,
        &self.seat,
        self.compositor.surfaceStore(),
        &self.text_input,
        .{
            .context = self,
            .surface_position = inputMethodSurfacePosition,
            .output_size = inputMethodOutputSize,
            .repaint = requestRepaint,
        },
    );
    errdefer self.input_method.deinit();
    try self.virtual_keyboard.init(
        allocator,
        io,
        display,
        &self.security_context,
        &self.seat,
        &self.transient_seat,
    );
    errdefer self.virtual_keyboard.deinit();
    try self.virtual_pointer.init(
        allocator,
        display,
        &self.security_context,
        &self.seat,
        &self.transient_seat,
        &self.outputs,
        .{ .context = self, .event = virtualPointerEvent },
    );
    errdefer self.virtual_pointer.deinit();
    try self.workspace.init(allocator, display, &self.security_context, &self.outputs);
    self.workspace_initialized = true;
    errdefer {
        self.workspace.deinit();
        self.workspace_initialized = false;
    }
    try self.window_manager.init(
        allocator,
        display,
        &self.outputs,
        render_output.protocol_id,
        &self.scene,
        &self.xdg_shell,
        .{
            .context = self,
            .window_info = xwaylandWindowInfo,
            .resize = resizeXwaylandWindow,
            .move = moveXwaylandWindow,
            .set_fullscreen = setXwaylandWindowFullscreen,
            .set_maximized = setXwaylandWindowMaximized,
            .set_minimized = setXwaylandWindowMinimized,
            .close = closeXwaylandWindow,
            .refresh_scene = refreshXwaylandScene,
            .stacking_changed = xwaylandStackingChanged,
        },
        &self.layer_shell,
        &self.workspace,
    );
    self.window_manager_initialized = true;
    errdefer {
        self.window_manager.deinit();
        self.window_manager_initialized = false;
    }
    try self.xdg_toplevel_drag.init(
        allocator,
        display,
        &self.data_device,
        &self.xdg_shell,
        &self.seat,
        .{
            .context = self,
            .begin = xdgToplevelDragBegin,
            .motion = xdgToplevelDragMotion,
            .end = xdgToplevelDragEnd,
        },
    );
    errdefer self.xdg_toplevel_drag.deinit();
    try self.xdg_toplevel_icon.init(allocator, display, &self.xdg_shell);
    errdefer self.xdg_toplevel_icon.deinit();
    try self.xdg_dialog.init(allocator, display, &self.xdg_shell);
    errdefer self.xdg_dialog.deinit();
    try self.xdg_system_bell.init(display);
    errdefer self.xdg_system_bell.deinit();
    try self.xdg_toplevel_tag.init(display, &self.xdg_shell);
    errdefer self.xdg_toplevel_tag.deinit();
    try self.xdg_session_management.init(
        allocator,
        io,
        display,
        &self.xdg_shell,
        &self.window_manager,
    );
    errdefer self.xdg_session_management.deinit();
    self.workspace.setActivationListener(.{
        .context = self,
        .activate = workspaceActivationRequested,
    });
    errdefer self.workspace.clearActivationListener();
    try self.foreign_toplevel_list.init(
        allocator,
        display,
        &self.security_context,
        &self.xdg_shell,
        .{
            .context = self,
            .window_info = xwaylandWindowInfo,
            .close = closeXwaylandWindow,
            .request_activation = requestXwaylandWindowActivation,
            .request_fullscreen = requestXwaylandWindowFullscreen,
            .request_maximized = requestXwaylandWindowMaximized,
            .request_minimized = requestXwaylandWindowMinimized,
        },
        &self.outputs,
    );
    self.foreign_toplevel_list_initialized = true;
    errdefer {
        self.foreign_toplevel_list.deinit();
        self.foreign_toplevel_list_initialized = false;
    }
    try self.image_capture_source.init(
        allocator,
        display,
        &self.security_context,
        &self.outputs,
        &self.foreign_toplevel_list,
        &self.xdg_shell,
    );
    self.image_capture_source_initialized = true;
    errdefer {
        self.image_capture_source.deinit();
        self.image_capture_source_initialized = false;
    }
    try self.image_copy_capture.init(
        allocator,
        display,
        &self.security_context,
        &self.image_capture_source,
        &self.linux_dmabuf,
        .{
            .context = self,
            .constraints = captureConstraints,
            .capture = captureImage,
            .cursor_info = captureCursorInfo,
        },
    );
    self.image_copy_capture_initialized = true;
    errdefer {
        self.image_copy_capture.deinit();
        self.image_copy_capture_initialized = false;
    }
    try self.screencopy.init(
        allocator,
        display,
        &self.security_context,
        &self.outputs,
        &self.linux_dmabuf,
        .{
            .context = self,
            .constraints = screencopyConstraints,
            .capture = captureScreencopy,
        },
    );
    self.screencopy_initialized = true;
    errdefer {
        self.screencopy.deinit();
        self.screencopy_initialized = false;
    }
    try self.xwayland_shell.init(
        allocator,
        display,
        &self.security_context,
        .{
            .context = self,
            .associated = xwaylandSurfaceAssociated,
            .committed = xwaylandSurfaceCommitted,
            .removed = xwaylandSurfaceRemoved,
        },
    );
    self.xwayland_shell_initialized = true;
    errdefer {
        self.xwayland_shell.deinit();
        self.xwayland_shell_initialized = false;
    }
    try self.xwayland_keyboard_grab.init(allocator, display, &self.security_context);
    self.xwayland_keyboard_grab_initialized = true;
    errdefer {
        self.xwayland_keyboard_grab.deinit();
        self.xwayland_keyboard_grab_initialized = false;
    }
    self.xwayland_server.init(
        allocator,
        display,
        &self.xwayland_shell,
        &self.xwayland_keyboard_grab,
        .{
            .context = self,
            .ready = xwaylandReady,
            .stopped = xwaylandStopped,
            .unavailable = xwaylandUnavailable,
        },
    );
    self.xwayland_server_initialized = true;
    errdefer {
        self.xwayland_server.deinit();
        self.xwayland_server_initialized = false;
    }
    self.subcompositor.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
        .surface_changed = surfaceChanged,
    });
    self.scene.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
        .surface_changed = surfaceChanged,
    });
    self.seat.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
        .cursor_moved = cursorMoved,
    });
    self.layer_shell.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
    });
    if (output_kind == .drm) {
        try self.native_input.init(
            allocator,
            io,
            display.getEventLoop(),
            &self.session,
            render_output.backend.size(),
            nativeInputListener(render_output),
        );
        self.native_input_initialized = true;
        errdefer {
            self.native_input.deinit();
            self.native_input_initialized = false;
        }
    }
    const native_input = if (self.native_input_initialized) &self.native_input else null;
    try self.input_manager.init(allocator, native_input);
    self.input_manager_initialized = true;
    errdefer {
        self.input_manager.detachNativeInput();
        self.input_manager.deinit();
        self.input_manager_initialized = false;
    }
    try self.input_manager.addDeviceListener(&self.input_device_listener);
    errdefer self.input_manager.removeDeviceListener(&self.input_device_listener);
    try self.builtin_keybindings.init(
        allocator,
        self.display,
        &self.window_manager,
        &self.input_manager,
        &self.keyboard_shortcuts_inhibit,
        native_input,
    );
    self.builtin_keybindings_initialized = true;
    errdefer {
        self.builtin_keybindings.deinit();
        self.builtin_keybindings_initialized = false;
    }
    requestRepaint(self);

    if (output_kind == .drm) self.drm_device.setListener(.{
        .context = self,
        .added = drmOutputAdded,
        .removing = drmOutputRemoving,
        .failed = drmDeviceFailed,
        .activated = drmDeviceActivated,
        .deactivating = drmDeviceDeactivating,
        .lease_revoked = drmLeaseRevoked,
    });

    return self;
}

pub fn configureXdgSessionStorage(
    self: *Self,
    runtime_directory: []const u8,
    instance_name: []const u8,
) !void {
    try self.xdg_session_management.configureStorage(runtime_directory, instance_name);
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    if (self.control_initialized) {
        self.control.deinit();
        self.control_initialized = false;
    }
    if (self.drm_lease_initialized) self.drm_lease.@"suspend"();
    if (self.drm_device_initialized) self.drm_device.clearListener();
    self.data_device.cancel();
    if (self.builtin_keybindings_initialized) self.builtin_keybindings.detachNativeInput();
    if (self.input_manager_initialized) {
        self.input_manager.detachNativeInput();
        self.input_manager.removeDeviceListener(&self.input_device_listener);
    }
    if (self.native_input_initialized) self.native_input.deinit();
    self.layer_shell.clearRepaintListener();
    self.seat.clearRepaintListener();
    self.scene.clearRepaintListener();
    self.subcompositor.clearRepaintListener();
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| stopRenderOutput(entry.value.*);
    self.display.destroyClients();
    if (self.drm_device_initialized) self.drm_device.releaseClientBuffers();
    if (self.builtin_keybindings_initialized) {
        self.builtin_keybindings.deinit();
        self.builtin_keybindings_initialized = false;
    }
    if (self.configuration) |*configuration| {
        configuration.deinit();
        self.configuration = null;
    }
    if (self.input_manager_initialized) {
        self.input_manager.deinit();
        self.input_manager_initialized = false;
    }
    if (self.drm_lease_initialized) {
        self.drm_lease.deinit();
        self.drm_lease_initialized = false;
    }
    if (self.gamma_control_initialized) {
        self.gamma_control.deinit();
        self.gamma_control_initialized = false;
    }
    if (self.output_power_initialized) {
        self.output_power.deinit();
        self.output_power_initialized = false;
    }
    if (self.output_management_initialized) {
        self.output_management.deinit();
        self.output_management_initialized = false;
    }
    self.xwayland_server.deinit();
    self.xwayland_server_initialized = false;
    std.debug.assert(self.xwayland_windows.count() == 0);
    self.xwayland_windows.deinit(allocator);
    self.xwayland_client_stack.deinit(allocator);
    self.xwayland_keyboard_grab.deinit();
    self.xwayland_keyboard_grab_initialized = false;
    self.xwayland_shell.deinit();
    self.xwayland_shell_initialized = false;
    self.screencopy.deinit();
    self.screencopy_initialized = false;
    self.image_copy_capture.deinit();
    self.image_copy_capture_initialized = false;
    self.image_capture_source.deinit();
    self.image_capture_source_initialized = false;
    self.foreign_toplevel_list.deinit();
    self.foreign_toplevel_list_initialized = false;
    self.workspace.clearActivationListener();
    self.xdg_session_management.deinit();
    self.xdg_toplevel_tag.deinit();
    self.xdg_system_bell.deinit();
    self.xdg_dialog.deinit();
    self.xdg_toplevel_icon.deinit();
    self.xdg_toplevel_drag.deinit();
    self.window_manager.deinit();
    self.window_manager_initialized = false;
    self.workspace.deinit();
    self.workspace_initialized = false;
    self.virtual_pointer.deinit();
    self.virtual_keyboard.deinit();
    self.transient_seat.deinit();
    self.input_method.deinit();
    self.text_input.deinit();
    self.data_control.deinit();
    self.primary_selection.deinit();
    self.data_device.deinit();
    self.xdg_activation.deinit();
    self.idle_notify.deinit();
    self.idle_notify_initialized = false;
    self.layer_shell.deinit();
    self.xdg_foreign.deinit();
    self.xdg_shell.deinit();
    self.gtk_shell.deinit();
    self.scene.deinit();
    self.subcompositor.deinit();
    self.commit_timing.deinit();
    self.fifo.deinit();
    self.tearing_control.deinit();
    self.linux_drm_syncobj.deinit();
    self.linux_dmabuf.deinit();
    self.fixes.deinit();
    self.fractional_scale.deinit();
    self.viewporter.deinit();
    self.presentation_protocol.deinit();
    self.keyboard_shortcuts_inhibit.deinit();
    self.idle_inhibit.deinit();
    self.pointer_warp.deinit();
    self.pointer_constraints.deinit();
    self.pointer_gestures.deinit();
    self.relative_pointer.deinit();
    self.cursor_shape.deinit();
    self.tablet.deinit();
    self.session_lock.deinit();
    self.session_lock_initialized = false;
    self.security_context.deinit();
    self.background_effect.deinit();
    self.content_type.deinit();
    self.single_pixel_buffer.deinit();
    self.xdg_output.deinit();
    self.xdg_output_initialized = false;
    render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        std.debug.assert(self.removeRenderOutput(entry.id));
    }
    self.alpha_modifier.deinit();
    self.color_representation.deinit();
    self.color_management.deinit();
    self.outputs.deinit();
    self.render_outputs.deinit(allocator);
    self.routed_touches.deinit(allocator);
    self.routed_gestures.deinit(allocator);
    self.routed_buttons.deinit(allocator);
    self.routed_keys.deinit(allocator);
    self.seat.deinit();
    self.compositor.deinit();
    if (self.drm_device_initialized) self.drm_device.deinit();
    if (self.session_initialized) self.session.deinit();
    self.renderer.deinit();
    self.display.destroy();
    allocator.destroy(self);
}

fn addRenderOutput(
    self: *Self,
    io: std.Io,
    config: RenderOutputConfig,
) !RenderOutputId {
    const render_output = try self.allocator.create(RenderOutput);
    errdefer self.allocator.destroy(render_output);
    render_output.* = .{
        .server = self,
        .backend = undefined,
        .protocol_id = undefined,
        .timer = null,
        .repaint_idle = null,
        .damage = Region.init(),
        .damage_rectangles = .empty,
        .repaint_needed = false,
        .render_scheduled = false,
        .lock_frame_pending = false,
        .frame_statistics = .{},
        .request_started_nanoseconds = null,
        .pending_frame = null,
    };
    errdefer render_output.damage.deinit();
    errdefer render_output.damage_rectangles.deinit(self.allocator);
    try render_output.backend.init(
        self.allocator,
        io,
        self.display,
        config.size,
        config.scale,
        config.kind,
        config.drm_output,
        backendListener(render_output),
        self.renderer.dmabufAccess(),
        self.renderer.offscreenAccess(),
    );
    errdefer render_output.backend.deinit();
    render_output.protocol_id = try self.outputs.add(.{
        .position = config.position,
        .size = render_output.backend.size(),
        .mode_size = render_output.backend.modeSize(),
        .physical_size = render_output.backend.physicalSize(),
        .mode_preferred = render_output.backend.modePreferred(),
        .refresh_millihertz = render_output.backend.refreshMillihertz(),
        .scale = render_output.backend.clientScale(),
        .preferred_scale = render_output.backend.renderScale(),
        .name = render_output.backend.name(config.name),
        .description = render_output.backend.description(config.description),
        .make = render_output.backend.make(config.make),
        .model = render_output.backend.model(config.model),
    });
    errdefer std.debug.assert(self.outputs.remove(render_output.protocol_id));
    if (render_output.backend.repaintDelayMilliseconds() != null) {
        render_output.timer = try self.display.getEventLoop().addTimer(
            *RenderOutput,
            handleRenderTimer,
            render_output,
        );
    }
    errdefer stopRenderOutput(render_output);
    const id = try self.render_outputs.insert(self.allocator, render_output);
    errdefer std.debug.assert(self.render_outputs.remove(id) != null);
    if (self.workspace_initialized) try self.workspace.addOutput(render_output.protocol_id);
    errdefer if (self.workspace_initialized) self.workspace.removeOutput(render_output.protocol_id);
    if (self.window_manager_initialized) {
        try self.window_manager.outputAdded(render_output.protocol_id);
    }
    if (self.session_lock_initialized) self.session_lock.refreshOutputs();
    self.damageFullOutput(render_output);
    return id;
}

fn backendListener(render_output: *RenderOutput) OutputBackend.Listener {
    return .{
        .context = render_output,
        .ready = outputReady,
        .presented = outputPresented,
        .discarded = outputDiscarded,
        .close = closeOutput,
        .keyboard_available = keyboardAvailable,
        .keyboard_keymap = keyboardKeymap,
        .keyboard_enter = keyboardEnter,
        .keyboard_leave = keyboardLeave,
        .keyboard_key = keyboardKey,
        .keyboard_modifiers = keyboardModifiers,
        .keyboard_repeat_info = keyboardRepeatInfo,
        .pointer_available = pointerAvailable,
        .pointer_enter = pointerEnter,
        .pointer_leave = pointerLeave,
        .pointer_motion = pointerMotion,
        .pointer_relative_motion = pointerRelativeMotion,
        .pointer_button = pointerButton,
        .pointer_axis = pointerAxis,
        .pointer_frame = pointerFrame,
        .pointer_axis_source = pointerAxisSource,
        .pointer_axis_stop = pointerAxisStop,
        .pointer_axis_discrete = pointerAxisDiscrete,
        .pointer_axis_value120 = pointerAxisValue120,
        .pointer_axis_relative_direction = pointerAxisRelativeDirection,
        .touch_available = touchAvailable,
        .touch_down = touchDown,
        .touch_up = touchUp,
        .touch_motion = touchMotion,
        .touch_frame = touchFrame,
        .touch_cancel = touchCancel,
        .touch_shape = touchShape,
        .touch_orientation = touchOrientation,
    };
}

fn nativeInputListener(render_output: *RenderOutput) NativeInput.Listener {
    return .{
        .context = render_output,
        .close = closeOutput,
        .keyboard_available = keyboardAvailable,
        .keyboard_keymap = nativeKeyboardKeymap,
        .keyboard_enter = keyboardEnter,
        .keyboard_key = nativeKeyboardKey,
        .keyboard_modifiers = nativeKeyboardModifiers,
        .keyboard_repeat_info = nativeKeyboardRepeatInfo,
        .pointer_available = pointerAvailable,
        .pointer_motion = nativePointerMotion,
        .pointer_relative_motion = nativePointerRelativeMotion,
        .pointer_button = nativePointerButton,
        .pointer_axis = nativePointerAxis,
        .pointer_frame = nativePointerFrame,
        .pointer_axis_source = nativePointerAxisSource,
        .pointer_axis_stop = nativePointerAxisStop,
        .pointer_axis_discrete = nativePointerAxisDiscrete,
        .pointer_axis_value120 = nativePointerAxisValue120,
        .swipe_begin = nativeSwipeBegin,
        .swipe_update = nativeSwipeUpdate,
        .swipe_end = nativeSwipeEnd,
        .pinch_begin = nativePinchBegin,
        .pinch_update = nativePinchUpdate,
        .pinch_end = nativePinchEnd,
        .hold_begin = nativeHoldBegin,
        .hold_end = nativeHoldEnd,
        .tablet_tool_proximity = nativeTabletToolProximity,
        .tablet_tool_axis = nativeTabletToolAxis,
        .tablet_tool_tip = nativeTabletToolTip,
        .tablet_tool_button = nativeTabletToolButton,
        .tablet_pad_button = nativeTabletPadButton,
        .tablet_pad_ring = nativeTabletPadRing,
        .tablet_pad_strip = nativeTabletPadStrip,
        .tablet_pad_dial = nativeTabletPadDial,
        .touch_available = touchAvailable,
        .touch_down = nativeTouchDown,
        .touch_up = nativeTouchUp,
        .touch_motion = nativeTouchMotion,
        .touch_frame = nativeTouchFrame,
        .touch_cancel = nativeTouchCancel,
    };
}

fn inputDeviceAdded(context: *anyopaque, device: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.configuration) |*configuration| {
        self.applyPhysicalInputConfiguration(device.physical_id, configuration.snapshot.input_rules);
    }
    const seat = &self.seat;
    if (device.device_type == .tablet) {
        const info = self.native_input.tabletInfo(device.id) orelse return;
        self.tablet.addTablet(
            device.id,
            device.physical_id,
            seat,
            device.name,
            info,
        ) catch return self.terminate();
    }
    if (device.device_type == .tablet_pad) {
        const info = self.native_input.tabletPadInfo(device.id) orelse return;
        self.tablet.addPad(device.id, device.physical_id, seat, info) catch return self.terminate();
    }
    self.refreshSeatCapabilities();
    if (device.device_type == .keyboard) self.prepareSeatKeyboard(seat, device.id);
}

fn inputDeviceRemoved(context: *anyopaque, device: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (device.device_type == .keyboard) self.releaseDeviceKeys(device.id);
    if (device.device_type == .pointer) {
        self.releaseDeviceButtons(device.id);
        self.cancelDeviceGestures(device.id);
    }
    if (device.device_type == .tablet) self.tablet.removeTablet(device.id);
    if (device.device_type == .tablet_pad) self.tablet.removePad(device.id);
    if (device.device_type == .touch) self.cancelDeviceTouches(device.id);
    self.refreshSeatCapabilities();
    if (device.device_type == .keyboard) self.prepareAnySeatKeyboard();
}

fn seatForDevice(self: *Self, _: NativeInput.DeviceId) *Seat {
    return &self.seat;
}

fn refreshSeatCapabilities(self: *Self) void {
    var keyboard = false;
    var pointer = false;
    var touch = false;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        switch (device.device_type) {
            .keyboard => keyboard = true,
            .pointer => pointer = true,
            .touch => touch = true,
            .tablet, .tablet_pad => {},
        }
    }
    if (!pointer and !self.seat.hasVirtualPointers()) {
        self.pointer_constraints.deactivateAll();
        self.data_device.cancel();
    }
    self.seat.setKeyboardAvailable(keyboard);
    self.seat.setPointerAvailable(pointer);
    self.seat.setTouchAvailable(touch);
}

fn prepareAnySeatKeyboard(self: *Self) void {
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        if (device.device_type != .keyboard) continue;
        self.prepareSeatKeyboard(&self.seat, device.id);
        return;
    }
    self.seat.setModifiers(0, 0, 0, 0);
}

fn prepareSeatKeyboard(self: *Self, seat: *Seat, id: NativeInput.DeviceId) void {
    const state = self.native_input.keyboardState(id) orelse return;
    const fd = self.native_input.duplicateKeyboardKeymapFd(id) catch {
        log.err("failed to duplicate keymap for input seat", .{});
        return self.terminate();
    } orelse return;
    seat.setKeymap(.xkb_v1, fd, state.keymap.size);
    if (self.native_input.deviceModifiers(id)) |modifiers| {
        seat.setModifiers(
            modifiers.depressed,
            modifiers.latched,
            modifiers.locked,
            modifiers.group,
        );
    }
}

fn removeRenderOutput(self: *Self, id: RenderOutputId) bool {
    const render_output = (self.render_outputs.get(id) orelse return false).*;
    if (self.gamma_control_initialized) self.gamma_control.removeOutput(render_output.protocol_id);
    const removed = self.render_outputs.remove(id) orelse unreachable;
    std.debug.assert(removed == render_output);
    stopRenderOutput(render_output);
    const protocol_output = self.outputs.get(render_output.protocol_id).?;
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.removeOutput(render_output.protocol_id);
    }
    if (self.image_capture_source_initialized) {
        self.image_capture_source.removeOutput(render_output.protocol_id);
    }
    if (self.screencopy_initialized) self.screencopy.removeOutput(render_output.protocol_id);
    if (self.output_power_initialized) self.output_power.removeOutput(render_output.protocol_id);
    if (self.window_manager_initialized) {
        self.window_manager.outputRemoved(render_output.protocol_id) catch self.terminate();
    }
    if (self.workspace_initialized) self.workspace.removeOutput(render_output.protocol_id);
    Surface.discardPresentation(self.compositor.surfaceStore(), protocol_output);
    Surface.clearFifoBarriersForOutput(self.compositor.surfaceStore(), protocol_output);
    if (self.xdg_output_initialized) self.xdg_output.removeOutput(protocol_output);
    self.color_management.removeOutput(protocol_output);
    std.debug.assert(self.outputs.remove(render_output.protocol_id));
    if (self.session_lock_initialized) {
        self.session_lock.outputRemoved(render_output.protocol_id);
        self.session_lock.refreshOutputs();
    }
    render_output.backend.deinit();
    render_output.damage.deinit();
    render_output.damage_rectangles.deinit(self.allocator);
    self.allocator.destroy(render_output);
    return true;
}

fn drmOutputAdded(context: *anyopaque, drm_output: *DrmOutput) void {
    const self: *Self = @ptrCast(@alignCast(context));
    var right: i32 = 0;
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| {
        const output = entry.value.*;
        const protocol_output = self.outputs.get(output.protocol_id).?;
        const position = protocol_output.logicalPosition();
        right = @max(right, position.x + @as(i32, @intCast(protocol_output.logicalSize().width)));
    }
    drm_output.logical_x = right;
    drm_output.logical_y = 0;
    if (drm_output.enabled) {
        _ = self.addRenderOutput(self.native_input.io, .{
            .kind = .drm,
            .size = drm_output.size,
            .position = .{ .x = right },
            .name = "DRM",
            .description = "Keywork DRM output",
            .model = "drm-kms",
            .drm_output = drm_output,
        }) catch return self.terminate();
    }
    if (self.output_management_initialized) {
        self.output_management.addHead(drm_output) catch return self.terminate();
        if (self.configuration) |*configuration| {
            self.applyConfiguredOutputs(configuration.snapshot.output_rules, drm_output) catch |err| {
                log.warn("failed to apply configuration for hotplugged output {s}: {t}", .{
                    drm_output.name(), err,
                });
            };
        }
    }
    if (self.drm_lease_initialized) {
        self.drm_lease.addConnector(drm_output) catch return self.terminate();
    }
    requestRepaint(self);
}

fn findDrmRenderOutput(self: *Self, drm_output: *DrmOutput) ?struct {
    id: RenderOutputId,
    output: *RenderOutput,
} {
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.*.backend.drmOutput() != drm_output) continue;
        return .{ .id = entry.id, .output = entry.value.* };
    }
    return null;
}

fn findProtocolRenderOutput(self: *Self, output_id: OutputLayout.Id) ?*RenderOutput {
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.*.protocol_id, output_id)) return entry.value.*;
    }
    return null;
}

fn outputPowerState(context: *anyopaque, output_id: OutputLayout.Id) ?bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return null;
    const drm_output = render_output.backend.drmOutput() orelse return null;
    return drm_output.powered;
}

fn setOutputPowerState(context: *anyopaque, output_id: OutputLayout.Id, powered: bool) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return false;
    const drm_output = render_output.backend.drmOutput() orelse return false;
    self.drm_device.setOutputPowered(drm_output, powered) catch |err| {
        log.warn("failed to set output {s} power state: {t}", .{ drm_output.name(), err });
        return false;
    };
    if (!powered) render_output.repaint_needed = false;
    requestRepaint(self);
    if (!powered) self.session_lock.refreshSecurity();
    return true;
}

fn outputGammaSize(context: *anyopaque, output_id: OutputLayout.Id) ?u32 {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return null;
    const drm_output = render_output.backend.drmOutput() orelse return null;
    return drm_output.gammaSize();
}

fn setOutputGamma(context: *anyopaque, output_id: OutputLayout.Id, table: []const u16) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return false;
    const drm_output = render_output.backend.drmOutput() orelse return false;
    drm_output.setGamma(table) catch |err| {
        log.warn("failed to set gamma ramps on {s}: {t}", .{ drm_output.name(), err });
        return false;
    };
    return true;
}

fn resetOutputGamma(context: *anyopaque, output_id: OutputLayout.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return;
    const drm_output = render_output.backend.drmOutput() orelse return;
    drm_output.resetGamma();
}

fn outputSecureWithoutFrame(context: *anyopaque, output_id: OutputLayout.Id) bool {
    return outputPowerState(context, output_id) == false;
}

fn setDrmOutputConfiguration(
    self: *Self,
    drm_output: *DrmOutput,
    position: Output.Position,
    scale: render.Scale,
) void {
    const position_changed = drm_output.logical_x != position.x or drm_output.logical_y != position.y;
    const scale_changed = drm_output.scale.numerator != scale.numerator;
    drm_output.logical_x = position.x;
    drm_output.logical_y = position.y;
    drm_output.scale = scale;
    const render_output = self.findDrmRenderOutput(drm_output) orelse return;
    const protocol_output = self.outputs.get(render_output.output.protocol_id).?;
    const old_logical_size = protocol_output.logicalSize();
    protocol_output.setPosition(position);
    const mode_changed = protocol_output.setMode(
        render_output.output.backend.size(),
        render_output.output.backend.modeSize(),
        drm_output.refreshMillihertz(),
        render_output.output.backend.modePreferred(),
    );
    protocol_output.setScale(
        render_output.output.backend.size(),
        render_output.output.backend.clientScale(),
        render_output.output.backend.renderScale(),
    );
    const dimensions_changed = !std.meta.eql(old_logical_size, protocol_output.logicalSize());
    const logical_size = render_output.output.backend.size();
    log.info(
        "configured {s} at {d},{d}: logical {d}x{d}, scale {d}/{d}",
        .{
            drm_output.name(),
            position.x,
            position.y,
            logical_size.width,
            logical_size.height,
            scale.numerator,
            render.Scale.denominator,
        },
    );
    self.xdg_output.refresh(protocol_output);
    self.window_manager.outputStateChanged(
        render_output.output.protocol_id,
        position_changed,
        dimensions_changed,
    );
    if ((scale_changed or mode_changed) and std.meta.eql(render_output.id, self.primary_render_output) and
        self.native_input_initialized)
    {
        self.native_input.retarget(
            render_output.output.backend.size(),
            nativeInputListener(render_output.output),
        );
    }
    if (position_changed or dimensions_changed) {
        self.layer_shell.refresh();
        self.session_lock.refreshOutputs();
    }
}

fn enableDrmOutput(self: *Self, drm_output: *DrmOutput, position: Output.Position) !void {
    if (drm_output.enabled) {
        self.setDrmOutputConfiguration(drm_output, position, drm_output.scale);
        return;
    }
    try self.drm_device.setOutputEnabled(drm_output, true);
    errdefer self.drm_device.setOutputEnabled(drm_output, false) catch {};
    drm_output.logical_x = position.x;
    drm_output.logical_y = position.y;
    _ = try self.addRenderOutput(self.native_input.io, .{
        .kind = .drm,
        .size = drm_output.size,
        .position = position,
        .name = "DRM",
        .description = "Keywork DRM output",
        .model = "drm-kms",
        .drm_output = drm_output,
    });
    requestRepaint(self);
}

fn disableDrmOutput(self: *Self, drm_output: *DrmOutput) !void {
    if (!drm_output.enabled) return;
    if (self.render_outputs.count <= 1) return error.LastEnabledOutput;
    const render_output = self.findDrmRenderOutput(drm_output) orelse
        return error.MissingRenderOutput;
    try self.drm_device.setOutputEnabled(drm_output, false);
    if (std.meta.eql(render_output.id, self.primary_render_output)) {
        self.replacePrimaryRenderOutput(render_output.id);
    }
    std.debug.assert(self.removeRenderOutput(render_output.id));
    requestRepaint(self);
}

fn replacePrimaryRenderOutput(self: *Self, removed_id: RenderOutputId) void {
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| if (!std.meta.eql(entry.id, removed_id)) {
        self.primary_render_output = entry.id;
        const replacement = entry.value.*;
        self.fractional_scale.setDefaultOutput(replacement.protocol_id);
        self.xdg_shell.setDefaultOutput(replacement.protocol_id);
        self.layer_shell.setDefaultOutput(replacement.protocol_id);
        self.window_manager.setDefaultOutput(replacement.protocol_id);
        self.native_input.retarget(replacement.backend.size(), nativeInputListener(replacement));
        return;
    };
    unreachable;
}

fn drmOutputRemoving(context: *anyopaque, drm_output: *DrmOutput) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.drm_lease_initialized) self.drm_lease.removeConnector(drm_output);
    if (self.output_management_initialized) self.output_management.removeHead(drm_output);
    const render_output = self.findDrmRenderOutput(drm_output) orelse return;
    const id = render_output.id;
    if (self.render_outputs.count == 1) {
        var fallback: ?*DrmOutput = null;
        for (self.drm_device.outputs()) |candidate| {
            if (candidate != drm_output and !candidate.enabled and
                (!self.drm_lease_initialized or !self.drm_lease.outputLeased(candidate)))
            {
                fallback = candidate;
                break;
            }
        }
        if (fallback) |replacement| {
            self.enableDrmOutput(replacement, .{
                .x = replacement.logical_x,
                .y = replacement.logical_y,
            }) catch return self.terminate();
            if (self.output_management_initialized) self.output_management.syncHead(replacement);
        } else {
            if (self.native_input_initialized) {
                if (self.builtin_keybindings_initialized) self.builtin_keybindings.detachNativeInput();
                if (self.input_manager_initialized) self.input_manager.detachNativeInput();
                self.native_input.deinit();
                self.native_input_initialized = false;
            }
            std.debug.assert(self.removeRenderOutput(id));
            self.terminate();
            return;
        }
    }
    if (std.meta.eql(id, self.primary_render_output)) {
        self.replacePrimaryRenderOutput(id);
    }
    std.debug.assert(self.removeRenderOutput(id));
    requestRepaint(self);
}

fn applyOutputConfiguration(context: *anyopaque, changes: []const OutputManagement.Change) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.applyOutputChanges(changes);
}

fn applyOutputChanges(self: *Self, changes: []const OutputManagement.Change) bool {
    if (self.drm_lease_initialized) for (changes) |change| {
        if (self.drm_lease.outputLeased(change.output)) return false;
    };
    for (changes) |change| {
        if (change.old_mode_index == change.mode_index) continue;
        self.drm_device.setOutputMode(change.output, change.mode_index) catch {
            rollbackOutputConfiguration(self, changes);
            return false;
        };
    }
    for (changes) |change| {
        if (change.was_enabled or !change.enabled) continue;
        change.output.scale = change.scale;
        self.enableDrmOutput(change.output, .{ .x = change.x, .y = change.y }) catch {
            rollbackOutputConfiguration(self, changes);
            return false;
        };
    }

    for (changes) |change| {
        if (change.enabled) self.setDrmOutputConfiguration(
            change.output,
            .{ .x = change.x, .y = change.y },
            change.scale,
        );
    }
    for (changes) |change| {
        if (!change.was_enabled or change.enabled) continue;
        self.disableDrmOutput(change.output) catch {
            rollbackOutputConfiguration(self, changes);
            return false;
        };
    }
    for (changes) |change| {
        if (change.enabled) continue;
        change.output.logical_x = change.x;
        change.output.logical_y = change.y;
        change.output.scale = change.scale;
    }
    requestRepaint(self);
    return true;
}

fn overlayOutputSettings(
    effective: *EffectiveOutputSettings,
    settings: Config.OutputSettings,
) void {
    if (settings.enable) |enabled| effective.enabled = enabled;
    if (settings.position) |position| {
        effective.x = position.x;
        effective.y = position.y;
    }
    if (settings.mode) |mode| effective.requested_mode = mode;
    if (settings.scale_v120_numerator) |numerator| effective.scale = .{ .numerator = numerator };
}

fn resolveOutputMode(modes: []const DrmOutput.Mode, requested: Config.OutputMode) !usize {
    var selected: ?usize = null;
    for (modes, 0..) |mode, index| {
        const size = mode.size();
        if (size.width != requested.width or size.height != requested.height) continue;
        if (selected == null or if (requested.refresh_millihertz) |refresh|
            @abs(@as(i64, mode.refreshMillihertz()) - refresh) <
                @abs(@as(i64, modes[selected.?].refreshMillihertz()) - refresh)
        else
            mode.preferred and !modes[selected.?].preferred)
        {
            selected = index;
        }
    }
    return selected orelse error.OutputModeUnavailable;
}

fn outputDeviceMatch(output: *const DrmOutput) Config.OutputDeviceMatch {
    return .{
        .name = output.name(),
        .make = output.make(),
        .model = output.model(),
        .serial = output.serial(),
    };
}

fn overlayMatchingOutputRules(
    effective: *EffectiveOutputSettings,
    device: Config.OutputDeviceMatch,
    rules: []const Config.OutputRule,
) bool {
    var matched = false;
    for (rules) |rule| {
        if (!rule.matcher.matches(device)) continue;
        matched = true;
        overlayOutputSettings(effective, rule.settings);
    }
    return matched;
}

fn configuredOutputChange(output: *DrmOutput, rules: []const Config.OutputRule) !?OutputManagement.Change {
    var effective: EffectiveOutputSettings = .{
        .enabled = output.enabled,
        .mode_index = output.currentModeIndex(),
        .x = output.logical_x,
        .y = output.logical_y,
        .scale = output.scale,
    };
    if (!overlayMatchingOutputRules(&effective, outputDeviceMatch(output), rules)) return null;
    if (effective.requested_mode) |mode| {
        effective.mode_index = try resolveOutputMode(output.availableModes(), mode);
    }
    _ = try effective.scale.logicalSize(output.availableModes()[effective.mode_index].size());
    if (effective.enabled == output.enabled and effective.mode_index == output.currentModeIndex() and
        effective.x == output.logical_x and effective.y == output.logical_y and
        effective.scale.numerator == output.scale.numerator) return null;
    return .{
        .output = output,
        .was_enabled = output.enabled,
        .enabled = effective.enabled,
        .old_x = output.logical_x,
        .old_y = output.logical_y,
        .old_scale = output.scale,
        .old_mode_index = output.currentModeIndex(),
        .x = effective.x,
        .y = effective.y,
        .scale = effective.scale,
        .mode_index = effective.mode_index,
    };
}

fn applyConfiguredOutputs(self: *Self, rules: []const Config.OutputRule, only: ?*DrmOutput) !void {
    if (!self.drm_device_initialized) return;
    var changes: std.ArrayList(OutputManagement.Change) = .empty;
    defer changes.deinit(self.allocator);
    for (self.drm_device.outputs()) |output| {
        if (only != null and only.? != output) continue;
        if (try configuredOutputChange(output, rules)) |change| try changes.append(self.allocator, change);
    }
    if (changes.items.len != 0) {
        if (!self.applyOutputChanges(changes.items)) return error.OutputConfigurationFailed;
        if (self.output_management_initialized) {
            for (changes.items) |change| self.output_management.syncHead(change.output);
        }
    }
}

fn rollbackOutputConfiguration(self: *Self, changes: []const OutputManagement.Change) void {
    // Restore previously enabled heads first so rolling back a newly enabled
    // head never violates the compositor's one-enabled-output invariant.
    for (changes) |change| {
        if (!change.was_enabled or change.output.enabled) continue;
        change.output.scale = change.old_scale;
        self.enableDrmOutput(
            change.output,
            .{ .x = change.old_x, .y = change.old_y },
        ) catch return self.terminate();
    }
    for (changes) |change| {
        if (change.output.currentModeIndex() == change.old_mode_index) continue;
        self.drm_device.setOutputMode(change.output, change.old_mode_index) catch
            return self.terminate();
    }
    for (changes) |change| {
        if (change.was_enabled) self.setDrmOutputConfiguration(
            change.output,
            .{ .x = change.old_x, .y = change.old_y },
            change.old_scale,
        );
    }
    for (changes) |change| {
        if (change.was_enabled or !change.output.enabled) continue;
        self.disableDrmOutput(change.output) catch return self.terminate();
    }
    for (changes) |change| {
        if (change.output.enabled) continue;
        change.output.logical_x = change.old_x;
        change.output.logical_y = change.old_y;
        change.output.scale = change.old_scale;
    }
    requestRepaint(self);
}

fn openDrmLeaseDevice(context: *anyopaque) ?std.posix.fd_t {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.drm_device.openNonMasterFd() catch |err| {
        log.warn("failed to open non-master DRM lease device: {t}", .{err});
        return null;
    };
}

fn grantDrmLease(context: *anyopaque, outputs: []const *DrmOutput) ?DrmLease.Grant {
    const self: *Self = @ptrCast(@alignCast(context));
    var disabled: std.ArrayList(*DrmOutput) = .empty;
    defer disabled.deinit(self.allocator);
    disabled.ensureUnusedCapacity(self.allocator, outputs.len) catch return null;

    for (outputs) |output| {
        if (self.drm_device.outputLeased(output)) {
            restoreDrmLeaseOutputs(self, disabled.items);
            return null;
        }
        if (!output.enabled) continue;
        disabled.appendAssumeCapacity(output);
        self.disableDrmOutput(output) catch {
            _ = disabled.pop();
            restoreDrmLeaseOutputs(self, disabled.items);
            return null;
        };
        if (self.output_management_initialized) self.output_management.syncHead(output);
    }

    const lease = self.drm_device.createLease(outputs) catch {
        restoreDrmLeaseOutputs(self, disabled.items);
        return null;
    };
    return .{ .fd = lease.fd, .lessee_id = lease.lessee_id };
}

fn restoreDrmLeaseOutputs(self: *Self, outputs: []const *DrmOutput) void {
    var index = outputs.len;
    while (index > 0) {
        index -= 1;
        const output = outputs[index];
        self.enableDrmOutput(output, .{
            .x = output.logical_x,
            .y = output.logical_y,
        }) catch return self.terminate();
        if (self.output_management_initialized) self.output_management.syncHead(output);
    }
}

fn revokeDrmLease(context: *anyopaque, lessee_id: u32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.drm_device.revokeLease(lessee_id);
}

fn drmDeviceActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.gamma_control_initialized) self.gamma_control.refreshOutputs();
    if (self.drm_lease_initialized) self.drm_lease.@"resume"();
}

fn drmDeviceDeactivating(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.drm_lease_initialized) self.drm_lease.@"suspend"();
}

fn drmLeaseRevoked(context: *anyopaque, lessee_id: u32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.drm_lease_initialized) self.drm_lease.leaseRevoked(lessee_id);
}

fn drmDeviceFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn stopRenderOutput(render_output: *RenderOutput) void {
    if (render_output.timer) |timer| {
        timer.remove();
        render_output.timer = null;
    }
    if (render_output.repaint_idle) |idle| {
        idle.remove();
        render_output.repaint_idle = null;
    }
    render_output.render_scheduled = false;
}

pub fn listen(self: *Self) ![:0]const u8 {
    std.debug.assert(!self.listening);
    const socket_name = try self.display.addSocketAuto(&self.socket_buffer);
    self.listening = true;
    return socket_name;
}

pub fn listenControl(self: *Self, runtime_directory: []const u8) !void {
    std.debug.assert(self.listening and !self.control_initialized);
    try self.control.init(
        self.allocator,
        self.io,
        self.eventLoop(),
        .{
            .context = self,
            .execute = executeControlCommand,
            .statistics = controlPerformanceStatistics,
            .reload = reloadControlConfiguration,
            .quit = quitControlSession,
        },
        runtime_directory,
    );
    self.control_initialized = true;
}

fn executeControlCommand(context: *anyopaque, command: Command) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.window_manager.execute(command);
}

fn controlPerformanceStatistics(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    reset: bool,
) ![]ControlProtocol.OutputStatistics {
    const self: *Self = @ptrCast(@alignCast(context));
    self.collectGpuTimings();
    const result = try allocator.alloc(ControlProtocol.OutputStatistics, self.render_outputs.count);
    var index: usize = 0;
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| : (index += 1) {
        const render_output = entry.value.*;
        const protocol_output = self.outputs.get(render_output.protocol_id).?;
        result[index] = render_output.frame_statistics.snapshot(
            protocol_output.name(),
            render_output.backend.modeSize(),
            render_output.backend.refreshMillihertz(),
        );
        if (reset) render_output.frame_statistics.reset();
    }
    if (reset) self.renderer.discardGpuTimings();
    return result;
}

fn outputStatisticsTag(id: OutputLayout.Id) u64 {
    return @as(u64, id.generation) << 32 | id.index;
}

fn outputStatisticsId(tag: u64) OutputLayout.Id {
    return .{
        .index = @truncate(tag),
        .generation = @truncate(tag >> 32),
    };
}

fn collectGpuTimings(self: *Self) void {
    while (self.renderer.takeGpuTiming()) |timing| {
        const render_output = self.findProtocolRenderOutput(
            outputStatisticsId(timing.tag),
        ) orelse continue;
        render_output.frame_statistics.addGpuExecution(timing.nanoseconds);
    }
}

fn reloadControlConfiguration(context: *anyopaque) ?[]const u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    self.reloadConfiguration() catch |err| {
        if (self.configuration) |*configuration| {
            if (configuration.failureMessage()) |message| return message;
        }
        return @errorName(err);
    };
    return null;
}

fn quitControlSession(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

pub fn setLauncher(self: *Self, launcher: *Launcher) void {
    if (self.builtin_keybindings_initialized) self.builtin_keybindings.setLauncher(launcher);
}

pub fn setConfiguration(self: *Self, configuration: *Config.Store) void {
    std.debug.assert(self.configuration == null);
    self.configuration = configuration.*;
    configuration.* = undefined;
    self.applyConfiguredOutputs(self.configuration.?.snapshot.output_rules, null) catch |err| {
        log.warn("failed to apply configured outputs; preserving default layout: {t}", .{err});
    };
    self.applyGeneralConfiguration(self.configuration.?.snapshot.general);
    self.applyInputConfiguration(self.configuration.?.snapshot.input_rules);
    if (self.builtin_keybindings_initialized) {
        self.builtin_keybindings.setConfiguredBindings(self.configuration.?.snapshot.bindings);
    }
}

pub fn reloadConfiguration(self: *Self) !void {
    const configuration = if (self.configuration) |*value| value else return error.ConfigurationUnavailable;
    var replacement = try configuration.loadSnapshot();
    errdefer replacement.deinit();
    try self.applyConfiguredOutputs(replacement.output_rules, null);
    self.applyGeneralConfiguration(replacement.general);
    self.applyInputConfiguration(replacement.input_rules);
    if (self.builtin_keybindings_initialized) {
        self.builtin_keybindings.setConfiguredBindings(replacement.bindings);
    }
    var previous = configuration.snapshot;
    configuration.snapshot = replacement;
    previous.deinit();
    log.info("configuration reloaded", .{});
}

fn applyGeneralConfiguration(self: *Self, general: Config.GeneralSettings) void {
    self.window_manager.setFocusFollowsMouse(general.focus_follows_mouse);
    self.window_manager.setGaps(general.inner_gap, general.outer_gap);
    const normal_effects = windowEffects(general, general.shadow_color);
    self.window_manager.setWindowEffects(
        normal_effects,
        windowEffects(general, general.focused_shadow_color),
    );
    self.window_manager.setFocusedWindowBorder(focusedWindowBorder(general));
    if (!std.meta.eql(self.layer_shell_effects, normal_effects)) {
        self.layer_shell_effects = normal_effects;
        requestRepaint(self);
    }
}

fn windowEffects(general: Config.GeneralSettings, shadow_color: Config.Color) Scene.Effects {
    const defaults = Scene.default_effects;
    return .{
        .corner_radius = defaults.corner_radius,
        .shadow = if (general.shadow_enabled) .{
            .offset = defaults.shadow.?.offset,
            .blur_radius = general.shadow_blur_radius,
            .spread = defaults.shadow.?.spread,
            .color = render.Color.rgba(
                shadow_color.red,
                shadow_color.green,
                shadow_color.blue,
                shadow_color.alpha,
            ),
        } else null,
    };
}

fn focusedWindowBorder(general: Config.GeneralSettings) ?Scene.Borders {
    if (general.focused_border_width == 0) return null;
    const color = general.focused_border_color;
    return .{
        .edges = .{ .top = true, .bottom = true, .left = true, .right = true },
        .width = general.focused_border_width,
        .color = render.Color.rgba(color.red, color.green, color.blue, color.alpha),
    };
}

const EffectiveInputSettings = struct {
    send_events: NativeInput.SendEventsModes,
    tap: ?NativeInput.Toggle,
    tap_button_map: ?NativeInput.TapButtonMap,
    drag: ?NativeInput.Toggle,
    drag_lock: ?NativeInput.DragLock,
    three_finger_drag: ?NativeInput.ThreeFingerDrag,
    accel_profile: ?NativeInput.AccelProfile,
    accel_speed: ?f64,
    natural_scroll: ?NativeInput.Toggle,
    left_handed: ?NativeInput.Toggle,
    click_method: ?NativeInput.ClickMethod,
    clickfinger_button_map: ?NativeInput.ClickfingerButtonMap,
    middle_emulation: ?NativeInput.Toggle,
    scroll_method: ?NativeInput.ScrollMethod,
    scroll_button: ?u32,
    scroll_button_lock: ?NativeInput.Toggle,
    disable_while_typing: ?NativeInput.Toggle,
    disable_while_trackpointing: ?NativeInput.Toggle,
    rotation: ?u32,
    scroll_factor: f64 = 1,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,

    fn init(defaults: NativeInput.DeviceConfig) EffectiveInputSettings {
        return .{
            .send_events = defaults.send_events.default,
            .tap = settingDefault(NativeInput.Toggle, defaults.tap),
            .tap_button_map = settingDefault(NativeInput.TapButtonMap, defaults.tap_button_map),
            .drag = settingDefault(NativeInput.Toggle, defaults.drag),
            .drag_lock = settingDefault(NativeInput.DragLock, defaults.drag_lock),
            .three_finger_drag = settingDefault(NativeInput.ThreeFingerDrag, defaults.three_finger_drag),
            .accel_profile = if (defaults.accel_profiles) |setting| setting.default else null,
            .accel_speed = if (defaults.accel_profiles) |setting| setting.speed.default else null,
            .natural_scroll = settingDefault(NativeInput.Toggle, defaults.natural_scroll),
            .left_handed = settingDefault(NativeInput.Toggle, defaults.left_handed),
            .click_method = if (defaults.click_method) |setting| setting.default else null,
            .clickfinger_button_map = settingDefault(NativeInput.ClickfingerButtonMap, defaults.clickfinger_button_map),
            .middle_emulation = settingDefault(NativeInput.Toggle, defaults.middle_emulation),
            .scroll_method = if (defaults.scroll_method) |setting| setting.default else null,
            .scroll_button = settingDefault(u32, defaults.scroll_button),
            .scroll_button_lock = settingDefault(NativeInput.Toggle, defaults.scroll_button_lock),
            .disable_while_typing = settingDefault(NativeInput.Toggle, defaults.dwt),
            .disable_while_trackpointing = settingDefault(NativeInput.Toggle, defaults.dwtp),
            .rotation = settingDefault(u32, defaults.rotation),
        };
    }
};

fn settingDefault(comptime T: type, setting: ?NativeInput.Setting(T)) ?T {
    return if (setting) |value| value.default else null;
}

fn applyInputConfiguration(self: *Self, rules: []const Config.InputRule) void {
    if (!self.native_input_initialized or !self.input_manager_initialized) return;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        var earlier = false;
        var candidates = self.input_manager.deviceIterator();
        while (candidates.next()) |candidate| {
            if (candidate.physical_id == device.physical_id and candidate.id < device.id) {
                earlier = true;
                break;
            }
        }
        if (!earlier) self.applyPhysicalInputConfiguration(device.physical_id, rules);
    }
}

fn applyPhysicalInputConfiguration(
    self: *Self,
    physical_id: NativeInput.PhysicalDeviceId,
    rules: []const Config.InputRule,
) void {
    if (!self.native_input_initialized or !self.input_manager_initialized) return;
    var representative: ?*InputManager.Device = null;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        if (device.physical_id != physical_id) continue;
        representative = device;
        break;
    }
    const device = representative orelse return;
    const capabilities = self.native_input.deviceCapabilities(device.id) orelse return;
    const defaults = self.native_input.deviceConfig(device.id) orelse return;
    const matched_device: Config.InputDeviceMatch = .{
        .name = device.name,
        .vendor = device.vendor,
        .product = device.product,
        .keyboard = capabilities.keyboard,
        .pointer = capabilities.pointer,
        .touchpad = capabilities.pointer and defaults.tap_finger_count > 0,
        .touch = capabilities.touch,
        .tablet = capabilities.tablet,
        .tablet_pad = capabilities.tablet_pad,
    };
    var effective: EffectiveInputSettings = .init(defaults);
    for (rules) |rule| {
        if (!rule.matcher.matches(matched_device)) continue;
        overlayInputSettings(&effective, defaults, matched_device, rule.settings);
    }
    self.applyEffectiveInputSettings(device, effective);
}

fn overlayInputSettings(
    effective: *EffectiveInputSettings,
    defaults: NativeInput.DeviceConfig,
    device: Config.InputDeviceMatch,
    settings: Config.InputSettings,
) void {
    if (settings.send_events) |configured| {
        effective.send_events = switch (configured) {
            .use_default => defaults.send_events.default,
            .value => |value| switch (value) {
                .enabled => .{},
                .disabled => .{ .disabled = true },
                .disabled_on_external_mouse => .{ .disabled_on_external_mouse = true },
            },
        };
    }
    overlayNativeSetting(NativeInput.Toggle, &effective.tap, settingDefault(NativeInput.Toggle, defaults.tap), settings.tap, device.name, "tap");
    overlayNativeSetting(NativeInput.TapButtonMap, &effective.tap_button_map, settingDefault(NativeInput.TapButtonMap, defaults.tap_button_map), settings.tap_button_map, device.name, "tap-button-map");
    overlayNativeSetting(NativeInput.Toggle, &effective.drag, settingDefault(NativeInput.Toggle, defaults.drag), settings.drag, device.name, "drag");
    overlayNativeSetting(NativeInput.DragLock, &effective.drag_lock, settingDefault(NativeInput.DragLock, defaults.drag_lock), settings.drag_lock, device.name, "drag-lock");
    overlayNativeSetting(NativeInput.ThreeFingerDrag, &effective.three_finger_drag, settingDefault(NativeInput.ThreeFingerDrag, defaults.three_finger_drag), settings.three_finger_drag, device.name, "three-finger-drag");
    overlayNativeSetting(NativeInput.AccelProfile, &effective.accel_profile, if (defaults.accel_profiles) |setting| setting.default else null, settings.accel_profile, device.name, "accel-profile");
    overlayNativeSetting(f64, &effective.accel_speed, if (defaults.accel_profiles) |setting| setting.speed.default else null, settings.accel_speed, device.name, "accel-speed");
    overlayNativeSetting(NativeInput.Toggle, &effective.natural_scroll, settingDefault(NativeInput.Toggle, defaults.natural_scroll), settings.natural_scroll, device.name, "natural-scroll");
    overlayNativeSetting(NativeInput.Toggle, &effective.left_handed, settingDefault(NativeInput.Toggle, defaults.left_handed), settings.left_handed, device.name, "left-handed");
    overlayNativeSetting(NativeInput.ClickMethod, &effective.click_method, if (defaults.click_method) |setting| setting.default else null, settings.click_method, device.name, "click-method");
    overlayNativeSetting(NativeInput.ClickfingerButtonMap, &effective.clickfinger_button_map, settingDefault(NativeInput.ClickfingerButtonMap, defaults.clickfinger_button_map), settings.clickfinger_button_map, device.name, "clickfinger-button-map");
    overlayNativeSetting(NativeInput.Toggle, &effective.middle_emulation, settingDefault(NativeInput.Toggle, defaults.middle_emulation), settings.middle_emulation, device.name, "middle-emulation");
    overlayNativeSetting(NativeInput.ScrollMethod, &effective.scroll_method, if (defaults.scroll_method) |setting| setting.default else null, settings.scroll_method, device.name, "scroll-method");
    overlayNativeSetting(u32, &effective.scroll_button, settingDefault(u32, defaults.scroll_button), settings.scroll_button, device.name, "scroll-button");
    overlayNativeSetting(NativeInput.Toggle, &effective.scroll_button_lock, settingDefault(NativeInput.Toggle, defaults.scroll_button_lock), settings.scroll_button_lock, device.name, "scroll-button-lock");
    overlayNativeSetting(NativeInput.Toggle, &effective.disable_while_typing, settingDefault(NativeInput.Toggle, defaults.dwt), settings.disable_while_typing, device.name, "disable-while-typing");
    overlayNativeSetting(NativeInput.Toggle, &effective.disable_while_trackpointing, settingDefault(NativeInput.Toggle, defaults.dwtp), settings.disable_while_trackpointing, device.name, "disable-while-trackpointing");
    overlayNativeSetting(u32, &effective.rotation, settingDefault(u32, defaults.rotation), settings.rotation, device.name, "rotation");
    overlayDeviceSetting(f64, &effective.scroll_factor, 1, settings.scroll_factor, device.pointer, device.name, "scroll-factor");
    overlayDeviceSetting(i32, &effective.repeat_rate, 25, settings.repeat_rate, device.keyboard, device.name, "repeat-rate");
    overlayDeviceSetting(i32, &effective.repeat_delay, 600, settings.repeat_delay, device.keyboard, device.name, "repeat-delay");
}

fn overlayNativeSetting(
    comptime T: type,
    effective: *?T,
    default_value: ?T,
    configured: ?Config.InputValue(T),
    device_name: []const u8,
    setting_name: []const u8,
) void {
    const value = configured orelse return;
    const default = default_value orelse {
        log.warn("input setting {s} is unsupported by {s}", .{ setting_name, device_name });
        return;
    };
    effective.* = value.resolve(default);
}

fn overlayDeviceSetting(
    comptime T: type,
    effective: *T,
    default_value: T,
    configured: ?Config.InputValue(T),
    supported: bool,
    device_name: []const u8,
    setting_name: []const u8,
) void {
    const value = configured orelse return;
    if (!supported) {
        log.warn("input setting {s} is unsupported by {s}", .{ setting_name, device_name });
        return;
    }
    effective.* = value.resolve(default_value);
}

fn applyEffectiveInputSettings(
    self: *Self,
    device: *InputManager.Device,
    settings: EffectiveInputSettings,
) void {
    reportInputStatus(device.name, "send-events", self.native_input.setSendEvents(device.id, settings.send_events));
    if (settings.tap) |value| reportInputStatus(device.name, "tap", self.native_input.setTap(device.id, value));
    if (settings.tap_button_map) |value| reportInputStatus(device.name, "tap-button-map", self.native_input.setTapButtonMap(device.id, value));
    if (settings.drag) |value| reportInputStatus(device.name, "drag", self.native_input.setDrag(device.id, value));
    if (settings.drag_lock) |value| reportInputStatus(device.name, "drag-lock", self.native_input.setDragLock(device.id, value));
    if (settings.three_finger_drag) |value| reportInputStatus(device.name, "three-finger-drag", self.native_input.setThreeFingerDrag(device.id, value));
    if (settings.accel_profile) |value| reportInputStatus(device.name, "accel-profile", self.native_input.setAccelProfile(device.id, value));
    if (settings.accel_speed) |value| reportInputStatus(device.name, "accel-speed", self.native_input.setAccelSpeed(device.id, value));
    if (settings.natural_scroll) |value| reportInputStatus(device.name, "natural-scroll", self.native_input.setNaturalScroll(device.id, value));
    if (settings.left_handed) |value| reportInputStatus(device.name, "left-handed", self.native_input.setLeftHanded(device.id, value));
    if (settings.click_method) |value| reportInputStatus(device.name, "click-method", self.native_input.setClickMethod(device.id, value));
    if (settings.clickfinger_button_map) |value| reportInputStatus(device.name, "clickfinger-button-map", self.native_input.setClickfingerButtonMap(device.id, value));
    if (settings.middle_emulation) |value| reportInputStatus(device.name, "middle-emulation", self.native_input.setMiddleEmulation(device.id, value));
    if (settings.scroll_method) |value| reportInputStatus(device.name, "scroll-method", self.native_input.setScrollMethod(device.id, value));
    if (settings.scroll_button) |value| reportInputStatus(device.name, "scroll-button", self.native_input.setScrollButton(device.id, value));
    if (settings.scroll_button_lock) |value| reportInputStatus(device.name, "scroll-button-lock", self.native_input.setScrollButtonLock(device.id, value));
    if (settings.disable_while_typing) |value| reportInputStatus(device.name, "disable-while-typing", self.native_input.setDwt(device.id, value));
    if (settings.disable_while_trackpointing) |value| reportInputStatus(device.name, "disable-while-trackpointing", self.native_input.setDwtp(device.id, value));
    if (settings.rotation) |value| reportInputStatus(device.name, "rotation", self.native_input.setRotation(device.id, value));

    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |logical_device| {
        if (logical_device.physical_id != device.physical_id) continue;
        switch (logical_device.device_type) {
            .keyboard => self.native_input.setDeviceRepeatInfo(logical_device.id, settings.repeat_rate, settings.repeat_delay),
            .pointer => self.native_input.setDeviceScrollFactor(logical_device.id, settings.scroll_factor),
            .touch, .tablet, .tablet_pad => {},
        }
    }
}

fn reportInputStatus(device_name: []const u8, setting_name: []const u8, status: ?NativeInput.Status) void {
    const result = status orelse {
        log.warn("input device {s} disappeared while applying {s}", .{ device_name, setting_name });
        return;
    };
    switch (result) {
        .success => {},
        .unsupported => log.warn("input setting {s} is unsupported by {s}", .{ setting_name, device_name }),
        .invalid => log.warn("input setting {s} was rejected by {s}", .{ setting_name, device_name }),
    }
}

pub fn setXwaylandDisplayListener(self: *Self, listener: XwaylandDisplayListener) void {
    self.xwayland_display_listener = listener;
}

pub fn startXwayland(
    self: *Self,
    environ_map: *std.process.Environ.Map,
) void {
    self.xwayland_server.start(environ_map) catch |err| {
        log.warn("Xwayland is unavailable: {t}", .{err});
        return;
    };
    if (self.xwayland_display_listener) |listener|
        listener.available(listener.context, self.xwayland_server.displayName());
}

pub fn eventLoop(self: *Self) *wl.EventLoop {
    return self.display.getEventLoop();
}

pub fn run(self: *Self) void {
    std.debug.assert(self.listening);
    std.debug.assert(self.configuration != null);
    self.display.run();
}

pub fn terminate(self: *Self) void {
    self.display.terminate();
}

fn requestRepaint(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
    if (self.image_copy_capture_initialized) self.image_copy_capture.refreshCursors();
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (!render_output.backend.powered()) {
            render_output.repaint_needed = false;
            render_output.damage.clear();
            continue;
        }
        self.damageFullOutput(render_output);
    }
}

fn cursorMoved(context: *anyopaque, old: Seat.CursorInfo, new: Seat.CursorInfo) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
    if (self.image_copy_capture_initialized) self.image_copy_capture.refreshCursors();
    const old_bounds = self.cursorBounds(old) orelse return requestRepaint(self);
    const new_bounds = self.cursorBounds(new) orelse return requestRepaint(self);
    self.damageGlobalRect(old_bounds);
    self.damageGlobalRect(new_bounds);
}

fn surfaceChanged(context: *anyopaque, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const surfaces = self.compositor.surfaceStore();
    if (!Surface.currentDamagePrecise(surfaces, surface_id)) return requestRepaint(self);
    const root = self.subcompositor.rootSurface(surface_id);
    const root_position = self.scene.surfacePosition(root) orelse return requestRepaint(self);
    const offset = self.subcompositor.surfaceOffset(surface_id);
    const damage = Surface.currentDamage(surfaces, surface_id) orelse
        return requestRepaint(self);
    const layer_shadow = if (std.meta.eql(surface_id, root) and
        self.layer_shell.castsShadow(root)) self.layer_shell_effects.shadow else null;
    if (damage.isEmpty()) {
        var bounds: ?render.Rect = null;
        self.addSurfaceTreeBounds(root, root_position.x, root_position.y, &bounds) catch
            return requestRepaint(self);
        if (bounds) |rectangle| self.damageGlobalRect(rectangle);
        return;
    }

    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        const global: render.Rect = .{
            .x = root_position.x +| offset.x +| rectangle.x,
            .y = root_position.y +| offset.y +| rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        };
        self.damageGlobalRect(if (layer_shadow) |shadow|
            shadowDamageRect(global, shadow)
        else
            global);
    }
}

fn cursorBounds(self: *Self, cursor: Seat.CursorInfo) ?render.Rect {
    return switch (cursor) {
        .shape => |shape| .{
            .x = shape.x,
            .y = shape.y,
            .width = shape.buffer.size.width,
            .height = shape.buffer.size.height,
        },
        .surface => |surface| bounds: {
            var value: ?render.Rect = null;
            self.addSurfaceTreeBounds(
                surface.surface_id,
                surface.x,
                surface.y,
                &value,
            ) catch return null;
            break :bounds value;
        },
    };
}

fn damageGlobalRect(self: *Self, rectangle: render.Rect) void {
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (!render_output.backend.powered()) continue;
        const output = self.outputs.get(render_output.protocol_id).?;
        const output_rect = output.logicalRect();
        const intersection = rectangle.intersection(output_rect) orelse continue;
        const physical = scaleDamageRect(
            .{
                .x = intersection.x -| output_rect.x,
                .y = intersection.y -| output_rect.y,
                .width = intersection.width,
                .height = intersection.height,
            },
            render_output.backend.renderScale(),
            render_output.backend.modeSize(),
        ) orelse continue;
        render_output.damage.add(
            physical.x,
            physical.y,
            @intCast(physical.width),
            @intCast(physical.height),
        ) catch {
            self.damageFullOutput(render_output);
            continue;
        };
        render_output.requestFrame();
        self.scheduleRepaint(render_output);
    }
}

fn scaleDamageRect(
    logical: render.Rect,
    scale: render.Scale,
    target_size: render.Size,
) ?render.Rect {
    std.debug.assert(logical.x >= 0 and logical.y >= 0);
    const denominator: i128 = render.Scale.denominator;
    const left_product = @as(i128, logical.x) * scale.numerator;
    const top_product = @as(i128, logical.y) * scale.numerator;
    const right_product = (@as(i128, logical.x) + logical.width) * scale.numerator;
    const bottom_product = (@as(i128, logical.y) + logical.height) * scale.numerator;
    var left: i64 = @intCast(@divTrunc(left_product, denominator));
    var top: i64 = @intCast(@divTrunc(top_product, denominator));
    var right: i64 = @intCast(@divTrunc(right_product + denominator - 1, denominator));
    var bottom: i64 = @intCast(@divTrunc(bottom_product + denominator - 1, denominator));
    if (scale.numerator % render.Scale.denominator != 0) {
        left -= 1;
        top -= 1;
        right += 1;
        bottom += 1;
    }
    left = std.math.clamp(left, 0, target_size.width);
    top = std.math.clamp(top, 0, target_size.height);
    right = std.math.clamp(right, 0, target_size.width);
    bottom = std.math.clamp(bottom, 0, target_size.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn damageFullOutput(self: *Self, output: *RenderOutput) void {
    const size = output.backend.modeSize();
    output.damage.setRectangle(0, 0, size.width, size.height);
    output.requestFrame();
    self.scheduleRepaint(output);
}

fn outputDamageRectangles(
    self: *Self,
    output: *RenderOutput,
    damage: *const Region,
) error{OutOfMemory}![]const render.Rect {
    output.damage_rectangles.clearRetainingCapacity();
    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        try output.damage_rectangles.append(self.allocator, .{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        });
    }
    return output.damage_rectangles.items;
}

fn clearCursorShapes(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.clearCursorShapes();
    self.tablet.clearCursorShapes();
}

fn idleInhibitorsChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
}

fn idleNotifyFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn refreshIdleInhibition(self: *Self) void {
    if (!self.idle_notify_initialized) return;
    self.idle_notify.setInhibited(self.idle_inhibit.hasVisibleInhibitor(
        self,
        idleInhibitorSurfaceVisible,
    ));
}

fn idleInhibitorSurfaceVisible(context: *anyopaque, surface_id: Surface.Id) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const root = self.subcompositor.rootSurface(surface_id);
    if (self.session_lock.isLocked()) return self.session_lock.ownsSurface(root);
    return self.scene.surfaceMapped(root);
}

fn workspaceActivationRequested(context: *anyopaque, output: OutputLayout.Id, number: u8) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.window_manager_initialized) return false;
    return self.window_manager.activateWorkspaceFromProtocol(output, number);
}

fn sessionLockStateChanged(context: *anyopaque, locked: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
    if (locked) self.xwayland_keyboard_grab.cancelAll();
    if (self.window_manager_initialized and self.window_manager.endTilingDrag(false)) {
        requestRepaint(self);
    }
    self.pointer_constraints.deactivateAll();
    self.data_device.cancel();
    self.tablet.cancelFocus();
    self.cancelSeatTouches(&self.seat);
    self.seat.suppressPointerFocus(true);
    self.xdg_shell.dismissPopupGrab();
    if (locked) {
        self.virtual_keyboard.setInhibited(true);
        self.input_method.setInhibited(true);
        self.seat.setKeyboardFocus(null);
    } else {
        self.seat.setKeyboardFocus(null);
        self.input_method.setInhibited(false);
        self.virtual_keyboard.setInhibited(false);
        if (self.seat.pointerPosition()) |position| {
            self.seat.pointerEnter(
                position.x,
                position.y,
                self.pointerFocus(position.x, position.y),
            );
        }
    }
}

fn inputMethodSurfacePosition(context: *anyopaque, surface_id: Surface.Id) ?InputMethod.Position {
    const self: *Self = @ptrCast(@alignCast(context));
    const position = self.scene.surfacePosition(surface_id) orelse return null;
    return .{ .x = position.x, .y = position.y };
}

fn inputMethodOutputSize(context: *anyopaque) render.Size {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.primaryRenderOutput().backend.size();
}

fn primaryRenderOutput(self: *Self) *RenderOutput {
    return self.render_outputs.get(self.primary_render_output).?.*;
}

fn scheduleRepaint(self: *Self, output: *RenderOutput) void {
    if (!output.repaint_needed or output.render_scheduled or !output.backend.ready()) return;
    if (output.backend.repaintDelayMilliseconds()) |delay| {
        const timer = output.timer orelse unreachable;
        timer.timerUpdate(delay) catch |err| {
            log.err("failed to schedule repaint: {t}", .{err});
            self.terminate();
            return;
        };
    } else {
        std.debug.assert(output.timer == null and output.repaint_idle == null);
        output.repaint_idle = self.display.getEventLoop().addIdle(
            *RenderOutput,
            handleRenderIdle,
            output,
        ) catch |err| {
            log.err("failed to schedule repaint: {t}", .{err});
            self.terminate();
            return;
        };
    }
    output.render_scheduled = true;
}

fn outputReady(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.scheduleRepaint(output);
}

fn outputPresented(context: *anyopaque, info: presentation.Info) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    output.presentFrame(info);
    const protocol_output = self.outputs.get(output.protocol_id).?;
    protocol_output.setRefresh(info);
    Surface.finishPresentation(self.compositor.surfaceStore(), protocol_output, info);
    if (output.lock_frame_pending) {
        output.lock_frame_pending = false;
        self.session_lock.outputPresented(output.protocol_id);
    }
}

fn outputDiscarded(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    output.discardFrame();
    output.lock_frame_pending = false;
    Surface.discardPresentation(
        self.compositor.surfaceStore(),
        self.outputs.get(output.protocol_id).?,
    );
    requestRepaint(self);
}

fn commitTimingFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn closeOutput(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.terminate();
}

fn serverForOutput(context: *anyopaque) *Self {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    return output.server;
}

fn nativeKeyboardKeymap(context: *anyopaque, source: ?NativeInput.DeviceId, format: wl.Keyboard.KeymapFormat, fd: std.posix.fd_t, size: u32) void {
    const self = serverForOutput(context);
    const seat = if (source) |id| self.seatForDevice(id) else &self.seat;
    seat.setKeymap(format, fd, size);
}
fn nativeKeyboardKey(context: *anyopaque, id: NativeInput.DeviceId, time: u32, key: u32, state: wl.Keyboard.KeyState) void {
    const self = serverForOutput(context);
    self.routeKeyboardKey(id, time, key, state);
}
fn nativeKeyboardModifiers(context: *anyopaque, source: ?NativeInput.DeviceId, depressed: u32, latched: u32, locked: u32, group: u32) void {
    const self = serverForOutput(context);
    const seat = if (source) |id| self.seatForDevice(id) else &self.seat;
    seat.setModifiers(depressed, latched, locked, group);
}
fn nativeKeyboardRepeatInfo(context: *anyopaque, source: ?NativeInput.DeviceId, rate: i32, delay: i32) void {
    const self = serverForOutput(context);
    const seat = if (source) |id| self.seatForDevice(id) else &self.seat;
    seat.setRepeatInfo(rate, delay);
}
fn nativePointerMotion(context: *anyopaque, id: NativeInput.DeviceId, time: u32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    pointerMotionForSeat(output, output.server.seatForDevice(id), time, x, y);
}
fn nativePointerRelativeMotion(context: *anyopaque, id: NativeInput.DeviceId, time: u64, dx: f64, dy: f64, dx_unaccelerated: f64, dy_unaccelerated: f64) void {
    const self = serverForOutput(context);
    if (self.seatForDevice(id) == &self.seat) {
        self.relative_pointer.motion(time, dx, dy, dx_unaccelerated, dy_unaccelerated);
    }
}
fn nativePointerButton(context: *anyopaque, id: NativeInput.DeviceId, time: u32, button: u32, state: wl.Pointer.ButtonState) void {
    const self = serverForOutput(context);
    self.routePointerButton(id, time, button, state);
}
fn nativePointerAxis(context: *anyopaque, id: NativeInput.DeviceId, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const self = serverForOutput(context);
    const seat = self.seatForDevice(id);
    self.idle_notify.notifyActivity(seat);
    seat.pointerAxis(time, axis, value);
}
fn nativePointerFrame(context: *anyopaque, id: NativeInput.DeviceId) void {
    serverForOutput(context).seatForDevice(id).pointerFrame();
}
fn nativePointerAxisSource(context: *anyopaque, id: NativeInput.DeviceId, source: wl.Pointer.AxisSource) void {
    serverForOutput(context).seatForDevice(id).pointerAxisSource(source);
}
fn nativePointerAxisStop(context: *anyopaque, id: NativeInput.DeviceId, time: u32, axis: wl.Pointer.Axis) void {
    serverForOutput(context).seatForDevice(id).pointerAxisStop(time, axis);
}
fn nativePointerAxisDiscrete(context: *anyopaque, id: NativeInput.DeviceId, axis: wl.Pointer.Axis, discrete: i32) void {
    serverForOutput(context).seatForDevice(id).pointerAxisDiscrete(axis, discrete);
}
fn nativePointerAxisValue120(context: *anyopaque, id: NativeInput.DeviceId, axis: wl.Pointer.Axis, value: i32) void {
    serverForOutput(context).seatForDevice(id).pointerAxisValue120(axis, value);
}
fn nativeSwipeBegin(context: *anyopaque, id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    serverForOutput(context).beginGesture(id, time, fingers, .swipe);
}
fn nativeSwipeUpdate(context: *anyopaque, id: NativeInput.DeviceId, time: u32, dx: f64, dy: f64) void {
    const self = serverForOutput(context);
    const seat = self.gestureSeat(id, .swipe) orelse return;
    self.idle_notify.notifyActivity(seat);
    self.pointer_gestures.updateSwipe(seat, time, dx, dy);
}
fn nativeSwipeEnd(context: *anyopaque, id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    serverForOutput(context).endGesture(id, time, .swipe, cancelled);
}
fn nativePinchBegin(context: *anyopaque, id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    serverForOutput(context).beginGesture(id, time, fingers, .pinch);
}
fn nativePinchUpdate(
    context: *anyopaque,
    id: NativeInput.DeviceId,
    time: u32,
    dx: f64,
    dy: f64,
    scale: f64,
    rotation: f64,
) void {
    const self = serverForOutput(context);
    const seat = self.gestureSeat(id, .pinch) orelse return;
    self.idle_notify.notifyActivity(seat);
    self.pointer_gestures.updatePinch(seat, time, dx, dy, scale, rotation);
}
fn nativePinchEnd(context: *anyopaque, id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    serverForOutput(context).endGesture(id, time, .pinch, cancelled);
}
fn nativeHoldBegin(context: *anyopaque, id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    serverForOutput(context).beginGesture(id, time, fingers, .hold);
}
fn nativeHoldEnd(context: *anyopaque, id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    serverForOutput(context).endGesture(id, time, .hold, cancelled);
}
fn nativeTabletToolProximity(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    x: f64,
    y: f64,
    in_proximity: bool,
    axes: NativeInput.TabletToolAxes,
) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const info = self.native_input.tabletToolInfo(tool_id) orelse return;
    const target = if (in_proximity) tabletFocus(output, x, y) else null;
    const routed_axes = tabletAxesRoute(output, axes).axes;
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.proximity(
        device_id,
        info,
        time,
        target,
        in_proximity,
        routed_axes,
    ) catch self.terminate();
}
fn nativeTabletToolAxis(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const route = tabletAxesRoute(output, axes);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.axis(device_id, tool_id, time, route.focus, route.axes);
}
fn nativeTabletToolTip(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
    down: bool,
) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const route = tabletAxesRoute(output, axes);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.tip(device_id, tool_id, time, route.focus, route.axes, down);
}
fn nativeTabletToolButton(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
    button: u32,
    pressed: bool,
) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const route = tabletAxesRoute(output, axes);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.button(
        device_id,
        tool_id,
        time,
        route.focus,
        route.axes,
        button,
        pressed,
    ) catch self.terminate();
}

fn nativeTabletPadButton(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    button: u32,
    pressed: bool,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padButton(device_id, time, button, pressed, group, mode);
}

fn nativeTabletPadRing(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    ring: u32,
    position: f64,
    finger: bool,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padRing(device_id, time, ring, position, finger, group, mode);
}

fn nativeTabletPadStrip(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    strip: u32,
    position: f64,
    finger: bool,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padStrip(device_id, time, strip, position, finger, group, mode);
}

fn nativeTabletPadDial(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    dial: u32,
    value120: i32,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padDial(device_id, time, dial, value120, group, mode);
}

const TabletAxisRoute = struct {
    axes: NativeInput.TabletToolAxes,
    focus: ?Seat.PointerFocus,
};

fn tabletAxesRoute(output: *RenderOutput, axes: NativeInput.TabletToolAxes) TabletAxisRoute {
    var routed = axes;
    const position = axes.position orelse return .{ .axes = routed, .focus = null };
    const point = output.globalPoint(position.x, position.y);
    routed.position = .{ .x = point.x, .y = point.y };
    return .{
        .axes = routed,
        .focus = output.server.pointerFocus(point.x, point.y),
    };
}

fn tabletFocus(output: *RenderOutput, x: f64, y: f64) ?Seat.PointerFocus {
    const point = output.globalPoint(x, y);
    return output.server.pointerFocus(point.x, point.y);
}

fn tabletSurfaceCoordinates(
    context: *anyopaque,
    surface_id: Surface.Id,
    x: f64,
    y: f64,
) ?Tablet.Point {
    const self: *Self = @ptrCast(@alignCast(context));
    const root = self.subcompositor.rootSurface(surface_id);
    const root_position = self.scene.surfacePosition(root) orelse return null;
    const offset = self.subcompositor.surfaceOffset(surface_id);
    return .{
        .x = x - @as(f64, @floatFromInt(root_position.x +| offset.x)),
        .y = y - @as(f64, @floatFromInt(root_position.y +| offset.y)),
    };
}
fn nativeTouchDown(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.routeTouchDown(output, device_id, time, id, x, y);
}
fn nativeTouchUp(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, id: i32) void {
    serverForOutput(context).routeTouchUp(device_id, time, id);
}
fn nativeTouchMotion(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.routeTouchMotion(output, device_id, time, id, x, y);
}
fn nativeTouchFrame(context: *anyopaque, device_id: NativeInput.DeviceId) void {
    const self = serverForOutput(context);
    const seat = self.touchSeatForDevice(device_id) orelse self.seatForDevice(device_id);
    seat.touchFrame();
}
fn nativeTouchCancel(context: *anyopaque, device_id: NativeInput.DeviceId) void {
    serverForOutput(context).cancelDeviceTouches(device_id);
}

fn routeKeyboardKey(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    key: u32,
    state: wl.Keyboard.KeyState,
) void {
    const seat = self.seatForDevice(device_id);
    self.idle_notify.notifyActivity(seat);
    switch (state) {
        .pressed => {
            for (self.routed_keys.items) |routed| {
                if (routed.device_id == device_id and routed.key == key) return;
            }
            const already_pressed = self.seatKeyHeld(seat, key);
            self.routed_keys.append(self.allocator, .{
                .device_id = device_id,
                .seat = seat,
                .key = key,
            }) catch return self.terminate();
            if (already_pressed) return;
        },
        .released => {
            for (self.routed_keys.items, 0..) |routed, index| {
                if (routed.device_id != device_id or routed.key != key) continue;
                _ = self.routed_keys.orderedRemove(index);
                if (self.seatKeyHeld(routed.seat, key)) return;
                routed.seat.key(time, key, state) catch return self.terminate();
                return;
            }
            return;
        },
        .repeated => {},
        else => return,
    }
    seat.key(time, key, state) catch self.terminate();
}

fn releaseDeviceKeys(self: *Self, device_id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.routed_keys.items.len) {
        const routed = self.routed_keys.items[index];
        if (routed.device_id != device_id) {
            index += 1;
            continue;
        }
        _ = self.routed_keys.orderedRemove(index);
        if (self.seatKeyHeld(routed.seat, routed.key)) continue;
        routed.seat.key(0, routed.key, .released) catch return self.terminate();
    }
}

fn seatKeyHeld(self: *const Self, seat: *Seat, key: u32) bool {
    for (self.routed_keys.items) |routed| {
        if (routed.seat == seat and routed.key == key) return true;
    }
    return false;
}

fn routePointerButton(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    const seat = self.seatForDevice(device_id);
    self.routePointerButtonFromSource(.{ .native = device_id }, seat, time, button, state);
}

fn routePointerButtonFromSource(
    self: *Self,
    source: PointerButtonSource,
    seat: *Seat,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    self.idle_notify.notifyActivity(seat);
    switch (state) {
        .pressed => {
            for (self.routed_buttons.items) |routed| {
                if (std.meta.eql(routed.source, source) and routed.button == button) return;
            }
            const already_pressed = self.seatButtonHeld(seat, button);
            self.routed_buttons.append(self.allocator, .{
                .source = source,
                .seat = seat,
                .button = button,
            }) catch return self.terminate();
            if (already_pressed) return;
        },
        .released => {
            for (self.routed_buttons.items, 0..) |routed, index| {
                if (!std.meta.eql(routed.source, source) or routed.button != button) continue;
                _ = self.routed_buttons.orderedRemove(index);
                if (self.seatButtonHeld(routed.seat, button)) return;
                self.pointerButtonForSeat(routed.seat, time, button, state);
                return;
            }
            return;
        },
        else => return,
    }
    self.pointerButtonForSeat(seat, time, button, state);
}

fn releaseDeviceButtons(self: *Self, device_id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.routed_buttons.items.len) {
        const routed = self.routed_buttons.items[index];
        const matches = switch (routed.source) {
            .native => |candidate| candidate == device_id,
            .virtual => false,
        };
        if (!matches) {
            index += 1;
            continue;
        }
        _ = self.routed_buttons.orderedRemove(index);
        if (self.seatButtonHeld(routed.seat, routed.button)) continue;
        self.pointerButtonForSeat(routed.seat, 0, routed.button, .released);
    }
}

fn seatButtonHeld(self: *const Self, seat: *Seat, button: u32) bool {
    for (self.routed_buttons.items) |routed| {
        if (routed.seat == seat and routed.button == button) return true;
    }
    return false;
}

fn beginGesture(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    fingers: u32,
    kind: GestureKind,
) void {
    const seat = self.seatForDevice(device_id);
    var index: usize = 0;
    while (index < self.routed_gestures.items.len) {
        const routed = self.routed_gestures.items[index];
        if (routed.device_id == device_id or routed.seat == seat) {
            self.cancelRoutedGesture(index);
        } else {
            index += 1;
        }
    }
    self.routed_gestures.append(self.allocator, .{
        .device_id = device_id,
        .seat = seat,
        .kind = kind,
    }) catch return self.terminate();
    self.idle_notify.notifyActivity(seat);
    switch (kind) {
        .swipe => self.pointer_gestures.beginSwipe(seat, time, fingers),
        .pinch => self.pointer_gestures.beginPinch(seat, time, fingers),
        .hold => self.pointer_gestures.beginHold(seat, time, fingers),
    }
}

fn endGesture(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    kind: GestureKind,
    cancelled: bool,
) void {
    for (self.routed_gestures.items, 0..) |routed, index| {
        if (routed.device_id != device_id or routed.kind != kind) continue;
        _ = self.routed_gestures.orderedRemove(index);
        self.idle_notify.notifyActivity(routed.seat);
        self.sendGestureEnd(routed.seat, time, kind, cancelled);
        return;
    }
}

fn gestureSeat(self: *const Self, device_id: NativeInput.DeviceId, kind: GestureKind) ?*Seat {
    for (self.routed_gestures.items) |routed| {
        if (routed.device_id == device_id and routed.kind == kind) return routed.seat;
    }
    return null;
}

fn cancelDeviceGestures(self: *Self, device_id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.routed_gestures.items.len) {
        if (self.routed_gestures.items[index].device_id == device_id) {
            self.cancelRoutedGesture(index);
        } else {
            index += 1;
        }
    }
}

fn cancelSeatGestures(self: *Self, seat: *Seat) void {
    var index: usize = 0;
    while (index < self.routed_gestures.items.len) {
        if (self.routed_gestures.items[index].seat == seat) {
            self.cancelRoutedGesture(index);
        } else {
            index += 1;
        }
    }
}

fn cancelRoutedGesture(self: *Self, index: usize) void {
    const routed = self.routed_gestures.orderedRemove(index);
    self.sendGestureEnd(routed.seat, 0, routed.kind, true);
}

fn sendGestureEnd(
    self: *Self,
    seat: *Seat,
    time: u32,
    kind: GestureKind,
    cancelled: bool,
) void {
    switch (kind) {
        .swipe => self.pointer_gestures.endSwipe(seat, time, cancelled),
        .pinch => self.pointer_gestures.endPinch(seat, time, cancelled),
        .hold => self.pointer_gestures.endHold(seat, time, cancelled),
    }
}

fn routeTouchDown(
    self: *Self,
    output: *RenderOutput,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    x: f64,
    y: f64,
) void {
    for (self.routed_touches.items) |touch| {
        if (touch.device_id == device_id and touch.native_id == native_id) return;
    }
    const seat = self.seatForDevice(device_id);
    self.idle_notify.notifyActivity(seat);
    const protocol_id = self.allocateTouchId(seat);
    self.routed_touches.append(self.allocator, .{
        .device_id = device_id,
        .native_id = native_id,
        .seat = seat,
        .protocol_id = protocol_id,
    }) catch return self.terminate();

    const point = output.globalPoint(x, y);
    const focus = self.pointerFocus(point.x, point.y);
    if (self.session_lock.isLocked()) {
        if (focus) |target| {
            self.session_lock.pointerPressed(self.subcompositor.rootSurface(target.surface_id));
        }
    } else if (seat == &self.seat) {
        if (focus) |target| {
            const root = self.subcompositor.rootSurface(target.surface_id);
            self.window_manager.pointerButton(root, .pressed);
            self.layer_shell.pointerPressed(root);
            requestRepaint(self);
        } else {
            self.window_manager.pointerButton(null, .pressed);
            if (self.xdg_shell.hasPopupGrab()) self.xdg_shell.dismissPopupGrab();
        }
    }
    seat.touchDown(time, protocol_id, point.x, point.y, focus) catch {
        _ = self.routed_touches.pop();
        self.terminate();
    };
}

fn routeTouchUp(self: *Self, device_id: NativeInput.DeviceId, time: u32, native_id: i32) void {
    for (self.routed_touches.items, 0..) |touch, index| {
        if (touch.device_id != device_id or touch.native_id != native_id) continue;
        self.idle_notify.notifyActivity(touch.seat);
        _ = self.routed_touches.orderedRemove(index);
        touch.seat.touchUp(time, touch.protocol_id) catch self.terminate();
        return;
    }
}

fn routeTouchMotion(
    self: *Self,
    output: *RenderOutput,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    x: f64,
    y: f64,
) void {
    for (self.routed_touches.items) |touch| {
        if (touch.device_id != device_id or touch.native_id != native_id) continue;
        self.idle_notify.notifyActivity(touch.seat);
        const point = output.globalPoint(x, y);
        touch.seat.touchMotion(time, touch.protocol_id, point.x, point.y) catch self.terminate();
        return;
    }
}

fn cancelDeviceTouches(self: *Self, device_id: NativeInput.DeviceId) void {
    while (self.touchSeatForDevice(device_id)) |seat| self.cancelSeatTouches(seat);
}

fn cancelSeatTouches(self: *Self, seat: *Seat) void {
    seat.touchCancel();
    var index: usize = 0;
    while (index < self.routed_touches.items.len) {
        if (self.routed_touches.items[index].seat == seat) {
            _ = self.routed_touches.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

fn touchSeatForDevice(self: *Self, device_id: NativeInput.DeviceId) ?*Seat {
    for (self.routed_touches.items) |touch| {
        if (touch.device_id == device_id) return touch.seat;
    }
    return null;
}

fn allocateTouchId(self: *Self, seat: *Seat) i32 {
    while (true) {
        const id: i32 = @intCast(self.next_touch_id);
        self.next_touch_id +%= 1;
        for (self.routed_touches.items) |touch| {
            if (touch.seat == seat and touch.protocol_id == id) break;
        } else return id;
    }
}

fn keyboardAvailable(context: *anyopaque, available: bool) void {
    const self = serverForOutput(context);
    self.seat.setKeyboardAvailable(available);
}

fn keyboardKeymap(
    context: *anyopaque,
    format: wl.Keyboard.KeymapFormat,
    fd: std.posix.fd_t,
    size: u32,
) void {
    const self = serverForOutput(context);
    self.seat.setKeymap(format, fd, size);
}

fn keyboardEnter(context: *anyopaque, pressed_keys: []const u32) void {
    const self = serverForOutput(context);
    self.seat.parentKeyboardEnter(pressed_keys) catch {
        log.err("failed to store pressed keyboard keys", .{});
        self.terminate();
    };
}

fn keyboardLeave(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.parentKeyboardLeave();
}

fn keyboardKey(
    context: *anyopaque,
    time: u32,
    key: u32,
    state: wl.Keyboard.KeyState,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    self.seat.key(time, key, state) catch {
        log.err("failed to store keyboard state", .{});
        self.terminate();
    };
}

fn keyboardModifiers(
    context: *anyopaque,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) void {
    const self = serverForOutput(context);
    self.seat.setModifiers(depressed, latched, locked, group);
}

fn keyboardRepeatInfo(context: *anyopaque, rate: i32, delay: i32) void {
    const self = serverForOutput(context);
    self.seat.setRepeatInfo(rate, delay);
}

fn pointerAvailable(context: *anyopaque, available: bool) void {
    const self = serverForOutput(context);
    // The nested backend can report its initial state before later input protocols exist.
    if (!available and self.window_manager_initialized) {
        self.pointer_constraints.deactivateAll();
        self.data_device.cancel();
    }
    self.seat.setPointerAvailable(available);
}

fn pointerEnter(context: *anyopaque, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const point = output.globalPoint(x, y);
    const route = self.pointerRoute(point.x, point.y);
    if (self.session_lock.isLocked()) {
        self.seat.pointerEnter(point.x, point.y, route.focus);
        return;
    }
    if (self.window_manager.tilingDragActive()) {
        self.seat.pointerEnter(point.x, point.y, null);
        if (self.window_manager.updateTilingDrag(point.x, point.y)) requestRepaint(self);
        return;
    }
    if (self.data_device.isDragging()) {
        self.pointer_constraints.deactivateAll();
        self.seat.pointerEnter(
            point.x,
            point.y,
            self.data_device.externalDragPointerFocus(point.x, point.y),
        );
        self.xdg_toplevel_drag.pointerMotion(point.x, point.y);
        self.routeActiveDrag(0, self.dragPointerRoute(point.x, point.y), point.x, point.y, false);
        return;
    }
    self.seat.pointerEnter(point.x, point.y, route.focus);
    if (!self.xdg_shell.hasPopupGrab()) self.window_manager.pointerMoved(route.root);
    self.pointer_constraints.syncFocus();
}

fn pointerLeave(context: *anyopaque) void {
    const self = serverForOutput(context);
    if (self.window_manager.endTilingDrag(false)) requestRepaint(self);
    self.pointer_constraints.deactivateAll();
    self.data_device.pointerLeft();
    if (self.xwm_initialized) self.xwm.dragLeft();
    self.seat.pointerLeave();
}

fn pointerMotion(context: *anyopaque, time: u32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    pointerMotionForSeat(output, &output.server.seat, time, x, y);
}

fn pointerMotionForSeat(output: *RenderOutput, seat: *Seat, time: u32, x: f64, y: f64) void {
    const self = output.server;
    const target = output.globalPoint(x, y);
    self.pointerMotionGlobalForSeat(output, seat, time, target.x, target.y);
}

fn pointerMotionGlobalForSeat(
    self: *Self,
    backend_output: ?*RenderOutput,
    seat: *Seat,
    time: u32,
    x: f64,
    y: f64,
) void {
    self.idle_notify.notifyActivity(seat);
    if (self.session_lock.isLocked()) {
        seat.pointerMotion(
            time,
            x,
            y,
            self.pointerFocus(x, y),
        );
        return;
    }
    if (seat == &self.seat and self.window_manager.tilingDragActive()) {
        self.pointer_constraints.deactivateAll();
        seat.pointerMotion(time, x, y, null);
        if (self.window_manager.updateTilingDrag(x, y)) requestRepaint(self);
        return;
    }
    if (seat == &self.seat and self.data_device.isDragging()) {
        self.pointer_constraints.deactivateAll();
        seat.pointerMotion(
            time,
            x,
            y,
            self.data_device.externalDragPointerFocus(x, y),
        );
        self.xdg_toplevel_drag.pointerMotion(x, y);
        self.routeActiveDrag(
            time,
            self.dragPointerRoute(x, y),
            x,
            y,
            true,
        );
        return;
    }
    if (seat != &self.seat) {
        const route = self.pointerRoute(x, y);
        seat.pointerMotion(time, x, y, route.focus);
        return;
    }
    const motion = self.pointer_constraints.constrainMotion(.{ .x = x, .y = y });
    if (motion.point.x != x or motion.point.y != y) {
        if (backend_output) |output| {
            self.synchronizeBackendPointer(output, motion.point.x, motion.point.y);
        }
    }
    if (motion.locked) return;
    const route = self.pointerRoute(motion.point.x, motion.point.y);
    seat.pointerMotion(
        time,
        motion.point.x,
        motion.point.y,
        route.focus,
    );
    if (!self.xdg_shell.hasPopupGrab()) self.window_manager.pointerMoved(route.root);
    self.pointer_constraints.syncFocus();
}

const VirtualPointerBounds = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    output: ?*RenderOutput,
};

fn virtualPointerBounds(
    self: *Self,
    mapped_output: ?OutputLayout.Id,
) ?VirtualPointerBounds {
    if (mapped_output) |output_id| {
        if (self.findProtocolRenderOutput(output_id)) |render_output| {
            const output = self.outputs.get(output_id) orelse return null;
            const position = output.logicalPosition();
            const size = output.logicalSize();
            return .{
                .x = @floatFromInt(position.x),
                .y = @floatFromInt(position.y),
                .width = @floatFromInt(size.width),
                .height = @floatFromInt(size.height),
                .output = render_output,
            };
        }
    }

    var left: ?i64 = null;
    var top: ?i64 = null;
    var right: ?i64 = null;
    var bottom: ?i64 = null;
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        const position = entry.output.logicalPosition();
        const size = entry.output.logicalSize();
        left = @min(left orelse position.x, position.x);
        top = @min(top orelse position.y, position.y);
        const output_right = @as(i64, position.x) + size.width;
        const output_bottom = @as(i64, position.y) + size.height;
        right = @max(right orelse output_right, output_right);
        bottom = @max(bottom orelse output_bottom, output_bottom);
    }
    const x = left orelse return null;
    const y = top orelse return null;
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(right.? - x),
        .height = @floatFromInt(bottom.? - y),
        .output = null,
    };
}

fn renderOutputAt(self: *Self, x: f64, y: f64) *RenderOutput {
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| {
        const output = entry.value.*;
        const protocol_output = self.outputs.get(output.protocol_id) orelse continue;
        if (pointInRect(x, y, protocol_output.logicalRect())) return output;
    }
    return self.primaryRenderOutput();
}

fn clampVirtualPointerCoordinate(value: f64, origin: f64, dimension: f64) f64 {
    std.debug.assert(dimension >= 1);
    return std.math.clamp(value, origin, origin + dimension - 1);
}

fn normalizedVirtualPointerCoordinate(
    value: u32,
    extent: u32,
    origin: f64,
    dimension: f64,
) f64 {
    std.debug.assert(extent > 0 and dimension >= 1);
    const position = @as(f64, @floatFromInt(@min(value, extent))) /
        @as(f64, @floatFromInt(extent));
    return origin + position * (dimension - 1);
}

fn virtualPointerEvent(
    context: *anyopaque,
    seat: *Seat,
    mapped_output: ?OutputLayout.Id,
    source: u64,
    event: VirtualPointer.Event,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    switch (event) {
        .motion => |motion| {
            const bounds = self.virtualPointerBounds(mapped_output) orelse return;
            if (seat == &self.seat) {
                self.relative_pointer.motion(
                    @as(u64, motion.time) * std.time.us_per_ms,
                    motion.dx,
                    motion.dy,
                    motion.dx,
                    motion.dy,
                );
            }
            const current = seat.pointerPosition();
            const current_x = if (current) |point| point.x else bounds.x;
            const current_y = if (current) |point| point.y else bounds.y;
            const x = clampVirtualPointerCoordinate(current_x + motion.dx, bounds.x, bounds.width);
            const y = clampVirtualPointerCoordinate(current_y + motion.dy, bounds.y, bounds.height);
            self.pointerMotionGlobalForSeat(
                bounds.output orelse self.renderOutputAt(x, y),
                seat,
                motion.time,
                x,
                y,
            );
        },
        .motion_absolute => |motion| {
            if (motion.x_extent == 0 or motion.y_extent == 0) return;
            const bounds = self.virtualPointerBounds(mapped_output) orelse return;
            const x = normalizedVirtualPointerCoordinate(
                motion.x,
                motion.x_extent,
                bounds.x,
                bounds.width,
            );
            const y = normalizedVirtualPointerCoordinate(
                motion.y,
                motion.y_extent,
                bounds.y,
                bounds.height,
            );
            self.pointerMotionGlobalForSeat(
                bounds.output orelse self.renderOutputAt(x, y),
                seat,
                motion.time,
                x,
                y,
            );
        },
        .button => |button| self.routePointerButtonFromSource(
            .{ .virtual = source },
            seat,
            button.time,
            button.button,
            button.state,
        ),
        .axis => |axis| {
            self.idle_notify.notifyActivity(seat);
            seat.pointerAxis(axis.time, axis.axis, axis.value);
        },
        .frame => seat.pointerFrame(),
        .axis_source => |axis_source| seat.pointerAxisSource(axis_source),
        .axis_stop => |stop| seat.pointerAxisStop(stop.time, stop.axis),
        .axis_discrete => |axis| {
            self.idle_notify.notifyActivity(seat);
            seat.pointerAxisDiscrete(axis.axis, axis.discrete);
            seat.pointerAxisValue120(axis.axis, axis.discrete *| 120);
            seat.pointerAxis(axis.time, axis.axis, axis.value);
        },
    }
}

fn synchronizeBackendPointer(self: *Self, output: *RenderOutput, x: f64, y: f64) void {
    if (!self.native_input_initialized) return;
    const position = self.outputs.get(output.protocol_id).?.logicalPosition();
    self.native_input.setPointerPosition(
        x - @as(f64, @floatFromInt(position.x)),
        y - @as(f64, @floatFromInt(position.y)),
    );
}

fn pointerWarp(context: *anyopaque, surface_id: Surface.Id, x: f64, y: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const position = self.seat.warpPointer(surface_id, x, y) orelse return;
    self.synchronizeBackendPointer(
        self.primaryRenderOutput(),
        position.x,
        position.y,
    );
}

fn pointerRelativeMotion(
    context: *anyopaque,
    time_usec: u64,
    dx: f64,
    dy: f64,
    dx_unaccelerated: f64,
    dy_unaccelerated: f64,
) void {
    const self = serverForOutput(context);
    self.relative_pointer.motion(time_usec, dx, dy, dx_unaccelerated, dy_unaccelerated);
}

fn pointerButton(
    context: *anyopaque,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    self.pointerButtonForSeat(&self.seat, time, button, state);
}

fn pointerButtonForSeat(
    self: *Self,
    seat: *Seat,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    if (self.session_lock.isLocked()) {
        if (state == .pressed) {
            const focused = if (seat.pointerFocusedSurface()) |surface_id|
                self.subcompositor.rootSurface(surface_id)
            else
                null;
            self.session_lock.pointerPressed(focused);
        }
        _ = seat.pointerButton(time, button, state) catch {
            log.err("failed to store pointer button state", .{});
            self.terminate();
        };
        return;
    }
    if (seat == &self.seat and self.data_device.isDragging()) {
        const grab_ended = seat.pointerButton(time, button, state) catch {
            log.err("failed to store pointer button state", .{});
            self.terminate();
            return;
        };
        if (state == .released and grab_ended) {
            if (!self.xwm_initialized or !self.xwm.dropDrag(time)) self.data_device.drop();
        }
        return;
    }
    if (seat == &self.seat and self.window_manager.tilingDragActive()) {
        if (button == linux_button_left and state == .released) {
            const position = seat.pointerPosition();
            if (position) |point| {
                _ = self.window_manager.updateTilingDrag(point.x, point.y);
            }
            _ = self.window_manager.endTilingDrag(true);
            if (position) |point| {
                const route = self.pointerRoute(point.x, point.y);
                seat.pointerEnter(point.x, point.y, route.focus);
                self.pointer_constraints.syncFocus();
            }
            requestRepaint(self);
        } else {
            _ = seat.pointerButton(time, button, state) catch {
                log.err("failed to store pointer button state", .{});
                self.terminate();
            };
        }
        return;
    }
    const root = if (seat.pointerPosition()) |position|
        self.pointerRoute(position.x, position.y).root
    else
        null;
    if (seat == &self.seat and button == linux_button_left and state == .pressed and
        seat.effectiveModifiers() & Config.super != 0 and
        !seat.hasPressedPointerButtons() and
        !self.keyboard_shortcuts_inhibit.inhibitsSeatNamed(InputManager.default_seat_name) and
        !self.xdg_shell.hasPopupGrab() and self.window_manager.beginTilingDrag(root))
    {
        self.pointer_constraints.deactivateAll();
        seat.suppressPointerFocus(true);
        if (seat.pointerPosition()) |position| {
            _ = self.window_manager.updateTilingDrag(position.x, position.y);
        }
        requestRepaint(self);
        return;
    }
    self.window_manager.pointerButton(root, state);
    if (state == .pressed) {
        const focused = if (seat.pointerFocusedSurface()) |surface_id|
            self.subcompositor.rootSurface(surface_id)
        else
            null;
        if (seat == &self.seat) self.layer_shell.pointerPressed(focused);
        requestRepaint(self);
    }
    if (seat == &self.seat and state == .pressed and self.xdg_shell.hasPopupGrab() and
        seat.pointerFocusedSurface() == null)
    {
        self.xdg_shell.dismissPopupGrab();
        return;
    }
    _ = seat.pointerButton(time, button, state) catch {
        log.err("failed to store pointer button state", .{});
        self.terminate();
    };
}

fn dragStarted(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager.endTilingDrag(false)) requestRepaint(self);
    self.pointer_constraints.deactivateAll();
    if (self.xwm_initialized) self.xwm.dragStarted();
    const position = self.seat.pointerPosition() orelse return;
    const route = self.dragPointerRoute(position.x, position.y);
    if (!self.data_device.dragIsExternal()) self.seat.suppressPointerFocus(true);
    self.routeActiveDrag(0, route, position.x, position.y, false);
}

fn xdgToplevelDragBegin(
    context: *anyopaque,
    window_id: XdgShell.WindowId,
    pointer_x: f64,
    pointer_y: f64,
    x_offset: i32,
    y_offset: i32,
    use_offset_hint: bool,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.window_manager.beginToplevelDrag(
        window_id,
        pointer_x,
        pointer_y,
        x_offset,
        y_offset,
        use_offset_hint,
    );
}

fn xdgToplevelDragMotion(context: *anyopaque, x: f64, y: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.window_manager.updateToplevelDrag(x, y);
}

fn xdgToplevelDragEnd(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.window_manager.endToplevelDrag();
}

fn dragEnded(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.physicalDragEnded();
    const position = self.seat.pointerPosition() orelse return;
    const route = self.pointerRoute(position.x, position.y);
    self.seat.pointerEnter(position.x, position.y, route.focus);
    if (!self.xdg_shell.hasPopupGrab()) self.window_manager.pointerMoved(route.root);
    self.pointer_constraints.syncFocus();
}

fn dragExternalSourceDestroyed(context: *anyopaque, generation: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.dragSourceDestroyed(generation);
}

fn routeActiveDrag(
    self: *Self,
    time: u32,
    route: PointerRoute,
    x: f64,
    y: f64,
    motion: bool,
) void {
    if (self.xwm_initialized) {
        if (self.data_device.dragIsExternal()) {
            if (route.root) |surface_id| if (self.xwaylandWindowForSurface(surface_id) != null) {
                self.data_device.pointerLeft();
                self.xwm.routeExternalDragOverXwayland(true);
                return;
            };
            self.xwm.routeExternalDragOverXwayland(false);
        } else {
            if (route.root) |surface_id| if (self.xwaylandWindowForSurface(surface_id)) |window_id| {
                self.data_device.pointerLeft();
                self.xwm.dragMotion(window_id, time, x, y);
                return;
            };
            self.xwm.dragLeft();
        }
    }
    if (motion) {
        self.data_device.pointerMotion(time, route.focus);
    } else {
        self.data_device.pointerEntered(route.focus);
    }
}

fn pointerAxis(context: *anyopaque, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    self.seat.pointerAxis(time, axis, value);
}

fn pointerFrame(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.pointerFrame();
}

fn pointerAxisSource(context: *anyopaque, source: wl.Pointer.AxisSource) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisSource(source);
}

fn pointerAxisStop(context: *anyopaque, time: u32, axis: wl.Pointer.Axis) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisStop(time, axis);
}

fn pointerAxisDiscrete(context: *anyopaque, axis: wl.Pointer.Axis, discrete: i32) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisDiscrete(axis, discrete);
}

fn pointerAxisValue120(context: *anyopaque, axis: wl.Pointer.Axis, value120: i32) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisValue120(axis, value120);
}

fn pointerAxisRelativeDirection(
    context: *anyopaque,
    axis: wl.Pointer.Axis,
    direction: wl.Pointer.AxisRelativeDirection,
) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisRelativeDirection(axis, direction);
}

fn touchAvailable(context: *anyopaque, available: bool) void {
    const self = serverForOutput(context);
    self.seat.setTouchAvailable(available);
}

fn touchDown(context: *anyopaque, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    self.idle_notify.notifyActivity(&self.seat);
    const point = output.globalPoint(x, y);
    const focus = self.pointerFocus(point.x, point.y);
    if (self.session_lock.isLocked()) {
        if (focus) |target| {
            self.session_lock.pointerPressed(self.subcompositor.rootSurface(target.surface_id));
        }
        self.seat.touchDown(time, id, point.x, point.y, focus) catch {
            log.err("failed to store touch point", .{});
            self.terminate();
        };
        return;
    }
    if (focus) |target| {
        const root = self.subcompositor.rootSurface(target.surface_id);
        self.window_manager.pointerButton(root, .pressed);
        self.layer_shell.pointerPressed(root);
        requestRepaint(self);
    } else {
        self.window_manager.pointerButton(null, .pressed);
        if (self.xdg_shell.hasPopupGrab()) self.xdg_shell.dismissPopupGrab();
    }
    self.seat.touchDown(time, id, point.x, point.y, focus) catch {
        log.err("failed to store touch point", .{});
        self.terminate();
    };
}

fn touchUp(context: *anyopaque, time: u32, id: i32) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    self.seat.touchUp(time, id) catch {
        log.err("failed to finish touch point", .{});
        self.terminate();
    };
}

fn touchMotion(context: *anyopaque, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    self.idle_notify.notifyActivity(&self.seat);
    const point = output.globalPoint(x, y);
    self.seat.touchMotion(time, id, point.x, point.y) catch {
        log.err("failed to update touch point", .{});
        self.terminate();
    };
}

fn touchFrame(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.touchFrame();
}

fn touchCancel(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.touchCancel();
}

fn touchShape(context: *anyopaque, id: i32, major: f64, minor: f64) void {
    const self = serverForOutput(context);
    self.seat.touchShape(id, major, minor) catch {
        log.err("failed to update touch shape", .{});
        self.terminate();
    };
}

fn touchOrientation(context: *anyopaque, id: i32, orientation: f64) void {
    const self = serverForOutput(context);
    self.seat.touchOrientation(id, orientation) catch {
        log.err("failed to update touch orientation", .{});
        self.terminate();
    };
}

fn pointerFocus(self: *Self, x: f64, y: f64) ?Seat.PointerFocus {
    return self.pointerFocusExcluding(x, y, null);
}

fn pointerFocusExcluding(
    self: *Self,
    x: f64,
    y: f64,
    excluded_window: ?Scene.Id,
) ?Seat.PointerFocus {
    if (self.session_lock.isLocked()) {
        var outputs = self.outputs.iterator();
        while (outputs.next()) |entry| {
            if (!pointInRect(x, y, entry.output.logicalRect())) continue;
            const info = self.session_lock.surfaceForOutput(entry.id) orelse return null;
            return self.hitTestSurface(info.surface_id, .{
                .x = info.position.x,
                .y = info.position.y,
            }, x, y);
        }
        return null;
    }
    const focus = self.scenePointerFocus(x, y, excluded_window);
    if (focus) |candidate| {
        if (self.xdg_shell.hasPopupGrab() and
            !self.xdg_shell.popupGrabOwnsSurface(candidate.surface_id)) return null;
    }
    return focus;
}

fn pointerRoute(self: *Self, x: f64, y: f64) PointerRoute {
    return self.pointerRouteExcluding(x, y, null);
}

fn dragPointerRoute(self: *Self, x: f64, y: f64) PointerRoute {
    return self.pointerRouteExcluding(x, y, self.xdg_toplevel_drag.attachedScene());
}

fn pointerRouteExcluding(
    self: *Self,
    x: f64,
    y: f64,
    excluded_window: ?Scene.Id,
) PointerRoute {
    const focus = self.pointerFocusExcluding(x, y, excluded_window);
    return .{
        .focus = focus,
        .root = if (focus) |value|
            self.subcompositor.rootSurface(value.surface_id)
        else if (self.session_lock.isLocked())
            null
        else
            self.borderRoot(x, y, excluded_window),
    };
}

fn borderRoot(self: *Self, x: f64, y: f64, excluded_window: ?Scene.Id) ?Surface.Id {
    const fullscreen = excludeScene(self.topFullscreenAtPoint(x, y), excluded_window);
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (excluded_window) |excluded| {
                if (std.meta.eql(window_entry.id, excluded)) continue;
            }
            if (fullscreen) |fullscreen_id| {
                if (!std.meta.eql(window_entry.id, fullscreen_id)) continue;
            }
            const window = window_entry.window;
            if (!window.mapped) continue;
            const borders = window.borders orelse continue;
            const buffer = Surface.currentBuffer(self.compositor.surfaceStore(), window.surface_id) orelse continue;
            const content_size = if (window.content_geometry) |geometry|
                geometry.size
            else
                buffer.logical_size;
            const content = windowContentRect(window, content_size) orelse continue;
            var commands: [4]render.Command = undefined;
            const clip = if (window.clip_box) |box| box.translated(window.position.x, window.position.y) else null;
            for (makeBorderCommands(
                content,
                borders,
                window.effects.corner_radius,
                clip,
                &commands,
            )) |command| {
                if (pointInBorderCommand(x, y, command)) return window.surface_id;
            }
            if (fullscreen != null) return null;
        },
        else => {},
    };
    return null;
}

fn scenePointerFocus(
    self: *Self,
    x: f64,
    y: f64,
    excluded_window: ?Scene.Id,
) ?Seat.PointerFocus {
    var input_popups = self.input_method.reversePopupIterator();
    while (input_popups.next()) |popup| {
        if (self.hitTestSurface(
            popup.surface_id,
            .{ .x = popup.position.x, .y = popup.position.y },
            x,
            y,
        )) |focus| return focus;
    }
    if (self.hitTestLayerPopups(x, y)) |focus| return focus;
    if (self.hitTestLayer(.overlay, x, y)) |focus| return focus;
    const fullscreen = excludeScene(self.topFullscreenAtPoint(x, y), excluded_window);
    if (fullscreen == null) {
        if (self.hitTestLayer(.top, x, y)) |focus| return focus;
    }
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (excluded_window) |excluded| {
                if (std.meta.eql(window_entry.id, excluded)) continue;
            }
            if (fullscreen) |fullscreen_id| {
                if (!std.meta.eql(window_entry.id, fullscreen_id)) continue;
                return self.hitTestWindow(window_entry.id, window_entry.window, x, y);
            }
            if (self.hitTestWindow(window_entry.id, window_entry.window, x, y)) |focus| return focus;
        },
        .shell_surface => |shell_entry| {
            const shell_surface = shell_entry.shell_surface;
            if (!shell_surface.mapped) continue;
            if (self.hitTestSurface(
                shell_surface.surface_id,
                shell_surface.position,
                x,
                y,
            )) |focus| return focus;
        },
    };
    if (fullscreen != null) return null;
    if (self.hitTestLayer(.bottom, x, y)) |focus| return focus;
    if (self.hitTestLayer(.background, x, y)) |focus| return focus;
    return null;
}

fn excludeScene(candidate: ?Scene.Id, excluded: ?Scene.Id) ?Scene.Id {
    const value = candidate orelse return null;
    if (excluded) |excluded_id| {
        if (std.meta.eql(value, excluded_id)) return null;
    }
    return value;
}

fn topFullscreenAtPoint(self: *Self, x: f64, y: f64) ?Scene.Id {
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        const output_rect = entry.output.logicalRect();
        if (pointInRect(x, y, output_rect)) return self.topFullscreenForOutput(output_rect);
    }
    return null;
}

fn topFullscreenForOutput(self: *Self, output_rect: render.Rect) ?Scene.Id {
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            const window = window_entry.window;
            if (!window.mapped or !window.fullscreen) continue;
            if (window.clip_box) |clip_box| {
                const global_clip = clip_box.translated(window.position.x, window.position.y);
                if (global_clip.intersection(output_rect) == null) continue;
            }
            return window_entry.id;
        },
        .shell_surface => {},
    };
    return null;
}

fn hitTestLayerPopups(self: *Self, x: f64, y: f64) ?Seat.PointerFocus {
    inline for (.{
        Scene.Layer.overlay,
        Scene.Layer.top,
        Scene.Layer.bottom,
        Scene.Layer.background,
    }) |layer| {
        var roots = self.scene.reverseLayerSurfaceIterator(layer);
        while (roots.next()) |root| {
            var popups = self.scene.reverseLayerPopupIterator(root.id);
            while (popups.next()) |entry| {
                if (!entry.popup.mapped) continue;
                const buffer = Surface.currentBuffer(
                    self.compositor.surfaceStore(),
                    entry.popup.surface_id,
                ) orelse continue;
                const geometry = entry.popup.content_geometry orelse Scene.ContentGeometry{
                    .size = buffer.logical_size,
                };
                if (self.hitTestSurface(entry.popup.surface_id, .{
                    .x = entry.position.x -| geometry.offset.x,
                    .y = entry.position.y -| geometry.offset.y,
                }, x, y)) |focus| return focus;
            }
        }
    }
    return null;
}

fn hitTestLayer(self: *Self, layer: Scene.Layer, x: f64, y: f64) ?Seat.PointerFocus {
    var surfaces = self.scene.reverseLayerSurfaceIterator(layer);
    while (surfaces.next()) |entry| {
        const layer_surface = entry.layer_surface;
        if (!layer_surface.mapped) continue;
        if (self.hitTestSurface(
            layer_surface.surface_id,
            layer_surface.position,
            x,
            y,
        )) |focus| return focus;
    }
    return null;
}

fn hitTestWindow(
    self: *Self,
    window_id: Scene.Id,
    window: *const Scene.Window,
    x: f64,
    y: f64,
) ?Seat.PointerFocus {
    if (!window.mapped) return null;
    var popups = self.scene.reversePopupIterator(window_id);
    while (popups.next()) |entry| {
        const popup = entry.popup;
        if (!popup.mapped) continue;
        const buffer = Surface.currentBuffer(
            self.compositor.surfaceStore(),
            popup.surface_id,
        ) orelse continue;
        const content_geometry = popup.content_geometry orelse Scene.ContentGeometry{
            .size = buffer.logical_size,
        };
        if (self.hitTestSurface(
            popup.surface_id,
            .{
                .x = entry.position.x -| content_geometry.offset.x,
                .y = entry.position.y -| content_geometry.offset.y,
            },
            x,
            y,
        )) |focus| return focus;
    }
    if (window.clip_box) |clip_box| {
        if (!pointInRect(x, y, clip_box.translated(window.position.x, window.position.y))) return null;
    }
    var above = self.scene.decorationIterator(window_id, .above);
    while (above.next()) |entry| if (entry.decoration.mapped) {
        if (self.hitTestSurface(entry.decoration.surface_id, .{
            .x = window.position.x +| entry.decoration.offset.x,
            .y = window.position.y +| entry.decoration.offset.y,
        }, x, y)) |focus| return focus;
    };
    const root_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) orelse return null;
    const content_geometry = window.content_geometry orelse Scene.ContentGeometry{
        .size = root_buffer.logical_size,
    };
    var test_content = true;
    if (window.content_clip_box) |clip_box| {
        const content_rect: render.Rect = .{
            .x = window.position.x,
            .y = window.position.y,
            .width = content_geometry.size.width,
            .height = content_geometry.size.height,
        };
        const visible = content_rect.intersection(
            clip_box.translated(window.position.x, window.position.y),
        );
        test_content = test_content and if (visible) |rect| pointInRect(x, y, rect) else false;
    }
    if (test_content and window.effects.corner_radius > 0) {
        const visible = windowContentRect(window, content_geometry.size) orelse return null;
        test_content = pointInRoundedRect(x, y, visible, window.effects.corner_radius);
    }
    if (test_content) if (self.hitTestSurface(
        window.surface_id,
        .{
            .x = window.position.x -| content_geometry.offset.x,
            .y = window.position.y -| content_geometry.offset.y,
        },
        x,
        y,
    )) |focus| return focus;
    var below = self.scene.decorationIterator(window_id, .below);
    while (below.next()) |entry| if (entry.decoration.mapped) {
        if (self.hitTestSurface(entry.decoration.surface_id, .{
            .x = window.position.x +| entry.decoration.offset.x,
            .y = window.position.y +| entry.decoration.offset.y,
        }, x, y)) |focus| return focus;
    };
    return null;
}

fn hitTestSurface(
    self: *Self,
    surface_id: Surface.Id,
    position: Scene.Position,
    x: f64,
    y: f64,
) ?Seat.PointerFocus {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return null;

    var stack = self.subcompositor.reverseStackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const surface_x = x - @as(f64, @floatFromInt(position.x));
            const surface_y = y - @as(f64, @floatFromInt(position.y));
            if (Surface.acceptsInput(
                self.compositor.surfaceStore(),
                surface_id,
                surface_x,
                surface_y,
            )) {
                return .{ .surface_id = surface_id, .x = surface_x, .y = surface_y };
            }
        },
        .child => |child| if (self.hitTestSurface(
            child.surface_id,
            .{
                .x = position.x +| child.position.x,
                .y = position.y +| child.position.y,
            },
            x,
            y,
        )) |focus| return focus,
    };
    return null;
}

fn pointInRect(x: f64, y: f64, rect: render.Rect) bool {
    return x >= @as(f64, @floatFromInt(rect.x)) and
        y >= @as(f64, @floatFromInt(rect.y)) and
        x < @as(f64, @floatFromInt(@as(i64, rect.x) + rect.width)) and
        y < @as(f64, @floatFromInt(@as(i64, rect.y) + rect.height));
}

fn pointInRoundedRect(x: f64, y: f64, rect: render.Rect, requested_radius: u32) bool {
    if (!pointInRect(x, y, rect)) return false;
    const radius: f64 = @floatFromInt(@min(
        requested_radius,
        @min(rect.width, rect.height) / 2,
    ));
    if (radius == 0) return true;

    const left: f64 = @floatFromInt(rect.x);
    const top: f64 = @floatFromInt(rect.y);
    const right: f64 = @floatFromInt(@as(i64, rect.x) + rect.width);
    const bottom: f64 = @floatFromInt(@as(i64, rect.y) + rect.height);
    const center_x = std.math.clamp(x, left + radius, right - radius);
    const center_y = std.math.clamp(y, top + radius, bottom - radius);
    const distance_x = x - center_x;
    const distance_y = y - center_y;
    return distance_x * distance_x + distance_y * distance_y <= radius * radius;
}

fn captureConstraints(
    context: *anyopaque,
    target: ImageCopyCapture.Target,
) ?ImageCopyCapture.Constraints {
    const self: *Self = @ptrCast(@alignCast(context));
    return switch (target) {
        .source => |source| captureSourceConstraints(self, source),
        .cursor => |cursor| if (self.cursorCaptureState(cursor)) |state|
            .{ .size = state.size }
        else
            null,
    };
}

fn captureSourceConstraints(
    self: *Self,
    target: ImageCaptureSource.Target,
) ?ImageCopyCapture.Constraints {
    return switch (target) {
        .output => |output_id| output: {
            const render_output = self.renderOutputForProtocol(output_id) orelse return null;
            break :output .{ .size = render_output.backend.modeSize() };
        },
        .toplevel => |window_id| toplevel: {
            const bounds = self.toplevelCaptureBounds(window_id) orelse return null;
            break :toplevel .{ .size = .{ .width = bounds.width, .height = bounds.height } };
        },
    };
}

fn screencopyConstraints(context: *anyopaque, target: Screencopy.Target) ?render.Size {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.renderOutputForProtocol(target.output) orelse return null;
    if (target.region) |region| {
        const physical = scaledScreencopyRegion(
            region,
            render_output.backend.renderScale(),
            render_output.backend.modeSize(),
        ) orelse return null;
        return .{ .width = physical.width, .height = physical.height };
    }
    return render_output.backend.modeSize();
}

fn xwaylandSurfaceAssociated(context: *anyopaque, serial: u64, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) _ = self.xwm.associateSurface(serial, surface_id);
}

fn xwaylandSurfaceCommitted(
    context: *anyopaque,
    serial: u64,
    surface_id: Surface.Id,
    _: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const window_id = self.xwm.windowForSerial(serial) orelse return;
    const window = self.xwayland_windows.get(window_id) orelse return;
    if (!std.meta.eql(window.surface_id, surface_id)) return;
    refreshXwaylandSceneWindow(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
    self.scene.surfaceCommitted(window.scene_id);
}

fn xwaylandSurfaceRemoved(context: *anyopaque, serial: u64, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.removeSurfaceAssociation(serial, surface_id);
}

fn xwaylandReady(
    context: *anyopaque,
    display_name: []const u8,
    wm_fd: std.posix.fd_t,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(!self.xwm_initialized);
    self.xwm.init(
        self.allocator,
        self.display.getEventLoop(),
        wm_fd,
        &self.data_device,
        &self.primary_selection,
        .{
            .context = self,
            .failed = xwmFailed,
            .created = xwmWindowCreated,
            .destroyed = xwmWindowDestroyed,
            .mapped = xwmWindowMapped,
            .configured = xwmWindowConfigured,
            .metadata_changed = xwmWindowMetadataChanged,
            .fullscreen_requested = xwmWindowFullscreenRequested,
            .maximize_requested = xwmWindowMaximizeRequested,
            .minimize_requested = xwmWindowMinimizeRequested,
            .activation_requested = xwmWindowActivationRequested,
            .activation_changed = xwmWindowActivationChanged,
            .move_resize_requested = xwmWindowMoveResizeRequested,
            .serial = xwmWindowSerial,
            .associated = xwmWindowAssociated,
            .dissociated = xwmWindowDissociated,
        },
    ) catch |err| {
        log.err("failed to initialize XWM: {t}", .{err});
        return false;
    };
    self.xwm_initialized = true;
    log.info("X11 clients may use DISPLAY={s}", .{display_name});
    return true;
}

fn xwaylandStopped(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) {
        self.xwm.deinit();
        self.xwm_initialized = false;
    }
    log.info("Xwayland stopped", .{});
}

fn xwaylandUnavailable(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwayland_display_listener) |listener|
        listener.unavailable(listener.context);
}

fn xwmFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(self.xwm_initialized);
    self.xwm.deinit();
    self.xwm_initialized = false;
    self.xwayland_server.terminate();
}

fn xwmWindowCreated(_: *anyopaque, _: Xwm.WindowInfo) void {}

fn xwmWindowDestroyed(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    removeXwaylandWindow(self, window_id);
}

fn xwmWindowMapped(context: *anyopaque, window_id: Xwm.WindowId, mapped: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMapped(window_id, mapped);
    }
    if (self.foreign_toplevel_list_initialized) {
        const surface_id = if (self.xwayland_windows.get(window_id)) |window|
            window.surface_id
        else
            null;
        self.foreign_toplevel_list.xwaylandWindowMapped(
            window_id,
            mapped,
            surface_id,
        ) catch {
            log.err("failed to update X11 foreign-toplevel mapping", .{});
            return self.terminate();
        };
    }
    refreshXwaylandSceneWindow(self, window_id);
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowConfigured(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    geometry: Xwm.Geometry,
    override_redirect: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const window = self.xwayland_windows.get(window_id) orelse return;
    configureXwaylandSceneWindow(self, window.scene_id, geometry);
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowConfigured(window_id, geometry, override_redirect);
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowConfigured(
            window_id,
            override_redirect,
            window.surface_id,
        ) catch {
            log.err("failed to update X11 foreign-toplevel configuration", .{});
            return self.terminate();
        };
    }
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowMetadataChanged(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const info = self.xwm.windowInfo(window_id) orelse return;
    log.debug("X11 window {d} metadata changed: type={s} app_id={?s} title={?s}", .{
        window_id,
        @tagName(info.window_type),
        info.app_id,
        info.title,
    });
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMetadataChanged(window_id);
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowMetadataChanged(window_id) catch {
            log.err("failed to update X11 foreign-toplevel metadata", .{});
            return self.terminate();
        };
    }
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowFullscreenRequested(context: *anyopaque, window_id: Xwm.WindowId, fullscreen: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        const info = self.xwm.windowInfo(window_id) orelse return;
        if (info.fullscreen == fullscreen) {
            self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
        }
    }
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowFullscreenRequested(window_id, fullscreen, null);
    }
}

fn xwmWindowMaximizeRequested(context: *anyopaque, window_id: Xwm.WindowId, maximized: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        const info = self.xwm.windowInfo(window_id) orelse return;
        if (info.maximized == maximized) {
            self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
        }
    }
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMaximizeRequested(window_id, maximized);
    }
}

fn xwmWindowMinimizeRequested(context: *anyopaque, window_id: Xwm.WindowId, minimized: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        const info = self.xwm.windowInfo(window_id) orelse return;
        if (info.minimized == minimized) {
            self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
        }
    }
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMinimizeRequested(window_id, minimized);
    }
}

fn xwmWindowActivationRequested(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowActivationRequested(window_id, &self.seat);
    }
}

fn xwmWindowActivationChanged(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn xwmWindowMoveResizeRequested(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    request: Xwm.MoveResizeRequest,
    x11_button: u32,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.window_manager_initialized) return;
    if (request == .cancel) {
        self.window_manager.xwaylandWindowMoveResizeRequested(window_id, request);
        return;
    }
    const info = self.xwm.windowInfo(window_id) orelse return;
    const surface_id = info.surface_id orelse return;
    const button = x11PointerButton(x11_button) orelse return;
    if (!self.seat.hasPressedPointerButtonForSurface(button, surface_id)) return;
    self.window_manager.xwaylandWindowMoveResizeRequested(window_id, request);
}

fn x11PointerButton(button: u32) ?u32 {
    return switch (button) {
        1 => 0x110,
        2 => 0x112,
        3 => 0x111,
        else => null,
    };
}

fn xwmWindowSerial(context: *anyopaque, _: Xwm.WindowId, serial: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const surface_id = self.xwayland_shell.surfaceForSerial(serial) orelse return;
    _ = self.xwm.associateSurface(serial, surface_id);
}

fn xwmWindowAssociated(context: *anyopaque, window_id: Xwm.WindowId, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const info = self.xwm.windowInfo(window_id) orelse return;
    const scene_id = self.scene.addWindow(surface_id) catch {
        log.err("failed to add X11 window {d} to the scene", .{window_id});
        self.terminate();
        return;
    };
    self.xwayland_windows.put(self.allocator, window_id, .{
        .scene_id = scene_id,
        .surface_id = surface_id,
    }) catch {
        self.scene.removeWindow(scene_id);
        log.err("failed to track X11 window {d}", .{window_id});
        self.terminate();
        return;
    };
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowAssociated(
            window_id,
            scene_id,
            surface_id,
        ) catch {
            _ = self.xwayland_windows.remove(window_id);
            self.scene.removeWindow(scene_id);
            log.err("failed to expose X11 window {d} to the window manager", .{window_id});
            self.terminate();
            return;
        };
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowAssociated(window_id, surface_id) catch {
            if (self.window_manager_initialized) {
                self.window_manager.xwaylandWindowDissociated(window_id);
            }
            _ = self.xwayland_windows.remove(window_id);
            self.scene.removeWindow(scene_id);
            log.err("failed to expose X11 window {d} through foreign-toplevel", .{window_id});
            self.terminate();
            return;
        };
    }
    configureXwaylandSceneWindow(self, scene_id, info.geometry);
    refreshXwaylandSceneWindow(self, window_id);
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowDissociated(context: *anyopaque, window_id: Xwm.WindowId, _: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized and self.xwayland_windows.contains(window_id)) {
        self.window_manager.xwaylandWindowDissociated(window_id);
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowDissociated(window_id);
    }
    removeXwaylandWindow(self, window_id);
}

fn configureXwaylandSceneWindow(
    self: *Self,
    scene_id: Scene.Id,
    geometry: Xwm.Geometry,
) void {
    self.scene.setPosition(scene_id, .{ .x = geometry.x, .y = geometry.y });
    self.scene.setContentGeometry(scene_id, .{
        .size = .{ .width = geometry.width, .height = geometry.height },
    });
}

fn refreshXwaylandSceneWindow(self: *Self, window_id: Xwm.WindowId) void {
    const window = self.xwayland_windows.get(window_id) orelse return;
    const info = self.xwm.windowInfo(window_id) orelse return;
    const has_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) != null;
    const displayed = !self.window_manager_initialized or
        self.window_manager.xwaylandWindowDisplayed(window_id);
    self.scene.setMapped(window.scene_id, info.mapped and has_buffer and displayed);
}

fn applyXwaylandSceneStacking(self: *Self, window_id: Xwm.WindowId) void {
    const window = self.xwayland_windows.get(window_id) orelse return;
    const info = self.xwm.windowInfo(window_id) orelse return;
    if (info.window_type == .desktop) {
        self.scene.placeBottom(window.scene_id);
    } else if (!info.participatesInWindowManagement()) {
        self.scene.placeTop(window.scene_id);
    } else if (info.parent) |parent_id| {
        if (self.xwayland_windows.get(parent_id)) |parent| {
            self.scene.placeAbove(window.scene_id, parent.scene_id);
        }
    }
    syncXwaylandClientStacking(self);
}

fn syncXwaylandClientStacking(self: *Self) void {
    if (!self.xwm_initialized) return;
    self.xwayland_client_stack.clearRetainingCapacity();
    var scene_windows = self.scene.iterator();
    while (scene_windows.next()) |scene_window| {
        var xwayland_windows = self.xwayland_windows.iterator();
        while (xwayland_windows.next()) |entry| {
            if (!std.meta.eql(entry.value_ptr.scene_id, scene_window.id)) continue;
            const info = self.xwm.windowInfo(entry.key_ptr.*) orelse break;
            if (info.mapped and !info.override_redirect) {
                self.xwayland_client_stack.append(
                    self.allocator,
                    entry.key_ptr.*,
                ) catch return self.terminate();
            }
            break;
        }
    }
    self.xwm.setClientStacking(self.xwayland_client_stack.items) catch {
        log.err("failed to publish X11 client stacking", .{});
        self.terminate();
    };
}

fn updateXwaylandOverrideRedirectFocus(self: *Self, window_id: Xwm.WindowId) void {
    const window = self.xwayland_windows.get(window_id) orelse return;
    const info = self.xwm.windowInfo(window_id) orelse return;
    if (info.mapped and info.override_redirect and info.override_redirect_wants_focus and
        self.scene.surfaceMapped(window.surface_id))
    {
        if (self.xwayland_override_redirect_focus) |current| {
            if (std.meta.eql(current, window.surface_id)) return;
        }
        self.xwayland_override_redirect_focus = window.surface_id;
        refreshKeyboardFocus(self);
        return;
    }
    const current = self.xwayland_override_redirect_focus orelse return;
    if (!std.meta.eql(current, window.surface_id)) return;
    var replacement: ?Surface.Id = null;
    if (info.parent) |parent_id| {
        if (self.xwayland_windows.get(parent_id)) |parent| {
            if (self.xwm.windowInfo(parent_id)) |parent_info| {
                if (parent_info.mapped and parent_info.override_redirect and
                    parent_info.override_redirect_wants_focus and
                    self.scene.surfaceMapped(parent.surface_id))
                {
                    replacement = parent.surface_id;
                }
            }
        }
    }
    self.xwayland_override_redirect_focus = replacement;
    refreshKeyboardFocus(self);
}

fn xwaylandWindowInfo(context: *anyopaque, window_id: Xwm.WindowId) ?Xwm.WindowInfo {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return null;
    return self.xwm.windowInfo(window_id);
}

fn resizeXwaylandWindow(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    width: u16,
    height: u16,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return false;
    self.xwm.resizeWindow(window_id, width, height) catch |err| {
        log.warn("failed to resize X11 window {d}: {t}", .{ window_id, err });
        return false;
    };
    return true;
}

fn moveXwaylandWindow(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    x: i16,
    y: i16,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return false;
    self.xwm.moveWindow(window_id, x, y) catch |err| {
        log.warn("failed to move X11 window {d}: {t}", .{ window_id, err });
        return false;
    };
    return true;
}

fn setXwaylandWindowFullscreen(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    fullscreen: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const changed = self.xwm.setFullscreen(window_id, fullscreen) catch |err| {
        log.warn("failed to set X11 window {d} fullscreen state: {t}", .{ window_id, err });
        return;
    };
    if (changed and self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn setXwaylandWindowMaximized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    maximized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const changed = self.xwm.setMaximized(window_id, maximized) catch |err| {
        log.warn("failed to set X11 window {d} maximized state: {t}", .{ window_id, err });
        return;
    };
    if (changed and self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn setXwaylandWindowMinimized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    minimized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const changed = self.xwm.setMinimized(window_id, minimized) catch |err| {
        log.warn("failed to set X11 window {d} minimized state: {t}", .{ window_id, err });
        return;
    };
    if (changed and self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn requestXwaylandWindowFullscreen(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    fullscreen: bool,
    preferred_output: ?OutputLayout.Id,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowFullscreenRequested(
            window_id,
            fullscreen,
            preferred_output,
        );
    }
}

fn requestXwaylandWindowActivation(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    seat: *Seat,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowActivationRequested(window_id, seat);
    }
}

fn requestXwaylandWindowMaximized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    maximized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMaximizeRequested(window_id, maximized);
    }
}

fn requestXwaylandWindowMinimized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    minimized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMinimizeRequested(window_id, minimized);
    }
}

fn closeXwaylandWindow(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.closeWindow(window_id);
}

fn refreshXwaylandScene(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) refreshXwaylandSceneWindow(self, window_id);
}

fn xwaylandStackingChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    syncXwaylandClientStacking(self);
}

fn removeXwaylandWindow(self: *Self, window_id: Xwm.WindowId) void {
    const removed = self.xwayland_windows.fetchRemove(window_id) orelse return;
    self.scene.removeWindow(removed.value.scene_id);
    syncXwaylandClientStacking(self);
    if (self.xwayland_override_redirect_focus) |current| {
        if (std.meta.eql(current, removed.value.surface_id)) {
            self.xwayland_override_redirect_focus = null;
            refreshKeyboardFocus(self);
        }
    }
}

fn xwaylandWindowForSurface(self: *Self, surface_id: Surface.Id) ?Xwm.WindowId {
    var windows = self.xwayland_windows.iterator();
    while (windows.next()) |entry| {
        if (std.meta.eql(entry.value_ptr.surface_id, surface_id)) return entry.key_ptr.*;
    }
    return null;
}

fn syncXwaylandFocus(self: *Self, surface_id: ?Surface.Id) void {
    if (!self.xwm_initialized) return;
    const target: ?Xwm.WindowId = if (surface_id) |surface| target: {
        var windows = self.xwayland_windows.iterator();
        while (windows.next()) |entry| {
            if (std.meta.eql(entry.value_ptr.surface_id, surface)) break :target entry.key_ptr.*;
        }
        break :target null;
    } else null;
    self.xwm.focusWindow(target) catch {
        log.err("failed to update X11 input focus", .{});
        self.terminate();
    };
}

fn captureImage(
    context: *anyopaque,
    target: ImageCopyCapture.Target,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) ImageCopyCapture.CaptureError!presentation.Timestamp {
    const self: *Self = @ptrCast(@alignCast(context));
    switch (target) {
        .source => |source| switch (source) {
            .output => |output_id| self.captureOutput(
                output_id,
                paint_cursors,
                pixel_buffer,
            ) catch return error.Failed,
            .toplevel => |window_id| {
                if (self.session_lock.isLocked()) return error.Failed;
                self.captureToplevel(window_id, pixel_buffer) catch |err| switch (err) {
                    error.Stopped => return error.Stopped,
                    else => return error.Failed,
                };
            },
        },
        .cursor => |cursor| self.captureCursor(cursor, pixel_buffer) catch return error.Failed,
    }
    return presentation.Info.now(self.io).timestamp;
}

fn captureScreencopy(
    context: *anyopaque,
    target: Screencopy.Target,
    overlay_cursor: bool,
    pixel_buffer: render.PixelBuffer,
) Screencopy.CaptureError!presentation.Timestamp {
    const self: *Self = @ptrCast(@alignCast(context));
    self.captureOutputRegion(
        target.output,
        target.region,
        overlay_cursor,
        pixel_buffer,
    ) catch return error.Failed;
    return presentation.Info.now(self.io).timestamp;
}

const CursorCaptureState = struct {
    cursor: Seat.CursorInfo,
    bounds: render.Rect,
    scale: render.Scale,
    size: render.Size,
    position: render.Position,
    hotspot: render.Position,
    entered: bool,
};

fn captureCursorInfo(
    context: *anyopaque,
    target: ImageCopyCapture.CursorTarget,
) ?ImageCopyCapture.CursorInfo {
    const self: *Self = @ptrCast(@alignCast(context));
    const state = self.cursorCaptureState(target) orelse return null;
    return .{
        .entered = state.entered,
        .position = state.position,
        .hotspot = state.hotspot,
    };
}

fn cursorCaptureState(
    self: *Self,
    target: ImageCopyCapture.CursorTarget,
) ?CursorCaptureState {
    const source_bounds, const scale, const cursor = switch (target.source) {
        .output => |output_id| output: {
            const render_output = self.renderOutputForProtocol(output_id) orelse return null;
            const output = self.outputs.get(output_id) orelse return null;
            const cursor = self.seatCursorInfo(
                target.seat,
                self.session_lock.isLocked(),
            ) orelse return null;
            break :output .{
                output.logicalRect(),
                render_output.backend.renderScale(),
                cursor,
            };
        },
        .toplevel => |window_id| toplevel: {
            if (self.session_lock.isLocked()) return null;
            const bounds = self.toplevelCaptureBounds(window_id) orelse return null;
            const cursor = self.seatCursorInfo(target.seat, false) orelse return null;
            break :toplevel .{ bounds, render.Scale{}, cursor };
        },
    };
    const pointer = target.seat.pointerPosition() orelse return null;
    const pointer_x = floorToI32(pointer.x);
    const pointer_y = floorToI32(pointer.y);
    const bounds = switch (cursor) {
        .shape => |shape| render.Rect{
            .x = shape.x,
            .y = shape.y,
            .width = shape.buffer.size.width,
            .height = shape.buffer.size.height,
        },
        .surface => |surface| bounds: {
            var value: ?render.Rect = null;
            self.addSurfaceTreeBounds(
                surface.surface_id,
                surface.x,
                surface.y,
                &value,
            ) catch return null;
            break :bounds value orelse return null;
        },
    };
    const size = scale.apply(.{ .width = bounds.width, .height = bounds.height }) catch
        return null;
    if (size.width == 0 or size.height == 0) return null;
    const position: render.Position = .{
        .x = scaleCaptureCoordinate(@as(i64, pointer_x) - source_bounds.x, scale),
        .y = scaleCaptureCoordinate(@as(i64, pointer_y) - source_bounds.y, scale),
    };
    const image_origin: render.Position = .{
        .x = scaleCaptureCoordinate(@as(i64, bounds.x) - source_bounds.x, scale),
        .y = scaleCaptureCoordinate(@as(i64, bounds.y) - source_bounds.y, scale),
    };
    return .{
        .cursor = cursor,
        .bounds = bounds,
        .scale = scale,
        .size = size,
        .position = position,
        .hotspot = .{
            .x = position.x -| image_origin.x,
            .y = position.y -| image_origin.y,
        },
        .entered = bounds.intersection(source_bounds) != null,
    };
}

fn captureCursor(
    self: *Self,
    target: ImageCopyCapture.CursorTarget,
    pixel_buffer: render.PixelBuffer,
) renderer_types.Renderer.Error!void {
    const state = self.cursorCaptureState(target) orelse return error.InvalidTarget;
    if (!std.meta.eql(pixel_buffer.size, state.size)) return error.InvalidTarget;
    const render_output = switch (target.source) {
        .output => |output_id| self.renderOutputForProtocol(output_id),
        .toplevel => self.firstRenderOutput(),
    } orelse return error.InvalidTarget;
    const output = self.outputs.get(render_output.protocol_id) orelse return error.InvalidTarget;
    try self.renderer.beginFrame(
        .{ .pixels = pixel_buffer },
        state.scale,
        .{ .x = state.bounds.x, .y = state.bounds.y },
        null,
    );
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = state.bounds,
        .track_visibility = false,
    };
    const clear_command = [_]render.Command{.{ .clear = render.Color.rgba(0, 0, 0, 0) }};
    try self.renderCommands(&frame, &clear_command);
    try self.renderCursor(&frame, state.cursor);
    renderer_frame_active = false;
    try self.renderer.finishFrame();
}

fn floorToI32(value: f64) i32 {
    const floored = @floor(value);
    if (floored <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (floored >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intFromFloat(floored);
}

fn scaleCaptureCoordinate(value: i64, scale: render.Scale) i32 {
    const product = @as(i128, value) * scale.numerator;
    const rounded = if (product >= 0)
        @divTrunc(product + render.Scale.denominator / 2, render.Scale.denominator)
    else
        -@divTrunc(-product + render.Scale.denominator / 2, render.Scale.denominator);
    return @intCast(std.math.clamp(
        rounded,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaledScreencopyRegion(
    logical: render.Rect,
    scale: render.Scale,
    output_size: render.Size,
) ?render.Rect {
    const left = scaleCaptureCoordinate(logical.x, scale);
    const top = scaleCaptureCoordinate(logical.y, scale);
    const right = scaleCaptureCoordinate(@as(i64, logical.x) + logical.width, scale);
    const bottom = scaleCaptureCoordinate(@as(i64, logical.y) + logical.height, scale);
    if (left < 0 or top < 0 or right <= left or bottom <= top or
        right > output_size.width or bottom > output_size.height) return null;
    return .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

test "cursor capture metadata preserves fractional image placement" {
    const scale: render.Scale = .{ .numerator = 180 };
    const position = scaleCaptureCoordinate(8, scale);
    const image_origin = scaleCaptureCoordinate(3, scale);
    const hotspot = position -| image_origin;
    try std.testing.expectEqual(@as(i32, 12), position);
    try std.testing.expectEqual(@as(i32, 5), image_origin);
    try std.testing.expectEqual(image_origin, position -| hotspot);
    try std.testing.expectEqual(@as(i32, -5), scaleCaptureCoordinate(-3, scale));
}

test "screencopy region follows full output fractional pixel boundaries" {
    try std.testing.expectEqual(
        render.Rect{ .x = 2, .y = 0, .width = 1, .height = 3 },
        scaledScreencopyRegion(
            .{ .x = 1, .y = 0, .width = 1, .height = 2 },
            .{ .numerator = 180 },
            .{ .width = 6, .height = 6 },
        ).?,
    );
}

test "output capture uses pixel dimensions at fractional scale" {
    const server = try Self.createWithVirtualOutput(
        std.testing.allocator,
        std.testing.io,
        .cpu,
        .headless,
        null,
        .{
            .size = .{ .width = 6, .height = 3 },
            .scale = .{ .numerator = 180 },
        },
    );
    defer server.destroy();
    const output = server.primaryRenderOutput();

    try std.testing.expectEqual(
        render.Size{ .width = 6, .height = 3 },
        captureSourceConstraints(server, .{ .output = output.protocol_id }).?.size,
    );
    try std.testing.expectEqual(
        render.Size{ .width = 6, .height = 3 },
        screencopyConstraints(server, .{ .output = output.protocol_id }).?,
    );

    var pixels: [18]u32 = undefined;
    try server.captureOutput(output.protocol_id, false, .{
        .size = .{ .width = 6, .height = 3 },
        .stride_pixels = 6,
        .pixels = &pixels,
    });
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xff18181b), pixel);
}

test "damage scaling covers fractional sampling edges" {
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 0, .width = 4, .height = 4 },
        scaleDamageRect(
            .{ .x = 1, .y = 1, .width = 1, .height = 1 },
            .{ .numerator = 180 },
            .{ .width = 10, .height = 10 },
        ).?,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 2, .y = 2, .width = 2, .height = 2 },
        scaleDamageRect(
            .{ .x = 1, .y = 1, .width = 1, .height = 1 },
            .{ .numerator = 240 },
            .{ .width = 10, .height = 10 },
        ).?,
    );
}

fn captureOutput(
    self: *Self,
    output_id: OutputLayout.Id,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) renderer_types.Renderer.Error!void {
    return self.captureOutputRegion(output_id, null, paint_cursors, pixel_buffer);
}

fn captureOutputRegion(
    self: *Self,
    output_id: OutputLayout.Id,
    local_region: ?render.Rect,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) renderer_types.Renderer.Error!void {
    const render_output = self.renderOutputForProtocol(output_id) orelse
        return error.InvalidTarget;
    const output = self.outputs.get(output_id) orelse return error.InvalidTarget;
    if (local_region) |region| {
        const physical = scaledScreencopyRegion(
            region,
            render_output.backend.renderScale(),
            render_output.backend.modeSize(),
        ) orelse return error.InvalidTarget;
        if (!std.meta.eql(pixel_buffer.size, render.Size{
            .width = physical.width,
            .height = physical.height,
        })) return error.InvalidTarget;
        const full_size = render_output.backend.modeSize();
        const pixel_count = full_size.pixelCount() catch return error.OutOfMemory;
        const pixels = self.allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
        defer self.allocator.free(pixels);
        const full_buffer: render.PixelBuffer = .{
            .size = full_size,
            .stride_pixels = full_size.width,
            .pixels = pixels,
        };
        try self.captureOutputRegion(output_id, null, paint_cursors, full_buffer);
        for (0..physical.height) |y| {
            const source_start = (@as(usize, @intCast(physical.y)) + y) * full_size.width +
                @as(usize, @intCast(physical.x));
            const destination_start = y * pixel_buffer.stride_pixels;
            @memcpy(
                pixel_buffer.pixels[destination_start..][0..physical.width],
                full_buffer.pixels[source_start..][0..physical.width],
            );
        }
        return;
    }
    const scale = render_output.backend.renderScale();
    const expected_size = render_output.backend.modeSize();
    if (!std.meta.eql(pixel_buffer.size, expected_size)) return error.InvalidTarget;
    const visible_rect = output.logicalRect();
    try self.renderer.beginFrame(
        .{ .pixels = pixel_buffer },
        scale,
        .{ .x = visible_rect.x, .y = visible_rect.y },
        null,
    );
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = visible_rect,
        .track_visibility = false,
    };
    const clear_command = [_]render.Command{.{ .clear = if (self.session_lock.isLocked())
        render.Color.rgba(0, 0, 0, 255)
    else
        render.Color.rgba(24, 24, 27, 255) }};
    try self.renderCommands(&frame, &clear_command);
    if (self.session_lock.isLocked()) {
        try self.renderSessionLockContents(&frame, paint_cursors);
    } else {
        _ = try self.renderDesktopContents(&frame, paint_cursors);
    }
    renderer_frame_active = false;
    try self.renderer.finishFrame();
}

const ToplevelCaptureError = renderer_types.Renderer.Error || error{Stopped};

fn captureToplevel(
    self: *Self,
    window_id: XdgShell.WindowId,
    pixel_buffer: render.PixelBuffer,
) ToplevelCaptureError!void {
    const info = self.xdg_shell.windowInfo(window_id) orelse return error.Stopped;
    if (!info.mapped) return error.Stopped;
    const surface_id = self.xdg_shell.windowSurface(window_id) orelse return error.Stopped;
    const position = self.scene.surfacePosition(surface_id) orelse return error.Stopped;
    const bounds = self.toplevelCaptureBounds(window_id) orelse return error.Stopped;
    if (!std.meta.eql(pixel_buffer.size, render.Size{
        .width = bounds.width,
        .height = bounds.height,
    })) return error.InvalidTarget;
    const render_output = self.firstRenderOutput() orelse return error.InvalidTarget;
    const output = self.outputs.get(render_output.protocol_id) orelse return error.InvalidTarget;
    try self.renderer.beginFrame(
        .{ .pixels = pixel_buffer },
        .{},
        .{ .x = bounds.x, .y = bounds.y },
        null,
    );
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = bounds,
        .track_visibility = false,
    };
    const clear_command = [_]render.Command{.{ .clear = render.Color.rgba(0, 0, 0, 0) }};
    try self.renderCommands(&frame, &clear_command);
    try self.renderSurfaceTree(
        &frame,
        surface_id,
        position.x,
        position.y,
        null,
        null,
    );
    renderer_frame_active = false;
    try self.renderer.finishFrame();
}

fn renderOutputForProtocol(self: *Self, output_id: OutputLayout.Id) ?*RenderOutput {
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (std.meta.eql(render_output.protocol_id, output_id)) return render_output;
    }
    return null;
}

fn firstRenderOutput(self: *Self) ?*RenderOutput {
    var outputs = self.render_outputs.iterator();
    const entry = outputs.next() orelse return null;
    return entry.value.*;
}

fn toplevelCaptureBounds(self: *Self, window_id: XdgShell.WindowId) ?render.Rect {
    const info = self.xdg_shell.windowInfo(window_id) orelse return null;
    if (!info.mapped) return null;
    const surface_id = self.xdg_shell.windowSurface(window_id) orelse return null;
    const position = self.scene.surfacePosition(surface_id) orelse return null;
    var bounds: ?render.Rect = null;
    self.addSurfaceTreeBounds(surface_id, position.x, position.y, &bounds) catch return null;
    return bounds;
}

fn addSurfaceTreeBounds(
    self: *Self,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    bounds: *?render.Rect,
) error{Overflow}!void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;
    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const buffer = Surface.currentBuffer(
                self.compositor.surfaceStore(),
                surface_id,
            ) orelse continue;
            const rect: render.Rect = .{
                .x = x,
                .y = y,
                .width = buffer.logical_size.width,
                .height = buffer.logical_size.height,
            };
            bounds.* = if (bounds.*) |current| try unionCaptureBounds(current, rect) else rect;
        },
        .child => |child| try self.addSurfaceTreeBounds(
            child.surface_id,
            x +| child.position.x,
            y +| child.position.y,
            bounds,
        ),
    };
}

fn unionCaptureBounds(a: render.Rect, b: render.Rect) error{Overflow}!render.Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(
        @as(i64, a.x) + a.width,
        @as(i64, b.x) + b.width,
    );
    const bottom = @max(
        @as(i64, a.y) + a.height,
        @as(i64, b.y) + b.height,
    );
    const width = right - left;
    const height = bottom - top;
    if (width <= 0 or height <= 0 or
        width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.Overflow;
    return .{
        .x = left,
        .y = top,
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

test "capture bounds include negative child offsets" {
    try std.testing.expectEqual(
        render.Rect{ .x = -20, .y = 5, .width = 120, .height = 70 },
        try unionCaptureBounds(
            .{ .x = 0, .y = 10, .width = 100, .height = 50 },
            .{ .x = -20, .y = 5, .width = 30, .height = 70 },
        ),
    );
}

fn handleRenderTimer(output_context: *RenderOutput) c_int {
    handleScheduledRender(output_context);
    return 0;
}

fn handleRenderIdle(output_context: *RenderOutput) void {
    std.debug.assert(output_context.repaint_idle != null);
    output_context.repaint_idle = null;
    handleScheduledRender(output_context);
}

fn handleScheduledRender(output_context: *RenderOutput) void {
    const self = output_context.server;
    output_context.render_scheduled = false;
    if (!output_context.repaint_needed or !output_context.backend.ready()) return;
    std.debug.assert(!output_context.damage.isEmpty());
    output_context.repaint_needed = false;
    self.renderFrame(output_context) catch |err| {
        log.err("output frame failed: {t}", .{err});
        self.terminate();
    };
    self.scheduleRepaint(output_context);
}

const BackdropBlurArea = struct {
    rect: render.Rect,
    radius: u32,
    downsample_level: ?u8,
};

fn backdropBlurArea(
    render_output: *const RenderOutput,
    output: *const Output,
    logical_rect: render.Rect,
    radius: u32,
    downsample_level: ?u8,
) ?BackdropBlurArea {
    if (radius == 0) return null;
    const output_rect = output.logicalRect();
    const logical = logical_rect.intersection(output_rect) orelse return null;
    const physical = scaleDamageRect(.{
        .x = logical.x -| output_rect.x,
        .y = logical.y -| output_rect.y,
        .width = logical.width,
        .height = logical.height,
    }, render_output.backend.renderScale(), render_output.backend.modeSize()) orelse return null;
    const scale = render_output.backend.renderScale();
    const scaled_radius = (@as(u64, radius) * scale.numerator +
        render.Scale.denominator / 2) / render.Scale.denominator;
    if (scaled_radius == 0) return null;
    return .{
        .rect = physical,
        .radius = @intCast(scaled_radius),
        .downsample_level = downsample_level,
    };
}

fn layerSurfaceRect(
    layer_surface: *const Scene.LayerSurface,
    size: render.Size,
) ?render.Rect {
    if (!layer_surface.mapped or size.width == 0 or size.height == 0) return null;
    return .{
        .x = layer_surface.position.x,
        .y = layer_surface.position.y,
        .width = size.width,
        .height = size.height,
    };
}

fn addBackdropBlurDamage(
    damage: *Region,
    blur: BackdropBlurArea,
    output_size: render.Size,
    footprint: u32,
) Region.Error!bool {
    const output_rect: render.Rect = .{ .x = 0, .y = 0, .width = output_size.width, .height = output_size.height };
    const affected = expandDamageRect(blur.rect, footprint).intersection(output_rect) orelse return false;
    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        if (affected.intersection(.{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        }) != null) break;
    } else return false;
    if (damage.coversRectangle(affected.x, affected.y, affected.width, affected.height)) {
        return false;
    }
    try damage.add(affected.x, affected.y, @intCast(affected.width), @intCast(affected.height));
    return true;
}

fn expandDamageRect(rectangle: anytype, amount: u32) render.Rect {
    const left = @as(i64, rectangle.x) - amount;
    const top = @as(i64, rectangle.y) - amount;
    const right = @as(i64, rectangle.x) + rectangle.width + amount;
    const bottom = @as(i64, rectangle.y) + rectangle.height + amount;
    return .{
        .x = @intCast(std.math.clamp(left, std.math.minInt(i32), std.math.maxInt(i32))),
        .y = @intCast(std.math.clamp(top, std.math.minInt(i32), std.math.maxInt(i32))),
        .width = @intCast(@min(right - left, std.math.maxInt(u32))),
        .height = @intCast(@min(bottom - top, std.math.maxInt(u32))),
    };
}

fn shadowDamageRect(rectangle: render.Rect, shadow: Scene.Shadow) render.Rect {
    const spread: u32 = if (shadow.spread > 0) @intCast(shadow.spread) else 0;
    const offset_x: u32 = if (shadow.offset.x < 0)
        @intCast(-@as(i64, shadow.offset.x))
    else
        @intCast(shadow.offset.x);
    const offset_y: u32 = if (shadow.offset.y < 0)
        @intCast(-@as(i64, shadow.offset.y))
    else
        @intCast(shadow.offset.y);
    const amount = render.shadowBlurExtent(shadow.blur_radius) +|
        spread +| @max(offset_x, offset_y);
    return expandDamageRect(rectangle, amount);
}

test "shadow damage includes blur spread and offset" {
    try std.testing.expectEqual(
        render.Rect{ .x = -14, .y = -4, .width = 78, .height = 88 },
        shadowDamageRect(
            .{ .x = 10, .y = 20, .width = 30, .height = 40 },
            .{
                .offset = .{ .x = 3, .y = -2 },
                .blur_radius = 12,
                .spread = 3,
                .color = render.Color.rgba(0, 0, 0, 128),
            },
        ),
    );
}

fn expandBackdropBlurDamage(
    self: *Self,
    render_output: *const RenderOutput,
    output: *const Output,
    damage: *Region,
) Region.Error!void {
    const surface_blur = Scene.background_blur;
    var changed = true;
    while (changed) {
        changed = false;
        const surfaces = self.compositor.surfaceStore();
        var surface_iterator = surfaces.iterator();
        while (surface_iterator.next()) |surface_entry| {
            const region = Surface.currentBlurRegion(surfaces, surface_entry.id) orelse continue;
            const buffer = Surface.currentBuffer(surfaces, surface_entry.id) orelse continue;
            if (surfaceFullyOpaque(surfaces, surface_entry.id, buffer)) continue;
            const root = self.subcompositor.rootSurface(surface_entry.id);
            if (!self.scene.surfaceMapped(root)) continue;
            const root_position = self.scene.surfacePosition(root) orelse continue;
            const offset = self.subcompositor.surfaceOffset(surface_entry.id);
            var rectangles = region.rectangleIterator();
            while (rectangles.next()) |rectangle| {
                const local = surfaceEffectRect(rectangle, buffer.logical_size) orelse continue;
                const blur = backdropBlurArea(
                    render_output,
                    output,
                    local.translated(
                        root_position.x +| offset.x,
                        root_position.y +| offset.y,
                    ),
                    surface_blur.radius,
                    surface_blur.downsample_level,
                ) orelse continue;
                const footprint = self.renderer.backdropBlurFootprint(
                    blur.radius,
                    blur.downsample_level,
                );
                changed = try addBackdropBlurDamage(
                    damage,
                    blur,
                    render_output.backend.modeSize(),
                    footprint,
                ) or changed;
            }
        }
    }
}

test "backdrop blur damage includes the whole blur and sample area" {
    var damage = Region.init();
    defer damage.deinit();
    damage.setRectangle(10, 10, 2, 2);
    const blur: BackdropBlurArea = .{
        .rect = .{ .x = 8, .y = 8, .width = 10, .height = 10 },
        .radius = 4,
        .downsample_level = null,
    };

    try std.testing.expect(try addBackdropBlurDamage(&damage, blur, .{ .width = 20, .height = 20 }, 4));
    try std.testing.expect(damage.coversRectangle(4, 4, 16, 16));
    try std.testing.expect(!try addBackdropBlurDamage(&damage, blur, .{ .width = 20, .height = 20 }, 4));

    var distant = Region.init();
    defer distant.deinit();
    distant.setRectangle(0, 0, 2, 2);
    try std.testing.expect(!try addBackdropBlurDamage(&distant, blur, .{ .width = 20, .height = 20 }, 4));
}

test "backdrop blur damage expands transitively across overlapping effects" {
    var damage = Region.init();
    defer damage.deinit();
    damage.setRectangle(5, 5, 1, 1);
    const blurs = [_]BackdropBlurArea{
        .{ .rect = .{ .x = 5, .y = 4, .width = 8, .height = 8 }, .radius = 2, .downsample_level = null },
        .{ .rect = .{ .x = 14, .y = 4, .width = 8, .height = 8 }, .radius = 2, .downsample_level = null },
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (blurs) |blur| {
            changed = try addBackdropBlurDamage(&damage, blur, .{ .width = 30, .height = 20 }, 2) or changed;
        }
    }
    try std.testing.expect(damage.coversRectangle(3, 2, 12, 12));
    try std.testing.expect(damage.coversRectangle(12, 2, 12, 12));
}

fn renderFrame(self: *Self, render_output: *RenderOutput) renderer_types.Renderer.Error!void {
    const render_target = render_output.backend.acquire() orelse {
        increment(&render_output.frame_statistics.acquire_retries);
        render_output.repaint_needed = true;
        return;
    };
    errdefer render_output.backend.cancel();
    render_output.beginFrame();
    errdefer render_output.pending_frame = null;
    const output = self.outputs.get(render_output.protocol_id).?;
    output.beginFrame();
    errdefer output.cancelFrame();
    const position = output.logicalPosition();
    var frame_damage = Region.init();
    defer frame_damage.deinit();
    try frame_damage.copyFrom(&render_output.damage);
    render_output.damage.clear();
    try render_output.backend.repairDamage(&frame_damage);
    try self.expandBackdropBlurDamage(render_output, output, &frame_damage);
    const damage = if (render_output.backend.persistentRenderTarget() and
        self.renderer.supportsPartialDamage())
        try self.outputDamageRectangles(render_output, &frame_damage)
    else
        null;
    const scale = render_output.backend.renderScale();
    const origin: render.Position = .{ .x = position.x, .y = position.y };
    try self.renderer.beginFrame(render_target, scale, origin, damage);
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = output.logicalRect(),
        .track_visibility = true,
        .presentation_damage = &frame_damage,
    };
    const clear_command = [_]render.Command{.{ .clear = if (self.session_lock.isLocked())
        render.Color.rgba(0, 0, 0, 255)
    else
        render.Color.rgba(24, 24, 27, 255) }};
    try self.renderCommands(&frame, &clear_command);
    if (self.session_lock.isLocked()) {
        try self.renderSessionLockContents(&frame, true);
        renderer_frame_active = false;
        const render_fence_fd = try self.renderer.finishFrameScanout(
            outputStatisticsTag(render_output.protocol_id),
        );
        self.collectGpuTimings();
        defer if (render_fence_fd) |fd| {
            _ = std.c.close(fd);
        };
        return self.presentSessionLockFrame(&frame, render_fence_fd);
    }

    const top_fullscreen = try self.renderDesktopContents(&frame, true);
    const fifo_barrier = Surface.hasFifoBarrierForOutput(
        self.compositor.surfaceStore(),
        output,
    );
    const allow_tearing = if (top_fullscreen) |window_id|
        if (self.scene.windowSurface(window_id)) |surface_id|
            Surface.currentPresentationHint(
                self.compositor.surfaceStore(),
                surface_id,
            ) == .async and !fifo_barrier
        else
            false
    else
        false;
    var presented: ?presentation.Info = null;
    var direct_scanout = false;
    if (self.renderer.directScanoutCandidate()) |candidate| {
        increment(&render_output.frame_statistics.direct_scanout_candidates);
        const result = render_output.backend.tryDirectScanout(candidate, allow_tearing);
        if (result.accepted) {
            self.renderer.cancelFrame();
            renderer_frame_active = false;
            direct_scanout = true;
            render_output.commitFrame(.direct_scanout);
        }
    }
    if (!direct_scanout) {
        renderer_frame_active = false;
        const render_fence_fd = try self.renderer.finishFrameScanout(
            outputStatisticsTag(render_output.protocol_id),
        );
        self.collectGpuTimings();
        defer if (render_fence_fd) |fd| {
            _ = std.c.close(fd);
        };
        presented = render_output.backend.present(
            &frame_damage,
            render_fence_fd,
            allow_tearing,
        ) catch
            return error.InvalidTarget;
        render_output.commitFrame(.composited);
    }
    output.endFrame();
    self.foreign_toplevel_list.syncOutput(render_output.protocol_id);

    self.submitLayerSurfaces(output, .background);
    self.submitLayerSurfaces(output, .bottom);
    if (top_fullscreen != null) self.submitLayerSurfaces(output, .top);
    var fullscreen_reached = top_fullscreen == null;
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (!window_entry.window.mapped) continue;
            if (top_fullscreen) |id| {
                if (!std.meta.eql(window_entry.id, id)) continue;
                fullscreen_reached = true;
            }
            self.submitWindowDecorations(output, window_entry.id, .below);
            self.submitSurfaceTree(output, window_entry.window.surface_id);
            self.submitWindowDecorations(output, window_entry.id, .above);
            self.submitWindowPopups(output, window_entry.id);
        },
        .shell_surface => |shell_entry| {
            if (!fullscreen_reached or !shell_entry.shell_surface.mapped) continue;
            self.submitSurfaceTree(output, shell_entry.shell_surface.surface_id);
        },
    };
    if (top_fullscreen == null) self.submitLayerSurfaces(output, .top);
    self.submitLayerSurfaces(output, .overlay);
    self.submitLayerPopups(output);
    var input_popups = self.input_method.popupIterator();
    while (input_popups.next()) |popup| self.submitSurfaceTree(output, popup.surface_id);
    const drag_icon = self.data_device.iconInfo();
    if (drag_icon) |info| self.submitSurfaceTree(output, info.surface_id);
    self.submitSeatCursor(output, &self.seat, false);
    self.submitTabletCursors(output, false);
    Surface.clearFifoBarriersForOutput(self.compositor.surfaceStore(), output);
    self.finishRepaintIfIdle();
    if (presented) |info| outputPresented(render_output, info);
    self.refreshKeyboardFocus();
}

fn renderDesktopContents(
    self: *Self,
    frame: *const OutputFrame,
    paint_cursors: bool,
) renderer_types.Renderer.Error!?Scene.Id {
    try self.renderLayerSurfaces(frame, .background);
    if (self.hasBackgroundEffect()) {
        const blur = Scene.background_blur;
        const cache_command = [_]render.Command{.{ .backdrop_blur = .{
            .rect = frame.visible_rect,
            .corner_radius = 0,
            .radius = blur.radius,
            .downsample_level = blur.downsample_level,
            .cache_only = true,
        } }};
        try self.renderCommands(frame, &cache_command);
    }
    try self.renderLayerSurfaces(frame, .bottom);
    const top_fullscreen = self.topFullscreenForOutput(frame.visible_rect);
    if (top_fullscreen != null) try self.renderLayerSurfaces(frame, .top);
    var fullscreen_reached = top_fullscreen == null;
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (!window_entry.window.mapped) continue;
            if (top_fullscreen) |id| {
                if (!std.meta.eql(window_entry.id, id)) continue;
                fullscreen_reached = true;
            }
            try self.renderWindow(frame, window_entry.id, window_entry.window);
        },
        .shell_surface => |shell_entry| {
            if (!fullscreen_reached or !shell_entry.shell_surface.mapped) continue;
            try self.renderSurfaceTree(
                frame,
                shell_entry.shell_surface.surface_id,
                shell_entry.shell_surface.position.x,
                shell_entry.shell_surface.position.y,
                null,
                null,
            );
        },
    };
    if (top_fullscreen == null) {
        try self.renderTilingDragPreview(frame);
        try self.renderLayerSurfaces(frame, .top);
    }
    try self.renderLayerSurfaces(frame, .overlay);
    try self.renderLayerPopups(frame);

    self.input_method.refreshPopups();
    var input_popups = self.input_method.popupIterator();
    while (input_popups.next()) |popup| {
        try self.renderSurfaceTree(
            frame,
            popup.surface_id,
            popup.position.x,
            popup.position.y,
            null,
            null,
        );
    }

    const drag_icon = self.data_device.iconInfo();
    if (drag_icon) |info| {
        try self.renderSurfaceTree(
            frame,
            info.surface_id,
            info.x,
            info.y,
            null,
            null,
        );
    }

    if (paint_cursors) {
        try self.renderSeatCursor(frame, &self.seat, false);
        try self.renderTabletCursors(frame, false);
    }
    return top_fullscreen;
}

fn hasBackgroundEffect(self: *Self) bool {
    const surfaces = self.compositor.surfaceStore();
    var iterator = surfaces.iterator();
    while (iterator.next()) |entry| {
        if (Surface.currentBlurRegion(surfaces, entry.id) == null) continue;
        const buffer = Surface.currentBuffer(surfaces, entry.id) orelse continue;
        if (!surfaceFullyOpaque(surfaces, entry.id, buffer)) return true;
    }
    return false;
}

fn presentSessionLockFrame(
    self: *Self,
    frame: *const OutputFrame,
    render_fence_fd: ?std.posix.fd_t,
) renderer_types.Renderer.Error!void {
    const lock_surface = self.session_lock.surfaceForOutput(frame.render_output.protocol_id);
    const presented = frame.render_output.backend.present(
        frame.presentation_damage.?,
        render_fence_fd,
        false,
    ) catch
        return error.InvalidTarget;
    frame.render_output.commitFrame(.composited);
    frame.render_output.lock_frame_pending = true;
    frame.output.endFrame();
    self.foreign_toplevel_list.syncOutput(frame.render_output.protocol_id);
    if (lock_surface) |info| self.submitSurfaceTree(frame.output, info.surface_id);
    self.submitSeatCursor(frame.output, &self.seat, true);
    self.submitTabletCursors(frame.output, true);
    Surface.clearFifoBarriersForOutput(self.compositor.surfaceStore(), frame.output);
    self.finishRepaintIfIdle();
    if (presented) |info| outputPresented(frame.render_output, info);
    self.refreshKeyboardFocus();
}

fn renderSessionLockContents(
    self: *Self,
    frame: *const OutputFrame,
    paint_cursors: bool,
) renderer_types.Renderer.Error!void {
    const lock_surface = self.session_lock.surfaceForOutput(frame.render_output.protocol_id);
    if (lock_surface) |info| {
        try self.renderSurfaceTree(
            frame,
            info.surface_id,
            info.position.x,
            info.position.y,
            null,
            null,
        );
    }

    if (paint_cursors) {
        try self.renderSeatCursor(frame, &self.seat, true);
        try self.renderTabletCursors(frame, true);
    }
}

fn refreshKeyboardFocus(self: *Self) void {
    if (self.session_lock.isLocked()) {
        const focus = self.session_lock.keyboardFocus();
        self.seat.setKeyboardFocus(focus);
        self.syncXwaylandFocus(null);
        return;
    }
    const default_focus = self.layer_shell.keyboardFocus(
        self.xdg_shell.popupKeyboardFocus(),
    ) orelse
        self.xwayland_override_redirect_focus orelse
        self.window_manager.focusedSurface() orelse self.scene.focusedSurface();
    self.seat.setKeyboardFocus(default_focus);
    self.syncXwaylandFocus(default_focus);
}

fn renderSeatCursor(
    self: *Self,
    frame: *const OutputFrame,
    seat: *Seat,
    locked: bool,
) renderer_types.Renderer.Error!void {
    const info = self.seatCursorInfo(seat, locked) orelse return;
    try self.renderCursor(frame, info);
}

fn renderTabletCursors(
    self: *Self,
    frame: *const OutputFrame,
    locked: bool,
) renderer_types.Renderer.Error!void {
    var cursors = self.tablet.cursorIterator();
    while (cursors.next()) |info| {
        if (!self.tabletCursorVisible(info.focus_surface, locked)) continue;
        try self.renderCursor(frame, info.cursor);
    }
}

fn renderCursor(
    self: *Self,
    frame: *const OutputFrame,
    info: Seat.CursorInfo,
) renderer_types.Renderer.Error!void {
    switch (info) {
        .surface => |surface| try self.renderSurfaceTree(
            frame,
            surface.surface_id,
            surface.x,
            surface.y,
            null,
            null,
        ),
        .shape => |shape| {
            const command = [_]render.Command{.{ .image = .{
                .x = shape.x,
                .y = shape.y,
                .size = shape.buffer.size,
                .buffer = shape.buffer,
            } }};
            try self.renderCommands(frame, &command);
        },
    }
}

fn submitSeatCursor(self: *Self, output: *Output, seat: *Seat, locked: bool) void {
    const info = self.seatCursorInfo(seat, locked) orelse return;
    self.submitCursor(output, info);
}

fn submitTabletCursors(self: *Self, output: *Output, locked: bool) void {
    var cursors = self.tablet.cursorIterator();
    while (cursors.next()) |info| {
        if (!self.tabletCursorVisible(info.focus_surface, locked)) continue;
        self.submitCursor(output, info.cursor);
    }
}

fn submitCursor(self: *Self, output: *Output, info: Seat.CursorInfo) void {
    switch (info) {
        .surface => |surface| self.submitSurfaceTree(output, surface.surface_id),
        .shape => {},
    }
}

fn seatCursorInfo(self: *Self, seat: *Seat, locked: bool) ?Seat.CursorInfo {
    if (locked) {
        const surface_id = seat.pointerFocusedSurface() orelse return null;
        const root = self.subcompositor.rootSurface(surface_id);
        if (!self.session_lock.ownsSurface(root)) return null;
    }
    return seat.cursorInfo();
}

fn tabletCursorVisible(self: *Self, focus_surface: Surface.Id, locked: bool) bool {
    if (!locked) return true;
    const root = self.subcompositor.rootSurface(focus_surface);
    return self.session_lock.ownsSurface(root);
}

fn finishRepaintIfIdle(self: *Self) void {
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (render_output.repaint_needed or render_output.render_scheduled) return;
    }
    self.fractional_scale.refresh();
    self.refreshSurfaceOutputPreferences();
    Surface.discardUnsubmittedFeedback(self.compositor.surfaceStore());
}

fn refreshSurfaceOutputPreferences(self: *Self) void {
    const default_scale = self.outputs.get(self.primaryRenderOutput().protocol_id).?.clientScale();
    const surfaces = self.compositor.surfaceStore();
    var surface_iterator = surfaces.iterator();
    while (surface_iterator.next()) |surface_entry| {
        var preferred_scale = default_scale;
        var found = false;
        var outputs = self.outputs.iterator();
        while (outputs.next()) |output_entry| {
            if (!output_entry.output.containsSurface(surface_entry.id)) continue;
            const output_scale = output_entry.output.clientScale();
            if (!found or output_scale > preferred_scale) preferred_scale = output_scale;
            found = true;
        }
        Surface.setPreferredBufferScale(surfaces, surface_entry.id, preferred_scale);
    }
}

fn renderLayerSurfaces(
    self: *Self,
    frame: *const OutputFrame,
    layer: Scene.Layer,
) renderer_types.Renderer.Error!void {
    var surfaces = self.scene.layerSurfaceIterator(layer);
    while (surfaces.next()) |entry| {
        const layer_surface = entry.layer_surface;
        if (!layer_surface.mapped) continue;
        if (self.layer_shell.castsShadow(layer_surface.surface_id)) {
            if (self.layer_shell_effects.shadow) |shadow| {
                const buffer = Surface.currentBuffer(
                    self.compositor.surfaceStore(),
                    layer_surface.surface_id,
                );
                if (buffer) |root_buffer| {
                    if (layerSurfaceRect(layer_surface, root_buffer.logical_size)) |rect| {
                        try self.renderShadow(
                            frame,
                            rect,
                            self.layer_shell_effects.corner_radius,
                            shadow,
                            null,
                        );
                    }
                }
            }
        }
        try self.renderSurfaceTree(
            frame,
            layer_surface.surface_id,
            layer_surface.position.x,
            layer_surface.position.y,
            null,
            null,
        );
    }
}

fn renderTilingDragPreview(
    self: *Self,
    frame: *const OutputFrame,
) renderer_types.Renderer.Error!void {
    const preview = self.window_manager.tilingDragPreview() orelse return;
    const command = [_]render.Command{tilingDragPreviewCommand(.{
        .x = preview.x,
        .y = preview.y,
        .width = preview.size.width,
        .height = preview.size.height,
    })};
    try self.renderCommands(frame, &command);
}

fn tilingDragPreviewCommand(rect: render.Rect) render.Command {
    std.debug.assert(rect.width > 0 and rect.height > 0);
    return .{ .shadow = .{
        .rect = rect,
        .corner_radius = 12,
        .blur_radius = 20,
        .spread = 0,
        .color = render.Color.rgba(0x28, 0x70, 0xbd, 0x70),
    } };
}

fn submitLayerSurfaces(self: *Self, output: *Output, layer: Scene.Layer) void {
    var surfaces = self.scene.layerSurfaceIterator(layer);
    while (surfaces.next()) |entry| {
        if (entry.layer_surface.mapped) {
            self.submitSurfaceTree(output, entry.layer_surface.surface_id);
        }
    }
}

fn renderLayerPopups(self: *Self, frame: *const OutputFrame) renderer_types.Renderer.Error!void {
    inline for (.{
        Scene.Layer.background,
        Scene.Layer.bottom,
        Scene.Layer.top,
        Scene.Layer.overlay,
    }) |layer| {
        var roots = self.scene.layerSurfaceIterator(layer);
        while (roots.next()) |root| {
            var popups = self.scene.layerPopupIterator(root.id);
            while (popups.next()) |entry| {
                if (!entry.popup.mapped) continue;
                const buffer = Surface.currentBuffer(
                    self.compositor.surfaceStore(),
                    entry.popup.surface_id,
                ) orelse continue;
                const geometry = entry.popup.content_geometry orelse Scene.ContentGeometry{
                    .size = buffer.logical_size,
                };
                try self.renderSurfaceTree(
                    frame,
                    entry.popup.surface_id,
                    entry.position.x -| geometry.offset.x,
                    entry.position.y -| geometry.offset.y,
                    null,
                    null,
                );
            }
        }
    }
}

fn submitLayerPopups(self: *Self, output: *Output) void {
    inline for (.{
        Scene.Layer.background,
        Scene.Layer.bottom,
        Scene.Layer.top,
        Scene.Layer.overlay,
    }) |layer| {
        var roots = self.scene.layerSurfaceIterator(layer);
        while (roots.next()) |root| {
            var popups = self.scene.layerPopupIterator(root.id);
            while (popups.next()) |entry| {
                if (entry.popup.mapped) self.submitSurfaceTree(output, entry.popup.surface_id);
            }
        }
    }
}

fn renderCommands(
    self: *Self,
    frame: *const OutputFrame,
    commands: []const render.Command,
) renderer_types.Renderer.Error!void {
    _ = frame;
    try self.renderer.append(commands);
}

fn renderShadow(
    self: *Self,
    frame: *const OutputFrame,
    rect: render.Rect,
    corner_radius: u32,
    shadow: Scene.Shadow,
    clip: ?render.Rect,
) renderer_types.Renderer.Error!void {
    const shadow_command = [_]render.Command{
        .{ .shadow = .{
            .rect = rect.translated(shadow.offset.x, shadow.offset.y),
            .corner_radius = corner_radius,
            .blur_radius = shadow.blur_radius,
            .spread = shadow.spread,
            .color = shadow.color,
            .cutout = .{
                .rect = rect,
                .radius = corner_radius,
            },
            .clip = clip,
        } },
    };
    try self.renderCommands(frame, &shadow_command);
}

fn renderWindow(
    self: *Self,
    frame: *const OutputFrame,
    id: Scene.Id,
    window: *const Scene.Window,
) renderer_types.Renderer.Error!void {
    const root_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) orelse return;
    const content_geometry = window.content_geometry orelse Scene.ContentGeometry{
        .size = root_buffer.logical_size,
    };
    const content_rect = windowContentRect(window, content_geometry.size) orelse return;
    const window_clip = if (window.clip_box) |clip_box|
        clip_box.translated(window.position.x, window.position.y)
    else
        null;
    const shadow_clip = if (window.shadow_clip_box orelse window.clip_box) |clip_box|
        clip_box.translated(window.position.x, window.position.y)
    else
        null;
    if (window.effects.shadow) |shadow| {
        try self.renderShadow(
            frame,
            content_rect,
            window.effects.corner_radius,
            shadow,
            shadow_clip,
        );
    }
    try self.renderWindowDecorations(frame, id, window, .below, window_clip);
    var content_visible = true;
    var content_clip = if (window.content_clip_box != null) content_rect else null;
    if (window_clip) |clip| {
        if (content_clip) |current| {
            content_clip = current.intersection(clip) orelse no_content: {
                content_visible = false;
                break :no_content null;
            };
        } else {
            content_clip = clip;
        }
    }
    if (content_visible) {
        const rounded_clip: ?render.RoundedClip = if (window.effects.corner_radius == 0)
            null
        else
            .{ .rect = content_rect, .radius = window.effects.corner_radius };
        try self.renderSurfaceTree(
            frame,
            window.surface_id,
            window.position.x -| content_geometry.offset.x,
            window.position.y -| content_geometry.offset.y,
            rounded_clip,
            content_clip,
        );
    }
    try self.renderWindowBorders(frame, window, content_rect, window_clip);
    try self.renderWindowDecorations(frame, id, window, .above, window_clip);
    try self.renderWindowPopups(frame, id);
}

fn renderWindowPopups(
    self: *Self,
    frame: *const OutputFrame,
    window_id: Scene.Id,
) renderer_types.Renderer.Error!void {
    var popups = self.scene.popupIterator(window_id);
    while (popups.next()) |entry| {
        const popup = entry.popup;
        if (!popup.mapped) continue;
        const buffer = Surface.currentBuffer(
            self.compositor.surfaceStore(),
            popup.surface_id,
        ) orelse continue;
        const content_geometry = popup.content_geometry orelse Scene.ContentGeometry{
            .size = buffer.logical_size,
        };
        try self.renderSurfaceTree(
            frame,
            popup.surface_id,
            entry.position.x -| content_geometry.offset.x,
            entry.position.y -| content_geometry.offset.y,
            null,
            null,
        );
    }
}

fn renderSurfaceTree(
    self: *Self,
    frame: *const OutputFrame,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
) renderer_types.Renderer.Error!void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;

    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const buffer = Surface.currentBuffer(
                self.compositor.surfaceStore(),
                surface_id,
            ) orelse continue;
            const surface_rect: render.Rect = .{
                .x = x,
                .y = y,
                .width = buffer.logical_size.width,
                .height = buffer.logical_size.height,
            };
            const visible_rect = surface_rect.intersection(frame.visible_rect) orelse continue;
            if (clip) |clip_rect| {
                if (visible_rect.intersection(clip_rect) == null) continue;
            }
            if (frame.track_visibility) {
                try frame.output.markSurfaceVisible(surface_id);
                Surface.markFifoBarrierVisible(
                    self.compositor.surfaceStore(),
                    surface_id,
                    frame.output,
                );
            }
            try self.renderSurfaceBackgroundEffect(
                frame,
                surface_id,
                x,
                y,
                buffer.logical_size,
                rounded_clip,
                clip,
            );
            const pixel_buffer = buffer.pixelBuffer();
            const alpha_multiplier = Surface.currentAlphaMultiplier(
                self.compositor.surfaceStore(),
                surface_id,
            ) orelse std.math.maxInt(u32);
            const image_command = [_]render.Command{
                .{ .image = .{
                    .x = x,
                    .y = y,
                    .size = buffer.logical_size,
                    .buffer = pixel_buffer,
                    .source = buffer.source,
                    .transform = renderBufferTransform(buffer.transform),
                    .rounded_clip = rounded_clip,
                    .clip = clip,
                    .is_opaque = surfaceFullyOpaque(
                        self.compositor.surfaceStore(),
                        surface_id,
                        buffer,
                    ),
                    .alpha_multiplier = alpha_multiplier,
                } },
            };
            try self.renderCommands(frame, &image_command);
        },
        .child => |child| try self.renderSurfaceTree(
            frame,
            child.surface_id,
            x +| child.position.x,
            y +| child.position.y,
            rounded_clip,
            clip,
        ),
    };
}

fn renderSurfaceBackgroundEffect(
    self: *Self,
    frame: *const OutputFrame,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    size: render.Size,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
) renderer_types.Renderer.Error!void {
    const blur = Scene.background_blur;
    const surfaces = self.compositor.surfaceStore();
    const buffer = Surface.currentBuffer(surfaces, surface_id) orelse return;
    if (surfaceFullyOpaque(surfaces, surface_id, buffer)) return;
    const region = Surface.currentBlurRegion(surfaces, surface_id) orelse return;
    var rectangles = region.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        var effect_rect = surfaceEffectRect(rectangle, size) orelse continue;
        effect_rect = effect_rect.translated(x, y);
        var corner_radius: u32 = 0;
        if (rounded_clip) |rounded| {
            effect_rect = effect_rect.intersection(rounded.rect) orelse continue;
            if (std.meta.eql(effect_rect, rounded.rect)) corner_radius = rounded.radius;
        }
        const command = [_]render.Command{.{ .backdrop_blur = .{
            .rect = effect_rect,
            .corner_radius = corner_radius,
            .radius = blur.radius,
            .downsample_level = blur.downsample_level,
            .clip = clip,
        } }};
        try self.renderCommands(frame, &command);
    }
}

fn surfaceFullyOpaque(
    surfaces: *Surface.Store,
    surface_id: Surface.Id,
    buffer: *const Surface.BufferSnapshot,
) bool {
    return Surface.currentAlphaMultiplier(surfaces, surface_id) == std.math.maxInt(u32) and
        (buffer.force_opaque or Surface.currentOpaqueCoversBuffer(surfaces, surface_id));
}

fn surfaceEffectRect(rectangle: Region.Rectangle, size: render.Size) ?render.Rect {
    return (render.Rect{
        .x = rectangle.x,
        .y = rectangle.y,
        .width = rectangle.width,
        .height = rectangle.height,
    }).clipTo(size);
}

test "background effect rectangles are clipped to the surface" {
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 4, .width = 6, .height = 4 },
        surfaceEffectRect(
            .{ .x = -2, .y = 4, .width = 8, .height = 10 },
            .{ .width = 10, .height = 8 },
        ).?,
    );
    try std.testing.expectEqual(
        @as(?render.Rect, null),
        surfaceEffectRect(
            .{ .x = 10, .y = 0, .width = 1, .height = 1 },
            .{ .width = 10, .height = 8 },
        ),
    );
}

fn renderBufferTransform(transform: wl.Output.Transform) render.BufferTransform {
    return switch (transform) {
        .normal => .normal,
        .@"90" => .rotate_90,
        .@"180" => .rotate_180,
        .@"270" => .rotate_270,
        .flipped => .flipped,
        .flipped_90 => .flipped_90,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_270,
        else => unreachable,
    };
}

fn renderWindowBorders(
    self: *Self,
    frame: *const OutputFrame,
    window: *const Scene.Window,
    content_rect: render.Rect,
    clip: ?render.Rect,
) renderer_types.Renderer.Error!void {
    const borders = window.borders orelse return;
    var commands: [4]render.Command = undefined;
    const border_commands = makeBorderCommands(
        content_rect,
        borders,
        window.effects.corner_radius,
        clip,
        &commands,
    );
    try self.renderCommands(frame, border_commands);
}

fn renderWindowDecorations(
    self: *Self,
    frame: *const OutputFrame,
    window_id: Scene.Id,
    window: *const Scene.Window,
    layer: Scene.DecorationLayer,
    clip: ?render.Rect,
) renderer_types.Renderer.Error!void {
    var decorations = self.scene.decorationIterator(window_id, layer);
    while (decorations.next()) |entry| {
        if (!entry.decoration.mapped) continue;
        try self.renderSurfaceTree(
            frame,
            entry.decoration.surface_id,
            window.position.x +| entry.decoration.offset.x,
            window.position.y +| entry.decoration.offset.y,
            null,
            clip,
        );
    }
}

fn makeBorderCommands(
    content_rect: render.Rect,
    borders: Scene.Borders,
    corner_radius: u32,
    clip: ?render.Rect,
    commands: *[4]render.Command,
) []const render.Command {
    const width = borders.width;
    if (corner_radius > 0 and borders.edges.top and borders.edges.bottom and
        borders.edges.left and borders.edges.right)
    {
        commands[0] = .{ .shadow = .{
            .rect = content_rect,
            .corner_radius = corner_radius,
            .blur_radius = 0,
            .spread = @intCast(width),
            .color = borders.color,
            .cutout = .{ .rect = content_rect, .radius = corner_radius },
            .clip = clip,
        } };
        return commands[0..1];
    }

    const width_i32: i32 = @intCast(width);
    const content_width_i32: i32 = @intCast(@min(
        content_rect.width,
        std.math.maxInt(i32),
    ));
    const content_height_i32: i32 = @intCast(@min(
        content_rect.height,
        std.math.maxInt(i32),
    ));
    const vertical_y = if (borders.edges.top)
        content_rect.y -| width_i32
    else
        content_rect.y;
    var vertical_height = content_rect.height;
    if (borders.edges.top) vertical_height +|= width;
    if (borders.edges.bottom) vertical_height +|= width;

    var command_count: usize = 0;
    if (borders.edges.top) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x,
                .y = content_rect.y -| width_i32,
                .width = content_rect.width,
                .height = width,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    if (borders.edges.bottom) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x,
                .y = content_rect.y +| content_height_i32,
                .width = content_rect.width,
                .height = width,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    if (borders.edges.left) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x -| width_i32,
                .y = vertical_y,
                .width = width,
                .height = vertical_height,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    if (borders.edges.right) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = content_rect.x +| content_width_i32,
                .y = vertical_y,
                .width = width,
                .height = vertical_height,
            },
            .color = borders.color,
            .clip = clip,
        } };
        command_count += 1;
    }
    std.debug.assert(command_count > 0);
    return commands[0..command_count];
}

fn pointInBorderCommand(x: f64, y: f64, command: render.Command) bool {
    return switch (command) {
        .solid_rect => |solid| if (solid.clip) |clip|
            pointInRect(x, y, solid.rect) and pointInRect(x, y, clip)
        else
            pointInRect(x, y, solid.rect),
        .shadow => |shadow| contains: {
            std.debug.assert(shadow.blur_radius == 0);
            std.debug.assert(shadow.spread > 0);
            if (shadow.clip) |clip| {
                if (!pointInRect(x, y, clip)) break :contains false;
            }
            const spread: u32 = @intCast(shadow.spread);
            const outer = expandDamageRect(shadow.rect, spread);
            if (!pointInRoundedRect(
                x,
                y,
                outer,
                shadow.corner_radius +| spread,
            )) break :contains false;
            const cutout = shadow.cutout orelse break :contains true;
            break :contains !pointInRoundedRect(x, y, cutout.rect, cutout.radius);
        },
        else => unreachable,
    };
}

fn windowContentRect(window: *const Scene.Window, content_size: render.Size) ?render.Rect {
    const content_rect: render.Rect = .{
        .x = window.position.x,
        .y = window.position.y,
        .width = content_size.width,
        .height = content_size.height,
    };
    const clip_box = window.content_clip_box orelse return content_rect;
    return content_rect.intersection(clip_box.translated(window.position.x, window.position.y));
}

fn submitSurfaceTree(self: *Self, output: *Output, surface_id: Surface.Id) void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;

    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => if (output.containsSurface(surface_id)) {
            Surface.submitPresentationFor(self.compositor.surfaceStore(), surface_id, output);
        },
        .child => |child| self.submitSurfaceTree(output, child.surface_id),
    };
}

fn submitWindowDecorations(
    self: *Self,
    output: *Output,
    window_id: Scene.Id,
    layer: Scene.DecorationLayer,
) void {
    var decorations = self.scene.decorationIterator(window_id, layer);
    while (decorations.next()) |entry| {
        if (!entry.decoration.mapped) continue;
        self.submitSurfaceTree(output, entry.decoration.surface_id);
    }
}

fn submitWindowPopups(self: *Self, output: *Output, window_id: Scene.Id) void {
    var popups = self.scene.popupIterator(window_id);
    while (popups.next()) |entry| {
        if (!entry.popup.mapped) continue;
        self.submitSurfaceTree(output, entry.popup.surface_id);
    }
}

test "server creates and destroys protocol globals" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless, null);
    defer server.destroy();
    try std.testing.expect(!server.native_input_initialized);
    try std.testing.expect(server.input_manager_initialized);
    try std.testing.expect(server.builtin_keybindings_initialized);
    try std.testing.expect(server.window_manager_initialized);
}

test "general configuration maps window shadows" {
    const defaults: Config.GeneralSettings = .{};
    try std.testing.expect(std.meta.eql(
        Scene.default_effects,
        windowEffects(defaults, defaults.shadow_color),
    ));

    const focused_color: Config.Color = .{
        .red = 0x7a,
        .green = 0xa2,
        .blue = 0xf7,
        .alpha = 0x80,
    };
    const focused = windowEffects(defaults, focused_color);
    try std.testing.expectEqual(
        render.Color.rgba(0x7a, 0xa2, 0xf7, 0x80),
        focused.shadow.?.color,
    );

    var disabled = defaults;
    disabled.shadow_enabled = false;
    const effects = windowEffects(disabled, disabled.shadow_color);
    try std.testing.expect(effects.shadow == null);
}

test "general configuration maps focused window border" {
    const defaults: Config.GeneralSettings = .{};
    const default_border = focusedWindowBorder(defaults).?;
    try std.testing.expectEqual(@as(u32, 2), default_border.width);
    try std.testing.expectEqual(
        render.Color.rgba(0x28, 0x70, 0xbd, 0xff),
        default_border.color,
    );

    var disabled = defaults;
    disabled.focused_border_width = 0;
    try std.testing.expect(focusedWindowBorder(disabled) == null);

    var configured = defaults;
    configured.focused_border_width = 3;
    configured.focused_border_color = .{
        .red = 0x7a,
        .green = 0xa2,
        .blue = 0xf7,
        .alpha = 0x80,
    };
    const border = focusedWindowBorder(configured).?;
    try std.testing.expectEqual(@as(u32, 3), border.width);
    try std.testing.expectEqual(
        render.Color.rgba(0x7a, 0xa2, 0xf7, 0x80),
        border.color,
    );
    try std.testing.expect(border.edges.top);
    try std.testing.expect(border.edges.bottom);
    try std.testing.expect(border.edges.left);
    try std.testing.expect(border.edges.right);
}

test "server adds and removes independent render outputs" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless, null);
    defer server.destroy();

    const second_id = try server.addRenderOutput(std.testing.io, .{
        .kind = .headless,
        .size = .{ .width = 640, .height = 480 },
        .position = .{ .x = 1280 },
        .name = "HEADLESS-2",
        .description = "Keywork test output",
        .model = "headless",
    });
    defer std.debug.assert(server.removeRenderOutput(second_id));

    try std.testing.expectEqual(@as(usize, 2), server.render_outputs.len());
    const second = server.render_outputs.get(second_id).?.*;
    try std.testing.expectEqual(
        Output.Position{ .x = 1280 },
        server.outputs.get(second.protocol_id).?.logicalPosition(),
    );
}

test "X11 pointer buttons map to Linux button codes" {
    try std.testing.expectEqual(@as(?u32, 0x110), x11PointerButton(1));
    try std.testing.expectEqual(@as(?u32, 0x112), x11PointerButton(2));
    try std.testing.expectEqual(@as(?u32, 0x111), x11PointerButton(3));
    try std.testing.expectEqual(@as(?u32, null), x11PointerButton(0));
    try std.testing.expectEqual(@as(?u32, null), x11PointerButton(4));
}

test "virtual pointer coordinates respect mapped bounds" {
    try std.testing.expectEqual(
        @as(f64, -100),
        clampVirtualPointerCoordinate(-200, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, 539),
        clampVirtualPointerCoordinate(700, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, -100),
        normalizedVirtualPointerCoordinate(0, 1000, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, 219.5),
        normalizedVirtualPointerCoordinate(500, 1000, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, 539),
        normalizedVirtualPointerCoordinate(1200, 1000, -100, 640),
    );
}

test "fullscreen selection is isolated to each output" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless, null);
    defer server.destroy();

    const first = try server.scene.addWindow(.{ .index = 100, .generation = 1 });
    defer server.scene.removeWindow(first);
    server.scene.setMapped(first, true);
    server.scene.setFullscreen(first, true);
    server.scene.setClipBox(first, .{ .x = 0, .y = 0, .width = 1280, .height = 720 });

    const second = try server.scene.addWindow(.{ .index = 101, .generation = 1 });
    defer server.scene.removeWindow(second);
    server.scene.setPosition(second, .{ .x = 1280 });
    server.scene.setMapped(second, true);
    server.scene.setFullscreen(second, true);
    server.scene.setClipBox(second, .{ .x = 0, .y = 0, .width = 640, .height = 480 });

    try std.testing.expectEqual(first, server.topFullscreenForOutput(.{
        .x = 0,
        .y = 0,
        .width = 1280,
        .height = 720,
    }).?);
    try std.testing.expectEqual(second, server.topFullscreenForOutput(.{
        .x = 1280,
        .y = 0,
        .width = 640,
        .height = 480,
    }).?);
}

test "window borders occupy only requested exterior edges and corners" {
    var commands: [4]render.Command = undefined;
    const color = render.Color.rgba(0x80, 0x40, 0x20, 0xff);
    const result = makeBorderCommands(
        .{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .{
            .edges = .{ .top = true, .left = true, .right = true },
            .width = 4,
            .color = color,
        },
        12,
        .{ .x = 0, .y = 0, .width = 200, .height = 200 },
        &commands,
    );

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(render.Rect{
        .x = 10,
        .y = 16,
        .width = 100,
        .height = 4,
    }, result[0].solid_rect.rect);
    try std.testing.expectEqual(render.Rect{
        .x = 6,
        .y = 16,
        .width = 4,
        .height = 54,
    }, result[1].solid_rect.rect);
    try std.testing.expectEqual(render.Rect{
        .x = 110,
        .y = 16,
        .width = 4,
        .height = 54,
    }, result[2].solid_rect.rect);
    try std.testing.expectEqual(color, result[0].solid_rect.color);
    try std.testing.expectEqual(render.Rect{
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 200,
    }, result[0].solid_rect.clip.?);
}

test "window border follows rounded content corners" {
    var commands: [4]render.Command = undefined;
    const content: render.Rect = .{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const result = makeBorderCommands(
        content,
        .{
            .edges = .{ .top = true, .bottom = true, .left = true, .right = true },
            .width = 4,
            .color = render.Color.rgba(0x80, 0x40, 0x20, 0xff),
        },
        12,
        null,
        &commands,
    );

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const border = result[0].shadow;
    try std.testing.expectEqual(content, border.rect);
    try std.testing.expectEqual(@as(u32, 12), border.corner_radius);
    try std.testing.expectEqual(@as(u32, 0), border.blur_radius);
    try std.testing.expectEqual(@as(i32, 4), border.spread);
    try std.testing.expectEqual(content, border.cutout.?.rect);
    try std.testing.expectEqual(@as(u32, 12), border.cutout.?.radius);
    try std.testing.expect(pointInBorderCommand(50, 18, result[0]));
    try std.testing.expect(pointInBorderCommand(12, 22, result[0]));
    try std.testing.expect(!pointInBorderCommand(7, 17, result[0]));
    try std.testing.expect(!pointInBorderCommand(50, 21, result[0]));
}

test "content clip boxes intersect window dimensions in global coordinates" {
    const window: Scene.Window = .{
        .surface_id = .{ .index = 1, .generation = 1 },
        .position = .{ .x = 100, .y = 50 },
        .content_clip_box = .{ .x = -10, .y = 20, .width = 80, .height = 100 },
    };

    try std.testing.expectEqual(render.Rect{
        .x = 100,
        .y = 70,
        .width = 70,
        .height = 60,
    }, windowContentRect(&window, .{ .width = 200, .height = 80 }).?);
}

test "rounded window corners reject points outside visible content" {
    const rect: render.Rect = .{ .x = 10, .y = 20, .width = 20, .height = 20 };

    try std.testing.expect(!pointInRoundedRect(10.5, 20.5, rect, 8));
    try std.testing.expect(pointInRoundedRect(14.5, 24.5, rect, 8));
    try std.testing.expect(pointInRoundedRect(20, 20.5, rect, 8));
    try std.testing.expect(!pointInRoundedRect(30, 30, rect, 8));
}

test "input settings overlay in order and can restore defaults" {
    const defaults: NativeInput.DeviceConfig = .{
        .physical_id = 1,
        .send_events = .{ .supported = .{ .disabled = true }, .default = .{}, .current = .{} },
        .tap_finger_count = 2,
        .tap = .{ .default = .disabled, .current = .disabled },
        .tap_button_map = null,
        .drag = null,
        .drag_lock = null,
        .three_finger_drag_count = 0,
        .three_finger_drag = null,
        .calibration_matrix = null,
        .accel_profiles = .{
            .supported = .{ .adaptive = true },
            .default = .adaptive,
            .current = .adaptive,
            .speed = .{ .default = 0, .current = 0 },
        },
        .natural_scroll = .{ .default = .disabled, .current = .disabled },
        .left_handed = null,
        .click_method = null,
        .clickfinger_button_map = null,
        .middle_emulation = null,
        .scroll_method = null,
        .scroll_button = null,
        .scroll_button_lock = null,
        .dwt = null,
        .dwtp = null,
        .rotation = null,
    };
    const device: Config.InputDeviceMatch = .{
        .name = "Test Touchpad",
        .vendor = 1,
        .product = 2,
        .keyboard = true,
        .pointer = true,
        .touchpad = true,
    };
    var effective: EffectiveInputSettings = .init(defaults);
    overlayInputSettings(&effective, defaults, device, .{
        .send_events = .{ .value = .disabled },
        .tap = .{ .value = .enabled },
        .accel_speed = .{ .value = 0.5 },
        .natural_scroll = .{ .value = .enabled },
        .scroll_factor = .{ .value = 0.75 },
        .repeat_rate = .{ .value = 30 },
    });
    overlayInputSettings(&effective, defaults, device, .{
        .tap = .use_default,
        .natural_scroll = .use_default,
        .scroll_factor = .use_default,
    });

    try std.testing.expect(effective.send_events.disabled);
    try std.testing.expectEqual(NativeInput.Toggle.disabled, effective.tap.?);
    try std.testing.expectEqual(@as(f64, 0.5), effective.accel_speed.?);
    try std.testing.expectEqual(NativeInput.Toggle.disabled, effective.natural_scroll.?);
    try std.testing.expectEqual(@as(f64, 1), effective.scroll_factor);
    try std.testing.expectEqual(@as(i32, 30), effective.repeat_rate);
}

fn testOutputMode(width: u16, height: u16, refresh_hertz: u32, preferred: bool) DrmOutput.Mode {
    var mode = std.mem.zeroes(DrmOutput.Mode);
    mode.value.hdisplay = width;
    mode.value.vdisplay = height;
    mode.value.vrefresh = refresh_hertz;
    mode.preferred = preferred;
    return mode;
}

test "output settings overlay in order and preserve unspecified live fields" {
    var effective: EffectiveOutputSettings = .{
        .enabled = true,
        .mode_index = 2,
        .x = 41,
        .y = -3,
        .scale = .{ .numerator = 120 },
    };
    overlayOutputSettings(&effective, .{
        .enable = false,
        .position = .{ .x = 10, .y = 20 },
        .scale_v120_numerator = 180,
    });
    overlayOutputSettings(&effective, .{ .enable = true, .position = .{ .x = 30, .y = 40 } });

    try std.testing.expect(effective.enabled);
    try std.testing.expectEqual(@as(usize, 2), effective.mode_index);
    try std.testing.expectEqual(@as(i32, 30), effective.x);
    try std.testing.expectEqual(@as(i32, 40), effective.y);
    try std.testing.expectEqual(@as(u32, 180), effective.scale.numerator);
}

test "nonmatching output rules are omitted" {
    var effective: EffectiveOutputSettings = .{
        .enabled = true,
        .mode_index = 0,
        .x = 4,
        .y = 5,
        .scale = .{},
    };
    const rules = [_]Config.OutputRule{.{
        .matcher = .{ .name = "DP-*" },
        .settings = .{ .enable = false },
    }};
    try std.testing.expect(!overlayMatchingOutputRules(&effective, .{ .name = "HDMI-A-1" }, &rules));
    try std.testing.expect(effective.enabled);
}

test "output mode resolution prefers preferred and closest refresh" {
    const modes = [_]DrmOutput.Mode{
        testOutputMode(1920, 1080, 60, false),
        testOutputMode(1920, 1080, 75, true),
        testOutputMode(1920, 1080, 120, false),
        testOutputMode(1280, 720, 60, true),
    };
    try std.testing.expectEqual(@as(usize, 1), try resolveOutputMode(&modes, .{
        .width = 1920,
        .height = 1080,
    }));
    try std.testing.expectEqual(@as(usize, 2), try resolveOutputMode(&modes, .{
        .width = 1920,
        .height = 1080,
        .refresh_millihertz = 110_000,
    }));
}

test "output mode resolution rejects unavailable size" {
    const modes = [_]DrmOutput.Mode{testOutputMode(1920, 1080, 60, true)};
    try std.testing.expectError(error.OutputModeUnavailable, resolveOutputMode(&modes, .{
        .width = 2560,
        .height = 1440,
    }));
}
