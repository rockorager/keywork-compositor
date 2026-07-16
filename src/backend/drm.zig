//! Native DRM/KMS output using CPU-mapped dumb buffers.

const Self = @This();

const std = @import("std");
const Gbm = @import("gbm.zig");
const NestedOutput = @import("nested_wayland.zig");
const presentation = @import("../presentation.zig");
const Region = @import("../region.zig");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("libdisplay-info/info.h");
    @cInclude("libudev.h");
    @cInclude("libdrm/drm_fourcc.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});
const log = std.log.scoped(.drm);
const buffer_count = 2;
const description_capacity = 512;
const drm_format_mod_linear: u64 = 0;

allocator: std.mem.Allocator,
io: std.Io,
device_access: DeviceAccess,
listener: ?Listener,
dmabuf_renderer: ?render.DmabufRenderer,
old_crtc: ?*c.drmModeCrtc,
buffers: [buffer_count]Buffer,
shadow_pixels: []u32,
buffer_damage: [buffer_count]Region,
mode: c.drmModeModeInfo,
mode_index: usize,
modes: []Mode,
size: render.Size,
physical_size: render.Size,
scale: render.Scale,
connector_id: u32,
crtc_id: u32,
primary_plane_id: ?u32,
atomic_plane: ?AtomicPlaneProperties,
scanout_modifiers: []u64,
implicit_scanout: bool,
connector_name: [32]u8,
connector_name_length: usize,
make_value: [*c]u8,
model_value: [*c]u8,
serial_value: [*c]u8,
description_value: [description_capacity]u8,
description_length: usize,
logical_x: i32,
logical_y: i32,
refresh_nanoseconds: u32,
presentation_clock_id: u32,
acquired: ?usize,
pending: ?usize,
displayed: ?usize,
direct_pending: ?DirectScanout,
direct_displayed: ?DirectScanout,
direct_framebuffers: std.AutoHashMapUnmanaged(u64, DirectFramebuffer),
direct_frame_number: u64,
direct_scanout_active: bool,
enabled: bool,
powered: bool,
mode_set: bool,
retired: bool,

pub const Listener = NestedOutput.Listener;

const Buffer = struct {
    gbm: ?Gbm.Buffer = null,
    render_target_id: ?u64 = null,
    handle: u32 = 0,
    framebuffer_id: u32 = 0,
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    pixels: []u32 = &.{},
    stride_pixels: u32 = 0,
};

const DirectFramebuffer = struct {
    framebuffer_id: u32,
    size: render.Size,
    format: u32,
    modifier: u64,
    stride: u32,
    offset: u32,
    last_used: u64,
};

const DirectScanout = struct {
    source: render.DmabufSource,
    cache_id: u64,

    fn release(self: DirectScanout) void {
        self.source.release(self.source.context);
    }
};

const AtomicPlaneProperties = struct {
    fb_id: u32 = 0,
    crtc_id: u32 = 0,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    crtc_x: u32 = 0,
    crtc_y: u32 = 0,
    crtc_w: u32 = 0,
    crtc_h: u32 = 0,
    in_fence_fd: u32 = 0,

    fn complete(self: AtomicPlaneProperties) bool {
        return self.fb_id != 0 and self.crtc_id != 0 and
            self.src_x != 0 and self.src_y != 0 and self.src_w != 0 and self.src_h != 0 and
            self.crtc_x != 0 and self.crtc_y != 0 and
            self.crtc_w != 0 and self.crtc_h != 0;
    }
};

pub const DirectScanoutResult = struct {
    accepted: bool = false,
};

const max_direct_framebuffers = 8;

pub const Selection = struct {
    modes: []Mode,
    mode_index: usize,
    physical_size: render.Size,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    crtc_id: u32,
    primary_plane_id: ?u32,
    scanout_modifiers: []u64,
    implicit_scanout: bool,
};

const PrimaryPlane = struct {
    id: ?u32 = null,
    modifiers: []u64 = &.{},
    implicit: bool = true,
};

pub const Mode = struct {
    value: c.drmModeModeInfo,
    preferred: bool,

    pub fn size(self: Mode) render.Size {
        return .{ .width = self.value.hdisplay, .height = self.value.vdisplay };
    }

    pub fn refreshMillihertz(self: Mode) i32 {
        return @intCast(@min(
            @as(u64, self.value.vrefresh) * 1000,
            std.math.maxInt(i32),
        ));
    }
};

pub const DeviceAccess = struct {
    context: *anyopaque,
    fd: *const fn (*anyopaque) ?std.posix.fd_t,
    gbm: *const fn (*anyopaque) ?*Gbm = unavailableGbm,
    atomic: *const fn (*anyopaque) bool = unavailableAtomic,
    active: *const fn (*anyopaque) bool,
    fail: *const fn (*anyopaque, anyerror) void,
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
    device_access: DeviceAccess,
) void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .device_access = device_access,
        .listener = null,
        .dmabuf_renderer = null,
        .old_crtc = null,
        .buffers = .{ .{}, .{} },
        .shadow_pixels = &.{},
        .buffer_damage = .{ Region.init(), Region.init() },
        .mode = std.mem.zeroes(c.drmModeModeInfo),
        .mode_index = 0,
        .modes = &.{},
        .size = .{ .width = 0, .height = 0 },
        .physical_size = .{ .width = 0, .height = 0 },
        .scale = .{},
        .connector_id = 0,
        .crtc_id = 0,
        .primary_plane_id = null,
        .atomic_plane = null,
        .scanout_modifiers = &.{},
        .implicit_scanout = true,
        .connector_name = undefined,
        .connector_name_length = 0,
        .make_value = null,
        .model_value = null,
        .serial_value = null,
        .description_value = undefined,
        .description_length = 0,
        .logical_x = 0,
        .logical_y = 0,
        .refresh_nanoseconds = presentation.nominal_refresh_nanoseconds,
        .presentation_clock_id = presentation.monotonic_clock_id,
        .acquired = null,
        .pending = null,
        .displayed = null,
        .direct_pending = null,
        .direct_displayed = null,
        .direct_framebuffers = .empty,
        .direct_frame_number = 0,
        .direct_scanout_active = false,
        .enabled = true,
        .powered = true,
        .mode_set = false,
        .retired = false,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.listener == null);
    std.debug.assert(self.old_crtc == null);
    std.debug.assert(self.shadow_pixels.len == 0);
    std.debug.assert(self.direct_pending == null and self.direct_displayed == null);
    std.debug.assert(self.direct_framebuffers.count() == 0);
    self.direct_framebuffers.deinit(self.allocator);
    self.clearIdentity();
    self.allocator.free(self.modes);
    self.allocator.free(self.scanout_modifiers);
    for (&self.buffer_damage) |*damage| damage.deinit();
    self.* = undefined;
}

pub fn attach(self: *Self, listener: Listener, dmabuf_renderer: ?render.DmabufRenderer) void {
    std.debug.assert(self.listener == null);
    std.debug.assert(dmabuf_renderer != null or self.buffers[0].render_target_id == null);
    self.dmabuf_renderer = dmabuf_renderer;
    self.listener = listener;
    if (dmabuf_renderer != null and self.buffers[0].render_target_id == null and
        self.acquired == null and self.pending == null and self.displayed == null and
        !self.mode_set and self.powered)
    {
        const fd = self.device_access.fd(self.device_access.context) orelse return;
        var replacement = self.allocateGpuPair(fd, self.size) catch |err| {
            log.warn("GPU scanout allocation failed, keeping CPU buffers: {t}", .{err});
            return;
        };
        var old_buffers = self.buffers;
        const old_shadow = self.shadow_pixels;
        self.buffers = replacement.buffers;
        self.shadow_pixels = replacement.shadow_pixels;
        replacement = .{};
        self.destroyPair(fd, &old_buffers, old_shadow);
        self.resetBufferDamage(self.size);
    }
}

pub fn detach(self: *Self) void {
    std.debug.assert(self.listener != null);
    self.listener = null;
}

pub fn releaseClientBuffers(self: *Self) void {
    self.releaseDirectScanouts();
}

pub fn name(self: *const Self) []const u8 {
    return self.connector_name[0..self.connector_name_length];
}

pub fn make(self: *const Self) ?[]const u8 {
    return if (self.make_value == null) null else std.mem.span(self.make_value);
}

pub fn model(self: *const Self) ?[]const u8 {
    return if (self.model_value == null) null else std.mem.span(self.model_value);
}

pub fn serial(self: *const Self) ?[]const u8 {
    return if (self.serial_value == null) null else std.mem.span(self.serial_value);
}

pub fn description(self: *const Self) []const u8 {
    return self.description_value[0..self.description_length];
}

pub fn refreshMillihertz(self: *const Self) i32 {
    return @intCast(@min(
        @as(u64, self.mode.vrefresh) * 1000,
        std.math.maxInt(i32),
    ));
}

pub fn availableModes(self: *const Self) []const Mode {
    return self.modes;
}

pub fn currentModeIndex(self: *const Self) usize {
    std.debug.assert(self.mode_index < self.modes.len);
    return self.mode_index;
}

pub fn logicalSize(self: *const Self) render.Size {
    return self.scale.logicalSize(self.size) catch unreachable;
}

pub fn ready(self: *const Self) bool {
    if (!self.enabled or !self.powered or !self.device_access.active(self.device_access.context) or
        self.acquired != null or self.pending != null or self.direct_pending != null) return false;
    return self.availableBuffer() != null;
}

pub fn acquire(self: *Self) ?render.Target {
    std.debug.assert(self.acquired == null);
    if (!self.ready()) return null;
    const index = self.availableBuffer().?;
    self.acquired = index;
    if (self.buffers[index].render_target_id) |id| return .{ .dmabuf = .{
        .id = id,
        .size = self.size,
    } };
    const pixel_count = self.size.pixelCount() catch unreachable;
    std.debug.assert(self.shadow_pixels.len == pixel_count);
    return .{ .pixels = .{
        .size = self.size,
        .stride_pixels = self.size.width,
        .pixels = self.shadow_pixels,
    } };
}

pub fn repairDamage(self: *Self, damage: *Region) !void {
    const index = self.acquired orelse unreachable;
    if (self.buffers[index].render_target_id != null) {
        try damage.unionWith(&self.buffer_damage[index]);
    }
}

pub fn cancel(self: *Self) void {
    self.acquired = null;
}

pub fn present(self: *Self, frame_damage: *const Region) !?presentation.Info {
    const index = self.acquired orelse return error.NoAcquiredBuffer;
    const fd = self.device_access.fd(self.device_access.context) orelse return error.SessionInactive;
    if (!self.device_access.active(self.device_access.context)) return error.SessionInactive;
    const buffer = &self.buffers[index];
    for (&self.buffer_damage) |*damage| try damage.unionWith(frame_damage);
    if (buffer.render_target_id == null) copyShadowDamage(
        buffer.pixels,
        buffer.stride_pixels,
        self.shadow_pixels,
        self.size,
        &self.buffer_damage[index],
    );
    self.buffer_damage[index].clear();

    if (!self.mode_set) {
        var connector_id = self.connector_id;
        if (c.drmModeSetCrtc(
            fd,
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
        self.setDirectScanoutActive(false);
        const clock: std.Io.Clock = if (self.presentation_clock_id ==
            presentation.monotonic_clock_id) .awake else .real;
        return .{
            .timestamp = .fromNanoseconds(clock.now(self.io).nanoseconds),
            .refresh_nanoseconds = self.refresh_nanoseconds,
        };
    }

    if (!self.queuePageFlip(fd, buffer.framebuffer_id, null)) return error.PageFlipFailed;
    self.pending = index;
    self.acquired = null;
    return null;
}

pub fn tryDirectScanout(self: *Self, buffer: render.PixelBuffer) DirectScanoutResult {
    const source = buffer.dmabuf orelse return .{};
    const source_cache = buffer.source_cache orelse return .{};
    if (!self.mode_set or self.acquired == null or self.pending != null or
        self.direct_pending != null or !std.meta.eql(buffer.size, self.size) or
        source.y_inverted or
        (source.format != c.DRM_FORMAT_ARGB8888 and source.format != c.DRM_FORMAT_XRGB8888) or
        (self.atomic_plane == null and !self.legacyFramebufferLayoutMatches(buffer)))
    {
        return .{};
    }
    const fd = self.device_access.fd(self.device_access.context) orelse
        return .{};
    if (!self.device_access.active(self.device_access.context)) return .{};
    const framebuffer = self.directFramebuffer(fd, buffer) catch return .{};

    source.retain(source.context);
    if (!self.queuePageFlip(fd, framebuffer.framebuffer_id, source)) {
        source.release(source.context);
        return .{};
    }
    self.direct_pending = .{
        .source = source,
        .cache_id = source_cache.id,
    };
    self.acquired = null;
    self.resetBufferDamage(self.size);
    return .{ .accepted = true };
}

pub fn activate(self: *Self, fd: std.posix.fd_t, selection: Selection, device_path: []const u8) !void {
    std.debug.assert(selection.modes.len > 0);
    std.debug.assert(selection.mode_index < selection.modes.len);
    const selected_mode = selection.modes[selection.mode_index];
    const selected_size = selected_mode.size();
    if (self.size.width != 0 and (!std.meta.eql(self.size, selected_size) or
        self.connector_id != selection.connector_id or
        self.primary_plane_id != selection.primary_plane_id or
        !modeListsEqual(self.modes, selection.modes)))
    {
        return error.OutputChanged;
    }
    const modes = try self.allocator.dupe(Mode, selection.modes);
    const scanout_modifiers = self.allocator.dupe(u64, selection.scanout_modifiers) catch |err| {
        self.allocator.free(modes);
        return err;
    };
    self.allocator.free(self.modes);
    self.allocator.free(self.scanout_modifiers);
    self.modes = modes;
    self.scanout_modifiers = scanout_modifiers;
    self.implicit_scanout = selection.implicit_scanout;
    self.mode_index = selection.mode_index;
    self.mode = selected_mode.value;
    self.size = selected_size;
    self.physical_size = selection.physical_size;
    self.connector_id = selection.connector_id;
    self.crtc_id = selection.crtc_id;
    self.primary_plane_id = selection.primary_plane_id;
    self.atomic_plane = if (self.device_access.atomic(self.device_access.context))
        loadAtomicPlaneProperties(fd, self.primary_plane_id orelse 0)
    else
        null;
    if (self.device_access.atomic(self.device_access.context) and self.atomic_plane == null) {
        log.warn("primary plane lacks required atomic properties; using legacy frame commits", .{});
    }
    self.retired = false;
    const connector_type = c.drmModeGetConnectorTypeName(selection.connector_type);
    const type_name = if (connector_type == null) "Unknown" else std.mem.span(connector_type);
    const name_value = try std.fmt.bufPrint(
        &self.connector_name,
        "{s}-{d}",
        .{ type_name, selection.connector_type_id },
    );
    self.connector_name_length = name_value.len;
    self.readIdentity(fd);
    const make_value = self.make() orelse "Unknown";
    const model_value = self.model() orelse "display";
    const description_value = if (self.serial()) |serial_text|
        try std.fmt.bufPrint(
            &self.description_value,
            "{s} {s} {s} ({s})",
            .{ make_value, model_value, serial_text, self.name() },
        )
    else
        try std.fmt.bufPrint(
            &self.description_value,
            "{s} {s} ({s})",
            .{ make_value, model_value, self.name() },
        );
    self.description_length = description_value.len;
    self.refresh_nanoseconds = refreshNanoseconds(self.mode);

    var monotonic: u64 = 0;
    if (c.drmGetCap(fd, c.DRM_CAP_TIMESTAMP_MONOTONIC, &monotonic) == 0 and
        monotonic != 0)
    {
        self.presentation_clock_id = presentation.monotonic_clock_id;
    } else {
        self.presentation_clock_id = @intCast(@intFromEnum(std.posix.CLOCK.REALTIME));
    }

    self.old_crtc = c.drmModeGetCrtc(fd, self.crtc_id);
    if (self.old_crtc == null) return error.GetCrtcFailed;
    errdefer {
        c.drmModeFreeCrtc(self.old_crtc.?);
        self.old_crtc = null;
    }

    if (!self.powered) {
        if (c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0) {
            return error.DisableFailed;
        }
    } else {
        const pair = try self.allocatePair(fd, self.size);
        self.buffers = pair.buffers;
        self.shadow_pixels = pair.shadow_pixels;
        self.resetBufferDamage(self.size);
    }
    log.info(
        "activated connector {s} ({d}) on {s} at {d}x{d}, CRTC {d}, enabled={}, powered={}: {s}",
        .{ self.name(), self.connector_id, device_path, self.size.width, self.size.height, self.crtc_id, self.enabled, self.powered, self.description() },
    );
}

fn readIdentity(self: *Self, fd: std.posix.fd_t) void {
    self.clearIdentity();
    const properties = c.drmModeObjectGetProperties(
        fd,
        self.connector_id,
        c.DRM_MODE_OBJECT_CONNECTOR,
    ) orelse return;
    defer c.drmModeFreeObjectProperties(properties);

    const property_count: usize = @intCast(properties.*.count_props);
    for (0..property_count) |index| {
        const property = c.drmModeGetProperty(fd, properties.*.props[index]) orelse continue;
        defer c.drmModeFreeProperty(property);
        const name_value = std.mem.sliceTo(property.*.name[0..], 0);
        if (!std.mem.eql(u8, name_value, "EDID")) continue;
        const blob_id = properties.*.prop_values[index];
        if (blob_id == 0 or blob_id > std.math.maxInt(u32)) return;
        const blob = c.drmModeGetPropertyBlob(fd, @intCast(blob_id)) orelse return;
        defer c.drmModeFreePropertyBlob(blob);
        if (blob.*.data == null or blob.*.length == 0) return;
        const info = c.di_info_parse_edid(blob.*.data, blob.*.length) orelse return;
        defer c.di_info_destroy(info);
        self.make_value = c.di_info_get_make(info);
        self.model_value = c.di_info_get_model(info);
        self.serial_value = c.di_info_get_serial(info);
        return;
    }
}

fn clearIdentity(self: *Self) void {
    if (self.make_value != null) c.free(self.make_value);
    if (self.model_value != null) c.free(self.model_value);
    if (self.serial_value != null) c.free(self.serial_value);
    self.make_value = null;
    self.model_value = null;
    self.serial_value = null;
}

pub fn isPrimaryNode(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, basename, "card") or basename.len == "card".len) return false;
    for (basename["card".len..]) |character| {
        if (!std.ascii.isDigit(character)) return false;
    }
    return true;
}

pub fn deactivate(self: *Self, fd: std.posix.fd_t) void {
    if (self.old_crtc) |old_crtc| restoreCrtc(fd, self.connector_id, old_crtc);
    self.release(fd);
}

pub fn disconnect(self: *Self, fd: std.posix.fd_t) void {
    if (self.powered and
        c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0)
    {
        log.warn("failed to disable disconnected CRTC {d}", .{self.crtc_id});
    }
    self.release(fd);
}

fn release(self: *Self, fd: std.posix.fd_t) void {
    self.mode_set = false;
    self.atomic_plane = null;
    self.acquired = null;
    self.pending = null;
    self.displayed = null;
    self.releaseDirectScanouts();
    self.destroyDirectFramebuffers(fd);
    self.destroyPair(fd, &self.buffers, self.shadow_pixels);
    self.shadow_pixels = &.{};
    for (&self.buffer_damage) |*damage| damage.clear();
    if (self.old_crtc) |old_crtc| {
        c.drmModeFreeCrtc(old_crtc);
        self.old_crtc = null;
    }
}

pub fn setEnabled(self: *Self, fd: std.posix.fd_t, enabled: bool) !void {
    if (self.enabled == enabled) return;
    std.debug.assert(self.old_crtc != null);
    if (enabled) {
        self.enabled = true;
        errdefer self.enabled = false;
        try self.setPowered(fd, true);
        return;
    }

    if (self.powered) try self.setPowered(fd, false);
    self.enabled = false;
}

pub fn setPowered(self: *Self, fd: std.posix.fd_t, powered: bool) !void {
    if (!self.enabled) return error.OutputDisabled;
    if (self.powered == powered) return;
    std.debug.assert(self.old_crtc != null);
    if (powered) {
        const pair = try self.allocatePair(fd, self.size);
        self.buffers = pair.buffers;
        self.shadow_pixels = pair.shadow_pixels;
        self.resetBufferDamage(self.size);
        self.powered = true;
        self.mode_set = false;
        return;
    }

    // Destroying a framebuffer queued for a page flip is not safe. Output
    // configuration is infrequent, so reject a busy head and let the client
    // retry rather than complicating the page-flip lifetime.
    if (self.pending != null or self.direct_pending != null) return error.OutputBusy;
    self.acquired = null;
    if (c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0) {
        return error.DisableFailed;
    }
    self.powered = false;
    self.mode_set = false;
    self.displayed = null;
    self.releaseDirectScanouts();
    self.destroyDirectFramebuffers(fd);
    self.notifyDeactivated();
    self.destroyPair(fd, &self.buffers, self.shadow_pixels);
    self.shadow_pixels = &.{};
    for (&self.buffer_damage) |*damage| damage.clear();
}

pub fn setMode(self: *Self, fd: std.posix.fd_t, mode_index: usize) !void {
    if (mode_index >= self.modes.len) return error.InvalidMode;
    if (mode_index == self.mode_index) return;
    if (self.pending != null or self.direct_pending != null) return error.OutputBusy;
    const mode = self.modes[mode_index];
    const size = mode.size();

    if (self.powered) {
        const pair = try self.allocatePair(fd, size);
        self.acquired = null;
        if (c.drmModeSetCrtc(fd, self.crtc_id, 0, 0, 0, null, 0, null) != 0) {
            var failed_buffers = pair.buffers;
            self.destroyPair(fd, &failed_buffers, pair.shadow_pixels);
            return error.DisableFailed;
        }
        self.notifyDeactivated();
        var old_buffers = self.buffers;
        const old_shadow_pixels = self.shadow_pixels;
        self.buffers = pair.buffers;
        self.shadow_pixels = pair.shadow_pixels;
        self.resetBufferDamage(size);
        self.destroyPair(fd, &old_buffers, old_shadow_pixels);
        self.displayed = null;
        self.releaseDirectScanouts();
        self.destroyDirectFramebuffers(fd);
        self.mode_set = false;
    }

    self.mode_index = mode_index;
    self.mode = mode.value;
    self.size = size;
    self.refresh_nanoseconds = refreshNanoseconds(self.mode);
}

fn availableBuffer(self: *const Self) ?usize {
    for (0..buffer_count) |index| {
        if (self.displayed == index or self.pending == index) continue;
        return index;
    }
    return null;
}

pub fn notifyReady(self: *Self) void {
    if (self.listener) |listener| listener.ready(listener.context);
}

pub fn notifyDeactivated(self: *Self) void {
    log.info("deactivating {s}", .{self.name()});
    if (self.listener) |listener| listener.discarded(listener.context);
}

pub fn retire(self: *Self) void {
    self.retired = true;
    self.pending = null;
}

pub fn dispatchEvent(_: *Self, fd: std.posix.fd_t) !void {
    var context = event_context;
    if (c.drmHandleEvent(fd, &context) != 0) return error.EventDispatchFailed;
}

fn handlePageFlip(
    _: c_int,
    sequence: c_uint,
    seconds: c_uint,
    microseconds: c_uint,
    data: ?*anyopaque,
) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    if (self.pending == null and self.direct_pending == null) {
        if (self.retired) return;
        self.device_access.fail(self.device_access.context, error.UnexpectedPageFlip);
        return;
    }
    if (self.direct_pending) |direct| {
        if (self.direct_displayed) |displayed| displayed.release();
        self.direct_displayed = direct;
        self.direct_pending = null;
        self.displayed = null;
        self.setDirectScanoutActive(true);
    } else {
        if (self.direct_displayed) |displayed| displayed.release();
        self.direct_displayed = null;
        self.displayed = self.pending.?;
        self.pending = null;
        self.setDirectScanoutActive(false);
    }
    const listener = self.listener orelse return;
    listener.presented(listener.context, .{
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
        },
    });
    listener.ready(listener.context);
}

pub fn selectOutputs(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    existing_outputs: []const *Self,
) ![]Selection {
    const resources = c.drmModeGetResources(fd) orelse return error.GetResourcesFailed;
    defer c.drmModeFreeResources(resources);
    if (resources.*.count_crtcs <= 0) return error.NoCrtc;
    var selections: std.ArrayList(Selection) = .empty;
    errdefer {
        for (selections.items) |selection| {
            allocator.free(selection.modes);
            allocator.free(selection.scanout_modifiers);
        }
        selections.deinit(allocator);
    }
    var claimed: u32 = 0;
    var claimed_primary_planes: std.ArrayList(u32) = .empty;
    defer claimed_primary_planes.deinit(allocator);
    var reserved_primary_planes: std.ArrayList(u32) = .empty;
    defer reserved_primary_planes.deinit(allocator);

    // Reserve working routes before assigning CRTCs to newly connected heads.
    // Otherwise connector enumeration order can steal an active output's CRTC.
    for (existing_outputs) |output| {
        const connector = c.drmModeGetConnector(fd, output.connector_id) orelse continue;
        defer c.drmModeFreeConnector(connector);
        if (connector.*.connection != c.DRM_MODE_CONNECTED or connector.*.count_modes <= 0) {
            continue;
        }
        const possible_crtcs = c.drmModeConnectorGetPossibleCrtcs(fd, connector);
        const index = crtcIndex(resources, output.crtc_id) orelse continue;
        if (crtcIndexPossible(possible_crtcs, index)) {
            claimed |= @as(u32, 1) << @intCast(index);
            if (output.primary_plane_id) |plane_id| {
                if (std.mem.indexOfScalar(u32, reserved_primary_planes.items, plane_id) == null) {
                    try reserved_primary_planes.append(allocator, plane_id);
                }
            }
        }
    }

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
        const existing_output = findOutput(existing_outputs, connector.*.connector_id);
        var preferred_crtc: ?u32 = null;
        if (connector.*.encoder_id != 0) {
            const encoder = c.drmModeGetEncoder(fd, connector.*.encoder_id);
            if (encoder) |value| {
                defer c.drmModeFreeEncoder(value);
                preferred_crtc = value.*.crtc_id;
            }
        }
        const existing_crtc_index = if (existing_output) |output| existing: {
            const index = crtcIndex(resources, output.crtc_id) orelse break :existing null;
            break :existing if (crtcIndexPossible(possible_crtcs, index)) index else null;
        } else null;
        const crtc_index = existing_crtc_index orelse selectCrtcIndex(
            resources,
            possible_crtcs,
            preferred_crtc,
            claimed,
        ) orelse {
            log.warn("skipping connector {d}: no unclaimed compatible CRTC", .{connector.*.connector_id});
            continue;
        };
        claimed |= @as(u32, 1) << @intCast(crtc_index);
        const crtc_id = resources.*.crtcs[crtc_index];
        const primary_plane = try primaryPlane(
            fd,
            crtc_id,
            crtc_index,
            if (existing_output) |output| output.primary_plane_id else null,
            claimed_primary_planes.items,
            reserved_primary_planes.items,
            allocator,
        );
        if (primary_plane.id) |plane_id| {
            claimed_primary_planes.append(allocator, plane_id) catch |err| {
                allocator.free(primary_plane.modifiers);
                return err;
            };
        }
        const mode_count: usize = @intCast(connector.*.count_modes);
        const connector_modes = connector.*.modes[0..mode_count];
        const modes = allocator.alloc(Mode, mode_count) catch |err| {
            allocator.free(primary_plane.modifiers);
            return err;
        };
        for (connector_modes, modes) |mode, *stored| stored.* = .{
            .value = mode,
            .preferred = mode.type & c.DRM_MODE_TYPE_PREFERRED != 0,
        };
        const mode_index = if (existing_output) |output|
            findModeIndex(modes, output.mode) orelse preferredModeIndex(connector_modes)
        else
            preferredModeIndex(connector_modes);
        selections.append(allocator, .{
            .modes = modes,
            .mode_index = mode_index,
            .physical_size = .{
                .width = @max(connector.*.mmWidth, 1),
                .height = @max(connector.*.mmHeight, 1),
            },
            .connector_id = connector.*.connector_id,
            .connector_type = connector.*.connector_type,
            .connector_type_id = connector.*.connector_type_id,
            .crtc_id = crtc_id,
            .primary_plane_id = primary_plane.id,
            .scanout_modifiers = primary_plane.modifiers,
            .implicit_scanout = primary_plane.implicit,
        }) catch |err| {
            allocator.free(modes);
            allocator.free(primary_plane.modifiers);
            return err;
        };
    }
    return selections.toOwnedSlice(allocator);
}

pub fn deinitSelections(allocator: std.mem.Allocator, selections: []Selection) void {
    for (selections) |selection| {
        allocator.free(selection.modes);
        allocator.free(selection.scanout_modifiers);
    }
    allocator.free(selections);
}

fn primaryPlane(
    fd: std.posix.fd_t,
    crtc_id: u32,
    crtc_index: usize,
    preferred_plane_id: ?u32,
    claimed_planes: []const u32,
    reserved_planes: []const u32,
    allocator: std.mem.Allocator,
) !PrimaryPlane {
    const resources = c.drmModeGetPlaneResources(fd) orelse return .{};
    defer c.drmModeFreePlaneResources(resources);
    var selected: PrimaryPlane = .{};
    errdefer allocator.free(selected.modifiers);
    var selected_score: u8 = 0;
    const plane_count: usize = @intCast(resources.*.count_planes);
    for (resources.*.planes[0..plane_count]) |plane_id| {
        const plane = c.drmModeGetPlane(fd, plane_id) orelse continue;
        defer c.drmModeFreePlane(plane);
        if (!crtcIndexPossible(plane.*.possible_crtcs, crtc_index) or
            std.mem.indexOfScalar(u32, claimed_planes, plane_id) != null or
            (preferred_plane_id != plane_id and
                std.mem.indexOfScalar(u32, reserved_planes, plane_id) != null)) continue;

        const properties = c.drmModeObjectGetProperties(
            fd,
            plane_id,
            c.DRM_MODE_OBJECT_PLANE,
        ) orelse continue;
        defer c.drmModeFreeObjectProperties(properties);
        var plane_type: ?u64 = null;
        var formats_blob_id: ?u32 = null;
        const property_count: usize = @intCast(properties.*.count_props);
        for (0..property_count) |property_index| {
            const property = c.drmModeGetProperty(
                fd,
                properties.*.props[property_index],
            ) orelse continue;
            defer c.drmModeFreeProperty(property);
            const property_name = std.mem.sliceTo(property.*.name[0..], 0);
            const value = properties.*.prop_values[property_index];
            if (std.mem.eql(u8, property_name, "type")) {
                plane_type = value;
            } else if (std.mem.eql(u8, property_name, "IN_FORMATS") and
                value > 0 and value <= std.math.maxInt(u32))
            {
                formats_blob_id = @intCast(value);
            }
        }
        if (plane_type != c.DRM_PLANE_TYPE_PRIMARY) continue;
        const score: u8 = if (preferred_plane_id == plane_id and
            (plane.*.crtc_id == 0 or plane.*.crtc_id == crtc_id))
            3
        else if (plane.*.crtc_id == crtc_id)
            2
        else if (plane.*.crtc_id == 0)
            1
        else
            0;
        if (score <= selected_score) continue;

        var implicit = false;
        const format_count: usize = @intCast(plane.*.count_formats);
        for (plane.*.formats[0..format_count]) |format| {
            if (format == c.DRM_FORMAT_XRGB8888) {
                implicit = true;
                break;
            }
        }
        var modifiers: std.ArrayList(u64) = .empty;
        defer modifiers.deinit(allocator);
        if (formats_blob_id) |blob_id| if (c.drmModeGetPropertyBlob(fd, blob_id)) |blob| {
            defer c.drmModeFreePropertyBlob(blob);
            var iterator = std.mem.zeroes(c.drmModeFormatModifierIterator);
            while (c.drmModeFormatModifierBlobIterNext(blob, &iterator)) {
                if (iterator.fmt != c.DRM_FORMAT_XRGB8888 or
                    std.mem.indexOfScalar(u64, modifiers.items, iterator.mod) != null) continue;
                try modifiers.append(allocator, iterator.mod);
            }
        };
        const owned_modifiers = try modifiers.toOwnedSlice(allocator);
        allocator.free(selected.modifiers);
        selected = .{
            .id = plane_id,
            .modifiers = owned_modifiers,
            .implicit = implicit,
        };
        selected_score = score;
        if (score == 3) break;
    }
    return selected;
}

fn findOutput(outputs: []const *Self, connector_id: u32) ?*Self {
    for (outputs) |output| if (output.connector_id == connector_id) return output;
    return null;
}

fn crtcIndex(resources: *c.drmModeRes, crtc_id: u32) ?usize {
    const count: usize = @intCast(@max(resources.*.count_crtcs, 0));
    for (0..count) |index| if (resources.*.crtcs[index] == crtc_id) return index;
    return null;
}

fn selectCrtcIndex(
    resources: *c.drmModeRes,
    possible_crtcs: u32,
    preferred_crtc: ?u32,
    claimed: u32,
) ?usize {
    const crtc_count: usize = @intCast(@max(resources.*.count_crtcs, 0));
    if (preferred_crtc) |preferred| for (0..crtc_count) |index| {
        if (resources.*.crtcs[index] == preferred and crtcIndexPossible(possible_crtcs, index) and
            claimed & (@as(u32, 1) << @intCast(index)) == 0) return index;
    };
    for (0..crtc_count) |crtc_index| {
        if (!crtcIndexPossible(possible_crtcs, crtc_index)) continue;
        if (claimed & (@as(u32, 1) << @intCast(crtc_index)) == 0) return crtc_index;
    }
    return null;
}

fn crtcIndexPossible(possible_crtcs: u32, index: usize) bool {
    return index < @bitSizeOf(u32) and
        possible_crtcs & (@as(u32, 1) << @intCast(index)) != 0;
}

fn preferredModeIndex(modes: []const c.drmModeModeInfo) usize {
    std.debug.assert(modes.len > 0);
    for (modes, 0..) |mode, index| {
        if (mode.type & c.DRM_MODE_TYPE_PREFERRED != 0) return index;
    }
    return 0;
}

fn findModeIndex(modes: []const Mode, target: c.drmModeModeInfo) ?usize {
    for (modes, 0..) |mode, index| {
        if (std.meta.eql(mode.value, target)) return index;
    }
    return null;
}

fn modeListsEqual(a: []const Mode, b: []const Mode) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_mode, b_mode| {
        if (!std.meta.eql(a_mode, b_mode)) return false;
    }
    return true;
}

fn refreshNanoseconds(mode: c.drmModeModeInfo) u32 {
    if (mode.vrefresh == 0) return presentation.nominal_refresh_nanoseconds;
    return @intCast(std.time.ns_per_s / mode.vrefresh);
}

fn resetBufferDamage(self: *Self, size: render.Size) void {
    for (&self.buffer_damage) |*damage| {
        damage.setRectangle(0, 0, size.width, size.height);
    }
}

fn createShadowBuffer(
    allocator: std.mem.Allocator,
    size: render.Size,
    pixels: *[]u32,
) !void {
    std.debug.assert(pixels.*.len == 0);
    pixels.* = try allocator.alloc(u32, try size.pixelCount());
    @memset(pixels.*, 0);
}

fn destroyShadowBuffer(allocator: std.mem.Allocator, pixels: *[]u32) void {
    allocator.free(pixels.*);
    pixels.* = &.{};
}

fn copyShadowDamage(
    destination: []u32,
    destination_stride: u32,
    source: []const u32,
    size: render.Size,
    damage: *const Region,
) void {
    std.debug.assert(destination_stride >= size.width);
    const source_count = size.pixelCount() catch unreachable;
    std.debug.assert(source.len >= source_count);
    const destination_count = std.math.add(
        usize,
        std.math.mul(usize, size.height - 1, destination_stride) catch unreachable,
        size.width,
    ) catch unreachable;
    std.debug.assert(destination.len >= destination_count);

    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        std.debug.assert(rectangle.x >= 0 and rectangle.y >= 0);
        const x: u32 = @intCast(rectangle.x);
        const y: u32 = @intCast(rectangle.y);
        std.debug.assert(x + rectangle.width <= size.width);
        std.debug.assert(y + rectangle.height <= size.height);
        for (0..rectangle.height) |row| {
            const source_offset = (@as(usize, y) + row) * size.width + x;
            const destination_offset = (@as(usize, y) + row) * destination_stride + x;
            @memcpy(
                destination[destination_offset..][0..rectangle.width],
                source[source_offset..][0..rectangle.width],
            );
        }
    }
}

fn directFramebuffer(
    self: *Self,
    fd: std.posix.fd_t,
    buffer: render.PixelBuffer,
) !*DirectFramebuffer {
    const source = buffer.dmabuf orelse return error.InvalidBuffer;
    const cache_id = buffer.source_cache.?.id;
    self.direct_frame_number +%= 1;
    if (self.direct_frame_number == 0) self.direct_frame_number = 1;
    if (self.direct_framebuffers.getPtr(cache_id)) |framebuffer| {
        if (!std.meta.eql(framebuffer.size, buffer.size) or
            framebuffer.format != source.format or framebuffer.modifier != source.modifier or
            framebuffer.stride != source.stride or framebuffer.offset != source.offset)
        {
            return error.CacheIdentityMismatch;
        }
        framebuffer.last_used = self.direct_frame_number;
        return framebuffer;
    }
    try self.makeDirectFramebufferRoom(fd);

    const modifier_supported = std.mem.indexOfScalar(
        u64,
        self.scanout_modifiers,
        source.modifier,
    ) != null;
    if (!modifier_supported and !(self.implicit_scanout and
        source.modifier == drm_format_mod_linear)) return error.UnsupportedModifier;

    var handle: u32 = 0;
    if (c.drmPrimeFDToHandle(fd, source.fd, &handle) != 0) return error.ImportHandleFailed;
    defer if (c.drmCloseBufferHandle(fd, handle) != 0) {
        log.err("failed to close imported DRM buffer handle {d}", .{handle});
    };
    var handles = [_]u32{ handle, 0, 0, 0 };
    var pitches = [_]u32{ source.stride, 0, 0, 0 };
    var offsets = [_]u32{ source.offset, 0, 0, 0 };
    const framebuffer_format = if (source.format == c.DRM_FORMAT_ARGB8888)
        c.DRM_FORMAT_XRGB8888
    else
        source.format;
    var framebuffer_id: u32 = 0;
    var add_result: c_int = -1;
    if (modifier_supported) {
        var modifiers = [_]u64{ source.modifier, 0, 0, 0 };
        add_result = c.drmModeAddFB2WithModifiers(
            fd,
            buffer.size.width,
            buffer.size.height,
            framebuffer_format,
            &handles,
            &pitches,
            &offsets,
            &modifiers,
            &framebuffer_id,
            c.DRM_MODE_FB_MODIFIERS,
        );
    }
    if (add_result != 0 and source.modifier == drm_format_mod_linear and self.implicit_scanout) {
        add_result = c.drmModeAddFB2(
            fd,
            buffer.size.width,
            buffer.size.height,
            framebuffer_format,
            &handles,
            &pitches,
            &offsets,
            &framebuffer_id,
            0,
        );
    }
    if (add_result != 0) return error.AddFramebufferFailed;
    errdefer _ = c.drmModeRmFB(fd, framebuffer_id);

    try self.direct_framebuffers.put(self.allocator, cache_id, .{
        .framebuffer_id = framebuffer_id,
        .size = buffer.size,
        .format = source.format,
        .modifier = source.modifier,
        .stride = source.stride,
        .offset = source.offset,
        .last_used = self.direct_frame_number,
    });
    return self.direct_framebuffers.getPtr(cache_id).?;
}

fn legacyFramebufferLayoutMatches(self: *const Self, buffer: render.PixelBuffer) bool {
    const source = buffer.dmabuf orelse return false;
    if (source.format != c.DRM_FORMAT_XRGB8888) return false;
    if (self.direct_displayed) |displayed| {
        const current = self.direct_framebuffers.get(displayed.cache_id) orelse return false;
        return std.meta.eql(current.size, buffer.size) and
            current.modifier == source.modifier and
            current.stride == source.stride and
            current.offset == source.offset;
    }

    const index = self.displayed orelse return false;
    const current = self.buffers[index].gbm orelse return false;
    // Legacy KMS only guarantees page flips between framebuffers allocated
    // with identical layouts. Enforcing this here also guarantees that the
    // compositor-owned framebuffer can be restored after direct scan-out.
    return current.modifier == source.modifier and
        current.stride == source.stride and
        current.offset == source.offset;
}

fn queuePageFlip(
    self: *Self,
    fd: std.posix.fd_t,
    framebuffer_id: u32,
    source: ?render.DmabufSource,
) bool {
    const properties = self.atomic_plane orelse return c.drmModePageFlip(
        fd,
        self.crtc_id,
        framebuffer_id,
        c.DRM_MODE_PAGE_FLIP_EVENT,
        self,
    ) == 0;
    const request = c.drmModeAtomicAlloc() orelse return false;
    defer c.drmModeAtomicFree(request);

    const plane_id = self.primary_plane_id orelse return false;
    if (!addAtomicProperty(request, plane_id, properties.fb_id, framebuffer_id) or
        !addAtomicProperty(request, plane_id, properties.crtc_id, self.crtc_id) or
        !addAtomicProperty(request, plane_id, properties.src_x, 0) or
        !addAtomicProperty(request, plane_id, properties.src_y, 0) or
        !addAtomicProperty(request, plane_id, properties.src_w, @as(u64, self.size.width) << 16) or
        !addAtomicProperty(request, plane_id, properties.src_h, @as(u64, self.size.height) << 16) or
        !addAtomicProperty(request, plane_id, properties.crtc_x, 0) or
        !addAtomicProperty(request, plane_id, properties.crtc_y, 0) or
        !addAtomicProperty(request, plane_id, properties.crtc_w, self.size.width) or
        !addAtomicProperty(request, plane_id, properties.crtc_h, self.size.height))
    {
        return false;
    }

    const fence_fd = if (properties.in_fence_fd != 0 and source != null)
        source.?.export_read_fence(source.?.context)
    else
        null;
    defer {
        if (fence_fd) |value| _ = std.c.close(value);
    }
    if (fence_fd) |value| {
        if (!addAtomicProperty(request, plane_id, properties.in_fence_fd, @bitCast(@as(i64, value)))) {
            return false;
        }
    }
    return c.drmModeAtomicCommit(
        fd,
        request,
        c.DRM_MODE_ATOMIC_NONBLOCK | c.DRM_MODE_PAGE_FLIP_EVENT,
        self,
    ) == 0;
}

fn addAtomicProperty(
    request: *c.drmModeAtomicReq,
    object_id: u32,
    property_id: u32,
    value: u64,
) bool {
    return c.drmModeAtomicAddProperty(request, object_id, property_id, value) >= 0;
}

fn loadAtomicPlaneProperties(fd: std.posix.fd_t, plane_id: u32) ?AtomicPlaneProperties {
    if (plane_id == 0) return null;
    const properties = c.drmModeObjectGetProperties(
        fd,
        plane_id,
        c.DRM_MODE_OBJECT_PLANE,
    ) orelse return null;
    defer c.drmModeFreeObjectProperties(properties);

    var result: AtomicPlaneProperties = .{};
    const property_count: usize = @intCast(properties.*.count_props);
    for (properties.*.props[0..property_count]) |property_id| {
        const property = c.drmModeGetProperty(fd, property_id) orelse continue;
        defer c.drmModeFreeProperty(property);
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        inline for (.{
            .{ "FB_ID", "fb_id" },
            .{ "CRTC_ID", "crtc_id" },
            .{ "SRC_X", "src_x" },
            .{ "SRC_Y", "src_y" },
            .{ "SRC_W", "src_w" },
            .{ "SRC_H", "src_h" },
            .{ "CRTC_X", "crtc_x" },
            .{ "CRTC_Y", "crtc_y" },
            .{ "CRTC_W", "crtc_w" },
            .{ "CRTC_H", "crtc_h" },
            .{ "IN_FENCE_FD", "in_fence_fd" },
        }) |mapping| {
            if (std.mem.eql(u8, property_name, mapping[0])) {
                @field(result, mapping[1]) = property_id;
            }
        }
    }
    return if (result.complete()) result else null;
}

fn makeDirectFramebufferRoom(self: *Self, fd: std.posix.fd_t) !void {
    if (self.direct_framebuffers.count() < max_direct_framebuffers) return;
    var oldest_id: ?u64 = null;
    var oldest_frame: u64 = std.math.maxInt(u64);
    var iterator = self.direct_framebuffers.iterator();
    while (iterator.next()) |entry| {
        const id = entry.key_ptr.*;
        if ((self.direct_pending != null and self.direct_pending.?.cache_id == id) or
            (self.direct_displayed != null and self.direct_displayed.?.cache_id == id) or
            entry.value_ptr.last_used >= oldest_frame) continue;
        oldest_id = id;
        oldest_frame = entry.value_ptr.last_used;
    }
    const id = oldest_id orelse return error.CacheFull;
    const framebuffer = self.direct_framebuffers.fetchRemove(id).?.value;
    if (c.drmModeRmFB(fd, framebuffer.framebuffer_id) != 0) {
        log.err("failed to remove direct-scanout framebuffer {d}", .{framebuffer.framebuffer_id});
    }
}

fn releaseDirectScanouts(self: *Self) void {
    if (self.direct_pending) |scanout| scanout.release();
    if (self.direct_displayed) |scanout| scanout.release();
    self.direct_pending = null;
    self.direct_displayed = null;
    self.setDirectScanoutActive(false);
}

fn destroyDirectFramebuffers(self: *Self, fd: std.posix.fd_t) void {
    while (self.direct_framebuffers.count() > 0) {
        var iterator = self.direct_framebuffers.iterator();
        const id = iterator.next().?.key_ptr.*;
        const framebuffer = self.direct_framebuffers.fetchRemove(id).?.value;
        if (c.drmModeRmFB(fd, framebuffer.framebuffer_id) != 0) {
            log.err("failed to remove direct-scanout framebuffer {d}", .{framebuffer.framebuffer_id});
        }
    }
}

fn setDirectScanoutActive(self: *Self, active: bool) void {
    if (self.direct_scanout_active == active) return;
    self.direct_scanout_active = active;
    log.info("Direct scan-out {s}", .{if (active) "enabled" else "disabled"});
}

fn unavailableAtomic(_: *anyopaque) bool {
    return false;
}

const BufferPair = struct {
    buffers: [buffer_count]Buffer = .{ .{}, .{} },
    shadow_pixels: []u32 = &.{},
};

fn allocatePair(self: *Self, fd: std.posix.fd_t, size: render.Size) !BufferPair {
    if (self.allocateGpuPair(fd, size)) |pair| return pair else |err| {
        if (self.dmabuf_renderer != null and
            self.device_access.gbm(self.device_access.context) != null)
        {
            log.warn("GPU scanout allocation failed, using CPU buffers: {t}", .{err});
        }
    }
    log.info("allocating CPU shadow and scanout buffers at {d}x{d}", .{ size.width, size.height });
    var pair: BufferPair = .{};
    errdefer self.destroyPair(fd, &pair.buffers, pair.shadow_pixels);
    for (&pair.buffers) |*buffer| try self.createBuffer(fd, size, buffer);
    try createShadowBuffer(self.allocator, size, &pair.shadow_pixels);
    return pair;
}

fn allocateGpuPair(self: *Self, fd: std.posix.fd_t, size: render.Size) !BufferPair {
    const renderer = self.dmabuf_renderer orelse return error.NoDmabufRenderer;
    const gbm = self.device_access.gbm(self.device_access.context) orelse return error.NoGbmDevice;
    var compatible_modifiers: std.ArrayList(u64) = .empty;
    defer compatible_modifiers.deinit(self.allocator);
    for (self.scanout_modifiers) |modifier| {
        if (std.mem.indexOfScalar(u64, renderer.modifiers, modifier) != null and
            renderer.supports_target(renderer.context, size, modifier))
        {
            try compatible_modifiers.append(self.allocator, modifier);
        }
    }
    var last_error: anyerror = error.NoSupportedModifier;
    if (compatible_modifiers.items.len > 0) {
        var pair: BufferPair = .{};
        createGpuPair(fd, gbm, renderer, size, compatible_modifiers.items, &pair) catch |err| {
            last_error = err;
            self.destroyPair(fd, &pair.buffers, pair.shadow_pixels);
        };
        if (pair.buffers[0].render_target_id != null) {
            log.info(
                "allocated GPU scanout buffers at {d}x{d}, modifier 0x{x}",
                .{ size.width, size.height, pair.buffers[0].gbm.?.modifier },
            );
            return pair;
        }
    }
    if (!self.implicit_scanout) return last_error;

    var pair: BufferPair = .{};
    createGpuPair(fd, gbm, renderer, size, null, &pair) catch |err| {
        self.destroyPair(fd, &pair.buffers, pair.shadow_pixels);
        return err;
    };
    log.info(
        "allocated GPU scanout buffers at {d}x{d}, implicit modifier 0x{x}",
        .{ size.width, size.height, pair.buffers[0].gbm.?.modifier },
    );
    return pair;
}

fn createGpuPair(
    fd: std.posix.fd_t,
    gbm: *Gbm,
    renderer: render.DmabufRenderer,
    size: render.Size,
    modifiers: ?[]const u64,
    pair: *BufferPair,
) !void {
    for (&pair.buffers) |*buffer| {
        buffer.gbm = if (modifiers) |explicit|
            try gbm.createBuffer(size, c.DRM_FORMAT_XRGB8888, explicit)
        else
            try gbm.createImplicitBuffer(size, c.DRM_FORMAT_XRGB8888);
        const bo = &buffer.gbm.?;
        if (std.mem.indexOfScalar(u64, renderer.modifiers, bo.modifier) == null) {
            return error.UnsupportedRendererModifier;
        }
        var handles = [_]u32{ bo.handle, 0, 0, 0 };
        var pitches = [_]u32{ bo.stride, 0, 0, 0 };
        var offsets = [_]u32{ bo.offset, 0, 0, 0 };
        const result = if (modifiers == null)
            c.drmModeAddFB2(fd, size.width, size.height, c.DRM_FORMAT_XRGB8888, &handles, &pitches, &offsets, &buffer.framebuffer_id, 0)
        else blk: {
            var framebuffer_modifiers = [_]u64{ bo.modifier, 0, 0, 0 };
            break :blk c.drmModeAddFB2WithModifiers(fd, size.width, size.height, c.DRM_FORMAT_XRGB8888, &handles, &pitches, &offsets, &framebuffer_modifiers, &buffer.framebuffer_id, c.DRM_MODE_FB_MODIFIERS);
        };
        if (result != 0) return error.AddFramebufferFailed;
        const id = render.allocateRenderTargetId();
        try renderer.import_target(renderer.context, .{
            .id = id,
            .size = size,
            .fd = bo.fd,
            .format = c.DRM_FORMAT_XRGB8888,
            .modifier = bo.modifier,
            .stride = bo.stride,
            .offset = bo.offset,
        });
        buffer.render_target_id = id;
    }
}

fn destroyPair(self: *Self, fd: std.posix.fd_t, buffers: *[buffer_count]Buffer, shadow: []u32) void {
    for (buffers) |*buffer| self.destroyBuffer(fd, buffer);
    self.allocator.free(shadow);
}

fn createBuffer(self: *Self, fd: std.posix.fd_t, size: render.Size, buffer: *Buffer) !void {
    var create = std.mem.zeroes(c.struct_drm_mode_create_dumb);
    create.width = size.width;
    create.height = size.height;
    create.bpp = 32;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) {
        return error.CreateDumbBufferFailed;
    }
    buffer.handle = create.handle;
    errdefer self.destroyBuffer(fd, buffer);

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
    std.debug.assert(create.pitch % @sizeOf(u32) == 0);
    std.debug.assert(create.pitch >= size.width * @sizeOf(u32));
    buffer.stride_pixels = create.pitch / @sizeOf(u32);
    buffer.pixels = @as([*]u32, @ptrCast(@alignCast(mapping.ptr)))[0 .. mapping.len / @sizeOf(u32)];
    @memset(buffer.pixels, 0);
}

fn destroyBuffer(self: *Self, fd: std.posix.fd_t, buffer: *Buffer) void {
    if (buffer.render_target_id) |id| {
        const renderer = self.dmabuf_renderer orelse unreachable;
        renderer.release_target(renderer.context, id);
    }
    if (buffer.mapping) |mapping| std.posix.munmap(mapping);
    if (buffer.framebuffer_id != 0 and c.drmModeRmFB(fd, buffer.framebuffer_id) != 0) {
        log.err("failed to remove DRM framebuffer {d}", .{buffer.framebuffer_id});
    }
    if (buffer.gbm) |*gbm_buffer| {
        gbm_buffer.deinit();
    } else if (buffer.handle != 0) {
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

test "shadow copy respects scanout pitch" {
    const untouched = 0xfeed_beef;
    var destination = [_]u32{untouched} ** 10;
    const source = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var damage = Region.init();
    defer damage.deinit();
    try damage.add(1, 0, 2, 2);

    copyShadowDamage(
        &destination,
        5,
        &source,
        .{ .width = 3, .height = 2 },
        &damage,
    );

    try std.testing.expectEqualSlices(
        u32,
        &.{ untouched, 2, 3, untouched, untouched, untouched, 5, 6, untouched, untouched },
        &destination,
    );
}

fn testDeviceFd(_: *anyopaque) ?std.posix.fd_t {
    return null;
}

fn unavailableGbm(_: *anyopaque) ?*Gbm {
    return null;
}

fn testDeviceGbm(_: *anyopaque) ?*Gbm {
    return null;
}

fn testDeviceActive(_: *anyopaque) bool {
    return false;
}

fn testDeviceFail(_: *anyopaque, _: anyerror) void {
    unreachable;
}

test "preferred DRM mode wins over the first mode" {
    var modes = [_]c.drmModeModeInfo{
        std.mem.zeroes(c.drmModeModeInfo),
        std.mem.zeroes(c.drmModeModeInfo),
    };
    modes[1].type = c.DRM_MODE_TYPE_PREFERRED;
    try std.testing.expectEqual(@as(usize, 1), preferredModeIndex(&modes));
}

test "DRM mode inventory equality includes timing and preference" {
    var a = [_]Mode{.{
        .value = std.mem.zeroes(c.drmModeModeInfo),
        .preferred = true,
    }};
    var b = a;
    try std.testing.expect(modeListsEqual(&a, &b));
    b[0].value.vrefresh = 120;
    try std.testing.expect(!modeListsEqual(&a, &b));
    b = a;
    b[0].preferred = false;
    try std.testing.expect(!modeListsEqual(&a, &b));
}

test "DRM mode refresh converts to presentation period" {
    var mode = std.mem.zeroes(c.drmModeModeInfo);
    mode.vrefresh = 50;
    try std.testing.expectEqual(@as(u32, 20_000_000), refreshNanoseconds(mode));
    mode.vrefresh = 0;
    try std.testing.expectEqual(presentation.nominal_refresh_nanoseconds, refreshNanoseconds(mode));
}

test "GBM Vulkan target is accepted as a DRM framebuffer" {
    const fd = std.c.open("/dev/dri/card0", std.c.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    });
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    const VulkanRenderer = @import("../render/vulkan.zig");
    var renderer = VulkanRenderer.init(std.testing.allocator, .{ .major = 226, .minor = 0 }) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const access = renderer.dmabufAccess() orelse return error.SkipZigTest;
    var gbm = Gbm.init(fd) catch return error.SkipZigTest;
    defer gbm.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    const Selected = struct {
        buffer: Gbm.Buffer,
        framebuffer_id: u32,
        target_id: u64,
    };
    var selected: ?Selected = null;
    for (access.modifiers) |modifier| {
        var buffer = gbm.createBuffer(size, c.DRM_FORMAT_XRGB8888, &.{modifier}) catch continue;
        var handles = [_]u32{ buffer.handle, 0, 0, 0 };
        var pitches = [_]u32{ buffer.stride, 0, 0, 0 };
        var offsets = [_]u32{ buffer.offset, 0, 0, 0 };
        var framebuffer_id: u32 = 0;
        const add_result = if (buffer.modifier == drm_format_mod_linear)
            c.drmModeAddFB2(fd, size.width, size.height, c.DRM_FORMAT_XRGB8888, &handles, &pitches, &offsets, &framebuffer_id, 0)
        else blk: {
            var modifiers = [_]u64{ buffer.modifier, 0, 0, 0 };
            break :blk c.drmModeAddFB2WithModifiers(fd, size.width, size.height, c.DRM_FORMAT_XRGB8888, &handles, &pitches, &offsets, &modifiers, &framebuffer_id, c.DRM_MODE_FB_MODIFIERS);
        };
        if (add_result != 0) {
            buffer.deinit();
            continue;
        }
        const target_id = render.allocateRenderTargetId();
        access.import_target(access.context, .{
            .id = target_id,
            .size = size,
            .fd = buffer.fd,
            .format = c.DRM_FORMAT_XRGB8888,
            .modifier = buffer.modifier,
            .stride = buffer.stride,
            .offset = buffer.offset,
        }) catch {
            _ = c.drmModeRmFB(fd, framebuffer_id);
            buffer.deinit();
            continue;
        };
        selected = .{
            .buffer = buffer,
            .framebuffer_id = framebuffer_id,
            .target_id = target_id,
        };
        break;
    }
    if (selected == null) return error.SkipZigTest;
    defer selected.?.buffer.deinit();
    defer _ = c.drmModeRmFB(fd, selected.?.framebuffer_id);
    defer access.release_target(access.context, selected.?.target_id);

    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(12, 34, 56, 255) }},
    }, .{ .dmabuf = .{ .id = selected.?.target_id, .size = size } });
}

test "DRM scale preserves mode pixels and derives logical size" {
    var context: u8 = 0;
    var output: Self = undefined;
    output.init(std.testing.allocator, std.testing.io, .{
        .context = &context,
        .fd = testDeviceFd,
        .gbm = testDeviceGbm,
        .active = testDeviceActive,
        .fail = testDeviceFail,
    });
    defer output.deinit();
    output.size = .{ .width = 3840, .height = 2160 };
    output.scale = .{ .numerator = 150 };

    try std.testing.expectEqual(
        render.Size{ .width = 3072, .height = 1728 },
        output.logicalSize(),
    );
    try std.testing.expectEqual(render.Size{ .width = 3840, .height = 2160 }, output.size);
}

test "DRM discovery only accepts primary nodes" {
    try std.testing.expect(isPrimaryNode("/dev/dri/card0"));
    try std.testing.expect(isPrimaryNode("/dev/dri/card12"));
    try std.testing.expect(!isPrimaryNode("/dev/dri/renderD128"));
    try std.testing.expect(!isPrimaryNode("/sys/class/drm/card0-DP-1"));
}

test "CRTC selection preserves preferred and never selects claimed" {
    var ids = [_]u32{ 10, 20, 30 };
    var resources = std.mem.zeroes(c.drmModeRes);
    resources.count_crtcs = ids.len;
    resources.crtcs = &ids;
    try std.testing.expectEqual(@as(?usize, 1), selectCrtcIndex(&resources, 0b111, 20, 0));
    try std.testing.expectEqual(@as(?usize, 0), selectCrtcIndex(&resources, 0b111, 20, 0b010));
    try std.testing.expectEqual(@as(?usize, null), selectCrtcIndex(&resources, 0b011, null, 0b011));
}
