//! Rectangle-region operations shared by Wayland state and damage tracking.

const Self = @This();

const std = @import("std");

const pixman = @cImport({
    @cInclude("pixman.h");
});

region: pixman.pixman_region32_t,

pub const Error = error{OutOfMemory};

pub fn init() Self {
    var self: Self = undefined;
    pixman.pixman_region32_init(&self.region);
    return self;
}

pub fn deinit(self: *Self) void {
    pixman.pixman_region32_fini(&self.region);
    self.* = undefined;
}

pub fn clear(self: *Self) void {
    pixman.pixman_region32_clear(&self.region);
}

pub fn copyFrom(self: *Self, other: *const Self) Error!void {
    if (pixman.pixman_region32_copy(&self.region, &other.region) == 0) {
        return error.OutOfMemory;
    }
}

pub fn unionWith(self: *Self, other: *const Self) Error!void {
    if (pixman.pixman_region32_union(&self.region, &self.region, &other.region) == 0) {
        return error.OutOfMemory;
    }
}

pub fn add(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
    if (width <= 0 or height <= 0) return;

    if (pixman.pixman_region32_union_rect(
        &self.region,
        &self.region,
        x,
        y,
        @intCast(width),
        @intCast(height),
    ) == 0) {
        return error.OutOfMemory;
    }
}

pub fn subtract(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
    if (width <= 0 or height <= 0) return;

    var rectangle: pixman.pixman_region32_t = undefined;
    pixman.pixman_region32_init_rect(
        &rectangle,
        x,
        y,
        @intCast(width),
        @intCast(height),
    );
    defer pixman.pixman_region32_fini(&rectangle);

    if (pixman.pixman_region32_subtract(&self.region, &self.region, &rectangle) == 0) {
        return error.OutOfMemory;
    }
}

pub fn contains(self: *const Self, x: i32, y: i32) bool {
    return pixman.pixman_region32_contains_point(&self.region, x, y, null) != 0;
}

test "region unions and subtracts rectangles" {
    var region = Self.init();
    defer region.deinit();

    try region.add(0, 0, 8, 8);
    try region.subtract(2, 2, 4, 4);

    try std.testing.expect(region.contains(1, 1));
    try std.testing.expect(!region.contains(3, 3));
    try std.testing.expect(region.contains(7, 7));
}

test "region copy has independent storage" {
    var source = Self.init();
    defer source.deinit();
    try source.add(0, 0, 4, 4);

    var copy = Self.init();
    defer copy.deinit();
    try copy.copyFrom(&source);
    try copy.subtract(0, 0, 2, 2);

    try std.testing.expect(source.contains(1, 1));
    try std.testing.expect(!copy.contains(1, 1));
}
