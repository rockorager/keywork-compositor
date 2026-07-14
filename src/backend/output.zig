//! Runtime-selected compositor output backend.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmOutput = @import("drm.zig");
const DrmDevice = @import("drm_device.zig");
const HeadlessOutput = @import("headless.zig");
const NestedOutput = @import("nested_wayland.zig");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");

const wl = wayland.server.wl;

io: std.Io,
backend: Backend,

const Backend = union(enum) {
    drm: *DrmOutput,
    headless: HeadlessOutput,
    nested: NestedOutput,
};

pub const Kind = enum {
    drm,
    headless,
    nested,
};

pub const Listener = NestedOutput.Listener;

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *wl.Server,
    output_size: render.Size,
    kind: Kind,
    drm_device: ?*DrmDevice,
    listener: Listener,
) !void {
    self.io = io;
    switch (kind) {
        .drm => {
            const output = &(drm_device orelse return error.MissingDrmDevice).output;
            output.attach(listener);
            self.backend = .{ .drm = output };
        },
        .headless => self.backend = .{ .headless = try HeadlessOutput.init(allocator, output_size) },
        .nested => {
            self.backend = .{ .nested = undefined };
            try self.backend.nested.init(io, display, output_size, listener);
        },
    }
}

pub fn name(self: *const Self, fallback: []const u8) []const u8 {
    return switch (self.backend) {
        .drm => |output| output.name(),
        .headless, .nested => fallback,
    };
}

pub fn model(self: *const Self, fallback: []const u8) []const u8 {
    return switch (self.backend) {
        .drm => |output| output.name(),
        .headless, .nested => fallback,
    };
}

pub fn deinit(self: *Self) void {
    switch (self.backend) {
        .drm => |output| output.detach(),
        .headless => |*output| output.deinit(),
        .nested => |*output| output.deinit(),
    }
    self.* = undefined;
}

pub fn size(self: *const Self) render.Size {
    return switch (self.backend) {
        .drm => |output| output.size,
        .headless => |output| output.size,
        .nested => |output| output.size,
    };
}

pub fn physicalSize(self: *const Self) render.Size {
    return switch (self.backend) {
        .drm => |output| output.physical_size,
        .headless => |output| output.size,
        .nested => |output| output.buffer_size,
    };
}

pub fn renderScale(self: *const Self) render.Scale {
    return switch (self.backend) {
        .drm => .{},
        .headless => .{},
        .nested => |output| output.render_scale,
    };
}

pub fn clientScale(self: *const Self) u32 {
    return switch (self.backend) {
        .drm => 1,
        .headless => 1,
        .nested => |output| output.client_scale,
    };
}

pub fn ready(self: *const Self) bool {
    return switch (self.backend) {
        .drm => |output| output.ready(),
        .headless => true,
        .nested => |*output| output.ready(),
    };
}

pub fn repaintDelayMilliseconds(self: *const Self) i32 {
    return switch (self.backend) {
        .drm => 1,
        .headless => 16,
        // A zero-delay libwayland timer is disarmed rather than immediate.
        .nested => 1,
    };
}

pub fn presentationClockId(self: *const Self) u32 {
    return switch (self.backend) {
        .drm => |output| output.presentation_clock_id,
        .headless => presentation.monotonic_clock_id,
        .nested => |*output| output.presentationClockId(),
    };
}

pub fn acquire(self: *Self) ?render.PixelBuffer {
    return switch (self.backend) {
        .drm => |output| output.acquire(),
        .headless => |*output| output.target(),
        .nested => |*output| output.acquire(),
    };
}

pub fn cancel(self: *Self) void {
    switch (self.backend) {
        .drm => |output| output.cancel(),
        .headless => {},
        .nested => |*output| output.cancel(),
    }
}

pub fn present(self: *Self) !?presentation.Info {
    return switch (self.backend) {
        .drm => |output| output.present(),
        .headless => presentation.Info.now(self.io),
        .nested => |*output| blk: {
            try output.present();
            break :blk null;
        },
    };
}
