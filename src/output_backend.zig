//! Runtime-selected compositor output backend.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const HeadlessOutput = @import("headless.zig");
const NestedOutput = @import("nested_output.zig");
const render = @import("render.zig");

const wl = wayland.server.wl;

backend: Backend,

const Backend = union(enum) {
    headless: HeadlessOutput,
    nested: NestedOutput,
};

pub const Kind = enum {
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
    listener: Listener,
) !void {
    switch (kind) {
        .headless => self.backend = .{ .headless = try HeadlessOutput.init(allocator, output_size) },
        .nested => {
            self.backend = .{ .nested = undefined };
            try self.backend.nested.init(io, display, output_size, listener);
        },
    }
}

pub fn deinit(self: *Self) void {
    switch (self.backend) {
        .headless => |*output| output.deinit(),
        .nested => |*output| output.deinit(),
    }
    self.* = undefined;
}

pub fn size(self: *const Self) render.Size {
    return switch (self.backend) {
        .headless => |output| output.size,
        .nested => |output| output.size,
    };
}

pub fn physicalSize(self: *const Self) render.Size {
    return switch (self.backend) {
        .headless => |output| output.size,
        .nested => |output| output.buffer_size,
    };
}

pub fn renderScale(self: *const Self) render.Scale {
    return switch (self.backend) {
        .headless => .{},
        .nested => |output| output.render_scale,
    };
}

pub fn clientScale(self: *const Self) u32 {
    return switch (self.backend) {
        .headless => 1,
        .nested => |output| output.client_scale,
    };
}

pub fn acquire(self: *Self) ?render.PixelBuffer {
    return switch (self.backend) {
        .headless => |*output| output.target(),
        .nested => |*output| output.acquire(),
    };
}

pub fn cancel(self: *Self) void {
    switch (self.backend) {
        .headless => {},
        .nested => |*output| output.cancel(),
    }
}

pub fn present(self: *Self) !void {
    switch (self.backend) {
        .headless => {},
        .nested => |*output| try output.present(),
    }
}
