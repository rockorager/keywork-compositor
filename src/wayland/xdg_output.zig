//! Desktop-oriented logical output metadata.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");

const wl = wayland.server.wl;
const zxdg = wayland.server.zxdg;

global: *wl.Global,
outputs: *OutputLayout,
resource_count: usize = 0,

pub fn init(self: *Self, display: *wl.Server, outputs: *OutputLayout) !void {
    self.* = .{
        .global = try wl.Global.create(display, zxdg.OutputManagerV1, 3, *Self, self, bind),
        .outputs = outputs,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.resource_count == 0);
    self.global.destroy();
    self.* = undefined;
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
    self.resource_count += 1;
    resource.setHandler(*Self, outputRequest, outputDestroyed, self);

    const position = output.logicalPosition();
    const size = output.logicalSize();
    resource.sendLogicalPosition(position.x, position.y);
    resource.sendLogicalSize(@intCast(size.width), @intCast(size.height));
    if (resource.getVersion() >= zxdg.OutputV1.name_since_version) {
        resource.sendName(Output.output_name);
        resource.sendDescription(Output.output_description);
    }
    if (resource.getVersion() < 3) {
        resource.sendDone();
    } else if (output_resource.getVersion() >= wl.Output.done_since_version) {
        output_resource.sendDone();
    }
}

fn outputRequest(resource: *zxdg.OutputV1, request: zxdg.OutputV1.Request, _: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn outputDestroyed(_: *zxdg.OutputV1, self: *Self) void {
    std.debug.assert(self.resource_count > 0);
    self.resource_count -= 1;
}
