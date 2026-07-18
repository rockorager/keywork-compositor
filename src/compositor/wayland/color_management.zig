//! Fixed SDR color-management-v1 implementation.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Output = @import("output.zig");
const OutputLayout = @import("output_layout.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;

pub const identity: u64 = 1;
pub const Description = struct {
    primaries: [8]i32,
    min_luminance: u32,
    max_luminance: u32,
    reference_luminance: u32,
};
pub const sdr: Description = .{
    .primaries = .{ 640000, 330000, 300000, 600000, 150000, 60000, 312700, 329000 },
    .min_luminance = 2000,
    .max_luminance = 80,
    .reference_luminance = 80,
};

allocator: std.mem.Allocator,
global: *wl.Global,
outputs: *OutputLayout,
output_objects: std.ArrayList(*ManagedOutput),
surface_states: std.ArrayList(*SurfaceState),
feedbacks: std.ArrayList(*Feedback),
references: std.ArrayList(*Reference),
object_count: usize,

pub fn init(self: *Self, allocator: std.mem.Allocator, display: *wl.Server, outputs: *OutputLayout) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(display, wp.ColorManagerV1, 3, *Self, self, bind),
        .outputs = outputs,
        .output_objects = .empty,
        .surface_states = .empty,
        .feedbacks = .empty,
        .references = .empty,
        .object_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.object_count == 0);
    std.debug.assert(self.output_objects.items.len == 0);
    std.debug.assert(self.surface_states.items.len == 0);
    std.debug.assert(self.feedbacks.items.len == 0);
    std.debug.assert(self.references.items.len == 0);
    self.global.destroy();
    self.output_objects.deinit(self.allocator);
    self.surface_states.deinit(self.allocator);
    self.feedbacks.deinit(self.allocator);
    self.references.deinit(self.allocator);
    self.* = undefined;
}

pub fn removeOutput(self: *Self, output: *Output) void {
    for (self.output_objects.items) |managed| {
        if (managed.output == output) managed.output = null;
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.ColorManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, managerRequest, null, self);
    resource.sendSupportedIntent(.perceptual);
    resource.sendDone();
}

fn managerRequest(resource: *wp.ColorManagerV1, request: wp.ColorManagerV1.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_output => |get| ManagedOutput.create(self, resource, get.id, if (self.outputs.findResource(get.output)) |entry| entry.output else null),
        .get_surface => |get| SurfaceState.create(self, resource, get.id, Surface.fromResource(get.surface)),
        .get_surface_feedback => |get| Feedback.create(self, resource, get.id, Surface.fromResource(get.surface)),
        .get_image_description => |get| Image.createFromReference(self, resource, get.image_description, get.reference),
        .create_icc_creator, .create_parametric_creator, .create_windows_scrgb, .create_windows_bt2100 => resource.postError(.unsupported_feature, "optional color-management feature is unsupported"),
    }
}

const Image = struct {
    manager: *Self,
    ready: bool,
    information: bool,

    fn create(manager: *Self, parent: anytype, id: u32, ready: bool, information: bool) ?*wp.ImageDescriptionV1 {
        const resource = wp.ImageDescriptionV1.create(parent.getClient(), parent.getVersion(), id) catch {
            parent.postNoMemory();
            return null;
        };
        const self = manager.allocator.create(Image) catch {
            resource.postNoMemory();
            resource.destroy();
            return null;
        };
        self.* = .{ .manager = manager, .ready = ready, .information = information };
        manager.object_count += 1;
        resource.setHandler(*Image, request, destroy, self);
        if (ready) sendReady(resource) else resource.sendFailed(.no_output, "output no longer exists");
        return resource;
    }

    fn createFromReference(manager: *Self, parent: *wp.ColorManagerV1, id: u32, reference: *wp.ImageDescriptionReferenceV1) void {
        const data = reference.getUserData() orelse {
            parent.postError(.unsupported_feature, "unknown image-description reference");
            return;
        };
        const ref = for (manager.references.items) |candidate| {
            if (@intFromPtr(candidate) == @intFromPtr(data)) break candidate;
        } else {
            parent.postError(.unsupported_feature, "unknown image-description reference");
            return;
        };
        _ = create(manager, parent, id, true, ref.information);
    }

    fn sendReady(resource: *wp.ImageDescriptionV1) void {
        if (resource.getVersion() >= 2) resource.sendReady2(@intCast(identity >> 32), @truncate(identity)) else resource.sendReady(@truncate(identity));
    }

    fn request(resource: *wp.ImageDescriptionV1, req: wp.ImageDescriptionV1.Request, self: *Image) void {
        switch (req) {
            .destroy => resource.destroy(),
            .get_information => |get| {
                if (!self.ready) return resource.postError(.not_ready, "image description failed");
                if (!self.information) return resource.postError(.no_information, "information is not permitted");
                const info = wp.ImageDescriptionInfoV1.create(resource.getClient(), resource.getVersion(), get.information) catch return resource.postNoMemory();
                sendInformation(info);
            },
        }
    }

    fn destroy(_: *wp.ImageDescriptionV1, self: *Image) void {
        self.manager.object_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn sendInformation(info: *wp.ImageDescriptionInfoV1) void {
    const p = sdr.primaries;
    info.sendPrimaries(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    info.sendPrimariesNamed(.srgb);
    info.sendTfNamed(.gamma22);
    info.sendLuminances(sdr.min_luminance, sdr.max_luminance, sdr.reference_luminance);
    info.sendTargetPrimaries(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    info.sendTargetLuminance(sdr.min_luminance, sdr.max_luminance);
    info.destroySendDone();
}

pub const Reference = struct {
    manager: *Self,
    information: bool,

    /// Registers a reference created by another protocol module for the fixed SDR record.
    pub fn attach(manager: *Self, resource: *wp.ImageDescriptionReferenceV1, information: bool) !void {
        const self = try manager.allocator.create(Reference);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .information = information };
        try manager.references.append(manager.allocator, self);
        resource.setHandler(*Reference, request, destroy, self);
    }

    fn request(resource: *wp.ImageDescriptionReferenceV1, req: wp.ImageDescriptionReferenceV1.Request, _: *Reference) void {
        switch (req) {
            .destroy => resource.destroy(),
        }
    }

    fn destroy(_: *wp.ImageDescriptionReferenceV1, self: *Reference) void {
        removePtr(Reference, &self.manager.references, self);
        self.manager.allocator.destroy(self);
    }
};

const ManagedOutput = struct {
    manager: *Self,
    output: ?*Output,

    fn create(manager: *Self, parent: *wp.ColorManagerV1, id: u32, output: ?*Output) void {
        const resource = wp.ColorManagementOutputV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        const self = manager.allocator.create(ManagedOutput) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .output = output };
        manager.output_objects.append(manager.allocator, self) catch {
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        resource.setHandler(*ManagedOutput, request, destroy, self);
    }
    fn request(resource: *wp.ColorManagementOutputV1, req: wp.ColorManagementOutputV1.Request, self: *ManagedOutput) void {
        switch (req) {
            .destroy => resource.destroy(),
            .get_image_description => |get| _ = Image.create(self.manager, resource, get.image_description, self.output != null, self.output != null),
        }
    }
    fn destroy(_: *wp.ColorManagementOutputV1, self: *ManagedOutput) void {
        removePtr(ManagedOutput, &self.manager.output_objects, self);
        self.manager.allocator.destroy(self);
    }
};

const SurfaceState = struct {
    manager: *Self,
    surface: ?*Surface,
    resource: ?*wp.ColorManagementSurfaceV1,
    listener: Surface.CommitListener,
    pending: ?bool = null,
    current: bool = false,

    fn create(manager: *Self, parent: *wp.ColorManagerV1, id: u32, surface: *Surface) void {
        var existing: ?*SurfaceState = null;
        for (manager.surface_states.items) |state| {
            if (state.surface != surface) continue;
            if (state.resource != null) {
                parent.postError(.surface_exists, "wl_surface already has a color-management object");
                return;
            }
            std.debug.assert(existing == null);
            existing = state;
        }
        const resource = wp.ColorManagementSurfaceV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        if (existing) |state| {
            state.resource = resource;
            resource.setHandler(*SurfaceState, request, destroyed, state);
            return;
        }
        const self = manager.allocator.create(SurfaceState) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface, .resource = resource, .listener = undefined };
        self.listener = .{ .context = self, .applied = applied, .surface_destroyed = surfaceDestroyed };
        surface.addCommitListener(&self.listener) catch {
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        manager.surface_states.append(manager.allocator, self) catch {
            surface.removeCommitListener(&self.listener);
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        resource.setHandler(*SurfaceState, request, destroyed, self);
    }
    fn request(resource: *wp.ColorManagementSurfaceV1, req: wp.ColorManagementSurfaceV1.Request, self: *SurfaceState) void {
        switch (req) {
            .destroy => resource.destroy(),
            .set_image_description => |set| {
                if (self.surface == null) return resource.postError(.inert, "wl_surface no longer exists");
                if (set.render_intent != .perceptual) return resource.postError(.render_intent, "unsupported rendering intent");
                const data = set.image_description.getUserData() orelse return resource.postError(.image_description, "invalid image description");
                const image: *Image = @ptrCast(@alignCast(data));
                if (!image.ready) return resource.postError(.image_description, "image description is not ready");
                self.pending = true;
            },
            .unset_image_description => {
                if (self.surface == null) return resource.postError(.inert, "wl_surface no longer exists");
                self.pending = false;
            },
        }
    }
    fn destroyed(_: *wp.ColorManagementSurfaceV1, self: *SurfaceState) void {
        self.resource = null;
        self.pending = false;
        self.maybeDestroy();
    }
    fn applied(context: *anyopaque) void {
        const self: *SurfaceState = @ptrCast(@alignCast(context));
        if (self.pending) |value| {
            self.current = value;
            self.pending = null;
        }
    }
    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *SurfaceState = @ptrCast(@alignCast(context));
        const surface = self.surface orelse unreachable;
        surface.removeCommitListener(&self.listener);
        self.surface = null;
        self.maybeDestroy();
    }
    fn maybeDestroy(self: *SurfaceState) void {
        if (self.resource != null or self.surface != null) return;
        removePtr(SurfaceState, &self.manager.surface_states, self);
        self.manager.allocator.destroy(self);
    }
};

const Feedback = struct {
    manager: *Self,
    surface: ?*Surface,
    listener: Surface.CommitListener,
    fn create(manager: *Self, parent: *wp.ColorManagerV1, id: u32, surface: *Surface) void {
        const resource = wp.ColorManagementSurfaceFeedbackV1.create(parent.getClient(), parent.getVersion(), id) catch return parent.postNoMemory();
        const self = manager.allocator.create(Feedback) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager, .surface = surface, .listener = undefined };
        self.listener = .{ .context = self, .applied = applied, .surface_destroyed = surfaceDestroyed };
        surface.addCommitListener(&self.listener) catch {
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        manager.feedbacks.append(manager.allocator, self) catch {
            surface.removeCommitListener(&self.listener);
            manager.allocator.destroy(self);
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        resource.setHandler(*Feedback, request, destroy, self);
    }
    fn request(resource: *wp.ColorManagementSurfaceFeedbackV1, req: wp.ColorManagementSurfaceFeedbackV1.Request, self: *Feedback) void {
        switch (req) {
            .destroy => resource.destroy(),
            .get_preferred => |get| {
                if (self.surface == null) return resource.postError(.inert, "wl_surface no longer exists");
                _ = Image.create(self.manager, resource, get.image_description, true, true);
            },
            .get_preferred_parametric => {
                if (self.surface == null) return resource.postError(.inert, "wl_surface no longer exists");
                resource.postError(.unsupported_feature, "parametric descriptions are unsupported");
            },
        }
    }
    fn applied(_: *anyopaque) void {}
    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        const surface = self.surface orelse unreachable;
        surface.removeCommitListener(&self.listener);
        self.surface = null;
    }
    fn destroy(_: *wp.ColorManagementSurfaceFeedbackV1, self: *Feedback) void {
        if (self.surface) |surface| surface.removeCommitListener(&self.listener);
        removePtr(Feedback, &self.manager.feedbacks, self);
        self.manager.allocator.destroy(self);
    }
};

fn removePtr(comptime T: type, list: *std.ArrayList(*T), ptr: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == ptr) {
        _ = list.orderedRemove(index);
        return;
    };
    unreachable;
}

test "fixed SDR metadata is internally consistent" {
    try std.testing.expect(identity != 0);
    try std.testing.expectEqual(@as(u32, 2000), sdr.min_luminance);
    try std.testing.expectEqual(sdr.max_luminance, sdr.reference_luminance);
    try std.testing.expectEqual(@as(i32, 640000), sdr.primaries[0]);
}

test "output objects become inert independently of protocol resources" {
    const output: *Output = @ptrFromInt(@alignOf(Output));
    var managed: ManagedOutput = .{ .manager = undefined, .output = output };
    var manager: Self = undefined;
    manager.output_objects = .empty;
    defer manager.output_objects.deinit(std.testing.allocator);
    try manager.output_objects.append(std.testing.allocator, &managed);

    manager.removeOutput(output);
    try std.testing.expect(managed.output == null);
    try std.testing.expectEqual(@as(usize, 1), manager.output_objects.items.len);
}

test "surface color state survives extension recreation and becomes inert" {
    const display = try wl.Server.create();
    defer display.destroy();

    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[1]);
    const client = wl.Client.create(display, sockets[0]) orelse return error.OutOfMemory;

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);
    var outputs: OutputLayout = undefined;
    outputs.init(std.testing.allocator, display, &surfaces);
    defer outputs.deinit();
    var manager: Self = undefined;
    try manager.init(std.testing.allocator, display, &outputs);
    defer manager.deinit();
    defer client.destroy();

    const surface = try Surface.create(std.testing.allocator, &surfaces, client, 7, 1);
    const manager_resource = try wp.ColorManagerV1.create(client, 3, 2);

    SurfaceState.create(&manager, manager_resource, 3, surface);
    try std.testing.expectEqual(@as(usize, 1), manager.surface_states.items.len);
    const state = manager.surface_states.items[0];
    state.resource.?.destroy();
    try std.testing.expectEqual(@as(?bool, false), state.pending);

    SurfaceState.create(&manager, manager_resource, 4, surface);
    try std.testing.expectEqual(@as(usize, 1), manager.surface_states.items.len);
    try std.testing.expect(manager.surface_states.items[0] == state);
    Feedback.create(&manager, manager_resource, 5, surface);
    try std.testing.expectEqual(@as(usize, 1), manager.feedbacks.items.len);

    surface.waylandResource().destroy();
    try std.testing.expect(state.surface == null);
    try std.testing.expect(manager.feedbacks.items[0].surface == null);

    state.resource.?.destroy();
    try std.testing.expectEqual(@as(usize, 0), manager.surface_states.items.len);
}
