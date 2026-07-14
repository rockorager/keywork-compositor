//! Stable protocol-output ownership and global logical layout.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const render = @import("../render/types.zig");
const slot_map = @import("../slot_map.zig");
const Output = @import("output.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
display: *wl.Server,
surfaces: *Surface.Store,
outputs: Store,

const Store = slot_map.SlotMap(*Output, enum { output });
pub const Id = Store.Id;

pub const Config = struct {
    position: Output.Position = .{},
    size: render.Size,
    physical_size: render.Size,
    scale: u32,
};

pub const Entry = struct {
    id: Id,
    output: *Output,
};

pub const Iterator = struct {
    inner: Store.Iterator,

    pub fn next(self: *Iterator) ?Entry {
        const entry = self.inner.next() orelse return null;
        return .{ .id = entry.id, .output = entry.value.* };
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surfaces: *Surface.Store,
) void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .surfaces = surfaces,
        .outputs = .{},
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.outputs.len() == 0);
    self.outputs.deinit(self.allocator);
    self.* = undefined;
}

pub fn add(self: *Self, config: Config) !Id {
    const output = try self.allocator.create(Output);
    errdefer self.allocator.destroy(output);
    try output.init(
        self.allocator,
        self.display,
        config.position,
        config.size,
        config.physical_size,
        config.scale,
        self.surfaces,
    );
    errdefer output.deinit();
    return self.outputs.insert(self.allocator, output);
}

pub fn remove(self: *Self, id: Id) bool {
    const output = self.outputs.remove(id) orelse return false;
    output.deinit();
    self.allocator.destroy(output);
    return true;
}

pub fn get(self: *Self, id: Id) ?*Output {
    const output = self.outputs.get(id) orelse return null;
    return output.*;
}

pub fn getConst(self: *const Self, id: Id) ?*const Output {
    const output = self.outputs.getConst(id) orelse return null;
    return output.*;
}

pub fn findResource(self: *Self, resource: *wl.Output) ?Entry {
    var outputs = self.iterator();
    while (outputs.next()) |entry| {
        if (entry.output.ownsResource(resource)) return entry;
    }
    return null;
}

pub fn configureSurface(self: *Self, surface: *wl.Surface) void {
    var outputs = self.iterator();
    while (outputs.next()) |entry| entry.output.configureSurface(surface);
}

pub fn iterator(self: *Self) Iterator {
    return .{ .inner = self.outputs.iterator() };
}

test "output handles are stable across additions and stale after removal" {
    const display = try wl.Server.create();
    defer display.destroy();

    var surfaces: Surface.Store = .{};
    defer surfaces.deinit(std.testing.allocator);

    var layout: Self = undefined;
    layout.init(std.testing.allocator, display, &surfaces);
    defer layout.deinit();

    const first = try layout.add(.{
        .size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 1280, .height = 720 },
        .scale = 1,
    });
    const first_output = layout.get(first).?;
    const second = try layout.add(.{
        .position = .{ .x = 1280 },
        .size = .{ .width = 1920, .height = 1080 },
        .physical_size = .{ .width = 3840, .height = 2160 },
        .scale = 2,
    });

    try std.testing.expect(layout.get(first).? == first_output);
    try std.testing.expectEqual(Output.Position{ .x = 1280 }, layout.get(second).?.logicalPosition());
    try std.testing.expect(layout.remove(first));
    try std.testing.expectEqual(@as(?*Output, null), layout.get(first));
    try std.testing.expect(layout.remove(second));
}
