//! wl_output advertisement for a compositor output.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("render.zig");

const wl = wayland.server.wl;

global: *wl.Global,
size: render.Size,

pub const Error = error{
    InvalidDimensions,
    GlobalCreateFailed,
};

pub fn init(self: *Self, display: *wl.Server, size: render.Size) Error!void {
    if (size.width == 0 or size.height == 0 or
        size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32))
    {
        return error.InvalidDimensions;
    }
    self.* = .{
        .global = try wl.Global.create(display, wl.Output, 4, *Self, self, bind),
        .size = size,
    };
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
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

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Output.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
    resource.sendGeometry(0, 0, 0, 0, .unknown, "keywork", "headless", .normal);
    resource.sendMode(
        .{ .current = true, .preferred = true },
        @intCast(self.size.width),
        @intCast(self.size.height),
        60_000,
    );
    if (version >= wl.Output.scale_since_version) resource.sendScale(1);
    if (version >= wl.Output.name_since_version) {
        resource.sendName("HEADLESS-1");
        resource.sendDescription("Keywork virtual output");
    }
    if (version >= wl.Output.done_since_version) resource.sendDone();
}

fn handleRequest(resource: *wl.Output, request: wl.Output.Request, _: *Self) void {
    switch (request) {
        .release => resource.destroy(),
    }
}
