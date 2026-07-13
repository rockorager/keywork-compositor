//! Preferred fractional scale protocol for client surfaces.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("render.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

allocator: std.mem.Allocator,
global: *wl.Global,
preferred_scale: render.Scale,
by_surface: std.AutoHashMapUnmanaged(Surface.Id, *FractionalScale),
resource_count: usize,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    preferred_scale: render.Scale,
) !void {
    if (preferred_scale.numerator == 0) return error.InvalidScale;
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            wp.FractionalScaleManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .preferred_scale = preferred_scale,
        .by_surface = .empty,
        .resource_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.resource_count == 0);
    std.debug.assert(self.by_surface.count() == 0);
    self.global.destroy();
    self.by_surface.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.FractionalScaleManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wp.FractionalScaleManagerV1,
    request: wp.FractionalScaleManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_fractional_scale => |get| self.createFractionalScale(
            resource,
            get.id,
            Surface.fromResource(get.surface),
        ),
    }
}

fn createFractionalScale(
    self: *Self,
    manager: *wp.FractionalScaleManagerV1,
    id: u32,
    surface: *Surface,
) void {
    const surface_id = surface.handle();
    if (self.by_surface.contains(surface_id)) {
        manager.postError(
            .fractional_scale_exists,
            "wl_surface already has a fractional scale object",
        );
        return;
    }
    const resource = wp.FractionalScaleV1.create(
        manager.getClient(),
        manager.getVersion(),
        id,
    ) catch {
        manager.postNoMemory();
        return;
    };
    const fractional_scale = self.allocator.create(FractionalScale) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    fractional_scale.* = .{
        .manager = self,
        .surface = surface,
        .surface_id = surface_id,
        .listener = undefined,
    };
    fractional_scale.listener = .{
        .context = fractional_scale,
        .applied = handleSurfaceApplied,
        .surface_destroyed = handleSurfaceDestroyed,
    };
    self.by_surface.put(self.allocator, surface_id, fractional_scale) catch {
        self.allocator.destroy(fractional_scale);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    surface.addCommitListener(&fractional_scale.listener) catch {
        _ = self.by_surface.remove(surface_id);
        self.allocator.destroy(fractional_scale);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    self.resource_count += 1;
    resource.setHandler(*FractionalScale, handleResourceRequest, handleResourceDestroy, fractional_scale);
    resource.sendPreferredScale(self.preferred_scale.numerator);
}

const FractionalScale = struct {
    manager: *Self,
    surface: ?*Surface,
    surface_id: Surface.Id,
    listener: Surface.CommitListener,
};

fn handleResourceRequest(
    resource: *wp.FractionalScaleV1,
    request: wp.FractionalScaleV1.Request,
    _: *FractionalScale,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleResourceDestroy(_: *wp.FractionalScaleV1, self: *FractionalScale) void {
    if (self.surface) |surface| {
        surface.removeCommitListener(&self.listener);
        _ = self.manager.by_surface.remove(self.surface_id);
    }
    self.manager.resource_count -= 1;
    self.manager.allocator.destroy(self);
}

fn handleSurfaceApplied(_: *anyopaque) void {}

fn handleSurfaceDestroyed(context: *anyopaque) void {
    const self: *FractionalScale = @ptrCast(@alignCast(context));
    const surface = self.surface orelse unreachable;
    surface.removeCommitListener(&self.listener);
    _ = self.manager.by_surface.remove(self.surface_id);
    self.surface = null;
}
