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
const XdgForeign = @import("wayland/xdg_foreign.zig");
const LayerShell = @import("wayland/layer_shell.zig");
const SinglePixelBuffer = @import("wayland/single_pixel_buffer.zig");
const ContentType = @import("wayland/content_type.zig");
const SecurityContext = @import("wayland/security_context.zig");
const SessionLock = @import("wayland/session_lock.zig");
const CursorShape = @import("wayland/cursor_shape.zig");
const RelativePointer = @import("wayland/relative_pointer.zig");
const PointerConstraints = @import("wayland/pointer_constraints.zig");
const IdleInhibit = @import("wayland/idle_inhibit.zig");
const Seat = @import("wayland/seat.zig");
const DataDevice = @import("wayland/data_device.zig");
const PrimarySelection = @import("wayland/primary_selection.zig");
const TextInput = @import("wayland/text_input.zig");
const InputMethod = @import("wayland/input_method.zig");
const VirtualKeyboard = @import("wayland/virtual_keyboard.zig");
const PresentationProtocol = @import("wayland/presentation.zig");
const FractionalScale = @import("wayland/fractional_scale.zig");
const Fixes = @import("wayland/fixes.zig");
const LinuxDmabuf = @import("wayland/linux_dmabuf.zig");
const XdgActivation = @import("wayland/xdg_activation.zig");
const Output = @import("wayland/output.zig");
const OutputLayout = @import("wayland/output_layout.zig");
const OutputManagement = @import("wayland/output_management.zig");
const OutputBackend = @import("backend/output.zig");
const DrmDevice = @import("backend/drm_device.zig");
const DrmOutput = @import("backend/drm.zig");
const NativeInput = @import("backend/native_input.zig");
const Session = @import("backend/session.zig");
const renderer_types = @import("render/renderer.zig");
const render = @import("render/types.zig");
const Scene = @import("scene.zig");
const Surface = @import("wayland/surface.zig");
const Viewporter = @import("wayland/viewporter.zig");
const InputManager = @import("river/input_manager.zig");
const LibinputConfig = @import("river/libinput_config.zig");
const XkbConfig = @import("river/xkb_config.zig");
const XkbBindings = @import("river/xkb_bindings.zig");
const WindowManager = @import("river/window_manager.zig");

const wl = wayland.server.wl;
const log = std.log.scoped(.server);

allocator: std.mem.Allocator,
display: *wl.Server,
session: Session,
session_initialized: bool,
drm_device: DrmDevice,
drm_device_initialized: bool,
native_input: NativeInput,
native_input_initialized: bool,
input_manager: InputManager,
input_manager_initialized: bool,
libinput_config: LibinputConfig,
libinput_config_initialized: bool,
xkb_config: XkbConfig,
xkb_config_initialized: bool,
xkb_bindings: XkbBindings,
xkb_bindings_initialized: bool,
render_outputs: RenderOutputStore,
primary_render_output: RenderOutputId,
outputs: OutputLayout,
xdg_output: XdgOutput,
xdg_output_initialized: bool,
output_management: OutputManagement,
output_management_initialized: bool,
single_pixel_buffer: SinglePixelBuffer,
content_type: ContentType,
security_context: SecurityContext,
session_lock: SessionLock,
session_lock_initialized: bool,
cursor_shape: CursorShape,
relative_pointer: RelativePointer,
pointer_constraints: PointerConstraints,
idle_inhibit: IdleInhibit,
compositor: Compositor,
subcompositor: Subcompositor,
scene: Scene,
xdg_shell: XdgShell,
xdg_foreign: XdgForeign,
layer_shell: LayerShell,
seat: Seat,
data_device: DataDevice,
primary_selection: PrimarySelection,
text_input: TextInput,
input_method: InputMethod,
virtual_keyboard: VirtualKeyboard,
presentation_protocol: PresentationProtocol,
fractional_scale: FractionalScale,
fixes: Fixes,
linux_dmabuf: LinuxDmabuf,
xdg_activation: XdgActivation,
viewporter: Viewporter,
window_manager: WindowManager,
window_manager_initialized: bool,
renderer: renderer_types.Renderer,
socket_buffer: [11]u8,
listening: bool,

const RenderOutput = struct {
    server: *Self,
    backend: OutputBackend,
    protocol_id: OutputLayout.Id,
    timer: ?*wl.EventSource,
    repaint_needed: bool,
    render_scheduled: bool,
    lock_frame_pending: bool,

    const Point = struct { x: f64, y: f64 };

    fn globalPoint(self: *RenderOutput, x: f64, y: f64) Point {
        const position = self.server.outputs.get(self.protocol_id).?.logicalPosition();
        return .{
            .x = x + @as(f64, @floatFromInt(position.x)),
            .y = y + @as(f64, @floatFromInt(position.y)),
        };
    }
};

const RenderOutputStore = slot_map.SlotMap(*RenderOutput, enum { render_output });
const RenderOutputId = RenderOutputStore.Id;

const RenderOutputConfig = struct {
    kind: OutputBackend.Kind,
    size: render.Size,
    position: Output.Position = .{},
    name: []const u8,
    description: []const u8,
    make: []const u8 = "keywork",
    model: []const u8,
    drm_output: ?*DrmOutput = null,
};

const OutputFrame = struct {
    render_output: *RenderOutput,
    output: *Output,
    target: renderer_types.Target,
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    renderer_kind: renderer_types.Renderer.Kind,
    output_kind: OutputBackend.Kind,
    drm_device_path: ?[]const u8,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const display = try wl.Server.create();
    errdefer display.destroy();
    try display.initShm();

    self.* = .{
        .allocator = allocator,
        .display = display,
        .session = undefined,
        .session_initialized = false,
        .drm_device = undefined,
        .drm_device_initialized = false,
        .native_input = undefined,
        .native_input_initialized = false,
        .input_manager = undefined,
        .input_manager_initialized = false,
        .libinput_config = undefined,
        .libinput_config_initialized = false,
        .xkb_config = undefined,
        .xkb_config_initialized = false,
        .xkb_bindings = undefined,
        .xkb_bindings_initialized = false,
        .render_outputs = .{},
        .primary_render_output = undefined,
        .outputs = undefined,
        .xdg_output = undefined,
        .xdg_output_initialized = false,
        .output_management = undefined,
        .output_management_initialized = false,
        .single_pixel_buffer = undefined,
        .content_type = undefined,
        .security_context = undefined,
        .session_lock = undefined,
        .session_lock_initialized = false,
        .cursor_shape = undefined,
        .relative_pointer = undefined,
        .pointer_constraints = undefined,
        .idle_inhibit = undefined,
        .compositor = undefined,
        .subcompositor = undefined,
        .scene = undefined,
        .xdg_shell = undefined,
        .xdg_foreign = undefined,
        .layer_shell = undefined,
        .seat = undefined,
        .data_device = undefined,
        .primary_selection = undefined,
        .text_input = undefined,
        .input_method = undefined,
        .virtual_keyboard = undefined,
        .presentation_protocol = undefined,
        .fractional_scale = undefined,
        .fixes = undefined,
        .linux_dmabuf = undefined,
        .xdg_activation = undefined,
        .viewporter = undefined,
        .window_manager = undefined,
        .window_manager_initialized = false,
        .renderer = try renderer_types.Renderer.init(allocator, renderer_kind),
        .socket_buffer = undefined,
        .listening = false,
    };
    errdefer self.render_outputs.deinit(allocator);
    errdefer self.renderer.deinit();
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
        errdefer self.drm_device.deinit();
    }
    try self.compositor.init(allocator, display);
    errdefer self.compositor.deinit();
    try self.security_context.init(allocator, display);
    errdefer self.security_context.deinit();
    self.outputs.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.outputs.deinit();
    try self.seat.init(allocator, io, display, "default", self.compositor.surfaceStore());
    errdefer self.seat.deinit();
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
            x += @intCast(drm_output.size.width);
        }
    } else render_output_id = try self.addRenderOutput(io, .{
        .kind = output_kind,
        .size = .{ .width = 1280, .height = 720 },
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
    }
    try self.single_pixel_buffer.init(allocator, display);
    errdefer self.single_pixel_buffer.deinit();
    try self.content_type.init(allocator, display);
    errdefer self.content_type.deinit();
    try self.session_lock.init(
        allocator,
        display,
        &self.outputs,
        self.compositor.surfaceStore(),
        &self.security_context,
        .{
            .context = self,
            .state_changed = sessionLockStateChanged,
            .repaint = requestRepaint,
        },
    );
    self.session_lock_initialized = true;
    errdefer {
        self.session_lock.deinit();
        self.session_lock_initialized = false;
    }
    try self.cursor_shape.init(allocator, display, &self.seat);
    errdefer self.cursor_shape.deinit();
    try self.relative_pointer.init(allocator, display, &self.seat);
    errdefer self.relative_pointer.deinit();
    try self.pointer_constraints.init(
        allocator,
        display,
        &self.seat,
        self.compositor.surfaceStore(),
    );
    errdefer self.pointer_constraints.deinit();
    try self.idle_inhibit.init(allocator, display);
    errdefer self.idle_inhibit.deinit();
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
    try self.linux_dmabuf.init(allocator, io, display);
    errdefer self.linux_dmabuf.deinit();
    try self.subcompositor.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.subcompositor.deinit();
    self.scene.init(allocator);
    errdefer self.scene.deinit();
    try self.xdg_shell.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        &self.scene,
        &self.seat,
        &self.outputs,
        render_output.protocol_id,
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
            .repaint = requestRepaint,
        },
    );
    errdefer self.data_device.deinit();
    try self.primary_selection.init(allocator, display, &self.seat);
    errdefer self.primary_selection.deinit();
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
    );
    errdefer self.virtual_keyboard.deinit();
    try self.window_manager.init(
        allocator,
        display,
        &self.security_context,
        &self.outputs,
        render_output.protocol_id,
        &self.seat,
        &self.scene,
        &self.xdg_shell,
        &self.layer_shell,
        .{ .context = self, .route = routePointer },
    );
    self.window_manager_initialized = true;
    errdefer {
        self.window_manager.deinit();
        self.window_manager_initialized = false;
    }
    self.subcompositor.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
    });
    self.scene.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
    });
    self.seat.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
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
        try self.input_manager.init(
            allocator,
            display,
            &self.security_context,
            &self.native_input,
            &self.outputs,
            render_output.protocol_id,
        );
        self.input_manager_initialized = true;
        errdefer {
            self.input_manager.detachNativeInput();
            self.input_manager.deinit();
            self.input_manager_initialized = false;
        }
        try self.libinput_config.init(
            allocator,
            display,
            &self.security_context,
            &self.input_manager,
            &self.native_input,
        );
        self.libinput_config_initialized = true;
        errdefer {
            self.libinput_config.deinit();
            self.libinput_config_initialized = false;
        }
        try self.xkb_config.init(
            allocator,
            io,
            display,
            &self.security_context,
            &self.input_manager,
            &self.native_input,
        );
        self.xkb_config_initialized = true;
        errdefer {
            self.xkb_config.deinit();
            self.xkb_config_initialized = false;
        }
        try self.xkb_bindings.init(
            allocator,
            display,
            &self.security_context,
            &self.window_manager,
            &self.input_manager,
            &self.native_input,
        );
        self.xkb_bindings_initialized = true;
        errdefer {
            self.xkb_bindings.deinit();
            self.xkb_bindings_initialized = false;
        }
    }
    requestRepaint(self);

    if (output_kind == .drm) self.drm_device.setListener(.{
        .context = self,
        .added = drmOutputAdded,
        .removing = drmOutputRemoving,
        .failed = drmDeviceFailed,
    });

    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    if (self.drm_device_initialized) self.drm_device.clearListener();
    self.data_device.cancel();
    if (self.xkb_bindings_initialized) self.xkb_bindings.detachNativeInput();
    if (self.xkb_config_initialized) self.xkb_config.detachNativeInput();
    if (self.input_manager_initialized) self.input_manager.detachNativeInput();
    if (self.native_input_initialized) self.native_input.deinit();
    self.layer_shell.clearRepaintListener();
    self.seat.clearRepaintListener();
    self.scene.clearRepaintListener();
    self.subcompositor.clearRepaintListener();
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| stopRenderOutput(entry.value.*);
    self.display.destroyClients();
    if (self.xkb_bindings_initialized) {
        self.xkb_bindings.deinit();
        self.xkb_bindings_initialized = false;
    }
    if (self.xkb_config_initialized) {
        self.xkb_config.deinit();
        self.xkb_config_initialized = false;
    }
    if (self.libinput_config_initialized) {
        self.libinput_config.deinit();
        self.libinput_config_initialized = false;
    }
    if (self.input_manager_initialized) {
        self.input_manager.deinit();
        self.input_manager_initialized = false;
    }
    if (self.output_management_initialized) {
        self.output_management.deinit();
        self.output_management_initialized = false;
    }
    self.window_manager.deinit();
    self.window_manager_initialized = false;
    self.virtual_keyboard.deinit();
    self.input_method.deinit();
    self.text_input.deinit();
    self.primary_selection.deinit();
    self.data_device.deinit();
    self.xdg_activation.deinit();
    self.layer_shell.deinit();
    self.xdg_foreign.deinit();
    self.xdg_shell.deinit();
    self.scene.deinit();
    self.subcompositor.deinit();
    self.linux_dmabuf.deinit();
    self.fixes.deinit();
    self.fractional_scale.deinit();
    self.viewporter.deinit();
    self.presentation_protocol.deinit();
    self.idle_inhibit.deinit();
    self.pointer_constraints.deinit();
    self.relative_pointer.deinit();
    self.cursor_shape.deinit();
    self.session_lock.deinit();
    self.session_lock_initialized = false;
    self.security_context.deinit();
    self.content_type.deinit();
    self.single_pixel_buffer.deinit();
    self.xdg_output.deinit();
    self.xdg_output_initialized = false;
    render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        std.debug.assert(self.removeRenderOutput(entry.id));
    }
    self.outputs.deinit();
    self.render_outputs.deinit(allocator);
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
        .repaint_needed = false,
        .render_scheduled = false,
        .lock_frame_pending = false,
    };
    try render_output.backend.init(
        self.allocator,
        io,
        self.display,
        config.size,
        config.kind,
        config.drm_output,
        backendListener(render_output),
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
    render_output.timer = try self.display.getEventLoop().addTimer(
        *RenderOutput,
        handleRenderTimer,
        render_output,
    );
    errdefer stopRenderOutput(render_output);
    const id = try self.render_outputs.insert(self.allocator, render_output);
    errdefer std.debug.assert(self.render_outputs.remove(id) != null);
    if (self.window_manager_initialized) {
        try self.window_manager.outputAdded(render_output.protocol_id);
    }
    if (self.session_lock_initialized) self.session_lock.refreshOutputs();
    render_output.repaint_needed = true;
    self.scheduleRepaint(render_output);
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
        .touch_available = touchAvailable,
        .touch_down = nativeTouchDown,
        .touch_up = nativeTouchUp,
        .touch_motion = nativeTouchMotion,
        .touch_frame = nativeTouchFrame,
        .touch_cancel = nativeTouchCancel,
    };
}

fn removeRenderOutput(self: *Self, id: RenderOutputId) bool {
    const render_output = self.render_outputs.remove(id) orelse return false;
    stopRenderOutput(render_output);
    const protocol_output = self.outputs.get(render_output.protocol_id).?;
    if (self.window_manager_initialized) {
        self.window_manager.outputRemoved(render_output.protocol_id);
    }
    if (self.input_manager_initialized) {
        self.input_manager.outputRemoved(render_output.protocol_id);
    }
    Surface.discardPresentation(self.compositor.surfaceStore(), protocol_output);
    if (self.xdg_output_initialized) self.xdg_output.removeOutput(protocol_output);
    std.debug.assert(self.outputs.remove(render_output.protocol_id));
    if (self.session_lock_initialized) {
        self.session_lock.outputRemoved(render_output.protocol_id);
        self.session_lock.refreshOutputs();
    }
    render_output.backend.deinit();
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
        if (self.input_manager_initialized) {
            self.input_manager.targetOutputChanged(replacement.protocol_id);
        }
        return;
    };
    unreachable;
}

fn drmOutputRemoving(context: *anyopaque, drm_output: *DrmOutput) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.output_management_initialized) self.output_management.removeHead(drm_output);
    const render_output = self.findDrmRenderOutput(drm_output) orelse return;
    const id = render_output.id;
    if (self.render_outputs.count == 1) {
        var fallback: ?*DrmOutput = null;
        for (self.drm_device.outputs()) |candidate| {
            if (candidate != drm_output and !candidate.enabled) {
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
                if (self.xkb_bindings_initialized) self.xkb_bindings.detachNativeInput();
                if (self.xkb_config_initialized) self.xkb_config.detachNativeInput();
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
    requestRepaint(self);
    return true;
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
        if (!change.output.enabled) change.output.scale = change.old_scale;
    }
    requestRepaint(self);
}

fn drmDeviceFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn stopRenderOutput(render_output: *RenderOutput) void {
    if (render_output.timer) |timer| {
        timer.remove();
        render_output.timer = null;
        render_output.render_scheduled = false;
    }
}

pub fn listen(self: *Self) ![:0]const u8 {
    std.debug.assert(!self.listening);
    const socket_name = try self.display.addSocketAuto(&self.socket_buffer);
    self.listening = true;
    return socket_name;
}

pub fn setLauncherEnvironment(
    self: *Self,
    environ_map: *const std.process.Environ.Map,
) void {
    if (self.native_input_initialized) self.native_input.setEnvironMap(environ_map);
}

pub fn eventLoop(self: *Self) *wl.EventLoop {
    return self.display.getEventLoop();
}

pub fn run(self: *Self) void {
    std.debug.assert(self.listening);
    self.display.run();
}

pub fn terminate(self: *Self) void {
    self.display.terminate();
}

fn requestRepaint(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        render_output.repaint_needed = true;
        self.scheduleRepaint(render_output);
    }
}

fn sessionLockStateChanged(context: *anyopaque, locked: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.pointer_constraints.deactivateAll();
    self.data_device.cancel();
    self.seat.touchCancel();
    self.seat.suppressPointerFocus(true);
    self.window_manager.pointerMoved(null);
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
    const timer = output.timer orelse return;
    timer.timerUpdate(output.backend.repaintDelayMilliseconds()) catch |err| {
        log.err("failed to schedule repaint: {t}", .{err});
        self.terminate();
        return;
    };
    output.render_scheduled = true;
}

fn outputReady(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.scheduleRepaint(output);
}

fn outputPresented(context: *anyopaque, info: presentation.Info) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
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
    output.lock_frame_pending = false;
    Surface.discardPresentation(
        self.compositor.surfaceStore(),
        self.outputs.get(output.protocol_id).?,
    );
    requestRepaint(self);
}

fn closeOutput(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.terminate();
}

fn serverForOutput(context: *anyopaque) *Self {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    return output.server;
}

fn nativeKeyboardKeymap(context: *anyopaque, _: ?NativeInput.DeviceId, format: wl.Keyboard.KeymapFormat, fd: std.posix.fd_t, size: u32) void {
    keyboardKeymap(context, format, fd, size);
}
fn nativeKeyboardKey(context: *anyopaque, _: NativeInput.DeviceId, time: u32, key: u32, state: wl.Keyboard.KeyState) void {
    keyboardKey(context, time, key, state);
}
fn nativeKeyboardModifiers(context: *anyopaque, _: ?NativeInput.DeviceId, depressed: u32, latched: u32, locked: u32, group: u32) void {
    keyboardModifiers(context, depressed, latched, locked, group);
}
fn nativeKeyboardRepeatInfo(context: *anyopaque, _: ?NativeInput.DeviceId, rate: i32, delay: i32) void {
    keyboardRepeatInfo(context, rate, delay);
}
fn nativePointerMotion(context: *anyopaque, _: NativeInput.DeviceId, time: u32, x: f64, y: f64) void {
    pointerMotion(context, time, x, y);
}
fn nativePointerRelativeMotion(context: *anyopaque, _: NativeInput.DeviceId, time: u64, dx: f64, dy: f64, dx_unaccelerated: f64, dy_unaccelerated: f64) void {
    pointerRelativeMotion(context, time, dx, dy, dx_unaccelerated, dy_unaccelerated);
}
fn nativePointerButton(context: *anyopaque, _: NativeInput.DeviceId, time: u32, button: u32, state: wl.Pointer.ButtonState) void {
    pointerButton(context, time, button, state);
}
fn nativePointerAxis(context: *anyopaque, _: NativeInput.DeviceId, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    pointerAxis(context, time, axis, value);
}
fn nativePointerFrame(context: *anyopaque, _: NativeInput.DeviceId) void {
    pointerFrame(context);
}
fn nativePointerAxisSource(context: *anyopaque, _: NativeInput.DeviceId, source: wl.Pointer.AxisSource) void {
    pointerAxisSource(context, source);
}
fn nativePointerAxisStop(context: *anyopaque, _: NativeInput.DeviceId, time: u32, axis: wl.Pointer.Axis) void {
    pointerAxisStop(context, time, axis);
}
fn nativePointerAxisDiscrete(context: *anyopaque, _: NativeInput.DeviceId, axis: wl.Pointer.Axis, discrete: i32) void {
    pointerAxisDiscrete(context, axis, discrete);
}
fn nativePointerAxisValue120(context: *anyopaque, _: NativeInput.DeviceId, axis: wl.Pointer.Axis, value: i32) void {
    pointerAxisValue120(context, axis, value);
}
fn nativeTouchDown(context: *anyopaque, _: NativeInput.DeviceId, time: u32, id: i32, x: f64, y: f64) void {
    touchDown(context, time, id, x, y);
}
fn nativeTouchUp(context: *anyopaque, _: NativeInput.DeviceId, time: u32, id: i32) void {
    touchUp(context, time, id);
}
fn nativeTouchMotion(context: *anyopaque, _: NativeInput.DeviceId, time: u32, id: i32, x: f64, y: f64) void {
    touchMotion(context, time, id, x, y);
}
fn nativeTouchFrame(context: *anyopaque, _: NativeInput.DeviceId) void {
    touchFrame(context);
}
fn nativeTouchCancel(context: *anyopaque, _: NativeInput.DeviceId) void {
    touchCancel(context);
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
    if (!available) {
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
        self.window_manager.pointerMoved(null);
        return;
    }
    if (self.data_device.isDragging()) {
        self.pointer_constraints.deactivateAll();
        self.seat.pointerEnter(point.x, point.y, null);
        self.data_device.pointerEntered(route.focus);
        self.window_manager.pointerMoved(null);
        return;
    }
    if (self.window_manager.pointerGrabbed()) self.pointer_constraints.deactivateAll();
    self.seat.pointerEnter(
        point.x,
        point.y,
        if (self.window_manager.pointerGrabbed()) null else route.focus,
    );
    self.window_manager.pointerMoved(if (self.window_manager.pointerGrabbed()) null else route.root);
    self.pointer_constraints.syncFocus();
}

fn pointerLeave(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.pointer_constraints.deactivateAll();
    self.data_device.pointerLeft();
    self.seat.pointerLeave();
    self.window_manager.pointerMoved(null);
}

fn pointerMotion(context: *anyopaque, time: u32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const target = output.globalPoint(x, y);
    if (self.session_lock.isLocked()) {
        self.seat.pointerMotion(
            time,
            target.x,
            target.y,
            self.pointerFocus(target.x, target.y),
        );
        self.window_manager.pointerMoved(null);
        return;
    }
    if (self.data_device.isDragging()) {
        self.pointer_constraints.deactivateAll();
        const route = self.pointerRoute(target.x, target.y);
        self.seat.pointerMotion(time, target.x, target.y, null);
        self.data_device.pointerMotion(time, route.focus);
        self.window_manager.pointerMoved(null);
        return;
    }
    if (self.window_manager.pointerGrabbed()) {
        self.pointer_constraints.deactivateAll();
        self.seat.pointerMotion(time, target.x, target.y, null);
        self.window_manager.pointerMoved(null);
        return;
    }
    const motion = self.pointer_constraints.constrainMotion(.{ .x = target.x, .y = target.y });
    if (motion.point.x != target.x or motion.point.y != target.y) {
        self.synchronizeBackendPointer(output, motion.point.x, motion.point.y);
    }
    if (motion.locked) return;
    const route = self.pointerRoute(motion.point.x, motion.point.y);
    self.seat.pointerMotion(
        time,
        motion.point.x,
        motion.point.y,
        route.focus,
    );
    self.window_manager.pointerMoved(route.root);
    self.pointer_constraints.syncFocus();
}

fn synchronizeBackendPointer(self: *Self, output: *RenderOutput, x: f64, y: f64) void {
    if (!self.native_input_initialized) return;
    const position = self.outputs.get(output.protocol_id).?.logicalPosition();
    self.native_input.setPointerPosition(
        x - @as(f64, @floatFromInt(position.x)),
        y - @as(f64, @floatFromInt(position.y)),
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
    if (self.session_lock.isLocked()) {
        if (state == .pressed) {
            const focused = if (self.seat.pointerFocusedSurface()) |surface_id|
                self.subcompositor.rootSurface(surface_id)
            else
                null;
            self.session_lock.pointerPressed(focused);
        }
        _ = self.seat.pointerButton(time, button, state) catch {
            log.err("failed to store pointer button state", .{});
            self.terminate();
        };
        return;
    }
    if (self.data_device.isDragging()) {
        const grab_ended = self.seat.pointerButton(time, button, state) catch {
            log.err("failed to store pointer button state", .{});
            self.terminate();
            return;
        };
        if (state == .released and grab_ended) self.data_device.drop();
        return;
    }
    const root = if (self.seat.pointerPosition()) |position|
        self.pointerRoute(position.x, position.y).root
    else
        null;
    if (self.window_manager.pointerButton(button, state, root)) {
        self.pointer_constraints.deactivateAll();
        self.seat.suppressPointerFocus(true);
        return;
    }
    if (state == .pressed) {
        const focused = if (self.seat.pointerFocusedSurface()) |surface_id|
            self.subcompositor.rootSurface(surface_id)
        else
            null;
        self.layer_shell.pointerPressed(focused);
        requestRepaint(self);
    }
    if (state == .pressed and self.xdg_shell.hasPopupGrab() and
        self.seat.pointerFocusedSurface() == null)
    {
        self.xdg_shell.dismissPopupGrab();
        return;
    }
    _ = self.seat.pointerButton(time, button, state) catch {
        log.err("failed to store pointer button state", .{});
        self.terminate();
    };
}

fn dragStarted(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.pointer_constraints.deactivateAll();
    const position = self.seat.pointerPosition() orelse return;
    const route = self.pointerRoute(position.x, position.y);
    self.seat.suppressPointerFocus(true);
    self.window_manager.pointerMoved(null);
    self.data_device.pointerEntered(route.focus);
}

fn dragEnded(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const position = self.seat.pointerPosition() orelse return;
    const route = self.pointerRoute(position.x, position.y);
    self.seat.pointerEnter(
        position.x,
        position.y,
        if (self.window_manager.pointerGrabbed()) null else route.focus,
    );
    self.window_manager.pointerMoved(if (self.window_manager.pointerGrabbed()) null else route.root);
    self.pointer_constraints.syncFocus();
}

fn pointerAxis(context: *anyopaque, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const self = serverForOutput(context);
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
        self.layer_shell.pointerPressed(self.subcompositor.rootSurface(target.surface_id));
        requestRepaint(self);
    } else if (self.xdg_shell.hasPopupGrab()) {
        self.xdg_shell.dismissPopupGrab();
    }
    self.seat.touchDown(time, id, point.x, point.y, focus) catch {
        log.err("failed to store touch point", .{});
        self.terminate();
    };
}

fn touchUp(context: *anyopaque, time: u32, id: i32) void {
    const self = serverForOutput(context);
    self.seat.touchUp(time, id) catch {
        log.err("failed to finish touch point", .{});
        self.terminate();
    };
}

fn touchMotion(context: *anyopaque, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
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
    const focus = self.scenePointerFocus(x, y);
    if (focus) |candidate| {
        if (self.xdg_shell.hasPopupGrab() and
            !self.xdg_shell.popupGrabOwnsSurface(candidate.surface_id)) return null;
    }
    return focus;
}

fn routePointer(context: *anyopaque, x: f64, y: f64) WindowManager.PointerRoute {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.pointerRoute(x, y);
}

fn pointerRoute(self: *Self, x: f64, y: f64) WindowManager.PointerRoute {
    const focus = self.pointerFocus(x, y);
    return .{
        .focus = focus,
        .root = if (focus) |value|
            self.subcompositor.rootSurface(value.surface_id)
        else if (self.session_lock.isLocked())
            null
        else
            self.borderRoot(x, y),
    };
}

fn borderRoot(self: *Self, x: f64, y: f64) ?Surface.Id {
    const fullscreen = self.topFullscreenAtPoint(x, y);
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
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
            for (makeBorderCommands(content, borders, clip, &commands)) |command| {
                const solid = command.solid_rect;
                const visible = if (solid.clip) |command_clip| solid.rect.intersection(command_clip) orelse continue else solid.rect;
                if (pointInRect(x, y, visible)) return window.surface_id;
            }
            if (fullscreen != null) return null;
        },
        else => {},
    };
    return null;
}

fn scenePointerFocus(self: *Self, x: f64, y: f64) ?Seat.PointerFocus {
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
    const fullscreen = self.topFullscreenAtPoint(x, y);
    if (fullscreen == null) {
        if (self.hitTestLayer(.top, x, y)) |focus| return focus;
    }
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
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
        if (buffer.transform != .normal) continue;
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
    var test_content = root_buffer.transform == .normal;
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

fn handleRenderTimer(output_context: *RenderOutput) c_int {
    const self = output_context.server;
    output_context.render_scheduled = false;
    if (!output_context.repaint_needed or !output_context.backend.ready()) return 0;
    output_context.repaint_needed = false;
    self.renderFrame(output_context) catch |err| {
        log.err("output frame failed: {t}", .{err});
        self.terminate();
    };
    self.scheduleRepaint(output_context);
    return 0;
}

fn renderFrame(self: *Self, render_output: *RenderOutput) renderer_types.Renderer.Error!void {
    const pixel_target = render_output.backend.acquire() orelse {
        render_output.repaint_needed = true;
        return;
    };
    errdefer render_output.backend.cancel();
    const output = self.outputs.get(render_output.protocol_id).?;
    output.beginFrame();
    errdefer output.cancelFrame();
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .target = self.renderer.makeTarget(pixel_target),
    };
    const clear_command = [_]render.Command{.{ .clear = if (self.session_lock.isLocked())
        render.Color.rgba(0, 0, 0, 255)
    else
        render.Color.rgba(24, 24, 27, 255) }};
    try self.renderCommands(&frame, &clear_command);
    if (self.session_lock.isLocked()) return self.renderSessionLockFrame(&frame);

    try self.renderLayerSurfaces(&frame, .background);
    try self.renderLayerSurfaces(&frame, .bottom);
    const top_fullscreen = self.topFullscreenForOutput(output.logicalRect());
    if (top_fullscreen != null) try self.renderLayerSurfaces(&frame, .top);
    var fullscreen_reached = top_fullscreen == null;
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (!window_entry.window.mapped) continue;
            if (top_fullscreen) |id| {
                if (!std.meta.eql(window_entry.id, id)) continue;
                fullscreen_reached = true;
            }
            try self.renderWindow(&frame, window_entry.id, window_entry.window);
        },
        .shell_surface => |shell_entry| {
            if (!fullscreen_reached or !shell_entry.shell_surface.mapped) continue;
            try self.renderSurfaceTree(
                &frame,
                shell_entry.shell_surface.surface_id,
                shell_entry.shell_surface.position.x,
                shell_entry.shell_surface.position.y,
                null,
                null,
            );
        },
    };
    if (top_fullscreen == null) try self.renderLayerSurfaces(&frame, .top);
    try self.renderLayerSurfaces(&frame, .overlay);
    try self.renderLayerPopups(&frame);

    self.input_method.refreshPopups();
    var input_popups = self.input_method.popupIterator();
    while (input_popups.next()) |popup| {
        try self.renderSurfaceTree(
            &frame,
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
            &frame,
            info.surface_id,
            info.x,
            info.y,
            null,
            null,
        );
    }

    const cursor = self.seat.cursorInfo();
    if (cursor) |info| {
        switch (info) {
            .surface => |surface| try self.renderSurfaceTree(
                &frame,
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
                try self.renderCommands(&frame, &command);
            },
        }
    }

    const presented = render_output.backend.present() catch return error.InvalidTarget;
    output.endFrame();

    self.submitLayerSurfaces(output, .background);
    self.submitLayerSurfaces(output, .bottom);
    if (top_fullscreen != null) self.submitLayerSurfaces(output, .top);
    fullscreen_reached = top_fullscreen == null;
    nodes = self.scene.nodeIterator();
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
    input_popups = self.input_method.popupIterator();
    while (input_popups.next()) |popup| self.submitSurfaceTree(output, popup.surface_id);
    if (drag_icon) |info| self.submitSurfaceTree(output, info.surface_id);
    if (cursor) |info| switch (info) {
        .surface => |surface| self.submitSurfaceTree(output, surface.surface_id),
        .shape => {},
    };
    self.finishRepaintIfIdle();
    if (presented) |info| outputPresented(render_output, info);
    const keyboard_focus = self.layer_shell.keyboardFocus(
        self.xdg_shell.popupKeyboardFocus(),
    ) orelse
        self.window_manager.focusedShellSurface() orelse self.scene.focusedSurface() orelse if (!self.window_manager.hasActiveManager())
        self.scene.topWindowSurface()
    else
        null;
    self.seat.setKeyboardFocus(keyboard_focus);
}

fn renderSessionLockFrame(
    self: *Self,
    frame: *const OutputFrame,
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

    const cursor = self.sessionLockCursorInfo();
    if (cursor) |info| switch (info) {
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
    };

    const presented = frame.render_output.backend.present() catch return error.InvalidTarget;
    frame.render_output.lock_frame_pending = true;
    frame.output.endFrame();
    if (lock_surface) |info| self.submitSurfaceTree(frame.output, info.surface_id);
    if (cursor) |info| switch (info) {
        .surface => |surface| self.submitSurfaceTree(frame.output, surface.surface_id),
        .shape => {},
    };
    self.finishRepaintIfIdle();
    if (presented) |info| outputPresented(frame.render_output, info);
    self.seat.setKeyboardFocus(self.session_lock.keyboardFocus());
}

fn sessionLockCursorInfo(self: *Self) ?Seat.CursorInfo {
    const surface_id = self.seat.pointerFocusedSurface() orelse return null;
    const root = self.subcompositor.rootSurface(surface_id);
    if (!self.session_lock.ownsSurface(root)) return null;
    return self.seat.cursorInfo();
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
    const position = frame.output.logicalPosition();
    try self.renderer.render(.{
        .size = frame.render_output.backend.size(),
        .commands = commands,
        .scale = frame.render_output.backend.renderScale(),
        .origin = .{ .x = position.x, .y = position.y },
    }, frame.target);
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
    if (window.effects.shadow) |shadow| {
        const shadow_command = [_]render.Command{
            .{ .shadow = .{
                .rect = .{
                    .x = content_rect.x +| shadow.offset.x,
                    .y = content_rect.y +| shadow.offset.y,
                    .width = content_rect.width,
                    .height = content_rect.height,
                },
                .corner_radius = window.effects.corner_radius,
                .blur_radius = shadow.blur_radius,
                .spread = shadow.spread,
                .color = shadow.color,
                .clip = window_clip,
            } },
        };
        try self.renderCommands(frame, &shadow_command);
    }
    if (window.effects.blur) |blur| {
        const blur_command = [_]render.Command{
            .{ .backdrop_blur = .{
                .rect = content_rect,
                .corner_radius = window.effects.corner_radius,
                .radius = blur.radius,
                .clip = window_clip,
            } },
        };
        try self.renderCommands(frame, &blur_command);
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
            const visible_rect = surface_rect.intersection(frame.output.logicalRect()) orelse continue;
            if (clip) |clip_rect| {
                if (visible_rect.intersection(clip_rect) == null) continue;
            }
            try frame.output.markSurfaceVisible(surface_id);
            if (buffer.transform != .normal) continue;
            const image_command = [_]render.Command{
                .{ .image = .{
                    .x = x,
                    .y = y,
                    .size = buffer.logical_size,
                    .buffer = buffer.pixelBuffer(),
                    .source = buffer.source,
                    .rounded_clip = rounded_clip,
                    .clip = clip,
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
    clip: ?render.Rect,
    commands: *[4]render.Command,
) []const render.Command {
    const width = borders.width;
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
    server.destroy();
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
