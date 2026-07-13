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
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const log = std.log.scoped(.server);

allocator: std.mem.Allocator,
display: *wl.Server,
headless_output: HeadlessOutput,
output: Output,
compositor: Compositor,
subcompositor: Subcompositor,
xdg_shell: XdgShell,
seat: Seat,
data_device: DataDevice,
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
        .xdg_shell = undefined,
        .seat = undefined,
        .data_device = undefined,
        .renderer = .{ .cpu = CpuRenderer.init() },
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
    try self.xdg_shell.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.xdg_shell.deinit();
    try self.seat.init(display);
    errdefer self.seat.deinit();
    try self.data_device.init(allocator, display, &self.seat);
    errdefer self.data_device.deinit();
    self.render_timer = try display.getEventLoop().addTimer(*Self, handleRenderTimer, self);
    self.xdg_shell.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
    });

    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    self.xdg_shell.clearRepaintListener();
    self.render_timer.remove();
    self.display.destroyClients();
    self.data_device.deinit();
    self.seat.deinit();
    self.xdg_shell.deinit();
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

    var windows = self.xdg_shell.windowIterator();
    while (windows.next()) |entry| {
        if (!entry.value.mapped) continue;
        const surface_id = self.xdg_shell.surfaceForWindow(entry.id) orelse continue;
        const buffer = Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) orelse
            continue;
        if (buffer.transform != .normal) continue;

        const image_command = [_]render.Command{
            .{ .image = .{
                .x = 0,
                .y = 0,
                .size = buffer.logical_size,
                .buffer = buffer.pixelBuffer(),
            } },
        };
        try self.renderer.render(
            .{ .size = output_size, .commands = &image_command },
            target,
        );
    }

    self.frame_time_milliseconds +%= 16;
    windows = self.xdg_shell.windowIterator();
    while (windows.next()) |entry| {
        if (!entry.value.mapped) continue;
        const surface_id = self.xdg_shell.surfaceForWindow(entry.id) orelse continue;
        Surface.sendFrameDoneFor(
            self.compositor.surfaceStore(),
            surface_id,
            self.frame_time_milliseconds,
        );
    }
}

test "server creates and destroys protocol globals" {
    const server = try Self.create(std.testing.allocator);
    server.destroy();
}
