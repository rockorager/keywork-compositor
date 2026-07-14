//! Native DRM/KMS output using CPU-mapped dumb buffers.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Session = @import("session.zig");
const NestedOutput = @import("nested_wayland.zig");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});
const wl = wayland.server.wl;

const log = std.log.scoped(.drm);
const buffer_count = 2;
const default_device_path = "/dev/dri/card0";

allocator: std.mem.Allocator,
io: std.Io,
session: *Session,
session_listener: Session.Listener,
event_loop: *wl.EventLoop,
event_source: ?*wl.EventSource,
listener: Listener,
device_path: [:0]u8,
device: ?Session.Device,
old_crtc: ?*c.drmModeCrtc,
buffers: [buffer_count]Buffer,
mode: c.drmModeModeInfo,
size: render.Size,
physical_size: render.Size,
connector_id: u32,
crtc_id: u32,
connector_name: [32]u8,
connector_name_length: usize,
refresh_nanoseconds: u32,
presentation_clock_id: u32,
acquired: ?usize,
pending: ?usize,
displayed: ?usize,
mode_set: bool,
initialized: bool,
failed: bool,

pub const Listener = NestedOutput.Listener;

const Buffer = struct {
    handle: u32 = 0,
    framebuffer_id: u32 = 0,
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    pixels: []u32 = &.{},
    stride_pixels: u32 = 0,
};

const Selection = struct {
    mode: c.drmModeModeInfo,
    size: render.Size,
    physical_size: render.Size,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    crtc_id: u32,
};

const event_context: c.drmEventContext = .{
    .version = 2,
    .vblank_handler = null,
    .page_flip_handler = handlePageFlip,
    .page_flip_handler2 = null,
    .sequence_handler = null,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    event_loop: *wl.EventLoop,
    session: *Session,
    device_path: ?[]const u8,
    listener: Listener,
) !void {
    const path = try allocator.dupeSentinel(
        u8,
        device_path orelse default_device_path,
        0,
    );
    errdefer allocator.free(path);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .session = session,
        .session_listener = .{
            .context = self,
            .activated = handleSessionActivated,
            .deactivated = handleSessionDeactivated,
            .failed = handleSessionFailed,
        },
        .event_loop = event_loop,
        .event_source = null,
        .listener = listener,
        .device_path = path,
        .device = null,
        .old_crtc = null,
        .buffers = .{ .{}, .{} },
        .mode = std.mem.zeroes(c.drmModeModeInfo),
        .size = .{ .width = 0, .height = 0 },
        .physical_size = .{ .width = 0, .height = 0 },
        .connector_id = 0,
        .crtc_id = 0,
        .connector_name = undefined,
        .connector_name_length = 0,
        .refresh_nanoseconds = presentation.nominal_refresh_nanoseconds,
        .presentation_clock_id = presentation.monotonic_clock_id,
        .acquired = null,
        .pending = null,
        .displayed = null,
        .mode_set = false,
        .initialized = false,
        .failed = false,
    };
    try session.addListener(&self.session_listener);
    errdefer session.removeListener(&self.session_listener);
    if (!session.isActive()) return error.SessionInactive;
    if (self.failed or self.device == null) return error.DrmInitializationFailed;
    self.initialized = true;
}

pub fn deinit(self: *Self) void {
    self.initialized = false;
    self.session.removeListener(&self.session_listener);
    self.deactivate();
    self.allocator.free(self.device_path);
    self.* = undefined;
}

pub fn name(self: *const Self) []const u8 {
    return self.connector_name[0..self.connector_name_length];
}

pub fn ready(self: *const Self) bool {
    if (self.failed or !self.session.isActive() or
        self.acquired != null or self.pending != null) return false;
    return self.availableBuffer() != null;
}

pub fn acquire(self: *Self) ?render.PixelBuffer {
    std.debug.assert(self.acquired == null);
    if (!self.ready()) return null;
    const index = self.availableBuffer().?;
    const buffer = &self.buffers[index];
    self.acquired = index;
    return .{
        .size = self.size,
        .stride_pixels = buffer.stride_pixels,
        .pixels = buffer.pixels,
    };
}

pub fn cancel(self: *Self) void {
    self.acquired = null;
}

pub fn present(self: *Self) !?presentation.Info {
    const index = self.acquired orelse return error.NoAcquiredBuffer;
    const device = self.device orelse return error.SessionInactive;
    if (!self.session.isActive() or self.failed) return error.SessionInactive;
    const buffer = &self.buffers[index];

    if (!self.mode_set) {
        var connector_id = self.connector_id;
        if (c.drmModeSetCrtc(
            device.fd,
            self.crtc_id,
            buffer.framebuffer_id,
            0,
            0,
            &connector_id,
            1,
            &self.mode,
        ) != 0) return error.ModeSetFailed;
        self.mode_set = true;
        self.displayed = index;
        self.acquired = null;
        const clock: std.Io.Clock = if (self.presentation_clock_id ==
            presentation.monotonic_clock_id) .awake else .real;
        return .{
            .timestamp = .fromNanoseconds(clock.now(self.io).nanoseconds),
            .refresh_nanoseconds = self.refresh_nanoseconds,
            .flags = .{ .zero_copy = true },
        };
    }

    if (c.drmModePageFlip(
        device.fd,
        self.crtc_id,
        buffer.framebuffer_id,
        c.DRM_MODE_PAGE_FLIP_EVENT,
        self,
    ) != 0) return error.PageFlipFailed;
    self.pending = index;
    self.acquired = null;
    return null;
}

fn activate(self: *Self) !void {
    std.debug.assert(self.device == null);
    const device = try self.session.openDevice(self.device_path);
    self.device = device;
    errdefer {
        self.session.closeDevice(device) catch {};
        self.device = null;
    }
    if (c.drmIsKMS(device.fd) != 1) return error.NotKmsDevice;

    const selection = try selectOutput(device.fd);
    if (self.size.width != 0 and (!std.meta.eql(self.size, selection.size) or
        self.connector_id != selection.connector_id or self.crtc_id != selection.crtc_id))
    {
        return error.OutputChanged;
    }
    self.mode = selection.mode;
    self.size = selection.size;
    self.physical_size = selection.physical_size;
    self.connector_id = selection.connector_id;
    self.crtc_id = selection.crtc_id;
    const connector_type = c.drmModeGetConnectorTypeName(selection.connector_type);
    const type_name = if (connector_type == null) "Unknown" else std.mem.span(connector_type);
    const name_value = try std.fmt.bufPrint(
        &self.connector_name,
        "{s}-{d}",
        .{ type_name, selection.connector_type_id },
    );
    self.connector_name_length = name_value.len;
    self.refresh_nanoseconds = refreshNanoseconds(self.mode);

    var monotonic: u64 = 0;
    if (c.drmGetCap(device.fd, c.DRM_CAP_TIMESTAMP_MONOTONIC, &monotonic) == 0 and
        monotonic != 0)
    {
        self.presentation_clock_id = presentation.monotonic_clock_id;
    } else {
        self.presentation_clock_id = @intCast(@intFromEnum(std.posix.CLOCK.REALTIME));
    }

    self.old_crtc = c.drmModeGetCrtc(device.fd, self.crtc_id);
    if (self.old_crtc == null) return error.GetCrtcFailed;
    errdefer {
        c.drmModeFreeCrtc(self.old_crtc.?);
        self.old_crtc = null;
    }

    errdefer for (&self.buffers) |*buffer| destroyBuffer(device.fd, buffer);
    for (&self.buffers) |*buffer| {
        try createBuffer(device.fd, self.size, buffer);
    }

    self.event_source = try self.event_loop.addFd(
        *Self,
        device.fd,
        .{ .readable = true },
        handleDrmEvent,
        self,
    );
}

fn deactivate(self: *Self) void {
    if (self.event_source) |source| {
        source.remove();
        self.event_source = null;
    }
    const device = self.device orelse return;
    if (self.mode_set) restoreCrtc(device.fd, self.connector_id, self.old_crtc.?);
    self.mode_set = false;
    self.acquired = null;
    self.pending = null;
    self.displayed = null;
    for (&self.buffers) |*buffer| destroyBuffer(device.fd, buffer);
    if (self.old_crtc) |old_crtc| {
        c.drmModeFreeCrtc(old_crtc);
        self.old_crtc = null;
    }
    self.session.closeDevice(device) catch |err| {
        log.err("failed to close DRM device: {t}", .{err});
    };
    self.device = null;
}

fn fail(self: *Self, err: anyerror) void {
    if (self.failed) return;
    self.failed = true;
    log.err("DRM output failed: {t}", .{err});
    if (self.pending != null) self.listener.discarded(self.listener.context);
    self.deactivate();
    if (self.initialized) self.listener.close(self.listener.context);
}

fn availableBuffer(self: *const Self) ?usize {
    for (0..buffer_count) |index| {
        if (self.displayed == index or self.pending == index) continue;
        return index;
    }
    return null;
}

fn handleSessionActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.failed) return;
    self.activate() catch |err| {
        self.fail(err);
        return;
    };
    if (self.initialized) self.listener.ready(self.listener.context);
}

fn handleSessionDeactivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.listener.discarded(self.listener.context);
    self.deactivate();
}

fn handleSessionFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.fail(error.SessionFailed);
}

fn handleDrmEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.hangup or mask.@"error") {
        self.fail(error.DeviceDisconnected);
        return 0;
    }
    if (mask.readable) {
        var context = event_context;
        if (c.drmHandleEvent(self.device.?.fd, &context) != 0) {
            self.fail(error.EventDispatchFailed);
        }
    }
    return 0;
}

fn handlePageFlip(
    _: c_int,
    sequence: c_uint,
    seconds: c_uint,
    microseconds: c_uint,
    data: ?*anyopaque,
) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const pending = self.pending orelse {
        self.fail(error.UnexpectedPageFlip);
        return;
    };
    self.displayed = pending;
    self.pending = null;
    self.listener.presented(self.listener.context, .{
        .timestamp = .{
            .seconds = seconds,
            .nanoseconds = microseconds * std.time.ns_per_us,
        },
        .refresh_nanoseconds = self.refresh_nanoseconds,
        .sequence = sequence,
        .flags = .{
            .vsync = true,
            .hardware_clock = true,
            .hardware_completion = true,
            .zero_copy = true,
        },
    });
    self.listener.ready(self.listener.context);
}

fn selectOutput(fd: std.posix.fd_t) !Selection {
    const resources = c.drmModeGetResources(fd) orelse return error.GetResourcesFailed;
    defer c.drmModeFreeResources(resources);
    if (resources.*.count_crtcs <= 0) return error.NoCrtc;

    const connector_count: usize = @intCast(@max(resources.*.count_connectors, 0));
    for (0..connector_count) |connector_index| {
        const connector = c.drmModeGetConnector(
            fd,
            resources.*.connectors[connector_index],
        ) orelse continue;
        defer c.drmModeFreeConnector(connector);
        if (connector.*.connection != c.DRM_MODE_CONNECTED or
            connector.*.count_modes <= 0) continue;

        const possible_crtcs = c.drmModeConnectorGetPossibleCrtcs(fd, connector);
        const crtc_id = selectCrtc(fd, resources, connector, possible_crtcs) orelse continue;
        const mode_count: usize = @intCast(connector.*.count_modes);
        const modes = connector.*.modes[0..mode_count];
        const mode = modes[preferredModeIndex(modes)];
        return .{
            .mode = mode,
            .size = .{ .width = mode.hdisplay, .height = mode.vdisplay },
            .physical_size = .{
                .width = @max(connector.*.mmWidth, 1),
                .height = @max(connector.*.mmHeight, 1),
            },
            .connector_id = connector.*.connector_id,
            .connector_type = connector.*.connector_type,
            .connector_type_id = connector.*.connector_type_id,
            .crtc_id = crtc_id,
        };
    }
    return error.NoConnectedOutput;
}

fn selectCrtc(
    fd: std.posix.fd_t,
    resources: *c.drmModeRes,
    connector: *c.drmModeConnector,
    possible_crtcs: u32,
) ?u32 {
    if (connector.*.encoder_id != 0) {
        const encoder = c.drmModeGetEncoder(fd, connector.*.encoder_id);
        if (encoder) |value| {
            defer c.drmModeFreeEncoder(value);
            if (crtcPossible(resources, possible_crtcs, value.*.crtc_id)) {
                return value.*.crtc_id;
            }
        }
    }

    const crtc_count: usize = @intCast(@max(resources.*.count_crtcs, 0));
    for (0..crtc_count) |crtc_index| {
        if (!crtcIndexPossible(possible_crtcs, crtc_index)) continue;
        const crtc_id = resources.*.crtcs[crtc_index];
        if (!crtcInUse(fd, resources, crtc_id)) return crtc_id;
    }
    for (0..crtc_count) |crtc_index| {
        if (crtcIndexPossible(possible_crtcs, crtc_index)) {
            return resources.*.crtcs[crtc_index];
        }
    }
    return null;
}

fn crtcPossible(resources: *c.drmModeRes, possible_crtcs: u32, crtc_id: u32) bool {
    const crtc_count: usize = @intCast(@max(resources.*.count_crtcs, 0));
    for (0..crtc_count) |index| {
        if (resources.*.crtcs[index] == crtc_id) {
            return crtcIndexPossible(possible_crtcs, index);
        }
    }
    return false;
}

fn crtcIndexPossible(possible_crtcs: u32, index: usize) bool {
    return index < @bitSizeOf(u32) and
        possible_crtcs & (@as(u32, 1) << @intCast(index)) != 0;
}

fn crtcInUse(fd: std.posix.fd_t, resources: *c.drmModeRes, crtc_id: u32) bool {
    const encoder_count: usize = @intCast(@max(resources.*.count_encoders, 0));
    for (0..encoder_count) |encoder_index| {
        const encoder = c.drmModeGetEncoder(fd, resources.*.encoders[encoder_index]) orelse continue;
        defer c.drmModeFreeEncoder(encoder);
        if (encoder.*.crtc_id == crtc_id) return true;
    }
    return false;
}

fn preferredModeIndex(modes: []const c.drmModeModeInfo) usize {
    std.debug.assert(modes.len > 0);
    for (modes, 0..) |mode, index| {
        if (mode.type & c.DRM_MODE_TYPE_PREFERRED != 0) return index;
    }
    return 0;
}

fn refreshNanoseconds(mode: c.drmModeModeInfo) u32 {
    if (mode.vrefresh == 0) return presentation.nominal_refresh_nanoseconds;
    return @intCast(std.time.ns_per_s / mode.vrefresh);
}

fn createBuffer(fd: std.posix.fd_t, size: render.Size, buffer: *Buffer) !void {
    var create = std.mem.zeroes(c.struct_drm_mode_create_dumb);
    create.width = size.width;
    create.height = size.height;
    create.bpp = 32;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) {
        return error.CreateDumbBufferFailed;
    }
    buffer.handle = create.handle;
    errdefer destroyBuffer(fd, buffer);

    if (c.drmModeAddFB(
        fd,
        size.width,
        size.height,
        24,
        32,
        create.pitch,
        create.handle,
        &buffer.framebuffer_id,
    ) != 0) return error.AddFramebufferFailed;

    var map = std.mem.zeroes(c.struct_drm_mode_map_dumb);
    map.handle = create.handle;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map) != 0) {
        return error.MapDumbBufferFailed;
    }
    const mapping = try std.posix.mmap(
        null,
        @intCast(create.size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        map.offset,
    );
    buffer.mapping = mapping;
    buffer.stride_pixels = create.pitch / @sizeOf(u32);
    buffer.pixels = @as([*]u32, @ptrCast(@alignCast(mapping.ptr)))[0 .. mapping.len / @sizeOf(u32)];
    @memset(buffer.pixels, 0);
}

fn destroyBuffer(fd: std.posix.fd_t, buffer: *Buffer) void {
    if (buffer.mapping) |mapping| std.posix.munmap(mapping);
    if (buffer.framebuffer_id != 0 and c.drmModeRmFB(fd, buffer.framebuffer_id) != 0) {
        log.err("failed to remove DRM framebuffer {d}", .{buffer.framebuffer_id});
    }
    if (buffer.handle != 0) {
        var destroy = c.struct_drm_mode_destroy_dumb{ .handle = buffer.handle };
        if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy) != 0) {
            log.err("failed to destroy DRM dumb buffer {d}", .{buffer.handle});
        }
    }
    buffer.* = .{};
}

fn restoreCrtc(fd: std.posix.fd_t, connector_id: u32, old_crtc: *c.drmModeCrtc) void {
    var connector = connector_id;
    const mode: ?*c.drmModeModeInfo = if (old_crtc.*.mode_valid != 0)
        &old_crtc.*.mode
    else
        null;
    if (c.drmModeSetCrtc(
        fd,
        old_crtc.*.crtc_id,
        old_crtc.*.buffer_id,
        old_crtc.*.x,
        old_crtc.*.y,
        if (mode == null) null else &connector,
        if (mode == null) 0 else 1,
        mode,
    ) != 0) {
        log.err("failed to restore CRTC {d}", .{old_crtc.*.crtc_id});
    }
}

test "preferred DRM mode wins over the first mode" {
    var modes = [_]c.drmModeModeInfo{
        std.mem.zeroes(c.drmModeModeInfo),
        std.mem.zeroes(c.drmModeModeInfo),
    };
    modes[1].type = c.DRM_MODE_TYPE_PREFERRED;
    try std.testing.expectEqual(@as(usize, 1), preferredModeIndex(&modes));
}

test "DRM mode refresh converts to presentation period" {
    var mode = std.mem.zeroes(c.drmModeModeInfo);
    mode.vrefresh = 50;
    try std.testing.expectEqual(@as(u32, 20_000_000), refreshNanoseconds(mode));
    mode.vrefresh = 0;
    try std.testing.expectEqual(presentation.nominal_refresh_nanoseconds, refreshNanoseconds(mode));
}
