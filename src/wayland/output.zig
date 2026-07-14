//! wl_output advertisement for a compositor output.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
size: render.Size,
physical_size: render.Size,
scale: i32,
resources: std.ArrayList(*wl.Output),
surfaces: *Surface.Store,

pub const Error = error{
    InvalidDimensions,
    GlobalCreateFailed,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    size: render.Size,
    physical_size: render.Size,
    scale: u32,
    surfaces: *Surface.Store,
) Error!void {
    if (size.width == 0 or size.height == 0 or
        size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32) or
        scale == 0 or scale > std.math.maxInt(i32) or
        physical_size.width == 0 or physical_size.height == 0 or
        physical_size.width > std.math.maxInt(i32) or
        physical_size.height > std.math.maxInt(i32))
    {
        return error.InvalidDimensions;
    }
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wl.Output, 4, *Self, self, bind),
        .size = size,
        .physical_size = physical_size,
        .scale = @intCast(scale),
        .resources = .empty,
        .surfaces = surfaces,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.resources.items.len == 0);
    self.global.destroy();
    self.resources.deinit(self.allocator);
    self.* = undefined;
}

pub fn globalName(self: *const Self, client: *const wl.Client) u32 {
    return self.global.getName(client);
}

pub fn logicalSize(self: *const Self) render.Size {
    return self.size;
}

pub fn ownsResource(self: *Self, resource: *wl.Output) bool {
    return resource.getUserData() == @as(?*anyopaque, @ptrCast(self));
}

pub fn configureSurface(self: *Self, surface: *wl.Surface) void {
    for (self.resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) {
            surface.sendEnter(resource);
        }
    }
    if (surface.getVersion() >= wl.Surface.preferred_buffer_scale_since_version) {
        surface.sendPreferredBufferScale(self.scale);
        surface.sendPreferredBufferTransform(.normal);
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Output.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    self.resources.append(self.allocator, resource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*Self, handleRequest, handleDestroy, self);
    resource.sendGeometry(0, 0, 0, 0, .unknown, "keywork", "headless", .normal);
    resource.sendMode(
        .{ .current = true, .preferred = true },
        @intCast(self.physical_size.width),
        @intCast(self.physical_size.height),
        60_000,
    );
    if (version >= wl.Output.scale_since_version) resource.sendScale(self.scale);
    if (version >= wl.Output.name_since_version) {
        resource.sendName("HEADLESS-1");
        resource.sendDescription("Keywork virtual output");
    }
    if (version >= wl.Output.done_since_version) resource.sendDone();
    var surfaces = self.surfaces.iterator();
    while (surfaces.next()) |entry| {
        if (entry.value.resource.getClient() == client) {
            entry.value.resource.sendEnter(resource);
        }
    }
}

fn handleRequest(resource: *wl.Output, request: wl.Output.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleDestroy(resource: *wl.Output, self: *Self) void {
    for (self.resources.items, 0..) |candidate, index| {
        if (candidate != resource) continue;
        _ = self.resources.orderedRemove(index);
        return;
    }
    unreachable;
}
