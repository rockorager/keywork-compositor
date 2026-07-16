//! Renderer-independent command, frame, and pixel-buffer data.

const std = @import("std");

var next_source_cache_id: std.atomic.Value(u64) = .init(1);
var next_render_target_id: std.atomic.Value(u64) = .init(1);

pub fn allocateSourceCacheId() u64 {
    const id = next_source_cache_id.fetchAdd(1, .monotonic);
    std.debug.assert(id != 0);
    return id;
}

pub fn allocateRenderTargetId() u64 {
    const id = next_render_target_id.fetchAdd(1, .monotonic);
    std.debug.assert(id != 0);
    return id;
}

pub const Size = struct {
    width: u32,
    height: u32,

    pub fn pixelCount(self: Size) error{Overflow}!usize {
        return std.math.mul(usize, self.width, self.height);
    }
};

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Scale = struct {
    numerator: u32 = denominator,

    pub const denominator = 120;

    pub fn ceil(self: Scale) error{ InvalidScale, Overflow }!u32 {
        if (self.numerator == 0) return error.InvalidScale;
        return std.math.divCeil(u32, self.numerator, denominator) catch
            return error.Overflow;
    }

    pub fn apply(self: Scale, size: Size) error{ InvalidScale, Overflow }!Size {
        if (self.numerator == 0) return error.InvalidScale;
        return .{
            .width = try self.applyDimension(size.width),
            .height = try self.applyDimension(size.height),
        };
    }

    pub fn logicalSize(self: Scale, pixel_size: Size) error{ InvalidScale, InvalidDimensions, Overflow }!Size {
        if (self.numerator == 0) return error.InvalidScale;
        const width = try self.logicalDimension(pixel_size.width);
        const height = try self.logicalDimension(pixel_size.height);
        if (width == 0 or height == 0) return error.InvalidDimensions;
        return .{ .width = width, .height = height };
    }

    fn applyDimension(self: Scale, value: u32) error{Overflow}!u32 {
        const product = std.math.mul(u64, value, self.numerator) catch
            return error.Overflow;
        const rounded = std.math.add(u64, product, denominator / 2) catch
            return error.Overflow;
        const result = rounded / denominator;
        if (result > std.math.maxInt(u32)) return error.Overflow;
        return @intCast(result);
    }

    fn logicalDimension(self: Scale, value: u32) error{Overflow}!u32 {
        const product = std.math.mul(u64, value, denominator) catch
            return error.Overflow;
        const result = product / self.numerator;
        if (result > std.math.maxInt(u32)) return error.Overflow;
        return @intCast(result);
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const left = @max(@as(i64, self.x), other.x);
        const top = @max(@as(i64, self.y), other.y);
        const right = @min(
            @as(i64, self.x) + self.width,
            @as(i64, other.x) + other.width,
        );
        const bottom = @min(
            @as(i64, self.y) + self.height,
            @as(i64, other.y) + other.height,
        );
        if (left >= right or top >= bottom) return null;
        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }

    pub fn translated(self: Rect, x: i32, y: i32) Rect {
        return .{
            .x = self.x +| x,
            .y = self.y +| y,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn clipTo(self: Rect, size: Size) ?Rect {
        const left = @max(@as(i64, self.x), 0);
        const top = @max(@as(i64, self.y), 0);
        const right = @min(@as(i64, self.x) + self.width, size.width);
        const bottom = @min(@as(i64, self.y) + self.height, size.height);

        if (left >= right or top >= bottom) return null;

        return .{
            .x = @intCast(left),
            .y = @intCast(top),
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }
};

/// An 8-bit premultiplied-alpha color.
pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,

    pub fn rgba(red: u8, green: u8, blue: u8, alpha: u8) Color {
        return .{
            .red = premultiply(red, alpha),
            .green = premultiply(green, alpha),
            .blue = premultiply(blue, alpha),
            .alpha = alpha,
        };
    }

    pub fn argb8888(self: Color) u32 {
        return @as(u32, self.alpha) << 24 |
            @as(u32, self.red) << 16 |
            @as(u32, self.green) << 8 |
            self.blue;
    }

    fn premultiply(component: u8, alpha: u8) u8 {
        const product = @as(u16, component) * alpha + 127;
        return @intCast(product / 255);
    }
};

pub const SolidRect = struct {
    rect: Rect,
    color: Color,
    clip: ?Rect = null,
};

pub const SourceRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const RoundedClip = struct {
    rect: Rect,
    radius: u32,
};

pub const BufferTransform = enum(u8) {
    normal,
    rotate_90,
    rotate_180,
    rotate_270,
    flipped,
    flipped_90,
    flipped_180,
    flipped_270,

    pub fn swapsAxes(self: BufferTransform) bool {
        return switch (self) {
            .rotate_90, .rotate_270, .flipped_90, .flipped_270 => true,
            .normal, .rotate_180, .flipped, .flipped_180 => false,
        };
    }

    pub fn applyToSize(self: BufferTransform, size: Size) Size {
        return if (self.swapsAxes())
            .{ .width = size.height, .height = size.width }
        else
            size;
    }
};

pub const Image = struct {
    x: i32,
    y: i32,
    size: Size,
    buffer: PixelBuffer,
    source: ?SourceRect = null,
    transform: BufferTransform = .normal,
    rounded_clip: ?RoundedClip = null,
    clip: ?Rect = null,
    is_opaque: bool = false,
};

pub const Shadow = struct {
    rect: Rect,
    corner_radius: u32,
    blur_radius: u32,
    spread: i32,
    color: Color,
    clip: ?Rect = null,
};

pub const BackdropBlur = struct {
    rect: Rect,
    corner_radius: u32,
    radius: u32,
    clip: ?Rect = null,
};

pub const Command = union(enum) {
    clear: Color,
    solid_rect: SolidRect,
    shadow: Shadow,
    backdrop_blur: BackdropBlur,
    image: Image,
};

pub const Frame = struct {
    size: Size,
    commands: []const Command,
    /// Target-local physical pixels to update. Null updates the full target.
    damage: ?[]const Rect = null,
    scale: Scale = .{},
    /// Global logical coordinate rendered at the target's top-left corner.
    origin: Position = .{},
};

/// A CPU-addressable ARGB8888 target or a retained DMA-BUF image source.
/// Render targets are always CPU-addressable. Image sources may instead set
/// `dmabuf` and leave `pixels` empty so GPU renderers can sample them directly.
pub const PixelBuffer = struct {
    size: Size,
    stride_pixels: u32,
    pixels: []u32 = &.{},
    dmabuf: ?DmabufSource = null,
    /// Stable content identity for renderer texture caches. Anonymous buffers
    /// leave this null and must be uploaded whenever they are rendered.
    source_cache: ?SourceCache = null,
    /// Changed pixels for this source-cache version, in buffer coordinates.
    /// Null means the full buffer or unknown damage.
    source_damage: ?[]const Rect = null,
};

pub const DmabufSource = struct {
    context: *anyopaque,
    fd: std.posix.fd_t,
    format: u32,
    modifier: u64,
    stride: u32,
    offset: u32,
    required_bytes: usize,
    y_inverted: bool,
    force_opaque: bool,
    retain: *const fn (*anyopaque) void,
    release: *const fn (*anyopaque) void,
    begin_cpu_read: *const fn (*anyopaque) bool,
    end_cpu_read: *const fn (*anyopaque) bool,
    export_read_fence: *const fn (*anyopaque) ?std.posix.fd_t,
};

pub const Target = union(enum) {
    pixels: PixelBuffer,
    offscreen: OffscreenTarget,
    dmabuf: DmabufTarget,

    pub fn size(self: Target) Size {
        return switch (self) {
            .pixels => |pixels| pixels.size,
            .offscreen => |offscreen| offscreen.size,
            .dmabuf => |dmabuf| dmabuf.size,
        };
    }
};

pub const OffscreenTarget = struct {
    id: u64,
    size: Size,
};

pub const DmabufTarget = struct {
    id: u64,
    size: Size,
};

pub const DmabufDescriptor = struct {
    id: u64,
    size: Size,
    fd: std.posix.fd_t,
    format: u32,
    modifier: u64,
    stride: u32,
    offset: u32,
};

pub const DrmDeviceId = struct {
    major: u32,
    minor: u32,
};

/// Renderer operations borrowed by a DRM output for the lifetime of the
/// renderer. Import duplicates the descriptor's borrowed file descriptor.
pub const DmabufRenderer = struct {
    context: *anyopaque,
    modifiers: []const u64,
    supports_target: *const fn (*anyopaque, Size, u64) bool,
    import_target: *const fn (*anyopaque, DmabufDescriptor) anyerror!void,
    release_target: *const fn (*anyopaque, u64) void,
};

/// Renderer-owned storage for outputs which have no display backend. The
/// target remains GPU-resident unless a separate capture operation requests
/// CPU-addressable pixels.
pub const OffscreenRenderer = struct {
    context: *anyopaque,
    create_target: *const fn (*anyopaque, Size) anyerror!OffscreenTarget,
    release_target: *const fn (*anyopaque, u64) void,
};

pub const SourceCache = struct {
    id: u64,
    version: u64,
};

test "color conversion premultiplies alpha" {
    const color = Color.rgba(255, 127, 0, 128);

    try std.testing.expectEqual(@as(u8, 128), color.red);
    try std.testing.expectEqual(@as(u8, 64), color.green);
    try std.testing.expectEqual(@as(u8, 0), color.blue);
    try std.testing.expectEqual(@as(u8, 128), color.alpha);
    try std.testing.expectEqual(@as(u32, 0x80804000), color.argb8888());
}

test "fractional scale rounds physical dimensions halfway up" {
    const scale: Scale = .{ .numerator = 180 };
    try std.testing.expectEqual(@as(u32, 2), try scale.ceil());
    try std.testing.expectEqual(
        Size{ .width = 1920, .height = 1080 },
        try scale.apply(.{ .width = 1280, .height = 720 }),
    );
    try std.testing.expectEqual(
        Size{ .width = 2, .height = 5 },
        try scale.apply(.{ .width = 1, .height = 3 }),
    );
}

test "fractional scale floors logical output dimensions" {
    const scale: Scale = .{ .numerator = 156 };
    try std.testing.expectEqual(
        Size{ .width = 1476, .height = 830 },
        try scale.logicalSize(.{ .width = 1920, .height = 1080 }),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        (Scale{ .numerator = 240 }).logicalSize(.{ .width = 1, .height = 1 }),
    );
}

test "rectangle clipping handles negative and overflowing coordinates" {
    const clipped = (Rect{
        .x = -2,
        .y = 3,
        .width = 8,
        .height = 10,
    }).clipTo(.{ .width = 5, .height = 7 });

    try std.testing.expectEqual(Rect{
        .x = 0,
        .y = 3,
        .width = 5,
        .height = 4,
    }, clipped.?);

    try std.testing.expectEqual(@as(?Rect, null), (Rect{
        .x = 5,
        .y = 0,
        .width = 1,
        .height = 1,
    }).clipTo(.{ .width = 5, .height = 7 }));
}

test "rectangle intersection and translation preserve logical coordinates" {
    const first: Rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 };
    const second: Rect = .{ .x = 25, .y = 5, .width = 30, .height = 30 };

    try std.testing.expectEqual(Rect{
        .x = 25,
        .y = 20,
        .width = 15,
        .height = 15,
    }, first.intersection(second).?);
    try std.testing.expectEqual(Rect{
        .x = 7,
        .y = 24,
        .width = 30,
        .height = 40,
    }, first.translated(-3, 4));
    try std.testing.expectEqual(@as(?Rect, null), first.intersection(.{
        .x = 40,
        .y = 20,
        .width = 1,
        .height = 1,
    }));
}
