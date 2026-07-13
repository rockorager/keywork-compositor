//! Server-side wl_surface state and shared-memory buffer snapshots.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Region = @import("region.zig");
const render_types = @import("render.zig");
const WaylandRegion = @import("wayland_region.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
resource: *wl.Surface,
pending_attachment: Attachment,
has_pending_attachment: bool,
pending_offset_x: i32,
pending_offset_y: i32,
current_offset_x: i32,
current_offset_y: i32,
pending_scale: i32,
current_scale: i32,
pending_transform: wl.Output.Transform,
current_transform: wl.Output.Transform,
pending_surface_damage: Region,
pending_buffer_damage: Region,
pending_opaque: Region,
current_opaque: Region,
pending_input: InputRegion,
current_input: InputRegion,
callbacks: std.ArrayList(*FrameCallback),
current_buffer: ?BufferSnapshot,

pub const CreateError = error{
    OutOfMemory,
    ResourceCreateFailed,
};

pub fn create(
    allocator: std.mem.Allocator,
    client: *wl.Client,
    version: u32,
    id: u32,
) CreateError!void {
    const resource = try wl.Surface.create(client, version, id);
    errdefer resource.destroy();

    const self = allocator.create(Self) catch return error.OutOfMemory;
    self.* = .{
        .allocator = allocator,
        .resource = resource,
        .pending_attachment = .{},
        .has_pending_attachment = false,
        .pending_offset_x = 0,
        .pending_offset_y = 0,
        .current_offset_x = 0,
        .current_offset_y = 0,
        .pending_scale = 1,
        .current_scale = 1,
        .pending_transform = .normal,
        .current_transform = .normal,
        .pending_surface_damage = Region.init(),
        .pending_buffer_damage = Region.init(),
        .pending_opaque = Region.init(),
        .current_opaque = Region.init(),
        .pending_input = InputRegion.init(),
        .current_input = InputRegion.init(),
        .callbacks = .empty,
        .current_buffer = null,
    };

    resource.setHandler(*Self, handleRequest, handleDestroy, self);
}

pub fn fromResource(resource: *wl.Surface) *Self {
    return @ptrCast(@alignCast(resource.getUserData().?));
}

pub fn sendFrameDone(self: *Self, time_milliseconds: u32) void {
    while (true) {
        const callback = for (self.callbacks.items) |candidate| {
            if (!candidate.pending) break candidate;
        } else return;

        callback.resource.destroySendDone(time_milliseconds);
    }
}

fn handleRequest(resource: *wl.Surface, request: wl.Surface.Request, self: *Self) void {
    switch (request) {
        .destroy => resource.destroy(),
        .attach => |attach| {
            self.pending_attachment.set(attach.buffer) catch {
                resource.getClient().postImplementationError("unsupported wl_buffer type");
                return;
            };
            self.has_pending_attachment = true;
            self.pending_offset_x = attach.x;
            self.pending_offset_y = attach.y;
        },
        .damage => |damage| self.pending_surface_damage.add(
            damage.x,
            damage.y,
            damage.width,
            damage.height,
        ) catch resource.postNoMemory(),
        .frame => |frame| createFrameCallback(self, frame.callback) catch
            resource.postNoMemory(),
        .set_opaque_region => |set| {
            if (set.region) |region_resource| {
                const region = WaylandRegion.fromResource(region_resource);
                self.pending_opaque.copyFrom(&region.value) catch {
                    resource.postNoMemory();
                    return;
                };
            } else {
                self.pending_opaque.clear();
            }
        },
        .set_input_region => |set| {
            if (set.region) |region_resource| {
                const region = WaylandRegion.fromResource(region_resource);
                self.pending_input.set(&region.value) catch {
                    resource.postNoMemory();
                    return;
                };
            } else {
                self.pending_input.setInfinite();
            }
        },
        .commit => commit(self),
        .set_buffer_transform => |set| {
            if (!validTransform(set.transform)) {
                resource.postError(.invalid_transform, "invalid buffer transform");
                return;
            }
            self.pending_transform = set.transform;
        },
        .set_buffer_scale => |set| {
            if (set.scale <= 0) {
                resource.postError(.invalid_scale, "buffer scale must be positive");
                return;
            }
            self.pending_scale = set.scale;
        },
        .damage_buffer => |damage| self.pending_buffer_damage.add(
            damage.x,
            damage.y,
            damage.width,
            damage.height,
        ) catch resource.postNoMemory(),
    }
}

fn commit(self: *Self) void {
    self.current_opaque.copyFrom(&self.pending_opaque) catch {
        self.resource.postNoMemory();
        return;
    };
    self.current_input.copyFrom(&self.pending_input) catch {
        self.resource.postNoMemory();
        return;
    };

    if (self.has_pending_attachment) {
        var snapshot: ?BufferSnapshot = null;
        if (self.pending_attachment.shm) |shm_buffer| {
            snapshot = BufferSnapshot.copyShm(
                self.allocator,
                shm_buffer,
                self.pending_scale,
                self.pending_transform,
            ) catch |err| {
                switch (err) {
                    error.OutOfMemory => self.resource.postNoMemory(),
                    error.InvalidSize => self.resource.postError(
                        .invalid_size,
                        "buffer dimensions are incompatible with surface state",
                    ),
                    error.InvalidBuffer => self.resource.getClient().postImplementationError(
                        "invalid shared-memory buffer",
                    ),
                }
                return;
            };
        }

        if (self.current_buffer) |*current| current.deinit();
        self.current_buffer = snapshot;
        self.current_offset_x = self.pending_offset_x;
        self.current_offset_y = self.pending_offset_y;

        if (self.pending_attachment.resource) |buffer| buffer.sendRelease();
        self.pending_attachment.clear();
        self.has_pending_attachment = false;
    } else if (self.current_buffer) |*current| {
        current.logical_size = logicalSize(
            current.buffer_size,
            self.pending_scale,
            self.pending_transform,
        ) catch {
            self.resource.postError(
                .invalid_size,
                "buffer dimensions are incompatible with surface state",
            );
            return;
        };
        current.scale = self.pending_scale;
        current.transform = self.pending_transform;
    }

    self.current_scale = self.pending_scale;
    self.current_transform = self.pending_transform;
    self.pending_surface_damage.clear();
    self.pending_buffer_damage.clear();
    for (self.callbacks.items) |callback| callback.pending = false;
}

fn handleDestroy(_: *wl.Surface, self: *Self) void {
    self.pending_attachment.clear();
    if (self.current_buffer) |*current| current.deinit();

    while (self.callbacks.items.len > 0) {
        self.callbacks.items[self.callbacks.items.len - 1].resource.destroy();
    }
    self.callbacks.deinit(self.allocator);

    self.pending_surface_damage.deinit();
    self.pending_buffer_damage.deinit();
    self.pending_opaque.deinit();
    self.current_opaque.deinit();
    self.pending_input.deinit();
    self.current_input.deinit();
    self.allocator.destroy(self);
}

fn validTransform(transform: wl.Output.Transform) bool {
    return switch (transform) {
        .normal,
        .@"90",
        .@"180",
        .@"270",
        .flipped,
        .flipped_90,
        .flipped_180,
        .flipped_270,
        => true,
        else => false,
    };
}

fn swapsAxes(transform: wl.Output.Transform) bool {
    return switch (transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
}

fn logicalSize(
    buffer_size: render_types.Size,
    scale: i32,
    transform: wl.Output.Transform,
) error{InvalidSize}!render_types.Size {
    if (scale <= 0 or !validTransform(transform)) return error.InvalidSize;

    const transformed: render_types.Size = if (swapsAxes(transform))
        .{ .width = buffer_size.height, .height = buffer_size.width }
    else
        buffer_size;
    const unsigned_scale: u32 = @intCast(scale);
    if (transformed.width % unsigned_scale != 0 or
        transformed.height % unsigned_scale != 0) return error.InvalidSize;

    return .{
        .width = transformed.width / unsigned_scale,
        .height = transformed.height / unsigned_scale,
    };
}

const InputRegion = struct {
    infinite: bool,
    value: Region,

    fn init() InputRegion {
        return .{ .infinite = true, .value = Region.init() };
    }

    fn deinit(self: *InputRegion) void {
        self.value.deinit();
        self.* = undefined;
    }

    fn set(self: *InputRegion, region: *const Region) Region.Error!void {
        try self.value.copyFrom(region);
        self.infinite = false;
    }

    fn setInfinite(self: *InputRegion) void {
        self.value.clear();
        self.infinite = true;
    }

    fn copyFrom(self: *InputRegion, other: *const InputRegion) Region.Error!void {
        try self.value.copyFrom(&other.value);
        self.infinite = other.infinite;
    }
};

const Attachment = struct {
    resource: ?*wl.Buffer = null,
    shm: ?*wl.shm.Buffer = null,
    destroy_listener: wl.Listener(*wl.Resource) = undefined,

    const Error = error{UnsupportedBuffer};

    fn set(self: *Attachment, resource: ?*wl.Buffer) Error!void {
        self.clear();
        const buffer = resource orelse return;
        const shm_buffer = wl.shm.Buffer.get(@ptrCast(buffer)) orelse
            return error.UnsupportedBuffer;

        self.resource = buffer;
        self.shm = wl_shm_buffer_ref(shm_buffer);
        self.destroy_listener = wl.Listener(*wl.Resource).init(handleResourceDestroy);
        @as(*wl.Resource, @ptrCast(buffer)).addDestroyListener(&self.destroy_listener);
    }

    fn clear(self: *Attachment) void {
        if (self.resource != null) self.destroy_listener.link.remove();
        if (self.shm) |buffer| wl_shm_buffer_unref(buffer);
        self.resource = null;
        self.shm = null;
    }

    fn handleResourceDestroy(
        listener: *wl.Listener(*wl.Resource),
        _: *wl.Resource,
    ) void {
        const self: *Attachment = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        self.resource = null;
    }
};

pub const BufferSnapshot = struct {
    allocator: std.mem.Allocator,
    buffer_size: render_types.Size,
    logical_size: render_types.Size,
    scale: i32,
    transform: wl.Output.Transform,
    pixels: []u32,

    const Error = error{
        OutOfMemory,
        InvalidSize,
        InvalidBuffer,
    };

    fn copyShm(
        allocator: std.mem.Allocator,
        shm_buffer: *wl.shm.Buffer,
        scale: i32,
        transform: wl.Output.Transform,
    ) Error!BufferSnapshot {
        const width = shm_buffer.getWidth();
        const height = shm_buffer.getHeight();
        const stride = shm_buffer.getStride();
        if (width <= 0 or height <= 0 or stride <= 0) return error.InvalidBuffer;

        const buffer_size: render_types.Size = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
        const logical_size = logicalSize(buffer_size, scale, transform) catch
            return error.InvalidSize;
        const row_bytes = std.math.mul(usize, buffer_size.width, @sizeOf(u32)) catch
            return error.InvalidBuffer;
        if (stride < row_bytes) return error.InvalidBuffer;

        const format = shm_buffer.getFormat();
        const argb8888: u32 = @intCast(@intFromEnum(wl.Shm.Format.argb8888));
        const xrgb8888: u32 = @intCast(@intFromEnum(wl.Shm.Format.xrgb8888));
        if (format != argb8888 and format != xrgb8888) return error.InvalidBuffer;

        const pixel_count = buffer_size.pixelCount() catch return error.InvalidBuffer;
        const pixels = allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
        errdefer allocator.free(pixels);

        shm_buffer.beginAccess();
        defer shm_buffer.endAccess();
        const data = shm_buffer.getData() orelse return error.InvalidBuffer;
        const source: [*]const u8 = @ptrCast(data);
        const destination = std.mem.sliceAsBytes(pixels);
        const source_stride: usize = @intCast(stride);
        for (0..buffer_size.height) |y| {
            const source_offset = y * source_stride;
            const destination_offset = y * row_bytes;
            @memcpy(
                destination[destination_offset..][0..row_bytes],
                source[source_offset..][0..row_bytes],
            );
        }

        if (format == xrgb8888) {
            for (pixels) |*pixel| pixel.* |= 0xff000000;
        }

        return .{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .logical_size = logical_size,
            .scale = scale,
            .transform = transform,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *BufferSnapshot) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn pixelBuffer(self: *BufferSnapshot) render_types.PixelBuffer {
        return .{
            .size = self.buffer_size,
            .stride_pixels = self.buffer_size.width,
            .pixels = self.pixels,
        };
    }
};

const FrameCallback = struct {
    surface: *Self,
    resource: *wl.Callback,
    pending: bool,

    fn handleDestroy(resource: *wl.Resource) callconv(.c) void {
        const self: *FrameCallback = @ptrCast(@alignCast(resource.getUserData().?));
        self.surface.removeCallback(self);
        self.surface.allocator.destroy(self);
    }
};

fn createFrameCallback(self: *Self, id: u32) error{OutOfMemory}!void {
    const resource = wl.Callback.create(self.resource.getClient(), 1, id) catch
        return error.OutOfMemory;
    errdefer resource.destroy();

    const callback = self.allocator.create(FrameCallback) catch return error.OutOfMemory;
    errdefer self.allocator.destroy(callback);
    callback.* = .{
        .surface = self,
        .resource = resource,
        .pending = true,
    };
    try self.callbacks.append(self.allocator, callback);

    @as(*wl.Resource, @ptrCast(resource)).setDispatcher(
        null,
        null,
        callback,
        FrameCallback.handleDestroy,
    );
}

fn removeCallback(self: *Self, callback: *FrameCallback) void {
    for (self.callbacks.items, 0..) |candidate, index| {
        if (candidate == callback) {
            _ = self.callbacks.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

extern fn wl_shm_buffer_ref(buffer: *wl.shm.Buffer) *wl.shm.Buffer;
extern fn wl_shm_buffer_unref(buffer: *wl.shm.Buffer) void;

test "logical surface size accounts for scale and transform" {
    try std.testing.expectEqual(
        render_types.Size{ .width = 100, .height = 50 },
        try logicalSize(.{ .width = 200, .height = 100 }, 2, .normal),
    );
    try std.testing.expectEqual(
        render_types.Size{ .width = 50, .height = 100 },
        try logicalSize(.{ .width = 200, .height = 100 }, 2, .@"90"),
    );
    try std.testing.expectError(
        error.InvalidSize,
        logicalSize(.{ .width = 201, .height = 100 }, 2, .normal),
    );
}
