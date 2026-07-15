//! Linux DMA-BUF wl_buffer import for CPU-addressable linear images.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");

const wl = wayland.server.wl;
const zwp = wayland.server.zwp;
const log = std.log.scoped(.linux_dmabuf);

const linux = @cImport({
    @cInclude("libdrm/drm_fourcc.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("linux/memfd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
});

const max_planes = 4;
const invalid_modifier: u64 = 0x00ff_ffff_ffff_ffff;
const linear_modifier: u64 = 0;
const argb8888: u32 = linux.DRM_FORMAT_ARGB8888;
const xrgb8888: u32 = linux.DRM_FORMAT_XRGB8888;

pub const Device = linux.dev_t;

pub const CaptureFormat = struct {
    format: u32,
    modifier: u64,
};

pub const capture_formats = [_]CaptureFormat{
    .{ .format = argb8888, .modifier = linear_modifier },
    .{ .format = xrgb8888, .modifier = linear_modifier },
};

allocator: std.mem.Allocator,
io: std.Io,
global: *wl.Global,
feedback_state: ?FeedbackState,
params_count: usize,
buffer_count: usize,
feedback_count: usize,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
) !void {
    const feedback_state = FeedbackState.init(io) catch |err| unavailable: {
        log.info("DMA-BUF feedback unavailable: {t}", .{err});
        break :unavailable null;
    };
    errdefer if (feedback_state) |state| state.file.close(io);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .global = try wl.Global.create(
            display,
            zwp.LinuxDmabufV1,
            if (feedback_state == null) 3 else 6,
            *Self,
            self,
            bind,
        ),
        .feedback_state = feedback_state,
        .params_count = 0,
        .buffer_count = 0,
        .feedback_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.params_count == 0);
    std.debug.assert(self.buffer_count == 0);
    std.debug.assert(self.feedback_count == 0);
    self.global.destroy();
    if (self.feedback_state) |state| state.file.close(self.io);
    self.* = undefined;
}

pub fn allocationDevice(self: *const Self) ?Device {
    return if (self.feedback_state) |state| state.device else null;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = zwp.LinuxDmabufV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
    if (version >= zwp.LinuxDmabufV1.modifier_since_version) {
        resource.sendModifier(argb8888, 0, @intCast(linear_modifier));
        resource.sendModifier(xrgb8888, 0, @intCast(linear_modifier));
    } else {
        resource.sendFormat(argb8888);
        resource.sendFormat(xrgb8888);
    }
}

fn handleRequest(
    resource: *zwp.LinuxDmabufV1,
    request: zwp.LinuxDmabufV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_params => |create| Params.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            create.params_id,
        ) catch resource.postNoMemory(),
        .get_default_feedback => |get| Feedback.create(self, resource, get.id),
        .get_surface_feedback => |get| Feedback.create(self, resource, get.id),
    }
}

const FormatTableEntry = extern struct {
    format: u32,
    padding: u32,
    modifier: u64,
};

const FeedbackState = struct {
    device: linux.dev_t,
    file: std.Io.File,

    fn init(io: std.Io) !FeedbackState {
        const device = findRenderDevice() orelse return error.NoRenderDevice;
        const entries = [_]FormatTableEntry{
            .{ .format = argb8888, .padding = 0, .modifier = linear_modifier },
            .{ .format = xrgb8888, .padding = 0, .modifier = linear_modifier },
        };
        comptime std.debug.assert(@sizeOf(FormatTableEntry) == 16);

        const fd = try std.posix.memfd_create(
            "keywork-dmabuf-formats",
            linux.MFD_CLOEXEC | linux.MFD_ALLOW_SEALING,
        );
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };
        errdefer file.close(io);
        const bytes = std.mem.asBytes(&entries);
        try file.setLength(io, bytes.len);
        try file.writePositionalAll(io, bytes, 0);
        const seals = std.os.linux.F.SEAL_SHRINK | std.os.linux.F.SEAL_GROW |
            std.os.linux.F.SEAL_WRITE | std.os.linux.F.SEAL_SEAL;
        const seal_result = std.os.linux.fcntl(fd, std.os.linux.F.ADD_SEALS, seals);
        if (std.posix.errno(seal_result) != .SUCCESS) return error.SealFailed;
        return .{ .device = device, .file = file };
    }
};

fn findRenderDevice() ?linux.dev_t {
    for (128..192) |minor| {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(
            &path_buffer,
            "/dev/dri/renderD{d}",
            .{minor},
            0,
        ) catch unreachable;
        var stat: linux.struct_stat = undefined;
        if (linux.stat(path.ptr, &stat) < 0) continue;
        if (stat.st_mode & linux.S_IFMT != linux.S_IFCHR) continue;
        return stat.st_rdev;
    }
    return null;
}

const Feedback = struct {
    manager: *Self,

    fn create(manager: *Self, factory: *zwp.LinuxDmabufV1, id: u32) void {
        const state = manager.feedback_state orelse unreachable;
        const resource = zwp.LinuxDmabufFeedbackV1.create(
            factory.getClient(),
            factory.getVersion(),
            id,
        ) catch {
            factory.postNoMemory();
            return;
        };
        const self = manager.allocator.create(Feedback) catch {
            resource.postNoMemory();
            resource.destroy();
            return;
        };
        self.* = .{ .manager = manager };
        manager.feedback_count += 1;
        resource.setHandler(*Feedback, Feedback.handleRequest, Feedback.handleDestroy, self);

        var device = state.device;
        var device_array: wl.Array = .{
            .size = @sizeOf(linux.dev_t),
            .alloc = @sizeOf(linux.dev_t),
            .data = @ptrCast(&device),
        };
        var indices: [2]u16 align(4) = .{ 0, 1 };
        var indices_array: wl.Array = .{
            .size = @sizeOf(@TypeOf(indices)),
            .alloc = @sizeOf(@TypeOf(indices)),
            .data = @ptrCast(&indices),
        };
        resource.sendFormatTable(state.file.handle, 2 * @sizeOf(FormatTableEntry));
        if (resource.getVersion() < 6) resource.sendMainDevice(&device_array);
        resource.sendTrancheTargetDevice(&device_array);
        resource.sendTrancheFlags(if (resource.getVersion() >= 6)
            .{ .sampling = true }
        else
            .{});
        resource.sendTrancheFormats(&indices_array);
        resource.sendTrancheDone();
        resource.sendDone();
    }

    fn handleRequest(
        resource: *zwp.LinuxDmabufFeedbackV1,
        request: zwp.LinuxDmabufFeedbackV1.Request,
        _: *Feedback,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *zwp.LinuxDmabufFeedbackV1, self: *Feedback) void {
        self.manager.feedback_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

const Plane = struct {
    fd: std.posix.fd_t,
    offset: u32,
    stride: u32,
    modifier: u64,

    fn close(self: Plane) void {
        _ = std.c.close(self.fd);
    }
};

const Params = struct {
    manager: *Self,
    resource: *zwp.LinuxBufferParamsV1,
    planes: [max_planes]?Plane,
    sampling_device: ?linux.dev_t,
    used: bool,

    fn create(
        manager: *Self,
        client: *wl.Client,
        version: u32,
        id: u32,
    ) error{ OutOfMemory, ResourceCreateFailed }!void {
        const resource = try zwp.LinuxBufferParamsV1.create(client, version, id);
        errdefer resource.destroy();
        const self = manager.allocator.create(Params) catch return error.OutOfMemory;
        self.* = .{
            .manager = manager,
            .resource = resource,
            .planes = @splat(null),
            .sampling_device = null,
            .used = false,
        };
        manager.params_count += 1;
        resource.setHandler(*Params, Params.handleRequest, Params.handleDestroy, self);
    }

    fn handleRequest(
        resource: *zwp.LinuxBufferParamsV1,
        request: zwp.LinuxBufferParamsV1.Request,
        self: *Params,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .add => |add| self.addPlane(resource, .{
                .fd = add.fd,
                .offset = add.offset,
                .stride = add.stride,
                .modifier = @as(u64, add.modifier_hi) << 32 | add.modifier_lo,
            }, add.plane_idx),
            .create => |create_request| self.createBuffer(
                create_request.width,
                create_request.height,
                create_request.format,
                create_request.flags,
                null,
            ),
            .create_immed => |create_request| self.createBuffer(
                create_request.width,
                create_request.height,
                create_request.format,
                create_request.flags,
                create_request.buffer_id,
            ),
            .set_sampling_device => |set| self.setSamplingDevice(resource, set.device),
        }
    }

    fn setSamplingDevice(
        self: *Params,
        resource: *zwp.LinuxBufferParamsV1,
        array: *wl.Array,
    ) void {
        if (self.used) {
            resource.postError(.already_used, "buffer parameters were already used");
            return;
        }
        self.sampling_device = deviceFromArray(array) catch {
            resource.postError(.invalid_dev_t_size, "sampling device has invalid size");
            return;
        };
    }

    fn addPlane(
        self: *Params,
        resource: *zwp.LinuxBufferParamsV1,
        plane: Plane,
        index: u32,
    ) void {
        if (self.used) {
            plane.close();
            resource.postError(.already_used, "buffer parameters were already used");
            return;
        }
        if (index >= max_planes) {
            plane.close();
            resource.postError(.plane_idx, "DMA-BUF plane index is out of bounds");
            return;
        }
        if (self.planes[index] != null) {
            plane.close();
            resource.postError(.plane_set, "DMA-BUF plane was already set");
            return;
        }
        self.planes[index] = plane;
    }

    fn createBuffer(
        self: *Params,
        width: i32,
        height: i32,
        format: u32,
        flags: zwp.LinuxBufferParamsV1.Flags,
        immediate_id: ?u32,
    ) void {
        if (self.used) {
            self.resource.postError(.already_used, "buffer parameters were already used");
            return;
        }
        self.used = true;

        const descriptor = validateDescriptor(
            self.planes,
            width,
            height,
            format,
            flags,
            self.resource.getVersion() < 3,
        ) catch |err| {
            switch (err) {
                error.Incomplete => self.resource.postError(
                    .incomplete,
                    "DMA-BUF requires exactly one plane",
                ),
                error.InvalidFormat => self.resource.postError(
                    .invalid_format,
                    "unsupported DMA-BUF format or modifier",
                ),
                error.InvalidDimensions => self.resource.postError(
                    .invalid_dimensions,
                    "DMA-BUF dimensions are invalid",
                ),
                error.OutOfBounds => self.resource.postError(
                    .out_of_bounds,
                    "DMA-BUF plane does not contain the requested image",
                ),
                error.ImportFailed => self.importFailed(immediate_id),
            }
            return;
        };
        if (self.sampling_device) |device| {
            if (device != self.manager.feedback_state.?.device) {
                self.importFailed(immediate_id);
                return;
            }
        }
        if (descriptor.plane.modifier == invalid_modifier) {
            log.warn("assuming a legacy implicit DMA-BUF has linear layout", .{});
        }

        const buffer = Buffer.create(
            self.manager,
            self.resource.getClient(),
            immediate_id orelse 0,
            descriptor,
        ) catch {
            self.resource.postNoMemory();
            return;
        };
        self.planes[0] = null;
        if (immediate_id == null) self.resource.sendCreated(buffer.resource);
    }

    fn importFailed(self: *Params, immediate_id: ?u32) void {
        if (immediate_id == null) {
            self.resource.sendFailed();
        } else {
            self.resource.postError(.invalid_wl_buffer, "DMA-BUF import failed");
        }
    }

    fn handleDestroy(_: *zwp.LinuxBufferParamsV1, self: *Params) void {
        for (self.planes) |plane| if (plane) |value| value.close();
        self.manager.params_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn deviceFromArray(array: *const wl.Array) error{InvalidSize}!linux.dev_t {
    if (array.size != @sizeOf(linux.dev_t)) return error.InvalidSize;
    const data = array.data orelse return error.InvalidSize;
    const bytes: [*]const u8 = @ptrCast(data);
    var device: linux.dev_t = undefined;
    @memcpy(std.mem.asBytes(&device), bytes[0..@sizeOf(linux.dev_t)]);
    return device;
}

const Descriptor = struct {
    plane: Plane,
    size: render.Size,
    format: u32,
    y_inverted: bool,
    required_bytes: usize,
};

const DescriptorError = error{
    Incomplete,
    InvalidFormat,
    InvalidDimensions,
    OutOfBounds,
    ImportFailed,
};

fn validateDescriptor(
    planes: [max_planes]?Plane,
    width: i32,
    height: i32,
    format: u32,
    flags: zwp.LinuxBufferParamsV1.Flags,
    allow_implicit_modifier: bool,
) DescriptorError!Descriptor {
    if (planes[0] == null) return error.Incomplete;
    for (planes[1..]) |plane| if (plane != null) return error.Incomplete;
    if (width <= 0 or height <= 0) return error.InvalidDimensions;
    if (format != argb8888 and format != xrgb8888) return error.InvalidFormat;

    const plane = planes[0].?;
    if (plane.modifier != linear_modifier and
        !(allow_implicit_modifier and plane.modifier == invalid_modifier))
    {
        return error.InvalidFormat;
    }
    const flag_bits: u32 = @bitCast(flags);
    if (flag_bits & ~@as(u32, 7) != 0 or flags.interlaced or flags.bottom_first) {
        return error.ImportFailed;
    }

    const size: render.Size = .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
    const row_bytes = std.math.mul(u64, size.width, @sizeOf(u32)) catch
        return error.OutOfBounds;
    if (plane.stride < row_bytes) return error.OutOfBounds;
    const row_offset = std.math.mul(u64, size.height - 1, plane.stride) catch
        return error.OutOfBounds;
    const required_bytes_u64 = std.math.add(u64, plane.offset, row_offset) catch
        return error.OutOfBounds;
    const required_end = std.math.add(u64, required_bytes_u64, row_bytes) catch
        return error.OutOfBounds;
    if (required_end == 0 or required_end > std.math.maxInt(usize)) return error.OutOfBounds;

    const fd_size = std.c.lseek(plane.fd, 0, std.c.SEEK.END);
    if (fd_size < 0) return error.ImportFailed;
    if (required_end > @as(u64, @intCast(fd_size))) return error.OutOfBounds;

    if (!syncDmaBuf(plane.fd, linux.DMA_BUF_SYNC_READ)) return error.ImportFailed;
    const mapping = std.posix.mmap(
        null,
        @intCast(required_end),
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        plane.fd,
        0,
    ) catch {
        _ = syncDmaBuf(plane.fd, linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END);
        return error.ImportFailed;
    };
    std.posix.munmap(mapping);
    if (!syncDmaBuf(plane.fd, linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END)) {
        return error.ImportFailed;
    }

    return .{
        .plane = plane,
        .size = size,
        .format = format,
        .y_inverted = flags.y_invert,
        .required_bytes = @intCast(required_end),
    };
}

pub const Buffer = struct {
    manager: *Self,
    resource: *wl.Buffer,
    descriptor: Descriptor,

    pub const CopyError = error{
        OutOfMemory,
        ImportFailed,
    };

    fn create(
        manager: *Self,
        client: *wl.Client,
        id: u32,
        descriptor: Descriptor,
    ) error{ OutOfMemory, ResourceCreateFailed }!*Buffer {
        const resource = try wl.Buffer.create(client, 1, id);
        errdefer resource.destroy();
        const self = manager.allocator.create(Buffer) catch return error.OutOfMemory;
        self.* = .{
            .manager = manager,
            .resource = resource,
            .descriptor = descriptor,
        };
        manager.buffer_count += 1;
        resource.setHandler(*Buffer, Buffer.handleRequest, Buffer.handleDestroy, self);
        return self;
    }

    pub fn fromResource(resource: *wl.Buffer) ?*Buffer {
        const raw_resource: *wl.Resource = @ptrCast(resource);
        if (wl_resource_instance_of(
            raw_resource,
            @ptrCast(wl.Buffer.interface),
            @ptrCast(&Buffer.handleRequest),
        ) == 0) return null;
        return @ptrCast(@alignCast(resource.getUserData().?));
    }

    pub fn size(self: *const Buffer) render.Size {
        return self.descriptor.size;
    }

    pub fn copyPixels(
        self: *const Buffer,
        allocator: std.mem.Allocator,
    ) CopyError![]u32 {
        const descriptor = self.descriptor;
        const pixels = allocator.alloc(
            u32,
            descriptor.size.pixelCount() catch return error.ImportFailed,
        ) catch return error.OutOfMemory;
        errdefer allocator.free(pixels);

        const mapping = std.posix.mmap(
            null,
            descriptor.required_bytes,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            descriptor.plane.fd,
            0,
        ) catch return error.ImportFailed;
        defer std.posix.munmap(mapping);

        if (!syncDmaBuf(descriptor.plane.fd, linux.DMA_BUF_SYNC_READ)) {
            return error.ImportFailed;
        }
        defer {
            _ = syncDmaBuf(
                descriptor.plane.fd,
                linux.DMA_BUF_SYNC_READ | linux.DMA_BUF_SYNC_END,
            );
        }

        const destination = std.mem.sliceAsBytes(pixels);
        const row_bytes = @as(usize, descriptor.size.width) * @sizeOf(u32);
        for (0..descriptor.size.height) |destination_y| {
            const source_y = if (descriptor.y_inverted)
                descriptor.size.height - destination_y - 1
            else
                destination_y;
            const source_offset = @as(usize, descriptor.plane.offset) +
                source_y * descriptor.plane.stride;
            const destination_offset = destination_y * row_bytes;
            @memcpy(
                destination[destination_offset..][0..row_bytes],
                mapping[source_offset..][0..row_bytes],
            );
        }
        if (descriptor.format == xrgb8888) {
            for (pixels) |*pixel| pixel.* |= 0xff00_0000;
        }
        return pixels;
    }

    pub fn copyFromPixels(
        self: *const Buffer,
        source: render.PixelBuffer,
    ) CopyError!void {
        const descriptor = self.descriptor;
        if (!std.meta.eql(source.size, descriptor.size) or
            source.stride_pixels < source.size.width) return error.ImportFailed;
        const source_row_offset = std.math.mul(
            usize,
            source.size.height - 1,
            source.stride_pixels,
        ) catch return error.ImportFailed;
        const required_pixels = std.math.add(
            usize,
            source_row_offset,
            source.size.width,
        ) catch return error.ImportFailed;
        if (source.pixels.len < required_pixels) return error.ImportFailed;

        const mapping = std.posix.mmap(
            null,
            descriptor.required_bytes,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            descriptor.plane.fd,
            0,
        ) catch return error.ImportFailed;
        defer std.posix.munmap(mapping);

        if (!syncDmaBuf(descriptor.plane.fd, linux.DMA_BUF_SYNC_WRITE)) {
            return error.ImportFailed;
        }
        const source_bytes = std.mem.sliceAsBytes(source.pixels);
        const row_bytes = @as(usize, descriptor.size.width) * @sizeOf(u32);
        for (0..descriptor.size.height) |source_y| {
            const destination_y = if (descriptor.y_inverted)
                descriptor.size.height - source_y - 1
            else
                source_y;
            const source_offset = source_y * source.stride_pixels * @sizeOf(u32);
            const destination_offset = @as(usize, descriptor.plane.offset) +
                destination_y * descriptor.plane.stride;
            @memcpy(
                mapping[destination_offset..][0..row_bytes],
                source_bytes[source_offset..][0..row_bytes],
            );
        }
        if (!syncDmaBuf(
            descriptor.plane.fd,
            linux.DMA_BUF_SYNC_WRITE | linux.DMA_BUF_SYNC_END,
        )) return error.ImportFailed;
    }

    fn handleRequest(resource: *wl.Buffer, request: wl.Buffer.Request, _: *Buffer) void {
        switch (request) {
            .destroy => resource.destroy(),
        }
    }

    fn handleDestroy(_: *wl.Buffer, self: *Buffer) void {
        self.descriptor.plane.close();
        self.manager.buffer_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn syncDmaBuf(fd: std.posix.fd_t, flags: u64) bool {
    while (true) {
        var sync: linux.dma_buf_sync = .{ .flags = flags };
        const result = linux.ioctl(fd, linux.DMA_BUF_IOCTL_SYNC, &sync);
        if (result >= 0) return true;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

extern fn wl_resource_instance_of(
    resource: *wl.Resource,
    interface: *const anyopaque,
    implementation: *const anyopaque,
) c_int;

test "DMA-BUF descriptor rejects malformed and unsupported layouts before import" {
    const no_flags: zwp.LinuxBufferParamsV1.Flags = @bitCast(@as(u32, 0));
    const linear_plane: Plane = .{
        .fd = -1,
        .offset = 0,
        .stride = 8,
        .modifier = linear_modifier,
    };
    var planes: [max_planes]?Plane = @splat(null);

    try std.testing.expectError(
        error.Incomplete,
        validateDescriptor(planes, 2, 2, argb8888, no_flags, false),
    );
    planes[0] = linear_plane;
    try std.testing.expectError(
        error.InvalidDimensions,
        validateDescriptor(planes, 0, 2, argb8888, no_flags, false),
    );

    planes[0].?.stride = 4;
    try std.testing.expectError(
        error.OutOfBounds,
        validateDescriptor(planes, 2, 2, argb8888, no_flags, false),
    );
    planes[0].?.stride = 8;
    planes[0].?.modifier = 1;
    try std.testing.expectError(
        error.InvalidFormat,
        validateDescriptor(planes, 2, 2, argb8888, no_flags, false),
    );

    planes[0].?.modifier = linear_modifier;
    const interlaced: zwp.LinuxBufferParamsV1.Flags = @bitCast(@as(u32, 2));
    try std.testing.expectError(
        error.ImportFailed,
        validateDescriptor(planes, 2, 2, argb8888, interlaced, false),
    );
}

test "DMA-BUF sampling device arrays use native dev_t representation" {
    var device: linux.dev_t = 0x1234;
    var array: wl.Array = .{
        .size = @sizeOf(linux.dev_t),
        .alloc = @sizeOf(linux.dev_t),
        .data = @ptrCast(&device),
    };
    try std.testing.expectEqual(device, try deviceFromArray(&array));

    array.size -= 1;
    try std.testing.expectError(error.InvalidSize, deviceFromArray(&array));
}
