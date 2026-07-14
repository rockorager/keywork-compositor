//! Surface-scoped inhibition of compositor idle behavior.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;

allocator: std.mem.Allocator,
global: *wl.Global,
inhibitors: std.ArrayList(*Inhibitor),

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            zwp.IdleInhibitManagerV1,
            1,
            *Self,
            self,
            bind,
        ),
        .inhibitors = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.inhibitors.items.len == 0);
    self.global.destroy();
    self.inhibitors.deinit(self.allocator);
    self.* = undefined;
}

/// Visibility policy may use this to decide whether a surface currently
/// prevents dimming, locking, or display power management.
pub fn hasInhibitor(self: *const Self, surface_id: Surface.Id) bool {
    for (self.inhibitors.items) |inhibitor| {
        if (inhibitor.surface_resource != null and
            std.meta.eql(inhibitor.surface_id, surface_id))
        {
            return true;
        }
    }
    return false;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.IdleInhibitManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwp.IdleInhibitManagerV1,
    request: zwp.IdleInhibitManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_inhibitor => |create| Inhibitor.create(
            self,
            resource,
            create.id,
            create.surface,
        ) catch resource.postNoMemory(),
    }
}

const Inhibitor = struct {
    manager: *Self,
    resource: *zwp.IdleInhibitorV1,
    surface_resource: ?*wl.Surface,
    surface_id: Surface.Id,
    surface_destroy_listener: wl.Listener(*wl.Resource),

    fn create(
        manager: *Self,
        manager_resource: *zwp.IdleInhibitManagerV1,
        id: u32,
        surface_resource: *wl.Surface,
    ) !void {
        const resource = try zwp.IdleInhibitorV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Inhibitor);
        errdefer manager.allocator.destroy(self);
        self.* = .{
            .manager = manager,
            .resource = resource,
            .surface_resource = surface_resource,
            .surface_id = Surface.fromResource(surface_resource).handle(),
            .surface_destroy_listener = wl.Listener(*wl.Resource).init(handleSurfaceDestroyed),
        };
        @as(*wl.Resource, @ptrCast(surface_resource)).addDestroyListener(
            &self.surface_destroy_listener,
        );
        errdefer self.surface_destroy_listener.link.remove();
        try manager.inhibitors.append(manager.allocator, self);
        resource.setHandler(*Inhibitor, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.IdleInhibitorV1,
        request: zwp.IdleInhibitorV1.Request,
        _: *Inhibitor,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.IdleInhibitorV1, self: *Inhibitor) void {
        if (self.surface_resource != null) self.surface_destroy_listener.link.remove();
        for (self.manager.inhibitors.items, 0..) |inhibitor, index| {
            if (inhibitor != self) continue;
            _ = self.manager.inhibitors.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }

    fn handleSurfaceDestroyed(listener: *wl.Listener(*wl.Resource), _: *wl.Resource) void {
        const self: *Inhibitor = @fieldParentPtr("surface_destroy_listener", listener);
        listener.link.remove();
        self.surface_resource = null;
    }
};
