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

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
display: *wl.Server,
headless_output: HeadlessOutput,
output: Output,
compositor: Compositor,
subcompositor: Subcompositor,
xdg_shell: XdgShell,
seat: Seat,
data_device: DataDevice,
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
        .socket_buffer = undefined,
        .listening = false,
    };
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

    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    self.display.destroyClients();
    self.data_device.deinit();
    self.seat.deinit();
    self.xdg_shell.deinit();
    self.subcompositor.deinit();
    self.compositor.deinit();
    self.output.deinit();
    self.headless_output.deinit();
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

test "server creates and destroys protocol globals" {
    const server = try Self.create(std.testing.allocator);
    server.destroy();
}
