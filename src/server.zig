//! Wayland display and compositor-global lifetime.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Compositor = @import("wayland/compositor.zig");
const Subcompositor = @import("wayland/subcompositor.zig");
const XdgShell = @import("wayland/xdg_shell.zig");
const Seat = @import("wayland/seat.zig");
const DataDevice = @import("wayland/data_device.zig");
const PrimarySelection = @import("wayland/primary_selection.zig");
const FractionalScale = @import("wayland/fractional_scale.zig");
const Output = @import("wayland/output.zig");
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
render_output: OutputBackend,
output: Output,
compositor: Compositor,
subcompositor: Subcompositor,
scene: Scene,
xdg_shell: XdgShell,
seat: Seat,
data_device: DataDevice,
primary_selection: PrimarySelection,
fractional_scale: FractionalScale,
viewporter: Viewporter,
window_manager: WindowManager,
renderer: renderer_types.Renderer,
render_timer: *wl.EventSource,
repaint_pending: bool,
frame_time_milliseconds: u32,
socket_buffer: [11]u8,
listening: bool,

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
        .render_output = undefined,
        .output = undefined,
        .compositor = undefined,
        .subcompositor = undefined,
        .scene = undefined,
        .xdg_shell = undefined,
        .seat = undefined,
        .data_device = undefined,
        .primary_selection = undefined,
        .fractional_scale = undefined,
        .viewporter = undefined,
        .window_manager = undefined,
        .renderer = try renderer_types.Renderer.init(allocator, renderer_kind),
        .render_timer = undefined,
        .repaint_pending = false,
        .frame_time_milliseconds = 0,
        .socket_buffer = undefined,
        .listening = false,
    };
    errdefer self.renderer.deinit();
    try self.compositor.init(allocator, display);
    errdefer self.compositor.deinit();
    try self.seat.init(allocator, io, display, self.compositor.surfaceStore());
    errdefer self.seat.deinit();
    try self.render_output.init(
        allocator,
        io,
        display,
        .{ .width = 1280, .height = 720 },
        output_kind,
        .{
            .context = self,
            .repaint = requestRepaint,
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
        },
    );
    errdefer self.render_output.deinit();
    try self.output.init(
        allocator,
        display,
        self.render_output.size(),
        self.render_output.physicalSize(),
        self.render_output.clientScale(),
        self.compositor.surfaceStore(),
    );
    errdefer self.output.deinit();
    self.compositor.setOutput(&self.output);
    try self.viewporter.init(allocator, display);
    errdefer self.viewporter.deinit();
    try self.fractional_scale.init(
        allocator,
        display,
        self.render_output.renderScale(),
    );
    errdefer self.fractional_scale.deinit();
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
        self.render_output.size(),
    );
    errdefer self.xdg_shell.deinit();
    try self.data_device.init(allocator, display, &self.seat);
    errdefer self.data_device.deinit();
    try self.primary_selection.init(allocator, display, &self.seat);
    errdefer self.primary_selection.deinit();
    try self.window_manager.init(
        allocator,
        display,
        &self.output,
        &self.seat,
        &self.scene,
        &self.xdg_shell,
    );
    errdefer self.window_manager.deinit();
    self.render_timer = try display.getEventLoop().addTimer(*Self, handleRenderTimer, self);
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
    requestRepaint(self);

    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    self.seat.clearRepaintListener();
    self.scene.clearRepaintListener();
    self.subcompositor.clearRepaintListener();
    self.render_timer.remove();
    self.display.destroyClients();
    self.window_manager.deinit();
    self.primary_selection.deinit();
    self.data_device.deinit();
    self.xdg_shell.deinit();
    self.scene.deinit();
    self.subcompositor.deinit();
    self.fractional_scale.deinit();
    self.viewporter.deinit();
    self.output.deinit();
    self.render_output.deinit();
    self.seat.deinit();
    self.compositor.deinit();
    self.renderer.deinit();
    self.display.destroy();
    allocator.destroy(self);
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
    if (self.repaint_pending) return;
    self.render_timer.timerUpdate(16) catch |err| {
        log.err("failed to schedule repaint: {t}", .{err});
        self.terminate();
        return;
    };
    self.repaint_pending = true;
}

fn closeOutput(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn keyboardAvailable(context: *anyopaque, available: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.setKeyboardAvailable(available);
}

fn keyboardKeymap(
    context: *anyopaque,
    format: wl.Keyboard.KeymapFormat,
    fd: std.posix.fd_t,
    size: u32,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.setKeymap(format, fd, size);
}

fn keyboardEnter(context: *anyopaque, pressed_keys: []const u32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.parentKeyboardEnter(pressed_keys) catch {
        log.err("failed to store pressed keyboard keys", .{});
        self.terminate();
    };
}

fn keyboardLeave(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.parentKeyboardLeave();
}

fn keyboardKey(
    context: *anyopaque,
    time: u32,
    key: u32,
    state: wl.Keyboard.KeyState,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
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
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.setModifiers(depressed, latched, locked, group);
}

fn keyboardRepeatInfo(context: *anyopaque, rate: i32, delay: i32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.setRepeatInfo(rate, delay);
}

fn pointerAvailable(context: *anyopaque, available: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.setPointerAvailable(available);
}

fn pointerEnter(context: *anyopaque, x: f64, y: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerEnter(x, y, self.pointerFocus(x, y));
}

fn pointerLeave(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerLeave();
}

fn pointerMotion(context: *anyopaque, time: u32, x: f64, y: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerMotion(time, x, y, self.pointerFocus(x, y));
}

fn pointerButton(
    context: *anyopaque,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (state == .pressed and self.xdg_shell.hasPopupGrab() and
        self.seat.pointerFocusedSurface() == null)
    {
        self.xdg_shell.dismissPopupGrab();
        return;
    }
    self.seat.pointerButton(time, button, state);
}

fn pointerAxis(context: *anyopaque, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerAxis(time, axis, value);
}

fn pointerFrame(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerFrame();
}

fn pointerAxisSource(context: *anyopaque, source: wl.Pointer.AxisSource) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerAxisSource(source);
}

fn pointerAxisStop(context: *anyopaque, time: u32, axis: wl.Pointer.Axis) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerAxisStop(time, axis);
}

fn pointerAxisDiscrete(context: *anyopaque, axis: wl.Pointer.Axis, discrete: i32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerAxisDiscrete(axis, discrete);
}

fn pointerAxisValue120(context: *anyopaque, axis: wl.Pointer.Axis, value120: i32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerAxisValue120(axis, value120);
}

fn pointerAxisRelativeDirection(
    context: *anyopaque,
    axis: wl.Pointer.Axis,
    direction: wl.Pointer.AxisRelativeDirection,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.pointerAxisRelativeDirection(axis, direction);
}

fn pointerFocus(self: *Self, x: f64, y: f64) ?Seat.PointerFocus {
    const focus = self.scenePointerFocus(x, y);
    if (focus) |candidate| {
        if (self.xdg_shell.hasPopupGrab() and
            !self.xdg_shell.popupGrabOwnsSurface(candidate.surface_id)) return null;
    }
    return focus;
}

fn scenePointerFocus(self: *Self, x: f64, y: f64) ?Seat.PointerFocus {
    const fullscreen = self.scene.topFullscreen();
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
    const root_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) orelse return null;
    if (root_buffer.transform != .normal) return null;
    const content_geometry = window.content_geometry orelse Scene.ContentGeometry{
        .size = root_buffer.logical_size,
    };
    if (window.clip_box) |clip_box| {
        if (!pointInRect(x, y, clip_box.translated(window.position.x, window.position.y))) return null;
    }
    if (window.content_clip_box) |clip_box| {
        const content_rect: render.Rect = .{
            .x = window.position.x,
            .y = window.position.y,
            .width = content_geometry.size.width,
            .height = content_geometry.size.height,
        };
        const visible = content_rect.intersection(
            clip_box.translated(window.position.x, window.position.y),
        ) orelse return null;
        if (!pointInRect(x, y, visible)) return null;
    }
    if (window.effects.corner_radius > 0) {
        const visible = windowContentRect(window, content_geometry.size) orelse return null;
        if (!pointInRoundedRect(x, y, visible, window.effects.corner_radius)) return null;
    }
    return self.hitTestSurface(
        window.surface_id,
        .{
            .x = window.position.x -| content_geometry.offset.x,
            .y = window.position.y -| content_geometry.offset.y,
        },
        x,
        y,
    );
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

fn handleRenderTimer(self: *Self) c_int {
    self.repaint_pending = false;
    self.renderFrame() catch |err| {
        log.err("output frame failed: {t}", .{err});
        self.terminate();
    };
    return 0;
}

fn renderFrame(self: *Self) renderer_types.Renderer.Error!void {
    const pixel_target = self.render_output.acquire() orelse return;
    errdefer self.render_output.cancel();
    const output_size = self.render_output.size();
    const target = self.renderer.makeTarget(pixel_target);
    const clear_command = [_]render.Command{
        .{ .clear = render.Color.rgba(24, 24, 27, 255) },
    };
    try self.renderCommands(output_size, &clear_command, target);

    const top_fullscreen = self.scene.topFullscreen();
    var fullscreen_reached = top_fullscreen == null;
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (!window_entry.window.mapped) continue;
            if (top_fullscreen) |id| {
                if (!std.meta.eql(window_entry.id, id)) continue;
                fullscreen_reached = true;
            }
            try self.renderWindow(window_entry.id, window_entry.window, output_size, target);
        },
        .shell_surface => |shell_entry| {
            if (!fullscreen_reached or !shell_entry.shell_surface.mapped) continue;
            try self.renderSurfaceTree(
                shell_entry.shell_surface.surface_id,
                shell_entry.shell_surface.position.x,
                shell_entry.shell_surface.position.y,
                null,
                null,
                target,
            );
        },
    };

    const cursor = self.seat.cursorInfo();
    if (cursor) |info| {
        try self.renderSurfaceTree(
            info.surface_id,
            info.x,
            info.y,
            null,
            null,
            target,
        );
    }

    self.render_output.present() catch return error.InvalidTarget;

    self.frame_time_milliseconds +%= 16;
    fullscreen_reached = top_fullscreen == null;
    nodes = self.scene.nodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (!window_entry.window.mapped) continue;
            if (top_fullscreen) |id| {
                if (!std.meta.eql(window_entry.id, id)) continue;
                fullscreen_reached = true;
            }
            self.finishWindowDecorations(window_entry.id, .below);
            self.finishSurfaceTree(window_entry.window.surface_id);
            self.finishWindowDecorations(window_entry.id, .above);
            self.finishWindowPopups(window_entry.id);
        },
        .shell_surface => |shell_entry| {
            if (!fullscreen_reached or !shell_entry.shell_surface.mapped) continue;
            self.finishSurfaceTree(shell_entry.shell_surface.surface_id);
        },
    };
    if (cursor) |info| self.finishSurfaceTree(info.surface_id);
    const keyboard_focus = self.xdg_shell.popupKeyboardFocus() orelse
        self.scene.focusedSurface() orelse if (!self.window_manager.hasActiveManager())
        self.scene.topWindowSurface()
    else
        null;
    self.seat.setKeyboardFocus(keyboard_focus);
}

fn renderCommands(
    self: *Self,
    output_size: render.Size,
    commands: []const render.Command,
    target: renderer_types.Target,
) renderer_types.Renderer.Error!void {
    try self.renderer.render(.{
        .size = output_size,
        .commands = commands,
        .scale = self.render_output.renderScale(),
    }, target);
}

fn renderWindow(
    self: *Self,
    id: Scene.Id,
    window: *const Scene.Window,
    output_size: render.Size,
    target: renderer_types.Target,
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
        try self.renderCommands(output_size, &shadow_command, target);
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
        try self.renderCommands(output_size, &blur_command, target);
    }
    try self.renderWindowDecorations(id, window, .below, window_clip, target);
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
            window.surface_id,
            window.position.x -| content_geometry.offset.x,
            window.position.y -| content_geometry.offset.y,
            rounded_clip,
            content_clip,
            target,
        );
    }
    try self.renderWindowBorders(window, content_rect, window_clip, target);
    try self.renderWindowDecorations(id, window, .above, window_clip, target);
    try self.renderWindowPopups(id, target);
}

fn renderWindowPopups(
    self: *Self,
    window_id: Scene.Id,
    target: renderer_types.Target,
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
            popup.surface_id,
            entry.position.x -| content_geometry.offset.x,
            entry.position.y -| content_geometry.offset.y,
            null,
            null,
            target,
        );
    }
}

fn renderSurfaceTree(
    self: *Self,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
    target: renderer_types.Target,
) renderer_types.Renderer.Error!void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;

    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const buffer = Surface.currentBuffer(
                self.compositor.surfaceStore(),
                surface_id,
            ) orelse continue;
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
            try self.renderCommands(self.render_output.size(), &image_command, target);
        },
        .child => |child| try self.renderSurfaceTree(
            child.surface_id,
            x +| child.position.x,
            y +| child.position.y,
            rounded_clip,
            clip,
            target,
        ),
    };
}

fn renderWindowBorders(
    self: *Self,
    window: *const Scene.Window,
    content_rect: render.Rect,
    clip: ?render.Rect,
    target: renderer_types.Target,
) renderer_types.Renderer.Error!void {
    const borders = window.borders orelse return;
    var commands: [4]render.Command = undefined;
    const border_commands = makeBorderCommands(
        content_rect,
        borders,
        clip,
        &commands,
    );
    try self.renderCommands(self.render_output.size(), border_commands, target);
}

fn renderWindowDecorations(
    self: *Self,
    window_id: Scene.Id,
    window: *const Scene.Window,
    layer: Scene.DecorationLayer,
    clip: ?render.Rect,
    target: renderer_types.Target,
) renderer_types.Renderer.Error!void {
    var decorations = self.scene.decorationIterator(window_id, layer);
    while (decorations.next()) |entry| {
        if (!entry.decoration.mapped) continue;
        try self.renderSurfaceTree(
            entry.decoration.surface_id,
            window.position.x +| entry.decoration.offset.x,
            window.position.y +| entry.decoration.offset.y,
            null,
            clip,
            target,
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

fn finishSurfaceTree(self: *Self, surface_id: Surface.Id) void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;

    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => Surface.sendFrameDoneFor(
            self.compositor.surfaceStore(),
            surface_id,
            self.frame_time_milliseconds,
        ),
        .child => |child| self.finishSurfaceTree(child.surface_id),
    };
}

fn finishWindowDecorations(
    self: *Self,
    window_id: Scene.Id,
    layer: Scene.DecorationLayer,
) void {
    var decorations = self.scene.decorationIterator(window_id, layer);
    while (decorations.next()) |entry| {
        if (!entry.decoration.mapped) continue;
        self.finishSurfaceTree(entry.decoration.surface_id);
    }
}

fn finishWindowPopups(self: *Self, window_id: Scene.Id) void {
    var popups = self.scene.popupIterator(window_id);
    while (popups.next()) |entry| {
        if (!entry.popup.mapped) continue;
        self.finishSurfaceTree(entry.popup.surface_id);
    }
}

test "server creates and destroys protocol globals" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless);
    server.destroy();
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
