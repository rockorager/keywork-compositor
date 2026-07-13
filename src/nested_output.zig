//! Output presented as a window on a parent Wayland compositor.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("render.zig");

const client = wayland.client;
const wl = client.wl;
const xdg = client.xdg;
const server_wl = wayland.server.wl;

const buffer_count = 3;

display: ?*wl.Display,
registry: ?*wl.Registry,
compositor: ?*wl.Compositor,
shm: ?*wl.Shm,
wm_base: ?*xdg.WmBase,
surface: ?*wl.Surface,
xdg_surface: ?*xdg.Surface,
toplevel: ?*xdg.Toplevel,
event_source: ?*server_wl.EventSource,
mapping: ?[]align(std.heap.page_size_min) u8,
buffers: [buffer_count]Buffer,
size: render.Size,
listener: Listener,
acquired: ?usize,
waiting_for_buffer: bool,
configured: bool,
failed: bool,

pub const Listener = struct {
    context: *anyopaque,
    repaint: *const fn (*anyopaque) void,
    close: *const fn (*anyopaque) void,
};

const Buffer = struct {
    owner: *Self,
    resource: ?*wl.Buffer,
    pixels: []u32,
    busy: bool,

    fn handleEvent(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => {
                std.debug.assert(self.busy);
                self.busy = false;
                if (self.owner.waiting_for_buffer) {
                    self.owner.waiting_for_buffer = false;
                    self.owner.listener.repaint(self.owner.listener.context);
                }
            },
        }
    }
};

pub fn init(
    self: *Self,
    io: std.Io,
    child_display: *server_wl.Server,
    size: render.Size,
    listener: Listener,
) !void {
    if (size.width == 0 or size.height == 0 or
        size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32))
    {
        return error.InvalidDimensions;
    }

    self.* = .{
        .display = null,
        .registry = null,
        .compositor = null,
        .shm = null,
        .wm_base = null,
        .surface = null,
        .xdg_surface = null,
        .toplevel = null,
        .event_source = null,
        .mapping = null,
        .buffers = undefined,
        .size = size,
        .listener = listener,
        .acquired = null,
        .waiting_for_buffer = false,
        .configured = false,
        .failed = false,
    };
    for (&self.buffers) |*buffer| {
        buffer.* = .{
            .owner = self,
            .resource = null,
            .pixels = &.{},
            .busy = false,
        };
    }
    errdefer self.deinit();

    const display = try wl.Display.connect(null);
    self.display = display;
    const registry = try display.getRegistry();
    self.registry = registry;
    registry.setListener(*Self, handleRegistryEvent, self);
    if (display.roundtrip() != .SUCCESS) return error.ParentDisplayFailed;
    if (self.compositor == null or self.shm == null or self.wm_base == null) {
        return error.MissingParentGlobal;
    }

    const surface = try self.compositor.?.createSurface();
    self.surface = surface;
    const xdg_surface = try self.wm_base.?.getXdgSurface(surface);
    self.xdg_surface = xdg_surface;
    xdg_surface.setListener(*Self, handleXdgSurfaceEvent, self);
    const toplevel = try xdg_surface.getToplevel();
    self.toplevel = toplevel;
    toplevel.setListener(*Self, handleToplevelEvent, self);
    toplevel.setTitle("Keywork Compositor");
    toplevel.setMinSize(@intCast(size.width), @intCast(size.height));
    toplevel.setMaxSize(@intCast(size.width), @intCast(size.height));

    try self.createBuffers(io);
    surface.commit();
    while (!self.configured) {
        if (display.dispatch() != .SUCCESS) return error.ParentDisplayFailed;
    }

    self.registry.?.destroy();
    self.registry = null;
    self.event_source = try child_display.getEventLoop().addFd(
        *Self,
        display.getFd(),
        .{ .readable = true },
        handleParentFd,
        self,
    );
}

pub fn deinit(self: *Self) void {
    if (self.event_source) |source| source.remove();
    for (&self.buffers) |*buffer| {
        if (buffer.resource) |resource| resource.destroy();
    }
    if (self.toplevel) |toplevel| toplevel.destroy();
    if (self.xdg_surface) |xdg_surface| xdg_surface.destroy();
    if (self.surface) |surface| surface.destroy();
    if (self.wm_base) |wm_base| wm_base.destroy();
    if (self.shm) |shm| shm.destroy();
    if (self.compositor) |compositor| compositor.destroy();
    if (self.registry) |registry| registry.destroy();
    if (self.display) |display| display.disconnect();
    if (self.mapping) |mapping| std.posix.munmap(mapping);
    self.* = undefined;
}

pub fn acquire(self: *Self) ?render.PixelBuffer {
    std.debug.assert(self.acquired == null);
    if (!self.configured or self.failed) return null;
    for (&self.buffers, 0..) |*buffer, index| {
        if (buffer.busy) continue;
        self.acquired = index;
        return .{
            .size = self.size,
            .stride_pixels = self.size.width,
            .pixels = buffer.pixels,
        };
    }
    self.waiting_for_buffer = true;
    return null;
}

pub fn cancel(self: *Self) void {
    self.acquired = null;
}

pub fn present(self: *Self) !void {
    const index = self.acquired orelse return error.NoAcquiredBuffer;
    const buffer = &self.buffers[index];
    const resource = buffer.resource orelse return error.ParentDisplayFailed;
    buffer.busy = true;
    self.acquired = null;

    const surface = self.surface orelse return error.ParentDisplayFailed;
    surface.attach(resource, 0, 0);
    surface.damageBuffer(0, 0, @intCast(self.size.width), @intCast(self.size.height));
    surface.commit();
    switch (self.display.?.flush()) {
        .SUCCESS => {},
        .AGAIN => try self.event_source.?.fdUpdate(.{ .readable = true, .writable = true }),
        else => return error.ParentDisplayFailed,
    }
}

fn createBuffers(self: *Self, io: std.Io) !void {
    const pixel_count = try self.size.pixelCount();
    const buffer_bytes = std.math.mul(usize, pixel_count, @sizeOf(u32)) catch
        return error.Overflow;
    const mapping_bytes = std.math.mul(usize, buffer_bytes, buffer_count) catch
        return error.Overflow;
    if (mapping_bytes > std.math.maxInt(i32)) return error.Overflow;

    const fd = try std.posix.memfd_create("keywork-nested-output", 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    try file.setLength(io, mapping_bytes);
    const mapping = try std.posix.mmap(
        null,
        mapping_bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    self.mapping = mapping;
    @memset(mapping, 0);

    const pool = try self.shm.?.createPool(fd, @intCast(mapping_bytes));
    defer pool.destroy();
    for (&self.buffers, 0..) |*buffer, index| {
        const offset = index * buffer_bytes;
        const resource = try pool.createBuffer(
            @intCast(offset),
            @intCast(self.size.width),
            @intCast(self.size.height),
            @intCast(self.size.width * @sizeOf(u32)),
            .argb8888,
        );
        buffer.resource = resource;
        buffer.pixels = @as([*]u32, @ptrCast(@alignCast(mapping.ptr + offset)))[0..pixel_count];
        resource.setListener(*Buffer, Buffer.handleEvent, buffer);
    }
}

fn handleRegistryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Self) void {
    switch (event) {
        .global => |global| {
            const interface = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface, std.mem.span(wl.Compositor.interface.name))) {
                if (self.compositor == null) {
                    self.compositor = self.registry.?.bind(global.name, wl.Compositor, global.version) catch {
                        self.failed = true;
                        return;
                    };
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(wl.Shm.interface.name))) {
                if (self.shm == null) {
                    self.shm = self.registry.?.bind(global.name, wl.Shm, global.version) catch {
                        self.failed = true;
                        return;
                    };
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(xdg.WmBase.interface.name))) {
                if (self.wm_base == null) {
                    const wm_base = self.registry.?.bind(global.name, xdg.WmBase, global.version) catch {
                        self.failed = true;
                        return;
                    };
                    self.wm_base = wm_base;
                    wm_base.setListener(*Self, handleWmBaseEvent, self);
                }
            }
        },
        .global_remove => {},
    }
}

fn handleWmBaseEvent(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Self) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn handleXdgSurfaceEvent(
    xdg_surface: *xdg.Surface,
    event: xdg.Surface.Event,
    self: *Self,
) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            self.configured = true;
        },
    }
}

fn handleToplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Self) void {
    switch (event) {
        .configure, .configure_bounds, .wm_capabilities => {},
        .close => self.fail(),
    }
}

fn handleParentFd(_: c_int, mask: server_wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail();
        return 0;
    }
    const display = self.display orelse return 0;
    if (mask.writable) switch (display.flush()) {
        .SUCCESS => self.event_source.?.fdUpdate(.{ .readable = true }) catch self.fail(),
        .AGAIN => {},
        else => self.fail(),
    };
    if (mask.readable and display.dispatch() != .SUCCESS) self.fail();
    return 0;
}

fn fail(self: *Self) void {
    if (self.failed) return;
    self.failed = true;
    self.listener.close(self.listener.context);
}
