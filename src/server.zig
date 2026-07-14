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
const LayerShell = @import("wayland/layer_shell.zig");
const SinglePixelBuffer = @import("wayland/single_pixel_buffer.zig");
const Seat = @import("wayland/seat.zig");
const DataDevice = @import("wayland/data_device.zig");
const PrimarySelection = @import("wayland/primary_selection.zig");
const TextInput = @import("wayland/text_input.zig");
const InputMethod = @import("wayland/input_method.zig");
const PresentationProtocol = @import("wayland/presentation.zig");
const FractionalScale = @import("wayland/fractional_scale.zig");
const Fixes = @import("wayland/fixes.zig");
const LinuxDmabuf = @import("wayland/linux_dmabuf.zig");
const XdgActivation = @import("wayland/xdg_activation.zig");
const Output = @import("wayland/output.zig");
const OutputLayout = @import("wayland/output_layout.zig");
const OutputBackend = @import("backend/output.zig");
const renderer_types = @import("render/renderer.zig");
const render = @import("render/types.zig");
const Scene = @import("scene.zig");
const Surface = @import("wayland/surface.zig");
const Viewporter = @import("wayland/viewporter.zig");
const WindowManager = @import("river/window_manager.zig");

const wl = wayland.server.wl;
const log = std.log.scoped(.server);

allocator: std.mem.Allocator,
display: *wl.Server,
render_outputs: RenderOutputStore,
primary_render_output: RenderOutputId,
outputs: OutputLayout,
xdg_output: XdgOutput,
single_pixel_buffer: SinglePixelBuffer,
compositor: Compositor,
subcompositor: Subcompositor,
scene: Scene,
xdg_shell: XdgShell,
layer_shell: LayerShell,
seat: Seat,
data_device: DataDevice,
primary_selection: PrimarySelection,
text_input: TextInput,
input_method: InputMethod,
presentation_protocol: PresentationProtocol,
fractional_scale: FractionalScale,
fixes: Fixes,
linux_dmabuf: LinuxDmabuf,
xdg_activation: XdgActivation,
viewporter: Viewporter,
window_manager: WindowManager,
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
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const display = try wl.Server.create();
    errdefer display.destroy();
    try display.initShm();

    self.* = .{
        .allocator = allocator,
        .display = display,
        .render_outputs = .{},
        .primary_render_output = undefined,
        .outputs = undefined,
        .xdg_output = undefined,
        .single_pixel_buffer = undefined,
        .compositor = undefined,
        .subcompositor = undefined,
        .scene = undefined,
        .xdg_shell = undefined,
        .layer_shell = undefined,
        .seat = undefined,
        .data_device = undefined,
        .primary_selection = undefined,
        .text_input = undefined,
        .input_method = undefined,
        .presentation_protocol = undefined,
        .fractional_scale = undefined,
        .fixes = undefined,
        .linux_dmabuf = undefined,
        .xdg_activation = undefined,
        .viewporter = undefined,
        .window_manager = undefined,
        .renderer = try renderer_types.Renderer.init(allocator, renderer_kind),
        .socket_buffer = undefined,
        .listening = false,
    };
    errdefer self.render_outputs.deinit(allocator);
    errdefer self.renderer.deinit();
    try self.compositor.init(allocator, display);
    errdefer self.compositor.deinit();
    self.outputs.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.outputs.deinit();
    try self.seat.init(allocator, io, display, self.compositor.surfaceStore());
    errdefer self.seat.deinit();
    const render_output_id = try self.addRenderOutput(io, .{
        .kind = output_kind,
        .size = .{ .width = 1280, .height = 720 },
        .name = switch (output_kind) {
            .headless => "HEADLESS-1",
            .nested => "NESTED-1",
        },
        .description = switch (output_kind) {
            .headless => "Keywork headless output",
            .nested => "Keywork nested output",
        },
        .model = switch (output_kind) {
            .headless => "headless",
            .nested => "nested-wayland",
        },
    });
    errdefer std.debug.assert(self.removeRenderOutput(render_output_id));
    self.primary_render_output = render_output_id;
    const render_output = self.render_outputs.get(render_output_id).?.*;
    try self.xdg_output.init(display, &self.outputs);
    errdefer self.xdg_output.deinit();
    try self.single_pixel_buffer.init(allocator, display);
    errdefer self.single_pixel_buffer.deinit();
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
        render_output.backend.renderScale(),
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
        render_output.backend.size(),
    );
    errdefer self.xdg_shell.deinit();
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
    try self.window_manager.init(
        allocator,
        display,
        &self.outputs,
        render_output.protocol_id,
        &self.seat,
        &self.scene,
        &self.xdg_shell,
        &self.layer_shell,
        .{ .context = self, .route = routePointer },
    );
    errdefer self.window_manager.deinit();
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
    requestRepaint(self);

    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    self.data_device.cancel();
    self.layer_shell.clearRepaintListener();
    self.seat.clearRepaintListener();
    self.scene.clearRepaintListener();
    self.subcompositor.clearRepaintListener();
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| stopRenderOutput(entry.value.*);
    self.display.destroyClients();
    self.window_manager.deinit();
    self.input_method.deinit();
    self.text_input.deinit();
    self.primary_selection.deinit();
    self.data_device.deinit();
    self.xdg_activation.deinit();
    self.layer_shell.deinit();
    self.xdg_shell.deinit();
    self.scene.deinit();
    self.subcompositor.deinit();
    self.linux_dmabuf.deinit();
    self.fixes.deinit();
    self.fractional_scale.deinit();
    self.viewporter.deinit();
    self.presentation_protocol.deinit();
    self.single_pixel_buffer.deinit();
    self.xdg_output.deinit();
    render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        std.debug.assert(self.removeRenderOutput(entry.id));
    }
    self.outputs.deinit();
    self.render_outputs.deinit(allocator);
    self.seat.deinit();
    self.compositor.deinit();
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
    };
    try render_output.backend.init(
        self.allocator,
        io,
        self.display,
        config.size,
        config.kind,
        .{
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
        },
    );
    errdefer render_output.backend.deinit();
    render_output.protocol_id = try self.outputs.add(.{
        .position = config.position,
        .size = render_output.backend.size(),
        .physical_size = render_output.backend.physicalSize(),
        .scale = render_output.backend.clientScale(),
        .name = config.name,
        .description = config.description,
        .make = config.make,
        .model = config.model,
    });
    errdefer std.debug.assert(self.outputs.remove(render_output.protocol_id));
    render_output.timer = try self.display.getEventLoop().addTimer(
        *RenderOutput,
        handleRenderTimer,
        render_output,
    );
    errdefer stopRenderOutput(render_output);
    const id = try self.render_outputs.insert(self.allocator, render_output);
    render_output.repaint_needed = true;
    self.scheduleRepaint(render_output);
    return id;
}

fn removeRenderOutput(self: *Self, id: RenderOutputId) bool {
    const render_output = self.render_outputs.remove(id) orelse return false;
    stopRenderOutput(render_output);
    const protocol_output = self.outputs.get(render_output.protocol_id).?;
    Surface.discardPresentation(self.compositor.surfaceStore(), protocol_output);
    std.debug.assert(self.outputs.remove(render_output.protocol_id));
    render_output.backend.deinit();
    self.allocator.destroy(render_output);
    return true;
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
}

fn outputDiscarded(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
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
    if (!available) self.data_device.cancel();
    self.seat.setPointerAvailable(available);
}

fn pointerEnter(context: *anyopaque, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const point = output.globalPoint(x, y);
    const route = self.pointerRoute(point.x, point.y);
    if (self.data_device.isDragging()) {
        self.seat.pointerEnter(point.x, point.y, null);
        self.data_device.pointerEntered(route.focus);
        self.window_manager.pointerMoved(null);
        return;
    }
    self.seat.pointerEnter(
        point.x,
        point.y,
        if (self.window_manager.pointerGrabbed()) null else route.focus,
    );
    self.window_manager.pointerMoved(if (self.window_manager.pointerGrabbed()) null else route.root);
}

fn pointerLeave(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.data_device.pointerLeft();
    self.seat.pointerLeave();
    self.window_manager.pointerMoved(null);
}

fn pointerMotion(context: *anyopaque, time: u32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const point = output.globalPoint(x, y);
    const route = self.pointerRoute(point.x, point.y);
    if (self.data_device.isDragging()) {
        self.seat.pointerMotion(time, point.x, point.y, null);
        self.data_device.pointerMotion(time, route.focus);
        self.window_manager.pointerMoved(null);
        return;
    }
    self.seat.pointerMotion(
        time,
        point.x,
        point.y,
        if (self.window_manager.pointerGrabbed()) null else route.focus,
    );
    self.window_manager.pointerMoved(if (self.window_manager.pointerGrabbed()) null else route.root);
}

fn pointerButton(
    context: *anyopaque,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    const self = serverForOutput(context);
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
        .root = if (focus) |value| self.subcompositor.rootSurface(value.surface_id) else self.borderRoot(x, y),
    };
}

fn borderRoot(self: *Self, x: f64, y: f64) ?Surface.Id {
    const fullscreen = self.scene.topFullscreen();
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
    const fullscreen = self.scene.topFullscreen();
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
    const clear_command = [_]render.Command{
        .{ .clear = render.Color.rgba(24, 24, 27, 255) },
    };
    try self.renderCommands(&frame, &clear_command);

    try self.renderLayerSurfaces(&frame, .background);
    try self.renderLayerSurfaces(&frame, .bottom);
    const top_fullscreen = self.scene.topFullscreen();
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
        try self.renderSurfaceTree(
            &frame,
            info.surface_id,
            info.x,
            info.y,
            null,
            null,
        );
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
    if (cursor) |info| self.submitSurfaceTree(output, info.surface_id);
    self.discardUnsubmittedFeedbackIfIdle();
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

fn discardUnsubmittedFeedbackIfIdle(self: *Self) void {
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (render_output.repaint_needed or render_output.render_scheduled) return;
    }
    Surface.discardUnsubmittedFeedback(self.compositor.surfaceStore());
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
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless);
    server.destroy();
}

test "server adds and removes independent render outputs" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless);
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
