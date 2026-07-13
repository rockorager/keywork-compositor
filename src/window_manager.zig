//! river-window-management-v1 lifecycle and transaction boundary.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const Seat = @import("seat.zig");

const wl = wayland.server.wl;
const river = wayland.server.river;

allocator: std.mem.Allocator,
global: *wl.Global,
output: *Output,
seat: *Seat,
active: ?*river.WindowManagerV1,
session_generation: u64,
sequence: Sequence,

const Sequence = struct {
    state: State = .idle,
    dirty: bool = false,

    const State = union(enum) {
        idle,
        manage,
        inflight_configures: u32,
        render,
    };

    fn reset(self: *Sequence) void {
        self.* = .{};
    }

    fn requestManage(self: *Sequence) bool {
        self.dirty = true;
        if (self.state != .idle) return false;
        self.dirty = false;
        self.state = .manage;
        return true;
    }

    fn finishManage(self: *Sequence) bool {
        if (self.state != .manage) return false;
        self.state = .render;
        return true;
    }

    fn finishRender(self: *Sequence) enum { invalid, idle, manage } {
        if (self.state != .render) return .invalid;
        if (self.dirty) {
            self.dirty = false;
            self.state = .manage;
            return .manage;
        }
        self.state = .idle;
        return .idle;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    output: *Output,
    seat: *Seat,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .output = output,
        .seat = seat,
        .active = null,
        .session_generation = 0,
        .sequence = .{},
    };
    self.global = try wl.Global.create(display, river.WindowManagerV1, 1, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = river.WindowManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, handleDestroy, self);

    if (self.active != null) {
        resource.sendUnavailable();
        return;
    }

    self.active = resource;
    self.session_generation +%= 1;
    self.createOutput(resource) catch {
        resource.postNoMemory();
        return;
    };
    self.createSeat(resource) catch {
        resource.postNoMemory();
        return;
    };
    std.debug.assert(self.sequence.requestManage());
    resource.sendManageStart();
}

fn handleRequest(
    resource: *river.WindowManagerV1,
    request: river.WindowManagerV1.Request,
    self: *Self,
) void {
    if (self.active != resource) {
        if (request == .destroy) resource.destroy();
        return;
    }

    switch (request) {
        .stop => {
            resource.sendFinished();
            self.active = null;
            self.sequence.reset();
        },
        .destroy => resource.postError(.sequence_order, "stop the window manager before destroying it"),
        .manage_finish => {
            if (!self.sequence.finishManage()) {
                resource.postError(.sequence_order, "manage_finish outside a manage sequence");
                return;
            }
            resource.sendRenderStart();
        },
        .manage_dirty => if (self.sequence.requestManage()) resource.sendManageStart(),
        .render_finish => switch (self.sequence.finishRender()) {
            .invalid => resource.postError(.sequence_order, "render_finish outside a render sequence"),
            .idle => {},
            .manage => resource.sendManageStart(),
        },
        .get_shell_surface => resource.getClient().postImplementationError(
            "river shell surfaces are not implemented",
        ),
        .exit_session => unreachable,
    }
}

fn handleDestroy(resource: *river.WindowManagerV1, self: *Self) void {
    if (self.active == resource) {
        self.active = null;
        self.sequence.reset();
    }
}

fn createOutput(self: *Self, manager: *river.WindowManagerV1) !void {
    const resource = try river.OutputV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(OutputResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .owner_generation = self.session_generation,
    };
    resource.setHandler(*OutputResource, OutputResource.handleRequest, OutputResource.handleDestroy, adapter);

    manager.sendOutput(resource);
    resource.sendWlOutput(self.output.globalName(manager.getClient()));
    resource.sendPosition(0, 0);
    const size = self.output.logicalSize();
    resource.sendDimensions(@intCast(size.width), @intCast(size.height));
}

fn createSeat(self: *Self, manager: *river.WindowManagerV1) !void {
    const resource = try river.SeatV1.create(
        manager.getClient(),
        manager.getVersion(),
        0,
    );
    errdefer resource.destroy();

    const adapter = try self.allocator.create(SeatResource);
    errdefer self.allocator.destroy(adapter);
    adapter.* = .{
        .allocator = self.allocator,
        .manager = self,
        .owner_generation = self.session_generation,
    };
    resource.setHandler(*SeatResource, SeatResource.handleRequest, SeatResource.handleDestroy, adapter);

    manager.sendSeat(resource);
    resource.sendWlSeat(self.seat.globalName(manager.getClient()));
}

const OutputResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    owner_generation: u64,

    fn handleRequest(
        resource: *river.OutputV1,
        request: river.OutputV1.Request,
        self: *OutputResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_presentation_mode => if (self.manager.active != null and
                self.manager.session_generation == self.owner_generation)
            {
                resource.getClient().postImplementationError(
                    "river output presentation modes are not implemented",
                );
            },
        }
    }

    fn handleDestroy(_: *river.OutputV1, self: *OutputResource) void {
        self.allocator.destroy(self);
    }
};

const SeatResource = struct {
    allocator: std.mem.Allocator,
    manager: *Self,
    owner_generation: u64,

    fn handleRequest(
        resource: *river.SeatV1,
        request: river.SeatV1.Request,
        self: *SeatResource,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        if (self.manager.active == null or
            self.manager.session_generation != self.owner_generation) return;
        const manager_resource = self.manager.active.?;

        switch (request) {
            .destroy => unreachable,
            .clear_focus, .op_start_pointer, .op_end => {
                if (self.manager.sequence.state != .manage) {
                    manager_resource.postError(
                        .sequence_order,
                        "seat request outside a manage sequence",
                    );
                }
            },
            .focus_window,
            .focus_shell_surface,
            .get_pointer_binding,
            .set_xcursor_theme,
            .pointer_warp,
            => resource.getClient().postImplementationError(
                "river seat operation is not implemented",
            ),
        }
    }

    fn handleDestroy(_: *river.SeatV1, self: *SeatResource) void {
        self.allocator.destroy(self);
    }
};

test "window management sequence preserves dirty work across render" {
    var sequence: Sequence = .{};

    try std.testing.expect(sequence.requestManage());
    try std.testing.expect(!sequence.requestManage());
    try std.testing.expect(sequence.finishManage());
    try std.testing.expectEqual(.manage, sequence.finishRender());
    try std.testing.expect(sequence.finishManage());
    try std.testing.expectEqual(.idle, sequence.finishRender());
}

test "window management sequence rejects out-of-order finishes" {
    var sequence: Sequence = .{};

    try std.testing.expect(!sequence.finishManage());
    try std.testing.expectEqual(.invalid, sequence.finishRender());
    try std.testing.expect(sequence.requestManage());
    try std.testing.expectEqual(.invalid, sequence.finishRender());
}
