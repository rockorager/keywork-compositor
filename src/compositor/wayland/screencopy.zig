//! Privileged wlr-screencopy compatibility protocol.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const LinuxDmabuf = @import("linux_dmabuf.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");

const wl = wayland.server.wl;
const zwlr = wayland.server.zwlr;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
outputs: *OutputLayout,
linux_dmabuf: *LinuxDmabuf,
listener: Listener,
frames: std.ArrayList(*Frame),

pub const Target = struct {
    output: OutputLayout.Id,
    /// Output-local logical coordinates. Null selects the complete output.
    region: ?render.Rect = null,
};

pub const CaptureError = error{ Stopped, Failed };

pub const Listener = struct {
    context: *anyopaque,
    constraints: *const fn (*anyopaque, Target) ?render.Size,
    capture: *const fn (
        *anyopaque,
        Target,
        bool,
        render.PixelBuffer,
    ) CaptureError!presentation.Timestamp,
};

const Destination = union(enum) {
    shm: *wl.shm.Buffer,
    dmabuf: *LinuxDmabuf.Buffer,
};

const Frame = struct {
    owner: *Self,
    resource: *zwlr.ScreencopyFrameV1,
    target: ?Target,
    size: ?render.Size,
    overlay_cursor: bool,
    used: bool = false,
    finished: bool = false,

    fn create(
        owner: *Self,
        manager: *zwlr.ScreencopyManagerV1,
        id: u32,
        target: ?Target,
        overlay_cursor: bool,
    ) !void {
        const resource = try zwlr.ScreencopyFrameV1.create(
            manager.getClient(),
            manager.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try owner.allocator.create(Frame);
        errdefer owner.allocator.destroy(self);
        const size = if (target) |value| owner.listener.constraints(
            owner.listener.context,
            value,
        ) else null;
        self.* = .{
            .owner = owner,
            .resource = resource,
            .target = target,
            .size = size,
            .overlay_cursor = overlay_cursor,
        };
        try owner.frames.append(owner.allocator, self);
        resource.setHandler(*Frame, handleRequest, handleDestroy, self);

        const capture_size = size orelse return self.fail();
        const stride = std.math.mul(u32, capture_size.width, @sizeOf(u32)) catch
            return self.fail();
        resource.sendBuffer(.argb8888, capture_size.width, capture_size.height, stride);
        if (resource.getVersion() >= 3) {
            if (owner.linux_dmabuf.allocationDevice() != null) {
                resource.sendLinuxDmabuf(
                    LinuxDmabuf.capture_formats[0].format,
                    capture_size.width,
                    capture_size.height,
                );
            }
            resource.sendBufferDone();
        }
    }

    fn handleRequest(
        resource: *zwlr.ScreencopyFrameV1,
        request: zwlr.ScreencopyFrameV1.Request,
        self: *Frame,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .copy => |copy_request| self.copy(copy_request.buffer, false),
            .copy_with_damage => |copy_request| self.copy(copy_request.buffer, true),
        }
    }

    fn handleDestroy(_: *zwlr.ScreencopyFrameV1, self: *Frame) void {
        for (self.owner.frames.items, 0..) |frame, index| {
            if (frame != self) continue;
            _ = self.owner.frames.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }

    fn copy(self: *Frame, buffer_resource: *wl.Buffer, with_damage: bool) void {
        if (self.finished) return;
        if (self.used) {
            self.resource.postError(.already_used, "screencopy frame was already used");
            return;
        }
        const size = self.size orelse return self.fail();
        const destination_value = self.destination(buffer_resource, size) orelse {
            self.resource.postError(.invalid_buffer, "buffer does not match screencopy constraints");
            return;
        };
        self.used = true;
        const target = self.target orelse return self.fail();
        const result = switch (destination_value) {
            .shm => |shm| capture: {
                shm.beginAccess();
                defer shm.endAccess();
                const pixels = shmPixelBuffer(shm, size) orelse unreachable;
                break :capture self.owner.listener.capture(
                    self.owner.listener.context,
                    target,
                    self.overlay_cursor,
                    pixels,
                );
            },
            .dmabuf => |dmabuf| capture: {
                const pixel_count = size.pixelCount() catch return self.fail();
                const pixels = self.owner.allocator.alloc(u32, pixel_count) catch {
                    self.resource.postNoMemory();
                    return;
                };
                defer self.owner.allocator.free(pixels);
                const pixel_buffer: render.PixelBuffer = .{
                    .size = size,
                    .stride_pixels = size.width,
                    .pixels = pixels,
                };
                const timestamp = self.owner.listener.capture(
                    self.owner.listener.context,
                    target,
                    self.overlay_cursor,
                    pixel_buffer,
                ) catch |err| break :capture err;
                dmabuf.copyFromPixels(pixel_buffer) catch break :capture error.Failed;
                break :capture timestamp;
            },
        } catch return self.fail();

        self.resource.sendFlags(.{
            .y_invert = switch (destination_value) {
                .shm => false,
                .dmabuf => |dmabuf| dmabuf.yInverted(),
            },
        });
        if (with_damage and self.resource.getVersion() >= 2) {
            self.resource.sendDamage(0, 0, size.width, size.height);
        }
        self.resource.sendReady(
            result.highSeconds(),
            result.lowSeconds(),
            result.nanoseconds,
        );
        self.finished = true;
    }

    fn destination(
        self: *Frame,
        resource: *wl.Buffer,
        size: render.Size,
    ) ?Destination {
        _ = self;
        if (wl.shm.Buffer.get(@ptrCast(resource))) |shm| {
            return if (validShmBuffer(shm, size)) .{ .shm = shm } else null;
        }
        const dmabuf = LinuxDmabuf.Buffer.fromResource(resource) orelse return null;
        if (!std.meta.eql(dmabuf.size(), size) or
            dmabuf.format() != LinuxDmabuf.capture_formats[0].format) return null;
        return .{ .dmabuf = dmabuf };
    }

    fn fail(self: *Frame) void {
        if (self.finished) return;
        self.resource.sendFailed();
        self.finished = true;
        self.target = null;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    outputs: *OutputLayout,
    linux_dmabuf: *LinuxDmabuf,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .outputs = outputs,
        .linux_dmabuf = linux_dmabuf,
        .listener = listener,
        .frames = .empty,
    };
    errdefer self.frames.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        zwlr.ScreencopyManagerV1,
        3,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
}

pub fn deinit(self: *Self) void {
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.frames.items.len == 0);
    self.frames.deinit(self.allocator);
    self.* = undefined;
}

pub fn removeOutput(self: *Self, output: OutputLayout.Id) void {
    for (self.frames.items) |frame| {
        const target = frame.target orelse continue;
        if (std.meta.eql(target.output, output)) frame.fail();
    }
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwlr.ScreencopyManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *zwlr.ScreencopyManagerV1,
    request: zwlr.ScreencopyManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .capture_output => |capture| Frame.create(
            self,
            resource,
            capture.frame,
            if (self.outputs.findResource(capture.output)) |entry|
                .{ .output = entry.id }
            else
                null,
            capture.overlay_cursor != 0,
        ) catch resource.postNoMemory(),
        .capture_output_region => |capture| Frame.create(
            self,
            resource,
            capture.frame,
            self.regionTarget(capture.output, .{
                .x = capture.x,
                .y = capture.y,
                .width = capture.width,
                .height = capture.height,
            }),
            capture.overlay_cursor != 0,
        ) catch resource.postNoMemory(),
    }
}

const RequestedRegion = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

fn regionTarget(
    self: *Self,
    output_resource: *wl.Output,
    requested: RequestedRegion,
) ?Target {
    if (requested.width <= 0 or requested.height <= 0) return null;
    const entry = self.outputs.findResource(output_resource) orelse return null;
    const output_rect = entry.output.logicalRect();
    const local_bounds: render.Rect = .{
        .x = 0,
        .y = 0,
        .width = output_rect.width,
        .height = output_rect.height,
    };
    const region = (render.Rect{
        .x = requested.x,
        .y = requested.y,
        .width = @intCast(requested.width),
        .height = @intCast(requested.height),
    }).intersection(local_bounds) orelse return null;
    return .{ .output = entry.id, .region = region };
}

fn shmPixelBuffer(buffer: *wl.shm.Buffer, expected: render.Size) ?render.PixelBuffer {
    if (!validShmBuffer(buffer, expected)) return null;
    const data = buffer.getData() orelse return null;
    if (@intFromPtr(data) % @alignOf(u32) != 0) return null;
    const pixel_count = expected.pixelCount() catch return null;
    const pixels: [*]u32 = @ptrCast(@alignCast(data));
    return .{
        .size = expected,
        .stride_pixels = expected.width,
        .pixels = pixels[0..pixel_count],
    };
}

fn validShmBuffer(buffer: *wl.shm.Buffer, expected: render.Size) bool {
    const width = buffer.getWidth();
    const height = buffer.getHeight();
    const stride = buffer.getStride();
    if (width <= 0 or height <= 0 or stride <= 0) return false;
    const size: render.Size = .{ .width = @intCast(width), .height = @intCast(height) };
    if (!std.meta.eql(size, expected)) return false;
    const expected_stride = std.math.mul(u32, size.width, @sizeOf(u32)) catch return false;
    return stride == expected_stride and
        buffer.getFormat() == @intFromEnum(wl.Shm.Format.argb8888);
}

test "screencopy regions reject empty geometry" {
    const invalid: RequestedRegion = .{ .x = 0, .y = 0, .width = 0, .height = 10 };
    try std.testing.expect(invalid.width <= 0 or invalid.height <= 0);
}
