//! Privileged image capture into client-provided buffers.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const ImageCaptureSource = @import("image_capture_source.zig");
const LinuxDmabuf = @import("linux_dmabuf.zig");
const SecurityContext = @import("security_context.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
global: *wl.Global,
security_context: *SecurityContext,
sources: *ImageCaptureSource,
linux_dmabuf: *LinuxDmabuf,
listener: Listener,
sessions: std.ArrayList(*Session),
frames: std.ArrayList(*Frame),
cursor_sessions: std.ArrayList(*CursorSession),

pub const Constraints = struct {
    size: render.Size,
    transform: wl.Output.Transform = .normal,
};

pub const CaptureError = error{ Stopped, Failed };

pub const Listener = struct {
    context: *anyopaque,
    constraints: *const fn (*anyopaque, ImageCaptureSource.Target) ?Constraints,
    capture: *const fn (
        *anyopaque,
        ImageCaptureSource.Target,
        bool,
        render.PixelBuffer,
    ) CaptureError!presentation.Timestamp,
};

const Destination = struct {
    resource: ?*wl.Buffer = null,
    shm: ?*wl.shm.Buffer = null,
    dmabuf: ?*LinuxDmabuf.Buffer = null,
    destroy_listener: wl.Listener(*wl.Resource) = undefined,

    fn set(self: *Destination, resource: *wl.Buffer) void {
        self.clear();
        const shm = wl.shm.Buffer.get(@ptrCast(resource));
        const dmabuf = if (shm == null) LinuxDmabuf.Buffer.fromResource(resource) else null;
        self.resource = resource;
        self.shm = if (shm) |buffer| wl_shm_buffer_ref(buffer) else null;
        self.dmabuf = dmabuf;
        self.destroy_listener = wl.Listener(*wl.Resource).init(handleResourceDestroy);
        @as(*wl.Resource, @ptrCast(resource)).addDestroyListener(&self.destroy_listener);
    }

    fn clear(self: *Destination) void {
        if (self.resource != null) self.destroy_listener.link.remove();
        if (self.shm) |buffer| wl_shm_buffer_unref(buffer);
        self.resource = null;
        self.shm = null;
        self.dmabuf = null;
    }

    fn attached(self: *const Destination) bool {
        return self.resource != null or self.shm != null;
    }

    fn handleResourceDestroy(
        listener: *wl.Listener(*wl.Resource),
        _: *wl.Resource,
    ) void {
        const self: *Destination = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        self.resource = null;
        self.dmabuf = null;
    }
};

const Session = struct {
    owner: *Self,
    resource: *ext.ImageCopyCaptureSessionV1,
    target: ?ImageCaptureSource.Target,
    constraints: ?Constraints,
    frame: ?*Frame = null,
    paint_cursors: bool,
    stopped: bool = false,

    fn create(
        owner: *Self,
        client: *wl.Client,
        id: u32,
        target: ?ImageCaptureSource.Target,
        paint_cursors: bool,
    ) !void {
        const resource = try ext.ImageCopyCaptureSessionV1.create(client, 1, id);
        errdefer resource.destroy();
        const self = try owner.allocator.create(Session);
        errdefer owner.allocator.destroy(self);
        const constraints = if (target) |value| owner.listener.constraints(
            owner.listener.context,
            value,
        ) else null;
        self.* = .{
            .owner = owner,
            .resource = resource,
            .target = target,
            .constraints = constraints,
            .paint_cursors = paint_cursors,
        };
        try owner.sessions.append(owner.allocator, self);
        resource.setHandler(*Session, handleRequest, handleDestroy, self);
        if (target == null or constraints == null) {
            self.stop();
        } else {
            self.sendConstraints(constraints.?);
        }
    }

    fn handleRequest(
        resource: *ext.ImageCopyCaptureSessionV1,
        request: ext.ImageCopyCaptureSessionV1.Request,
        self: *Session,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .create_frame => |create_frame| {
                if (self.frame != null) {
                    resource.postError(.duplicate_frame, "a capture frame already exists");
                    return;
                }
                Frame.create(self, create_frame.frame) catch resource.postNoMemory();
            },
        }
    }

    fn handleDestroy(_: *ext.ImageCopyCaptureSessionV1, self: *Session) void {
        if (self.frame) |frame| frame.session = null;
        for (self.owner.sessions.items, 0..) |session, index| {
            if (session != self) continue;
            _ = self.owner.sessions.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }

    fn sendConstraints(self: *Session, constraints: Constraints) void {
        self.resource.sendBufferSize(constraints.size.width, constraints.size.height);
        self.resource.sendShmFormat(.argb8888);
        self.resource.sendShmFormat(.xrgb8888);
        if (self.owner.linux_dmabuf.allocationDevice()) |device_value| {
            var device = device_value;
            var device_array: wl.Array = .{
                .size = @sizeOf(LinuxDmabuf.Device),
                .alloc = @sizeOf(LinuxDmabuf.Device),
                .data = @ptrCast(&device),
            };
            self.resource.sendDmabufDevice(&device_array);
            for (LinuxDmabuf.capture_formats) |format| {
                var modifiers = [_]u64{format.modifier};
                var modifier_array: wl.Array = .{
                    .size = @sizeOf(@TypeOf(modifiers)),
                    .alloc = @sizeOf(@TypeOf(modifiers)),
                    .data = @ptrCast(&modifiers),
                };
                self.resource.sendDmabufFormat(format.format, &modifier_array);
            }
        }
        self.resource.sendDone();
    }

    fn stop(self: *Session) void {
        if (self.stopped) return;
        self.stopped = true;
        self.target = null;
        self.resource.sendStopped();
    }
};

const Frame = struct {
    owner: *Self,
    resource: *ext.ImageCopyCaptureFrameV1,
    session: ?*Session,
    target: ?ImageCaptureSource.Target,
    constraints: ?Constraints,
    paint_cursors: bool,
    destination: Destination = .{},
    capture_requested: bool = false,
    finished: bool = false,

    fn create(session: *Session, id: u32) !void {
        const resource = try ext.ImageCopyCaptureFrameV1.create(
            session.resource.getClient(),
            1,
            id,
        );
        errdefer resource.destroy();
        const self = try session.owner.allocator.create(Frame);
        errdefer session.owner.allocator.destroy(self);
        self.* = .{
            .owner = session.owner,
            .resource = resource,
            .session = session,
            .target = session.target,
            .constraints = session.constraints,
            .paint_cursors = session.paint_cursors,
        };
        try session.owner.frames.append(session.owner.allocator, self);
        session.frame = self;
        resource.setHandler(*Frame, handleRequest, handleDestroy, self);
        if (session.stopped) self.fail(.stopped);
    }

    fn handleRequest(
        resource: *ext.ImageCopyCaptureFrameV1,
        request: ext.ImageCopyCaptureFrameV1.Request,
        self: *Frame,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        switch (request) {
            .destroy => unreachable,
            .attach_buffer => |attach| {
                if (self.capture_requested) {
                    resource.postError(.already_captured, "the capture request was already sent");
                    return;
                }
                if (!self.finished) self.destination.set(attach.buffer);
            },
            .damage_buffer => |damage| {
                if (self.capture_requested) {
                    resource.postError(.already_captured, "the capture request was already sent");
                    return;
                }
                if (self.finished) return;
                if (damage.x < 0 or damage.y < 0 or damage.width <= 0 or damage.height <= 0) {
                    resource.postError(.invalid_buffer_damage, "buffer damage must be positive");
                    return;
                }
                // The whole destination is copied, so client damage is only a hint.
            },
            .capture => {
                if (self.capture_requested) {
                    resource.postError(.already_captured, "the capture request was already sent");
                    return;
                }
                self.capture_requested = true;
                if (!self.finished) self.capture();
            },
        }
    }

    fn handleDestroy(_: *ext.ImageCopyCaptureFrameV1, self: *Frame) void {
        if (self.session) |session| session.frame = null;
        for (self.owner.frames.items, 0..) |frame, index| {
            if (frame != self) continue;
            _ = self.owner.frames.swapRemove(index);
            break;
        }
        self.destination.clear();
        self.owner.allocator.destroy(self);
    }

    fn capture(self: *Frame) void {
        if (!self.destination.attached()) {
            self.resource.postError(.no_buffer, "capture requires an attached buffer");
            return;
        }
        const target = self.target orelse return self.fail(.stopped);
        const expected = self.constraints orelse return self.fail(.stopped);
        const current = self.owner.listener.constraints(self.owner.listener.context, target) orelse {
            self.fail(.stopped);
            self.stopSession();
            return;
        };
        if (!std.meta.eql(current, expected)) {
            if (self.session) |session| {
                if (!session.stopped) {
                    session.constraints = current;
                    session.sendConstraints(current);
                }
            }
            return self.fail(.buffer_constraints);
        }
        const timestamp = if (self.destination.shm) |shm| timestamp: {
            shm.beginAccess();
            defer shm.endAccess();
            const pixel_buffer = shmPixelBuffer(shm, expected.size) orelse
                return self.fail(.buffer_constraints);
            break :timestamp self.performCapture(target, pixel_buffer) orelse return;
        } else if (self.destination.dmabuf) |dmabuf| timestamp: {
            if (self.owner.linux_dmabuf.allocationDevice() == null or
                !std.meta.eql(dmabuf.size(), expected.size)) return self.fail(.buffer_constraints);
            const pixel_count = expected.size.pixelCount() catch
                return self.fail(.buffer_constraints);
            const pixels = self.owner.allocator.alloc(u32, pixel_count) catch {
                self.resource.postNoMemory();
                return;
            };
            defer self.owner.allocator.free(pixels);
            const pixel_buffer: render.PixelBuffer = .{
                .size = expected.size,
                .stride_pixels = expected.size.width,
                .pixels = pixels,
            };
            const value = self.performCapture(target, pixel_buffer) orelse return;
            dmabuf.copyFromPixels(pixel_buffer) catch return self.fail(.unknown);
            break :timestamp value;
        } else return self.fail(.buffer_constraints);
        self.ready(expected, timestamp);
    }

    fn performCapture(
        self: *Frame,
        target: ImageCaptureSource.Target,
        pixel_buffer: render.PixelBuffer,
    ) ?presentation.Timestamp {
        return self.owner.listener.capture(
            self.owner.listener.context,
            target,
            self.paint_cursors,
            pixel_buffer,
        ) catch |err| switch (err) {
            error.Stopped => {
                self.fail(.stopped);
                self.stopSession();
                return null;
            },
            error.Failed => {
                self.fail(.unknown);
                return null;
            },
        };
    }

    fn ready(
        self: *Frame,
        expected: Constraints,
        timestamp: presentation.Timestamp,
    ) void {
        self.resource.sendTransform(expected.transform);
        self.resource.sendDamage(
            0,
            0,
            @intCast(expected.size.width),
            @intCast(expected.size.height),
        );
        self.resource.sendPresentationTime(
            timestamp.highSeconds(),
            timestamp.lowSeconds(),
            timestamp.nanoseconds,
        );
        self.resource.sendReady();
        self.finished = true;
    }

    fn fail(self: *Frame, reason: ext.ImageCopyCaptureFrameV1.FailureReason) void {
        if (self.finished) return;
        self.finished = true;
        self.resource.sendFailed(reason);
    }

    fn stopSession(self: *Frame) void {
        if (self.session) |session| session.stop();
    }
};

const CursorSession = struct {
    owner: *Self,
    resource: *ext.ImageCopyCaptureCursorSessionV1,
    capture_session_created: bool = false,

    fn create(owner: *Self, client: *wl.Client, id: u32) !void {
        const resource = try ext.ImageCopyCaptureCursorSessionV1.create(client, 1, id);
        errdefer resource.destroy();
        const self = try owner.allocator.create(CursorSession);
        errdefer owner.allocator.destroy(self);
        self.* = .{ .owner = owner, .resource = resource };
        try owner.cursor_sessions.append(owner.allocator, self);
        resource.setHandler(*CursorSession, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *ext.ImageCopyCaptureCursorSessionV1,
        request: ext.ImageCopyCaptureCursorSessionV1.Request,
        self: *CursorSession,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .get_capture_session => |get_session| {
                if (self.capture_session_created) {
                    resource.postError(.duplicate_session, "a cursor capture session already exists");
                    return;
                }
                self.capture_session_created = true;
                // Dedicated cursor-image capture is added separately. Until then, the
                // protocol-defined inert session reports that capture is unavailable.
                Session.create(self.owner, resource.getClient(), get_session.session, null, false) catch
                    resource.postNoMemory();
            },
        }
    }

    fn handleDestroy(_: *ext.ImageCopyCaptureCursorSessionV1, self: *CursorSession) void {
        for (self.owner.cursor_sessions.items, 0..) |session, index| {
            if (session != self) continue;
            _ = self.owner.cursor_sessions.swapRemove(index);
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
    sources: *ImageCaptureSource,
    linux_dmabuf: *LinuxDmabuf,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .security_context = security_context,
        .sources = sources,
        .linux_dmabuf = linux_dmabuf,
        .listener = listener,
        .sessions = .empty,
        .frames = .empty,
        .cursor_sessions = .empty,
    };
    errdefer self.sessions.deinit(allocator);
    errdefer self.frames.deinit(allocator);
    errdefer self.cursor_sessions.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        ext.ImageCopyCaptureManagerV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    sources.setInvalidationListener(.{
        .context = self,
        .invalidated = sourceInvalidated,
    });
}

pub fn deinit(self: *Self) void {
    self.sources.clearInvalidationListener();
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.sessions.items.len == 0);
    std.debug.assert(self.frames.items.len == 0);
    std.debug.assert(self.cursor_sessions.items.len == 0);
    self.cursor_sessions.deinit(self.allocator);
    self.frames.deinit(self.allocator);
    self.sessions.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.ImageCopyCaptureManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *ext.ImageCopyCaptureManagerV1,
    request: ext.ImageCopyCaptureManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_session => |create| {
            const option_bits: u32 = @bitCast(create.options);
            if (option_bits & ~@as(u32, 1) != 0) {
                resource.postError(.invalid_option, "unknown capture option");
                return;
            }
            const target = self.sources.targetForResource(create.source);
            Session.create(
                self,
                resource.getClient(),
                create.session,
                target,
                create.options.paint_cursors,
            ) catch resource.postNoMemory();
        },
        .create_pointer_cursor_session => |create| {
            _ = create.source;
            _ = create.pointer;
            CursorSession.create(self, resource.getClient(), create.session) catch
                resource.postNoMemory();
        },
    }
}

fn sourceInvalidated(context: *anyopaque, target: ImageCaptureSource.Target) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.frames.items) |frame| {
        const current = frame.target orelse continue;
        if (std.meta.eql(current, target)) frame.fail(.stopped);
    }
    for (self.sessions.items) |session| {
        const current = session.target orelse continue;
        if (std.meta.eql(current, target)) session.stop();
    }
}

fn shmPixelBuffer(buffer: *wl.shm.Buffer, expected: render.Size) ?render.PixelBuffer {
    const width = buffer.getWidth();
    const height = buffer.getHeight();
    const stride = buffer.getStride();
    if (width <= 0 or height <= 0 or stride <= 0 or @mod(stride, @sizeOf(u32)) != 0) {
        return null;
    }
    const size: render.Size = .{ .width = @intCast(width), .height = @intCast(height) };
    if (!std.meta.eql(size, expected)) return null;
    const stride_pixels: u32 = @intCast(@divExact(stride, @sizeOf(u32)));
    if (stride_pixels < size.width) return null;
    const format = buffer.getFormat();
    if (format != @intFromEnum(wl.Shm.Format.argb8888) and
        format != @intFromEnum(wl.Shm.Format.xrgb8888)) return null;
    const row_offset = std.math.mul(usize, size.height - 1, stride_pixels) catch return null;
    const required_pixels = std.math.add(usize, row_offset, size.width) catch return null;
    const data = buffer.getData() orelse return null;
    if (@intFromPtr(data) % @alignOf(u32) != 0) return null;
    const pixels: [*]u32 = @ptrCast(@alignCast(data));
    return .{
        .size = size,
        .stride_pixels = stride_pixels,
        .pixels = pixels[0..required_pixels],
    };
}

extern fn wl_shm_buffer_ref(buffer: *wl.shm.Buffer) *wl.shm.Buffer;
extern fn wl_shm_buffer_unref(buffer: *wl.shm.Buffer) void;

test "capture option mask accepts only paint cursors" {
    const valid: ext.ImageCopyCaptureManagerV1.Options = .{ .paint_cursors = true };
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(valid)));
}
