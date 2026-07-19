//! GBM allocation for DRM scanout buffers shared with a GPU renderer.

const Self = @This();

const std = @import("std");
const render = @import("../render/types.zig");

const c = @cImport({
    @cInclude("gbm.h");
});

device: *c.gbm_device,

pub const Buffer = struct {
    bo: *c.gbm_bo,
    fd: std.posix.fd_t,
    format: u32,
    handle: u32,
    stride: u32,
    offset: u32,
    modifier: u64,

    pub fn deinit(self: *Buffer) void {
        _ = std.c.close(self.fd);
        c.gbm_bo_destroy(self.bo);
        self.* = undefined;
    }
};

pub fn init(fd: std.posix.fd_t) !Self {
    return .{ .device = c.gbm_create_device(fd) orelse return error.CreateDeviceFailed };
}

pub fn deinit(self: *Self) void {
    c.gbm_device_destroy(self.device);
    self.* = undefined;
}

pub fn createBuffer(
    self: *Self,
    size: render.Size,
    format: u32,
    modifiers: []const u64,
) !Buffer {
    std.debug.assert(modifiers.len > 0);
    const flags = c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING;
    const bo = c.gbm_bo_create_with_modifiers2(
        self.device,
        size.width,
        size.height,
        format,
        modifiers.ptr,
        @intCast(modifiers.len),
        flags,
    ) orelse return error.CreateBufferFailed;
    return exportBuffer(bo);
}

pub fn createImplicitBuffer(self: *Self, size: render.Size, format: u32) !Buffer {
    const bo = c.gbm_bo_create(
        self.device,
        size.width,
        size.height,
        format,
        c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING,
    ) orelse return error.CreateBufferFailed;
    return exportBuffer(bo);
}

fn exportBuffer(bo: *c.gbm_bo) !Buffer {
    errdefer c.gbm_bo_destroy(bo);
    if (c.gbm_bo_get_plane_count(bo) != 1) return error.UnsupportedPlaneCount;
    const fd = c.gbm_bo_get_fd_for_plane(bo, 0);
    if (fd < 0) return error.ExportBufferFailed;
    return .{
        .bo = bo,
        .fd = fd,
        .format = c.gbm_bo_get_format(bo),
        .handle = c.gbm_bo_get_handle_for_plane(bo, 0).u32,
        .stride = c.gbm_bo_get_stride_for_plane(bo, 0),
        .offset = c.gbm_bo_get_offset(bo, 0),
        .modifier = c.gbm_bo_get_modifier(bo),
    };
}
