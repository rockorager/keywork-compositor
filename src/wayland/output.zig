//! wl_output advertisement for a compositor output.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
position: Position,
size: render.Size,
physical_size: render.Size,
scale: i32,
refresh_millihertz: i32,
name_value: [:0]u8,
description_value: [:0]u8,
make: [:0]u8,
model: [:0]u8,
resources: std.ArrayList(*wl.Output),
surfaces: *Surface.Store,
memberships: std.ArrayList(Membership),
frame_active: bool,

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Config = struct {
    position: Position = .{},
    size: render.Size,
    physical_size: render.Size,
    scale: u32,
    name: []const u8,
    description: []const u8,
    make: []const u8 = "keywork",
    model: []const u8,
};

const Membership = struct {
    surface_id: Surface.Id,
    visible: bool,
};

pub const Error = error{
    OutOfMemory,
    InvalidDimensions,
    GlobalCreateFailed,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    config: Config,
    surfaces: *Surface.Store,
) Error!void {
    if (config.size.width == 0 or config.size.height == 0 or
        config.size.width > std.math.maxInt(i32) or config.size.height > std.math.maxInt(i32) or
        config.scale == 0 or config.scale > std.math.maxInt(i32) or
        config.physical_size.width == 0 or config.physical_size.height == 0 or
        config.physical_size.width > std.math.maxInt(i32) or
        config.physical_size.height > std.math.maxInt(i32))
    {
        return error.InvalidDimensions;
    }

    const name_value = try allocator.dupeSentinel(u8, config.name, 0);
    errdefer allocator.free(name_value);
    const description_value = try allocator.dupeSentinel(u8, config.description, 0);
    errdefer allocator.free(description_value);
    const make = try allocator.dupeSentinel(u8, config.make, 0);
    errdefer allocator.free(make);
    const model = try allocator.dupeSentinel(u8, config.model, 0);
    errdefer allocator.free(model);

    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wl.Output, 4, *Self, self, bind),
        .position = config.position,
        .size = config.size,
        .physical_size = config.physical_size,
        .scale = @intCast(config.scale),
        .refresh_millihertz = 60_000,
        .name_value = name_value,
        .description_value = description_value,
        .make = make,
        .model = model,
        .resources = .empty,
        .surfaces = surfaces,
        .memberships = .empty,
        .frame_active = false,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.resources.items.len == 0);
    std.debug.assert(!self.frame_active);
    self.global.destroy();
    self.resources.deinit(self.allocator);
    self.memberships.deinit(self.allocator);
    self.allocator.free(self.model);
    self.allocator.free(self.make);
    self.allocator.free(self.description_value);
    self.allocator.free(self.name_value);
    self.* = undefined;
}

pub fn globalName(self: *const Self, client: *const wl.Client) u32 {
    return self.global.getName(client);
}

pub fn logicalSize(self: *const Self) render.Size {
    return self.size;
}

pub fn logicalPosition(self: *const Self) Position {
    return self.position;
}

pub fn logicalRect(self: *const Self) render.Rect {
    return .{
        .x = self.position.x,
        .y = self.position.y,
        .width = self.size.width,
        .height = self.size.height,
    };
}

pub fn name(self: *const Self) [:0]const u8 {
    return self.name_value;
}

pub fn description(self: *const Self) [:0]const u8 {
    return self.description_value;
}

pub fn ownsResource(self: *Self, resource: *wl.Output) bool {
    return resource.getUserData() == @as(?*anyopaque, @ptrCast(self));
}

pub fn boundResources(self: *const Self) []const *wl.Output {
    return self.resources.items;
}

pub fn setRefresh(self: *Self, info: presentation.Info) void {
    const refresh_millihertz: i32 = @intCast(@min(
        info.refreshMillihertz(),
        std.math.maxInt(i32),
    ));
    if (self.refresh_millihertz == refresh_millihertz) return;
    self.refresh_millihertz = refresh_millihertz;
    for (self.resources.items) |resource| {
        self.sendMode(resource);
        if (resource.getVersion() >= wl.Output.done_since_version) resource.sendDone();
    }
}

pub fn beginFrame(self: *Self) void {
    std.debug.assert(!self.frame_active);
    for (self.memberships.items) |*membership| membership.visible = false;
    self.frame_active = true;
}

pub fn markSurfaceVisible(self: *Self, surface_id: Surface.Id) error{OutOfMemory}!void {
    std.debug.assert(self.frame_active);
    for (self.memberships.items) |*membership| {
        if (!std.meta.eql(membership.surface_id, surface_id)) continue;
        membership.visible = true;
        return;
    }

    const surface = Surface.resourceFor(self.surfaces, surface_id) orelse return;
    try self.memberships.append(self.allocator, .{
        .surface_id = surface_id,
        .visible = true,
    });
    for (self.resources.items) |resource| {
        if (resource.getClient() == surface.getClient()) surface.sendEnter(resource);
    }
    if (surface.getVersion() >= wl.Surface.preferred_buffer_scale_since_version) {
        surface.sendPreferredBufferScale(self.scale);
        surface.sendPreferredBufferTransform(.normal);
    }
}

pub fn endFrame(self: *Self) void {
    std.debug.assert(self.frame_active);
    var index = self.memberships.items.len;
    while (index > 0) {
        index -= 1;
        const membership = self.memberships.items[index];
        if (membership.visible) continue;
        if (Surface.resourceFor(self.surfaces, membership.surface_id)) |surface| {
            for (self.resources.items) |resource| {
                if (resource.getClient() == surface.getClient()) surface.sendLeave(resource);
            }
        }
        _ = self.memberships.orderedRemove(index);
    }
    self.frame_active = false;
}

pub fn cancelFrame(self: *Self) void {
    std.debug.assert(self.frame_active);
    for (self.memberships.items) |*membership| membership.visible = true;
    self.frame_active = false;
}

pub fn containsSurface(self: *const Self, surface_id: Surface.Id) bool {
    for (self.memberships.items) |membership| {
        if (std.meta.eql(membership.surface_id, surface_id)) return true;
    }
    return false;
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
    resource.sendGeometry(
        self.position.x,
        self.position.y,
        0,
        0,
        .unknown,
        self.make,
        self.model,
        .normal,
    );
    self.sendMode(resource);
    if (version >= wl.Output.scale_since_version) resource.sendScale(self.scale);
    if (version >= wl.Output.name_since_version) {
        resource.sendName(self.name_value);
        resource.sendDescription(self.description_value);
    }
    if (version >= wl.Output.done_since_version) resource.sendDone();
    for (self.memberships.items) |membership| {
        const surface = Surface.resourceFor(self.surfaces, membership.surface_id) orelse continue;
        if (surface.getClient() == client) surface.sendEnter(resource);
    }
}

fn sendMode(self: *const Self, resource: *wl.Output) void {
    resource.sendMode(
        .{ .current = true, .preferred = true },
        @intCast(self.physical_size.width),
        @intCast(self.physical_size.height),
        self.refresh_millihertz,
    );
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

test "frame membership removes surfaces which are no longer visible" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);

    var output: Self = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 1280, .height = 720 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surfaces,
    );
    defer output.deinit();

    try output.memberships.append(std.testing.allocator, .{
        .surface_id = .{ .index = 0, .generation = 1 },
        .visible = true,
    });
    output.beginFrame();
    output.endFrame();
    try std.testing.expectEqual(@as(usize, 0), output.memberships.items.len);
}

test "cancelled frame preserves existing membership" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);

    var output: Self = undefined;
    try output.init(
        std.testing.allocator,
        display,
        .{
            .size = .{ .width = 1280, .height = 720 },
            .physical_size = .{ .width = 1280, .height = 720 },
            .scale = 1,
            .name = "HEADLESS-1",
            .description = "Keywork headless output",
            .model = "headless",
        },
        &surfaces,
    );
    defer output.deinit();

    try output.memberships.append(std.testing.allocator, .{
        .surface_id = .{ .index = 0, .generation = 1 },
        .visible = true,
    });
    output.beginFrame();
    output.cancelFrame();
    try std.testing.expectEqual(@as(usize, 1), output.memberships.items.len);
    try std.testing.expect(output.memberships.items[0].visible);
}
