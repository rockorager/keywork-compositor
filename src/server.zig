//! Wayland display and compositor-global lifetime.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Compositor = @import("compositor.zig");
const Subcompositor = @import("subcompositor.zig");
const XdgShell = @import("xdg_shell.zig");
const Seat = @import("seat.zig");
const DataDevice = @import("data_device.zig");
const HeadlessOutput = @import("headless.zig");
const Output = @import("output.zig");
const CpuRenderer = @import("cpu_renderer.zig");
const renderer_types = @import("renderer.zig");
const render = @import("render.zig");
const Scene = @import("scene.zig");
const Surface = @import("surface.zig");
const WindowManager = @import("window_manager.zig");

const wl = wayland.server.wl;
const log = std.log.scoped(.server);

allocator: std.mem.Allocator,
display: *wl.Server,
headless_output: HeadlessOutput,
output: Output,
compositor: Compositor,
subcompositor: Subcompositor,
scene: Scene,
xdg_shell: XdgShell,
seat: Seat,
data_device: DataDevice,
window_manager: WindowManager,
renderer: renderer_types.Renderer,
render_timer: *wl.EventSource,
repaint_pending: bool,
frame_time_milliseconds: u32,
socket_buffer: [11]u8,
listening: bool,

pub fn create(allocator: std.mem.Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const display = try wl.Server.create();
    errdefer display.destroy();
    try display.initShm();

    self.* = .{
        .allocator = allocator,
        .display = display,
        .headless_output = undefined,
        .output = undefined,
        .compositor = undefined,
        .subcompositor = undefined,
        .scene = undefined,
        .xdg_shell = undefined,
        .seat = undefined,
        .data_device = undefined,
        .window_manager = undefined,
        .renderer = .{ .cpu = CpuRenderer.init(allocator) },
        .render_timer = undefined,
        .repaint_pending = false,
        .frame_time_milliseconds = 0,
        .socket_buffer = undefined,
        .listening = false,
    };
    errdefer self.renderer.deinit();
    self.headless_output = try HeadlessOutput.init(allocator, .{ .width = 1280, .height = 720 });
    errdefer self.headless_output.deinit();
    try self.output.init(display, self.headless_output.size);
    errdefer self.output.deinit();
    try self.compositor.init(allocator, display);
    errdefer self.compositor.deinit();
    try self.subcompositor.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.subcompositor.deinit();
    self.scene.init(allocator);
    errdefer self.scene.deinit();
    try self.xdg_shell.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        &self.scene,
    );
    errdefer self.xdg_shell.deinit();
    try self.seat.init(display);
    errdefer self.seat.deinit();
    try self.data_device.init(allocator, display, &self.seat);
    errdefer self.data_device.deinit();
    try self.window_manager.init(allocator, display, &self.output, &self.seat, &self.xdg_shell);
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

    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    self.scene.clearRepaintListener();
    self.subcompositor.clearRepaintListener();
    self.render_timer.remove();
    self.display.destroyClients();
    self.window_manager.deinit();
    self.data_device.deinit();
    self.seat.deinit();
    self.xdg_shell.deinit();
    self.scene.deinit();
    self.subcompositor.deinit();
    self.compositor.deinit();
    self.output.deinit();
    self.headless_output.deinit();
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

fn handleRenderTimer(self: *Self) c_int {
    self.repaint_pending = false;
    self.renderFrame() catch |err| {
        log.err("headless frame failed: {t}", .{err});
        self.terminate();
    };
    return 0;
}

fn renderFrame(self: *Self) renderer_types.Renderer.Error!void {
    const output_size = self.headless_output.size;
    const target: renderer_types.Target = .{ .cpu = self.headless_output.target() };
    const clear_command = [_]render.Command{
        .{ .clear = render.Color.rgba(24, 24, 27, 255) },
    };
    try self.renderer.render(
        .{ .size = output_size, .commands = &clear_command },
        target,
    );

    var windows = self.scene.iterator();
    while (windows.next()) |entry| {
        if (!entry.window.mapped) continue;
        if (entry.window.effects.shadow) |shadow| {
            const buffer = Surface.currentBuffer(
                self.compositor.surfaceStore(),
                entry.window.surface_id,
            );
            if (buffer) |root_buffer| {
                const shadow_command = [_]render.Command{
                    .{ .shadow = .{
                        .rect = .{
                            .x = entry.window.position.x +| shadow.offset.x,
                            .y = entry.window.position.y +| shadow.offset.y,
                            .width = root_buffer.logical_size.width,
                            .height = root_buffer.logical_size.height,
                        },
                        .corner_radius = entry.window.effects.corner_radius,
                        .blur_radius = shadow.blur_radius,
                        .spread = shadow.spread,
                        .color = shadow.color,
                    } },
                };
                try self.renderer.render(
                    .{ .size = output_size, .commands = &shadow_command },
                    target,
                );
            }
        }
        if (entry.window.effects.blur) |blur| {
            const buffer = Surface.currentBuffer(
                self.compositor.surfaceStore(),
                entry.window.surface_id,
            );
            if (buffer) |root_buffer| {
                const blur_command = [_]render.Command{
                    .{ .backdrop_blur = .{
                        .rect = .{
                            .x = entry.window.position.x,
                            .y = entry.window.position.y,
                            .width = root_buffer.logical_size.width,
                            .height = root_buffer.logical_size.height,
                        },
                        .corner_radius = entry.window.effects.corner_radius,
                        .radius = blur.radius,
                    } },
                };
                try self.renderer.render(
                    .{ .size = output_size, .commands = &blur_command },
                    target,
                );
            }
        }
        try self.renderSurfaceTree(
            entry.window.surface_id,
            entry.window.position.x,
            entry.window.position.y,
            entry.window.effects.corner_radius,
            target,
        );
        try self.renderWindowBorders(entry.window, target);
    }

    self.frame_time_milliseconds +%= 16;
    windows = self.scene.iterator();
    while (windows.next()) |entry| {
        if (!entry.window.mapped) continue;
        self.finishSurfaceTree(entry.window.surface_id);
    }
}

fn renderSurfaceTree(
    self: *Self,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    corner_radius: u32,
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
                    .corner_radius = corner_radius,
                } },
            };
            try self.renderer.render(
                .{ .size = self.headless_output.size, .commands = &image_command },
                target,
            );
        },
        .child => |child| try self.renderSurfaceTree(
            child.surface_id,
            x +| child.position.x,
            y +| child.position.y,
            0,
            target,
        ),
    };
}

fn renderWindowBorders(
    self: *Self,
    window: *const Scene.Window,
    target: renderer_types.Target,
) renderer_types.Renderer.Error!void {
    const borders = window.borders orelse return;
    const buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) orelse return;
    var commands: [4]render.Command = undefined;
    const border_commands = makeBorderCommands(
        window.position,
        buffer.logical_size,
        borders,
        &commands,
    );
    try self.renderer.render(
        .{ .size = self.headless_output.size, .commands = border_commands },
        target,
    );
}

fn makeBorderCommands(
    position: Scene.Position,
    content_size: render.Size,
    borders: Scene.Borders,
    commands: *[4]render.Command,
) []const render.Command {
    const width = borders.width;
    const width_i32: i32 = @intCast(width);
    const content_width_i32: i32 = @intCast(@min(
        content_size.width,
        std.math.maxInt(i32),
    ));
    const content_height_i32: i32 = @intCast(@min(
        content_size.height,
        std.math.maxInt(i32),
    ));
    const vertical_y = if (borders.edges.top)
        position.y -| width_i32
    else
        position.y;
    var vertical_height = content_size.height;
    if (borders.edges.top) vertical_height +|= width;
    if (borders.edges.bottom) vertical_height +|= width;

    var command_count: usize = 0;
    if (borders.edges.top) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = position.x,
                .y = position.y -| width_i32,
                .width = content_size.width,
                .height = width,
            },
            .color = borders.color,
        } };
        command_count += 1;
    }
    if (borders.edges.bottom) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = position.x,
                .y = position.y +| content_height_i32,
                .width = content_size.width,
                .height = width,
            },
            .color = borders.color,
        } };
        command_count += 1;
    }
    if (borders.edges.left) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = position.x -| width_i32,
                .y = vertical_y,
                .width = width,
                .height = vertical_height,
            },
            .color = borders.color,
        } };
        command_count += 1;
    }
    if (borders.edges.right) {
        commands[command_count] = .{ .solid_rect = .{
            .rect = .{
                .x = position.x +| content_width_i32,
                .y = vertical_y,
                .width = width,
                .height = vertical_height,
            },
            .color = borders.color,
        } };
        command_count += 1;
    }
    std.debug.assert(command_count > 0);
    return commands[0..command_count];
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

test "server creates and destroys protocol globals" {
    const server = try Self.create(std.testing.allocator);
    server.destroy();
}

test "window borders occupy only requested exterior edges and corners" {
    var commands: [4]render.Command = undefined;
    const color = render.Color.rgba(0x80, 0x40, 0x20, 0xff);
    const result = makeBorderCommands(
        .{ .x = 10, .y = 20 },
        .{ .width = 100, .height = 50 },
        .{
            .edges = .{ .top = true, .left = true, .right = true },
            .width = 4,
            .color = color,
        },
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
}
