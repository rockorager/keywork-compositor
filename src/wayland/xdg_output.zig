//! Desktop-oriented logical output metadata.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");

const wl = wayland.server.wl;
const zxdg = wayland.server.zxdg;

allocator: std.mem.Allocator,
global: *wl.Global,
outputs: *OutputLayout,
resources: std.ArrayList(*OutputResource),

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    outputs: *OutputLayout,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, zxdg.OutputManagerV1, 3, *Self, self, bind),
        .outputs = outputs,
        .resources = .empty,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.resources.items.len == 0);
    self.global.destroy();
    self.resources.deinit(self.allocator);
    self.* = undefined;
}

pub fn refresh(self: *Self, output: *Output) void {
    for (self.resources.items) |managed| {
        if (managed.output != output) continue;
        managed.sendState();
    }
}

pub fn removeOutput(self: *Self, output: *Output) void {
    var index = self.resources.items.len;
    while (index > 0) {
        index -= 1;
        const managed = self.resources.items[index];
        if (managed.output == output) managed.resource.destroy();
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zxdg.OutputManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, managerRequest, null, self);
}

fn managerRequest(
    resource: *zxdg.OutputManagerV1,
    request: zxdg.OutputManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_xdg_output => |get| {
            const output = self.outputs.findResource(get.output) orelse {
                resource.getClient().postImplementationError(
                    "zxdg_output_v1 requested for an unknown wl_output",
                );
                return;
            };
            self.createOutput(resource, get.id, get.output, output.output);
        },
    }
}

fn createOutput(
    self: *Self,
    manager: *zxdg.OutputManagerV1,
    id: u32,
    output_resource: *wl.Output,
    output: *Output,
) void {
    const resource = zxdg.OutputV1.create(
        manager.getClient(),
        manager.getVersion(),
        id,
    ) catch {
        manager.postNoMemory();
        return;
    };
    const managed = self.allocator.create(OutputResource) catch {
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    managed.* = .{
        .manager = self,
        .resource = resource,
        .wl_output = output_resource,
        .output = output,
    };
    self.resources.append(self.allocator, managed) catch {
        self.allocator.destroy(managed);
        resource.postNoMemory();
        resource.destroy();
        return;
    };
    resource.setHandler(*OutputResource, outputRequest, outputDestroyed, managed);
    managed.sendState();
}

const OutputResource = struct {
    manager: *Self,
    resource: *zxdg.OutputV1,
    wl_output: *wl.Output,
    output: *Output,

    fn sendState(self: *OutputResource) void {
        const position = self.output.logicalPosition();
        const size = self.output.logicalSize();
        self.resource.sendLogicalPosition(position.x, position.y);
        self.resource.sendLogicalSize(@intCast(size.width), @intCast(size.height));
        if (self.resource.getVersion() >= zxdg.OutputV1.name_since_version) {
            self.resource.sendName(self.output.name());
            self.resource.sendDescription(self.output.description());
        }
        if (self.resource.getVersion() < 3) {
            self.resource.sendDone();
        } else if (self.wl_output.getVersion() >= wl.Output.done_since_version) {
            self.wl_output.sendDone();
        }
    }
};

fn outputRequest(
    resource: *zxdg.OutputV1,
    request: zxdg.OutputV1.Request,
    _: *OutputResource,
) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn outputDestroyed(_: *zxdg.OutputV1, managed: *OutputResource) void {
    const self = managed.manager;
    for (self.resources.items, 0..) |candidate, index| {
        if (candidate != managed) continue;
        _ = self.resources.orderedRemove(index);
        self.allocator.destroy(managed);
        return;
    }
    unreachable;
}
