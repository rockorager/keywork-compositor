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
const Tablet = @import("wayland/tablet.zig");
const RelativePointer = @import("wayland/relative_pointer.zig");
const PointerGestures = @import("wayland/pointer_gestures.zig");
const PointerConstraints = @import("wayland/pointer_constraints.zig");
const IdleInhibit = @import("wayland/idle_inhibit.zig");
const IdleNotify = @import("wayland/idle_notify.zig");
const Seat = @import("wayland/seat.zig");
const DataDevice = @import("wayland/data_device.zig");
const PrimarySelection = @import("wayland/primary_selection.zig");
const DataControl = @import("wayland/data_control.zig");
const ForeignToplevelList = @import("wayland/foreign_toplevel_list.zig");
const ImageCaptureSource = @import("wayland/image_capture_source.zig");
const ImageCopyCapture = @import("wayland/image_copy_capture.zig");
const Workspace = @import("wayland/workspace.zig");
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
const OutputPower = @import("wayland/output_power.zig");
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
io: std.Io,
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
output_power: OutputPower,
output_power_initialized: bool,
single_pixel_buffer: SinglePixelBuffer,
content_type: ContentType,
security_context: SecurityContext,
session_lock: SessionLock,
session_lock_initialized: bool,
cursor_shape: CursorShape,
tablet: Tablet,
relative_pointer: RelativePointer,
pointer_gestures: PointerGestures,
pointer_constraints: PointerConstraints,
idle_inhibit: IdleInhibit,
idle_notify: IdleNotify,
idle_notify_initialized: bool,
compositor: Compositor,
subcompositor: Subcompositor,
scene: Scene,
xdg_shell: XdgShell,
xdg_foreign: XdgForeign,
layer_shell: LayerShell,
seat: Seat,
dynamic_seats: std.ArrayList(*SeatEntry),
input_device_listener: InputManager.DeviceListener,
routed_keys: std.ArrayList(RoutedKey),
routed_buttons: std.ArrayList(RoutedButton),
routed_gestures: std.ArrayList(RoutedGesture),
routed_touches: std.ArrayList(RoutedTouch),
next_touch_id: u31,
data_device: DataDevice,
primary_selection: PrimarySelection,
data_control: DataControl,
foreign_toplevel_list: ForeignToplevelList,
foreign_toplevel_list_initialized: bool,
image_capture_source: ImageCaptureSource,
image_capture_source_initialized: bool,
image_copy_capture: ImageCopyCapture,
image_copy_capture_initialized: bool,
workspace: Workspace,
workspace_initialized: bool,
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

const SeatEntry = struct {
    name: [:0]u8,
    seat: Seat,
    removed: bool,
};

const RoutedKey = struct {
    device_id: NativeInput.DeviceId,
    seat: *Seat,
    key: u32,
};

const RoutedButton = struct {
    device_id: NativeInput.DeviceId,
    seat: *Seat,
    button: u32,
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
    size: render.Size,
    scale: render.Scale,
    origin: render.Position,
    visible_rect: render.Rect,
    track_visibility: bool,
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
        .io = io,
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
        .output_power = undefined,
        .output_power_initialized = false,
        .single_pixel_buffer = undefined,
        .content_type = undefined,
        .security_context = undefined,
        .session_lock = undefined,
        .session_lock_initialized = false,
        .cursor_shape = undefined,
        .tablet = undefined,
        .relative_pointer = undefined,
        .pointer_gestures = undefined,
        .pointer_constraints = undefined,
        .idle_inhibit = undefined,
        .idle_notify = undefined,
        .idle_notify_initialized = false,
        .compositor = undefined,
        .subcompositor = undefined,
        .scene = undefined,
        .xdg_shell = undefined,
        .xdg_foreign = undefined,
        .layer_shell = undefined,
        .seat = undefined,
        .dynamic_seats = .empty,
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
        .primary_selection = undefined,
        .data_control = undefined,
        .foreign_toplevel_list = undefined,
        .foreign_toplevel_list_initialized = false,
        .image_capture_source = undefined,
        .image_capture_source_initialized = false,
        .image_copy_capture = undefined,
        .image_copy_capture_initialized = false,
        .workspace = undefined,
        .workspace_initialized = false,
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
    errdefer self.routed_touches.deinit(allocator);
    errdefer self.routed_gestures.deinit(allocator);
    errdefer self.routed_buttons.deinit(allocator);
    errdefer self.routed_keys.deinit(allocator);
    errdefer self.dynamic_seats.deinit(allocator);
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
    try self.idle_inhibit.init(allocator, display, .{
        .context = self,
        .changed = idleInhibitorsChanged,
    });
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
    try self.idle_notify.init(allocator, io, display, .{
        .context = self,
        .failed = idleNotifyFailed,
    });
    self.idle_notify_initialized = true;
    errdefer {
        self.idle_notify.deinit();
        self.idle_notify_initialized = false;
    }
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
    try self.foreign_toplevel_list.init(
        allocator,
        display,
        &self.security_context,
        &self.xdg_shell,
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
        },
    );
    self.image_copy_capture_initialized = true;
    errdefer {
        self.image_copy_capture.deinit();
        self.image_copy_capture_initialized = false;
    }
    try self.workspace.init(allocator, display, &self.security_context, &self.outputs);
    self.workspace_initialized = true;
    errdefer {
        self.workspace.deinit();
        self.workspace_initialized = false;
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
        self.input_manager.setSeatListener(.{
            .context = self,
            .created = inputSeatCreated,
            .device_changed = inputDeviceSeatChanged,
            .destroyed = inputSeatDestroyed,
        });
        errdefer self.input_manager.clearSeatListener();
        try self.input_manager.addDeviceListener(&self.input_device_listener);
        errdefer self.input_manager.removeDeviceListener(&self.input_device_listener);
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
    if (self.input_manager_initialized) {
        self.input_manager.detachNativeInput();
        self.input_manager.removeDeviceListener(&self.input_device_listener);
        self.input_manager.clearSeatListener();
    }
    if (self.native_input_initialized) self.native_input.deinit();
    self.layer_shell.clearRepaintListener();
    self.seat.clearRepaintListener();
    for (self.dynamic_seats.items) |entry| {
        if (!entry.removed) entry.seat.clearRepaintListener();
    }
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
    if (self.output_power_initialized) {
        self.output_power.deinit();
        self.output_power_initialized = false;
    }
    if (self.output_management_initialized) {
        self.output_management.deinit();
        self.output_management_initialized = false;
    }
    self.workspace.deinit();
    self.workspace_initialized = false;
    self.image_copy_capture.deinit();
    self.image_copy_capture_initialized = false;
    self.image_capture_source.deinit();
    self.image_capture_source_initialized = false;
    self.foreign_toplevel_list.deinit();
    self.foreign_toplevel_list_initialized = false;
    self.window_manager.deinit();
    self.window_manager_initialized = false;
    self.virtual_keyboard.deinit();
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
    self.scene.deinit();
    self.subcompositor.deinit();
    self.linux_dmabuf.deinit();
    self.fixes.deinit();
    self.fractional_scale.deinit();
    self.viewporter.deinit();
    self.presentation_protocol.deinit();
    self.idle_inhibit.deinit();
    self.pointer_constraints.deinit();
    self.pointer_gestures.deinit();
    self.relative_pointer.deinit();
    self.cursor_shape.deinit();
    self.tablet.deinit();
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
    self.routed_touches.deinit(allocator);
    self.routed_gestures.deinit(allocator);
    self.routed_buttons.deinit(allocator);
    self.routed_keys.deinit(allocator);
    for (self.dynamic_seats.items) |entry| {
        entry.seat.deinit();
        allocator.free(entry.name);
        allocator.destroy(entry);
    }
    self.dynamic_seats.deinit(allocator);
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
    if (self.workspace_initialized) {
        self.workspace.addOutput(render_output.protocol_id);
        errdefer self.workspace.removeOutput(render_output.protocol_id);
    }
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

fn inputSeatCreated(context: *anyopaque, name: [:0]const u8) error{OutOfMemory}!void {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(self.seatForName(name) == null);

    const name_copy = try self.allocator.dupeSentinel(u8, name, 0);
    errdefer self.allocator.free(name_copy);
    const entry = try self.allocator.create(SeatEntry);
    errdefer self.allocator.destroy(entry);
    entry.* = .{ .name = name_copy, .seat = undefined, .removed = false };
    entry.seat.init(
        self.allocator,
        self.native_input.io,
        self.display,
        name_copy,
        self.compositor.surfaceStore(),
    ) catch |err| {
        log.err("failed to create input seat {s}: {t}", .{ name, err });
        self.terminate();
        return error.OutOfMemory;
    };
    errdefer entry.seat.deinit();
    entry.seat.ensureParentKeyboardEnter();
    entry.seat.setRepaintListener(.{ .context = self, .request = requestRepaint });
    errdefer entry.seat.clearRepaintListener();
    try self.window_manager.seatAdded(&entry.seat);
    errdefer self.window_manager.seatRemoved(&entry.seat);
    try self.data_control.addSeat(&entry.seat);
    errdefer self.data_control.removeSeat(&entry.seat);
    try self.dynamic_seats.append(self.allocator, entry);
    self.refreshSeatCapabilities(&entry.seat, name_copy);
    requestRepaint(self);
}

fn inputSeatDestroyed(context: *anyopaque, name: [:0]const u8) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.dynamic_seats.items) |entry| {
        if (entry.removed or !std.mem.eql(u8, entry.name, name)) continue;
        self.cancelSeatGestures(&entry.seat);
        entry.seat.setKeyboardAvailable(false);
        entry.seat.setPointerAvailable(false);
        entry.seat.setTouchAvailable(false);
        entry.seat.parentKeyboardLeave();
        self.window_manager.seatRemoved(&entry.seat);
        self.data_control.removeSeat(&entry.seat);
        entry.seat.clearRepaintListener();
        entry.seat.removeGlobal();
        entry.removed = true;
        requestRepaint(self);
        return;
    }
    unreachable;
}

fn inputDeviceAdded(context: *anyopaque, device: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const seat = self.seatForName(device.seat_name) orelse return;
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
    self.refreshSeatCapabilities(seat, device.seat_name);
    if (device.device_type == .keyboard) self.prepareSeatKeyboard(seat, device.id);
}

fn inputDeviceRemoved(context: *anyopaque, device: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const seat = self.seatForName(device.seat_name) orelse return;
    if (device.device_type == .keyboard) self.releaseDeviceKeys(device.id);
    if (device.device_type == .pointer) {
        self.releaseDeviceButtons(device.id);
        self.cancelDeviceGestures(device.id);
    }
    if (device.device_type == .tablet) self.tablet.removeTablet(device.id);
    if (device.device_type == .tablet_pad) self.tablet.removePad(device.id);
    if (device.device_type == .touch) self.cancelDeviceTouches(device.id);
    self.refreshSeatCapabilities(seat, device.seat_name);
    if (device.device_type == .keyboard) self.prepareAnySeatKeyboard(seat, device.seat_name);
}

fn inputDeviceSeatChanged(
    context: *anyopaque,
    device: *InputManager.Device,
    previous_name: [:0]const u8,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (device.device_type == .keyboard) self.releaseDeviceKeys(device.id);
    if (device.device_type == .pointer) {
        self.releaseDeviceButtons(device.id);
        self.cancelDeviceGestures(device.id);
    }
    if (device.device_type == .touch) self.cancelDeviceTouches(device.id);
    if (self.seatForName(previous_name)) |previous| {
        self.refreshSeatCapabilities(previous, previous_name);
        if (device.device_type == .keyboard) self.prepareAnySeatKeyboard(previous, previous_name);
    }
    const next = self.seatForName(device.seat_name) orelse return;
    if (device.device_type == .tablet) {
        self.tablet.moveTablet(device.id, next) catch return self.terminate();
    }
    if (device.device_type == .tablet_pad) {
        self.tablet.movePad(device.id, next) catch return self.terminate();
    }
    self.refreshSeatCapabilities(next, device.seat_name);
    if (device.device_type == .keyboard) {
        next.ensureParentKeyboardEnter();
        self.prepareSeatKeyboard(next, device.id);
    }
}

fn seatForName(self: *Self, name: []const u8) ?*Seat {
    if (std.mem.eql(u8, name, "default")) return &self.seat;
    for (self.dynamic_seats.items) |entry| {
        if (!entry.removed and std.mem.eql(u8, entry.name, name)) return &entry.seat;
    }
    return null;
}

fn seatForDevice(self: *Self, id: NativeInput.DeviceId) *Seat {
    if (!self.input_manager_initialized) return &self.seat;
    const device = self.input_manager.findDevice(id) orelse return &self.seat;
    return self.seatForName(device.seat_name) orelse &self.seat;
}

fn refreshSeatCapabilities(self: *Self, seat: *Seat, name: []const u8) void {
    var keyboard = false;
    var pointer = false;
    var touch = false;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        if (!std.mem.eql(u8, device.seat_name, name)) continue;
        switch (device.device_type) {
            .keyboard => keyboard = true,
            .pointer => pointer = true,
            .touch => touch = true,
            .tablet, .tablet_pad => {},
        }
    }
    if (seat == &self.seat and !pointer) {
        self.pointer_constraints.deactivateAll();
        self.data_device.cancel();
    }
    seat.setKeyboardAvailable(keyboard);
    seat.setPointerAvailable(pointer);
    seat.setTouchAvailable(touch);
}

fn prepareAnySeatKeyboard(self: *Self, seat: *Seat, name: []const u8) void {
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        if (device.device_type != .keyboard or !std.mem.eql(u8, device.seat_name, name)) continue;
        self.prepareSeatKeyboard(seat, device.id);
        return;
    }
    seat.setModifiers(0, 0, 0, 0);
}

fn prepareSeatKeyboard(self: *Self, seat: *Seat, id: NativeInput.DeviceId) void {
    const state = self.native_input.keyboardState(id) orelse return;
    const fd = self.native_input.duplicateKeyboardKeymapFd(id) catch {
        log.err("failed to duplicate keymap for input seat", .{});
        return self.terminate();
    } orelse return;
    seat.setKeymap(.xkb_v1, fd, state.keymap.size);
    if (self.native_input.deviceRepeatInfo(id)) |repeat| {
        seat.setRepeatInfo(repeat.rate, repeat.delay);
    }
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
    const render_output = self.render_outputs.remove(id) orelse return false;
    stopRenderOutput(render_output);
    const protocol_output = self.outputs.get(render_output.protocol_id).?;
    if (self.workspace_initialized) self.workspace.removeOutput(render_output.protocol_id);
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.removeOutput(render_output.protocol_id);
    }
    if (self.image_capture_source_initialized) {
        self.image_capture_source.removeOutput(render_output.protocol_id);
    }
    if (self.output_power_initialized) self.output_power.removeOutput(render_output.protocol_id);
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
    self.refreshIdleInhibition();
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (!render_output.backend.powered()) {
            render_output.repaint_needed = false;
            continue;
        }
        render_output.repaint_needed = true;
        self.scheduleRepaint(render_output);
    }
}

fn clearCursorShapes(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.clearCursorShapes();
    for (self.dynamic_seats.items) |entry| entry.seat.clearCursorShapes();
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

fn sessionLockStateChanged(context: *anyopaque, locked: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
    self.pointer_constraints.deactivateAll();
    self.data_device.cancel();
    self.tablet.cancelFocus();
    self.cancelSeatTouches(&self.seat);
    self.seat.suppressPointerFocus(true);
    self.window_manager.pointerMoved(null);
    for (self.dynamic_seats.items) |entry| {
        if (entry.removed) continue;
        self.cancelSeatTouches(&entry.seat);
        entry.seat.suppressPointerFocus(true);
        self.window_manager.pointerMovedForSeat(&entry.seat, null);
    }
    self.xdg_shell.dismissPopupGrab();
    if (locked) {
        self.virtual_keyboard.setInhibited(true);
        self.input_method.setInhibited(true);
        self.seat.setKeyboardFocus(null);
        for (self.dynamic_seats.items) |entry| {
            if (!entry.removed) entry.seat.setKeyboardFocus(null);
        }
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
        for (self.dynamic_seats.items) |entry| {
            if (entry.removed) continue;
            entry.seat.setKeyboardFocus(null);
            if (entry.seat.pointerPosition()) |position| {
                entry.seat.pointerEnter(
                    position.x,
                    position.y,
                    self.pointerFocus(position.x, position.y),
                );
            }
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
    self.idle_notify.notifyActivity(seat);
    switch (state) {
        .pressed => {
            for (self.routed_buttons.items) |routed| {
                if (routed.device_id == device_id and routed.button == button) return;
            }
            const already_pressed = self.seatButtonHeld(seat, button);
            self.routed_buttons.append(self.allocator, .{
                .device_id = device_id,
                .seat = seat,
                .button = button,
            }) catch return self.terminate();
            if (already_pressed) return;
        },
        .released => {
            for (self.routed_buttons.items, 0..) |routed, index| {
                if (routed.device_id != device_id or routed.button != button) continue;
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
        if (routed.device_id != device_id) {
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
            self.layer_shell.pointerPressed(self.subcompositor.rootSurface(target.surface_id));
            requestRepaint(self);
        } else if (self.xdg_shell.hasPopupGrab()) {
            self.xdg_shell.dismissPopupGrab();
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
    pointerMotionForSeat(output, &output.server.seat, time, x, y);
}

fn pointerMotionForSeat(output: *RenderOutput, seat: *Seat, time: u32, x: f64, y: f64) void {
    const self = output.server;
    self.idle_notify.notifyActivity(seat);
    const target = output.globalPoint(x, y);
    if (self.session_lock.isLocked()) {
        seat.pointerMotion(
            time,
            target.x,
            target.y,
            self.pointerFocus(target.x, target.y),
        );
        self.window_manager.pointerMovedForSeat(seat, null);
        return;
    }
    if (seat == &self.seat and self.data_device.isDragging()) {
        self.pointer_constraints.deactivateAll();
        const route = self.pointerRoute(target.x, target.y);
        seat.pointerMotion(time, target.x, target.y, null);
        self.data_device.pointerMotion(time, route.focus);
        self.window_manager.pointerMovedForSeat(seat, null);
        return;
    }
    if (self.window_manager.pointerGrabbedForSeat(seat)) {
        if (seat == &self.seat) self.pointer_constraints.deactivateAll();
        seat.pointerMotion(time, target.x, target.y, null);
        self.window_manager.pointerMovedForSeat(seat, null);
        return;
    }
    if (seat != &self.seat) {
        const route = self.pointerRoute(target.x, target.y);
        seat.pointerMotion(time, target.x, target.y, route.focus);
        self.window_manager.pointerMovedForSeat(seat, route.root);
        return;
    }
    const motion = self.pointer_constraints.constrainMotion(.{ .x = target.x, .y = target.y });
    if (motion.point.x != target.x or motion.point.y != target.y) {
        self.synchronizeBackendPointer(output, motion.point.x, motion.point.y);
    }
    if (motion.locked) return;
    const route = self.pointerRoute(motion.point.x, motion.point.y);
    seat.pointerMotion(
        time,
        motion.point.x,
        motion.point.y,
        route.focus,
    );
    self.window_manager.pointerMovedForSeat(seat, route.root);
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
        if (state == .released and grab_ended) self.data_device.drop();
        return;
    }
    const root = if (seat.pointerPosition()) |position|
        self.pointerRoute(position.x, position.y).root
    else
        null;
    if (self.window_manager.pointerButtonForSeat(seat, button, state, root)) {
        if (seat == &self.seat) self.pointer_constraints.deactivateAll();
        seat.suppressPointerFocus(true);
        return;
    }
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

fn captureConstraints(
    context: *anyopaque,
    target: ImageCaptureSource.Target,
) ?ImageCopyCapture.Constraints {
    const self: *Self = @ptrCast(@alignCast(context));
    return switch (target) {
        .output => |output_id| output: {
            const render_output = self.renderOutputForProtocol(output_id) orelse return null;
            break :output .{ .size = render_output.backend.size() };
        },
        .toplevel => |window_id| toplevel: {
            const bounds = self.toplevelCaptureBounds(window_id) orelse return null;
            break :toplevel .{ .size = .{ .width = bounds.width, .height = bounds.height } };
        },
    };
}

fn captureImage(
    context: *anyopaque,
    target: ImageCaptureSource.Target,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) ImageCopyCapture.CaptureError!presentation.Timestamp {
    const self: *Self = @ptrCast(@alignCast(context));
    switch (target) {
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
    }
    return presentation.Info.now(self.io).timestamp;
}

fn captureOutput(
    self: *Self,
    output_id: OutputLayout.Id,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) renderer_types.Renderer.Error!void {
    const render_output = self.renderOutputForProtocol(output_id) orelse
        return error.InvalidTarget;
    const output = self.outputs.get(output_id) orelse return error.InvalidTarget;
    if (!std.meta.eql(pixel_buffer.size, render_output.backend.size())) {
        return error.InvalidTarget;
    }
    const position = output.logicalPosition();
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .target = self.renderer.makeTarget(pixel_buffer),
        .size = pixel_buffer.size,
        .scale = render_output.backend.renderScale(),
        .origin = .{ .x = position.x, .y = position.y },
        .visible_rect = output.logicalRect(),
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
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .target = self.renderer.makeTarget(pixel_buffer),
        .size = pixel_buffer.size,
        .scale = .{},
        .origin = .{ .x = bounds.x, .y = bounds.y },
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
    const position = output.logicalPosition();
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .target = self.renderer.makeTarget(pixel_target),
        .size = render_output.backend.size(),
        .scale = render_output.backend.renderScale(),
        .origin = .{ .x = position.x, .y = position.y },
        .visible_rect = output.logicalRect(),
        .track_visibility = true,
    };
    const clear_command = [_]render.Command{.{ .clear = if (self.session_lock.isLocked())
        render.Color.rgba(0, 0, 0, 255)
    else
        render.Color.rgba(24, 24, 27, 255) }};
    try self.renderCommands(&frame, &clear_command);
    if (self.session_lock.isLocked()) return self.renderSessionLockFrame(&frame);

    const top_fullscreen = try self.renderDesktopContents(&frame, true);

    const presented = render_output.backend.present() catch return error.InvalidTarget;
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
    for (self.dynamic_seats.items) |entry| {
        if (!entry.removed) self.submitSeatCursor(output, &entry.seat, false);
    }
    self.submitTabletCursors(output, false);
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
    if (top_fullscreen == null) try self.renderLayerSurfaces(frame, .top);
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
        for (self.dynamic_seats.items) |entry| {
            if (!entry.removed) try self.renderSeatCursor(frame, &entry.seat, false);
        }
        try self.renderTabletCursors(frame, false);
    }
    return top_fullscreen;
}

fn renderSessionLockFrame(
    self: *Self,
    frame: *const OutputFrame,
) renderer_types.Renderer.Error!void {
    try self.renderSessionLockContents(frame, true);

    const lock_surface = self.session_lock.surfaceForOutput(frame.render_output.protocol_id);
    const presented = frame.render_output.backend.present() catch return error.InvalidTarget;
    frame.render_output.lock_frame_pending = true;
    frame.output.endFrame();
    self.foreign_toplevel_list.syncOutput(frame.render_output.protocol_id);
    if (lock_surface) |info| self.submitSurfaceTree(frame.output, info.surface_id);
    self.submitSeatCursor(frame.output, &self.seat, true);
    for (self.dynamic_seats.items) |entry| {
        if (!entry.removed) self.submitSeatCursor(frame.output, &entry.seat, true);
    }
    self.submitTabletCursors(frame.output, true);
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
        for (self.dynamic_seats.items) |entry| {
            if (!entry.removed) try self.renderSeatCursor(frame, &entry.seat, true);
        }
        try self.renderTabletCursors(frame, true);
    }
}

fn refreshKeyboardFocus(self: *Self) void {
    if (self.session_lock.isLocked()) {
        const focus = self.session_lock.keyboardFocus();
        self.seat.setKeyboardFocus(focus);
        for (self.dynamic_seats.items) |entry| {
            if (!entry.removed) entry.seat.setKeyboardFocus(focus);
        }
        return;
    }
    const default_focus = self.layer_shell.keyboardFocus(
        self.xdg_shell.popupKeyboardFocus(),
    ) orelse
        self.window_manager.focusedShellSurface() orelse self.scene.focusedSurface() orelse if (!self.window_manager.hasActiveManager())
        self.scene.topWindowSurface()
    else
        null;
    self.seat.setKeyboardFocus(default_focus);
    for (self.dynamic_seats.items) |entry| {
        if (entry.removed) continue;
        const focus = self.window_manager.focusedSurfaceForSeat(&entry.seat) orelse if (!self.window_manager.hasActiveManager())
            self.scene.focusedSurface() orelse self.scene.topWindowSurface()
        else
            null;
        entry.seat.setKeyboardFocus(focus);
    }
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
    try self.renderer.render(.{
        .size = frame.size,
        .commands = commands,
        .scale = frame.scale,
        .origin = frame.origin,
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
            const visible_rect = surface_rect.intersection(frame.visible_rect) orelse continue;
            if (clip) |clip_rect| {
                if (visible_rect.intersection(clip_rect) == null) continue;
            }
            if (frame.track_visibility) try frame.output.markSurfaceVisible(surface_id);
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
