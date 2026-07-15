//! Privileged workspace discovery for the compositor's single workspace.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
outputs: *OutputLayout,
bindings: std.ArrayList(*Binding),

const Binding = struct {
    owner: *Self,
    manager: ?*ext.WorkspaceManagerV1,
    group: ?*ext.WorkspaceGroupHandleV1,
    workspace: ?*ext.WorkspaceHandleV1,

    fn create(owner: *Self, client: *wl.Client, version: u32, id: u32) !void {
        const manager = try ext.WorkspaceManagerV1.create(client, version, id);
        errdefer manager.destroy();
        const group = try ext.WorkspaceGroupHandleV1.create(client, version, 0);
        errdefer group.destroy();
        const workspace = try ext.WorkspaceHandleV1.create(client, version, 0);
        errdefer workspace.destroy();
        const self = try owner.allocator.create(Binding);
        errdefer owner.allocator.destroy(self);
        self.* = .{
            .owner = owner,
            .manager = manager,
            .group = group,
            .workspace = workspace,
        };
        try owner.bindings.append(owner.allocator, self);
        manager.setHandler(*Binding, handleManagerRequest, handleManagerDestroy, self);
        group.setHandler(*Binding, handleGroupRequest, handleGroupDestroy, self);
        workspace.setHandler(*Binding, handleWorkspaceRequest, handleWorkspaceDestroy, self);

        manager.sendWorkspaceGroup(group);
        group.sendCapabilities(.{});
        var outputs = owner.outputs.iterator();
        while (outputs.next()) |entry| {
            for (entry.output.boundResources()) |output_resource| {
                if (output_resource.getClient() == client) group.sendOutputEnter(output_resource);
            }
        }
        manager.sendWorkspace(workspace);
        workspace.sendCapabilities(.{});
        workspace.sendName("1");
        workspace.sendState(.{ .active = true });
        group.sendWorkspaceEnter(workspace);
        manager.sendDone();
    }

    fn handleManagerRequest(
        resource: *ext.WorkspaceManagerV1,
        request: ext.WorkspaceManagerV1.Request,
        _: *Binding,
    ) void {
        switch (request) {
            .commit => {},
            .stop => resource.destroySendFinished(),
        }
    }

    fn handleManagerDestroy(_: *ext.WorkspaceManagerV1, self: *Binding) void {
        self.manager = null;
        self.maybeDestroy();
    }

    fn handleGroupRequest(
        resource: *ext.WorkspaceGroupHandleV1,
        request: ext.WorkspaceGroupHandleV1.Request,
        self: *Binding,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        if (self.manager == null) return;
        // No create capability is advertised for the compositor's static group.
    }

    fn handleGroupDestroy(_: *ext.WorkspaceGroupHandleV1, self: *Binding) void {
        self.group = null;
        self.maybeDestroy();
    }

    fn handleWorkspaceRequest(
        resource: *ext.WorkspaceHandleV1,
        request: ext.WorkspaceHandleV1.Request,
        self: *Binding,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        if (self.manager == null) return;
        // The sole workspace is permanent and has no mutation capabilities.
    }

    fn handleWorkspaceDestroy(_: *ext.WorkspaceHandleV1, self: *Binding) void {
        self.workspace = null;
        self.maybeDestroy();
    }

    fn maybeDestroy(self: *Binding) void {
        if (self.manager != null or self.group != null or self.workspace != null) return;
        for (self.owner.bindings.items, 0..) |binding, index| {
            if (binding != self) continue;
            _ = self.owner.bindings.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    outputs: *OutputLayout,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .outputs = outputs,
        .bindings = .empty,
    };
    errdefer self.bindings.deinit(allocator);
    self.global = try wl.Global.create(display, ext.WorkspaceManagerV1, 1, *Self, self, bind);
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    var iterator = outputs.iterator();
    while (iterator.next()) |entry| entry.output.setBindListener(.{
        .context = self,
        .bound = outputBound,
    });
}

pub fn deinit(self: *Self) void {
    var iterator = self.outputs.iterator();
    while (iterator.next()) |entry| entry.output.clearBindListener();
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.bindings.items.len == 0);
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}

pub fn addOutput(self: *Self, output_id: OutputLayout.Id) void {
    const output = self.outputs.get(output_id) orelse return;
    output.setBindListener(.{ .context = self, .bound = outputBound });
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        const group = binding.group orelse continue;
        for (output.boundResources()) |output_resource| {
            if (output_resource.getClient() == manager.getClient()) {
                group.sendOutputEnter(output_resource);
            }
        }
        manager.sendDone();
    }
}

pub fn removeOutput(self: *Self, output_id: OutputLayout.Id) void {
    const output = self.outputs.get(output_id) orelse return;
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        const group = binding.group orelse continue;
        for (output.boundResources()) |output_resource| {
            if (output_resource.getClient() == manager.getClient()) {
                group.sendOutputLeave(output_resource);
            }
        }
        manager.sendDone();
    }
    output.clearBindListener();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    Binding.create(self, client, version, id) catch client.postNoMemory();
}

fn outputBound(context: *anyopaque, _: *Output, output_resource: *wl.Output) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.bindings.items) |binding| {
        const manager = binding.manager orelse continue;
        const group = binding.group orelse continue;
        if (output_resource.getClient() != manager.getClient()) continue;
        group.sendOutputEnter(output_resource);
        manager.sendDone();
    }
}
