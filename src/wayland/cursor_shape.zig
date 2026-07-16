//! Enumerated cursor shapes backed by the user's Xcursor theme.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const Seat = @import("seat.zig");
const Tablet = @import("tablet.zig");
const render = @import("../render/types.zig");

const xcursor = @cImport({
    @cInclude("X11/Xcursor/Xcursor.h");
});

const wl = wayland.server.wl;
const wp = wayland.server.wp;
const log = std.log.scoped(.cursor_shape);

const Shape = wp.CursorShapeDeviceV1.Shape;
const shape_count = @intFromEnum(Shape.all_resize);
const default_cursor_size = 24;

allocator: std.mem.Allocator,
global: *wl.Global,
tablet: *Tablet,
listener: Listener,
images: [shape_count]?*xcursor.XcursorImage,
source_cache_ids: [shape_count]u64,
theme: ?[*:0]u8,
size: c_int,
device_count: usize,

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    tablet: *Tablet,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = try wl.Global.create(
            display,
            wp.CursorShapeManagerV1,
            2,
            *Self,
            self,
            bind,
        ),
        .tablet = tablet,
        .listener = listener,
        .images = @splat(null),
        .source_cache_ids = @splat(0),
        .theme = std.c.getenv("XCURSOR_THEME"),
        .size = configuredSize(),
        .device_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.device_count == 0);
    self.listener.clear_shapes(self.listener.context);
    self.global.destroy();
    for (self.images) |image| if (image) |loaded| xcursor.XcursorImageDestroy(loaded);
    self.* = undefined;
}

pub const Listener = struct {
    context: *anyopaque,
    clear_shapes: *const fn (*anyopaque) void,
};

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wp.CursorShapeManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *wp.CursorShapeManagerV1,
    request: wp.CursorShapeManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_pointer => |get| Device.create(
            self,
            resource,
            get.cursor_shape_device,
            if (Seat.pointerBinding(get.pointer)) |pointer|
                .{ .pointer = pointer }
            else
                null,
        ) catch resource.postNoMemory(),
        .get_tablet_tool_v2 => |get| Device.create(
            self,
            resource,
            get.cursor_shape_device,
            if (self.tablet.toolBinding(get.tablet_tool)) |tool|
                .{ .tablet_tool = tool }
            else
                null,
        ) catch resource.postNoMemory(),
    }
}

pub fn defaultCursor(self: *Self) ?Seat.CursorImage {
    const cursor_image = self.cursorImage(.default) orelse return null;
    return .{
        .buffer = cursor_image.buffer,
        .hotspot_x = cursor_image.hotspot_x,
        .hotspot_y = cursor_image.hotspot_y,
    };
}

fn cursor(self: *Self, client: *wl.Client, shape: Shape) ?Seat.ShapeCursor {
    const cursor_image = self.cursorImage(shape) orelse return null;
    return .{
        .client = client,
        .buffer = cursor_image.buffer,
        .hotspot_x = cursor_image.hotspot_x,
        .hotspot_y = cursor_image.hotspot_y,
    };
}

fn cursorImage(self: *Self, shape: Shape) ?Seat.CursorImage {
    const index = shapeIndex(shape);
    const image = self.images[index] orelse loaded: {
        const name = shapeName(shape);
        const loaded_image_c = xcursor.XcursorLibraryLoadImage(
            name,
            if (self.theme) |theme| theme else null,
            self.size,
        ) orelse xcursor.XcursorLibraryLoadImage(
            if (shape == .default) "left_ptr" else "default",
            if (self.theme) |theme| theme else null,
            self.size,
        ) orelse {
            log.warn("Xcursor theme has no image for {s}", .{name});
            return null;
        };
        const loaded_image: *xcursor.XcursorImage = @ptrCast(loaded_image_c);
        self.images[index] = loaded_image;
        self.source_cache_ids[index] = render.allocateSourceCacheId();
        break :loaded loaded_image;
    };
    const pixel_count = std.math.mul(usize, image.width, image.height) catch return null;
    const pixels: [*]u32 = @ptrCast(image.pixels);
    return .{
        .buffer = .{
            .size = .{ .width = image.width, .height = image.height },
            .stride_pixels = image.width,
            .pixels = pixels[0..pixel_count],
            .source_cache = .{ .id = self.source_cache_ids[index], .version = 1 },
        },
        .hotspot_x = @intCast(image.xhot),
        .hotspot_y = @intCast(image.yhot),
    };
}

const Device = struct {
    manager: *Self,
    client: *wl.Client,
    target: ?Target,

    const Target = union(enum) {
        pointer: Seat.PointerBinding,
        tablet_tool: Tablet.ToolBinding,
    };

    fn create(
        manager: *Self,
        manager_resource: *wp.CursorShapeManagerV1,
        id: u32,
        target: ?Target,
    ) !void {
        const resource = try wp.CursorShapeDeviceV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Device);
        self.* = .{
            .manager = manager,
            .client = manager_resource.getClient(),
            .target = target,
        };
        manager.device_count += 1;
        resource.setHandler(*Device, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *wp.CursorShapeDeviceV1,
        request: wp.CursorShapeDeviceV1.Request,
        self: *Device,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_shape => |set| {
                const shape_value = @intFromEnum(set.shape);
                if (shape_value < @intFromEnum(Shape.default) or
                    shape_value > maximumShape(resource.getVersion()))
                {
                    resource.postError(.invalid_shape, "shape is unavailable at this protocol version");
                    return;
                }
                const target = self.target orelse return;
                const cursor_image = self.manager.cursor(self.client, set.shape) orelse return;
                switch (target) {
                    .pointer => |pointer| {
                        if (!pointer.isActive()) return;
                        pointer.seat.setCursorShape(self.client, set.serial, cursor_image);
                    },
                    .tablet_tool => |tool| tool.setCursorShape(
                        self.client,
                        set.serial,
                        cursor_image,
                    ),
                }
            },
        }
    }

    fn handleDestroy(_: *wp.CursorShapeDeviceV1, self: *Device) void {
        self.manager.device_count -= 1;
        self.manager.allocator.destroy(self);
    }
};

fn configuredSize() c_int {
    const value_z = std.c.getenv("XCURSOR_SIZE") orelse return default_cursor_size;
    const value = std.fmt.parseInt(u15, std.mem.span(value_z), 10) catch
        return default_cursor_size;
    return if (value > 0) value else default_cursor_size;
}

fn maximumShape(version: u32) c_int {
    return if (version >= 2) @intFromEnum(Shape.all_resize) else @intFromEnum(Shape.zoom_out);
}

fn shapeIndex(shape: Shape) usize {
    return @intCast(@intFromEnum(shape) - 1);
}

fn shapeName(shape: Shape) [:0]const u8 {
    return switch (shape) {
        .default => "default",
        .context_menu => "context-menu",
        .help => "help",
        .pointer => "pointer",
        .progress => "progress",
        .wait => "wait",
        .cell => "cell",
        .crosshair => "crosshair",
        .text => "text",
        .vertical_text => "vertical-text",
        .alias => "alias",
        .copy => "copy",
        .move => "move",
        .no_drop => "no-drop",
        .not_allowed => "not-allowed",
        .grab => "grab",
        .grabbing => "grabbing",
        .e_resize => "e-resize",
        .n_resize => "n-resize",
        .ne_resize => "ne-resize",
        .nw_resize => "nw-resize",
        .s_resize => "s-resize",
        .se_resize => "se-resize",
        .sw_resize => "sw-resize",
        .w_resize => "w-resize",
        .ew_resize => "ew-resize",
        .ns_resize => "ns-resize",
        .nesw_resize => "nesw-resize",
        .nwse_resize => "nwse-resize",
        .col_resize => "col-resize",
        .row_resize => "row-resize",
        .all_scroll => "all-scroll",
        .zoom_in => "zoom-in",
        .zoom_out => "zoom-out",
        .dnd_ask => "dnd-ask",
        .all_resize => "all-resize",
        _ => unreachable,
    };
}

test "shape names use the standard Xcursor spelling" {
    try std.testing.expectEqualStrings("default", shapeName(.default));
    try std.testing.expectEqualStrings("context-menu", shapeName(.context_menu));
    try std.testing.expectEqualStrings("nwse-resize", shapeName(.nwse_resize));
    try std.testing.expectEqualStrings("dnd-ask", shapeName(.dnd_ask));
}

test "version one excludes version two cursor shapes" {
    try std.testing.expectEqual(@intFromEnum(Shape.zoom_out), maximumShape(1));
    try std.testing.expectEqual(@intFromEnum(Shape.all_resize), maximumShape(2));
}
