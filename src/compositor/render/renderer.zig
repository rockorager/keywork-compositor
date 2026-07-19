//! Runtime-selected renderer.

const std = @import("std");
const CpuRenderer = @import("cpu.zig");
const VulkanRenderer = @import("vulkan.zig");
const headless = @import("../backend/headless.zig");
const render_types = @import("types.zig");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    commands: std.ArrayList(render_types.Command),
    active_frame: ?ActiveFrame,

    pub const Kind = enum {
        cpu,
        vulkan,
    };

    pub const Error = CpuRenderer.Error || VulkanRenderer.Error;
    pub const GpuTiming = VulkanRenderer.GpuTiming;

    const Backend = union(enum) {
        cpu: CpuRenderer,
        vulkan: VulkanRenderer,
    };

    const ActiveFrame = struct {
        target: render_types.Target,
        damage: ?[]const render_types.Rect,
        scale: render_types.Scale,
        origin: render_types.Position,
        color_description: render_types.ColorDescription,
    };

    pub fn init(allocator: std.mem.Allocator, kind: Kind) VulkanRenderer.InitError!Renderer {
        return initForDevice(allocator, kind, null);
    }

    pub fn initForDevice(
        allocator: std.mem.Allocator,
        kind: Kind,
        drm_device_id: ?render_types.DrmDeviceId,
    ) VulkanRenderer.InitError!Renderer {
        return .{
            .allocator = allocator,
            .backend = switch (kind) {
                .cpu => .{ .cpu = CpuRenderer.init(allocator) },
                .vulkan => .{ .vulkan = try VulkanRenderer.init(allocator, drm_device_id) },
            },
            .commands = .empty,
            .active_frame = null,
        };
    }

    pub fn deinit(self: *Renderer) void {
        std.debug.assert(self.active_frame == null);
        self.commands.deinit(self.allocator);
        switch (self.backend) {
            .cpu => |*renderer| renderer.deinit(),
            .vulkan => |*renderer| renderer.deinit(),
        }
        self.* = undefined;
    }

    pub fn supportsPartialDamage(self: *const Renderer) bool {
        return switch (self.backend) {
            .cpu, .vulkan => true,
        };
    }

    pub fn supportsColorManagement(self: *const Renderer) bool {
        return switch (self.backend) {
            .cpu => false,
            .vulkan => true,
        };
    }

    pub fn backdropBlurFootprint(
        self: *const Renderer,
        radius: u32,
        downsample_level: ?u8,
    ) u32 {
        return switch (self.backend) {
            .cpu => radius,
            .vulkan => VulkanRenderer.backdropBlurFootprint(radius, downsample_level),
        };
    }

    pub fn beginFrame(
        self: *Renderer,
        target: render_types.Target,
        scale: render_types.Scale,
        origin: render_types.Position,
        damage: ?[]const render_types.Rect,
        color_description: render_types.ColorDescription,
    ) Error!void {
        // Damage and buffers referenced by appended commands must remain valid through finishFrame.
        std.debug.assert(self.active_frame == null);
        std.debug.assert(self.commands.items.len == 0);
        try validateTarget(target);
        if (scale.numerator == 0 or scale.numerator > std.math.maxInt(i32)) {
            return error.InvalidTarget;
        }
        self.active_frame = .{
            .target = target,
            .damage = damage,
            .scale = scale,
            .origin = origin,
            .color_description = color_description,
        };
    }

    pub fn dmabufAccess(self: *Renderer) ?render_types.DmabufRenderer {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.dmabufAccess(),
        };
    }

    pub fn dmabufDeviceId(self: *const Renderer) ?render_types.DrmDeviceId {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.dmabufDeviceId(),
        };
    }

    pub fn dmabufSourceFormats(self: *const Renderer) []const render_types.DmabufFormatModifier {
        return switch (self.backend) {
            .cpu => &.{
                .{ .format = @intFromEnum(render_types.DmabufFormat.argb8888), .modifier = 0 },
                .{ .format = @intFromEnum(render_types.DmabufFormat.xrgb8888), .modifier = 0 },
                .{ .format = @intFromEnum(render_types.DmabufFormat.abgr8888), .modifier = 0 },
                .{ .format = @intFromEnum(render_types.DmabufFormat.xbgr8888), .modifier = 0 },
            },
            .vulkan => |*renderer| renderer.dmabufSourceFormats(),
        };
    }

    pub fn dmabufSourceValidator(self: *Renderer) ?render_types.DmabufSourceValidator {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.dmabufSourceValidator(),
        };
    }

    pub fn offscreenAccess(self: *Renderer) ?render_types.OffscreenRenderer {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.offscreenAccess(),
        };
    }

    pub fn append(self: *Renderer, commands: []const render_types.Command) Error!void {
        const active = self.active_frame orelse unreachable;
        const translated = active.origin.x != 0 or active.origin.y != 0;
        const scaled = active.scale.numerator != render_types.Scale.denominator;
        if (!translated and !scaled) {
            try self.commands.appendSlice(self.allocator, commands);
            return;
        }

        for (commands) |command| {
            const local_command = translateCommand(command, active.origin);
            try self.commands.append(self.allocator, if (scaled)
                scaleCommand(local_command, active.scale)
            else
                local_command);
        }
    }

    pub fn finishFrame(self: *Renderer) Error!void {
        const active = self.active_frame orelse unreachable;
        self.active_frame = null;
        defer self.commands.clearRetainingCapacity();
        try self.renderDirect(.{
            .size = active.target.size(),
            .commands = self.commands.items,
            .damage = active.damage,
            .output_color_description = active.color_description,
        }, active.target);
    }

    /// Returns an owned sync-file descriptor when rendering can complete
    /// asynchronously. The caller must close it after handing it to the
    /// display backend.
    pub fn finishFrameScanout(
        self: *Renderer,
        gpu_sample_tag: ?u64,
    ) Error!?std.posix.fd_t {
        const active = self.active_frame orelse unreachable;
        self.active_frame = null;
        defer self.commands.clearRetainingCapacity();
        const frame: render_types.Frame = .{
            .size = active.target.size(),
            .commands = self.commands.items,
            .damage = active.damage,
            .output_color_description = active.color_description,
        };
        return switch (self.backend) {
            .cpu => |*renderer| switch (active.target) {
                .pixels => |pixels| blk: {
                    try renderer.render(frame, pixels);
                    break :blk null;
                },
                .offscreen, .dmabuf => error.InvalidTarget,
            },
            .vulkan => |*renderer| renderer.renderFrameScanout(
                frame,
                active.target,
                gpu_sample_tag,
            ),
        };
    }

    pub fn takeGpuTiming(self: *Renderer) ?GpuTiming {
        return switch (self.backend) {
            .cpu => null,
            .vulkan => |*renderer| renderer.takeGpuTiming(),
        };
    }

    pub fn discardGpuTimings(self: *Renderer) void {
        switch (self.backend) {
            .cpu => {},
            .vulkan => |*renderer| renderer.discardGpuTimings(),
        }
    }

    pub fn directScanoutCandidate(self: *Renderer) render_types.DirectScanoutCandidate {
        const active = self.active_frame orelse return .{ .rejected = .no_fullscreen_surface };
        const last_command = self.commands.getLastOrNull() orelse
            return .{ .rejected = .no_fullscreen_surface };
        const image = switch (last_command) {
            .image => |image| image,
            else => return .{ .rejected = .no_fullscreen_surface },
        };
        if (image.x != 0 or image.y != 0 or
            !std.meta.eql(image.size, active.target.size()))
        {
            return .{ .rejected = .no_fullscreen_surface };
        }
        if (!image.is_opaque or image.alpha_multiplier != std.math.maxInt(u32)) {
            return .{ .rejected = .non_opaque_surface };
        }
        if (image.source != null or image.transform != .normal or
            image.rounded_clip != null or image.clip != null)
        {
            return .{ .rejected = .surface_transform };
        }
        const dmabuf = image.buffer.dmabuf orelse return .{ .rejected = .non_dmabuf };
        if (dmabuf.y_inverted) return .{ .rejected = .y_inverted };
        if (image.buffer.source_cache == null) {
            return .{ .rejected = .missing_buffer_identity };
        }
        if (!std.meta.eql(image.buffer.color_description, active.color_description)) {
            return .{ .rejected = .color_conversion };
        }
        return .{ .candidate = image.buffer };
    }

    pub fn cancelFrame(self: *Renderer) void {
        std.debug.assert(self.active_frame != null);
        self.active_frame = null;
        self.commands.clearRetainingCapacity();
    }

    pub fn render(
        self: *Renderer,
        frame: render_types.Frame,
        target: render_types.PixelBuffer,
    ) Error!void {
        try self.beginFrame(
            .{ .pixels = target },
            frame.scale,
            frame.origin,
            frame.damage,
            frame.output_color_description,
        );
        var active = true;
        errdefer if (active) self.cancelFrame();
        try self.append(frame.commands);
        active = false;
        try self.finishFrame();
    }

    fn renderDirect(
        self: *Renderer,
        frame: render_types.Frame,
        target: render_types.Target,
    ) Error!void {
        return switch (self.backend) {
            .cpu => |*renderer| switch (target) {
                .pixels => |pixels| renderer.render(frame, pixels),
                .offscreen, .dmabuf => error.InvalidTarget,
            },
            .vulkan => |*renderer| renderer.renderFrame(frame, target),
        };
    }
};

fn validateTarget(target: render_types.Target) Renderer.Error!void {
    const size = target.size();
    if (size.width == 0 or size.height == 0) return error.InvalidTarget;
    const pixels = switch (target) {
        .pixels => |pixels| pixels,
        .offscreen => |offscreen| {
            if (offscreen.id == 0) return error.InvalidTarget;
            return;
        },
        .dmabuf => |dmabuf| {
            if (dmabuf.id == 0) return error.InvalidTarget;
            return;
        },
    };
    if (pixels.dmabuf != null) return error.InvalidTarget;
    if (pixels.stride_pixels < pixels.size.width) return error.InvalidTarget;
    const last_row = std.math.mul(
        usize,
        pixels.size.height - 1,
        pixels.stride_pixels,
    ) catch return error.InvalidTarget;
    const required_pixels = std.math.add(usize, last_row, pixels.size.width) catch
        return error.InvalidTarget;
    if (pixels.pixels.len < required_pixels) return error.InvalidTarget;
}

fn translateCommand(
    command: render_types.Command,
    origin: render_types.Position,
) render_types.Command {
    return switch (command) {
        .clear => |color| .{ .clear = color },
        .solid_rect => |solid| .{ .solid_rect = .{
            .rect = translateRect(solid.rect, origin),
            .color = solid.color,
            .clip = if (solid.clip) |clip| translateRect(clip, origin) else null,
        } },
        .shadow => |shadow| .{ .shadow = .{
            .rect = translateRect(shadow.rect, origin),
            .corner_radius = shadow.corner_radius,
            .blur_radius = shadow.blur_radius,
            .spread = shadow.spread,
            .color = shadow.color,
            .cutout = if (shadow.cutout) |cutout| .{
                .rect = translateRect(cutout.rect, origin),
                .radius = cutout.radius,
            } else null,
            .clip = if (shadow.clip) |clip| translateRect(clip, origin) else null,
        } },
        .backdrop_blur => |blur| .{ .backdrop_blur = .{
            .rect = translateRect(blur.rect, origin),
            .corner_radius = blur.corner_radius,
            .radius = blur.radius,
            .downsample_level = blur.downsample_level,
            .clip = if (blur.clip) |clip| translateRect(clip, origin) else null,
            .cache_only = blur.cache_only,
        } },
        .image => |image| .{ .image = .{
            .x = translateCoordinate(image.x, origin.x),
            .y = translateCoordinate(image.y, origin.y),
            .size = image.size,
            .buffer = image.buffer,
            .source = image.source,
            .transform = image.transform,
            .is_opaque = image.is_opaque,
            .alpha_multiplier = image.alpha_multiplier,
            .rounded_clip = if (image.rounded_clip) |clip| .{
                .rect = translateRect(clip.rect, origin),
                .radius = clip.radius,
            } else null,
            .clip = if (image.clip) |clip| translateRect(clip, origin) else null,
        } },
    };
}

fn translateRect(rect: render_types.Rect, origin: render_types.Position) render_types.Rect {
    return .{
        .x = translateCoordinate(rect.x, origin.x),
        .y = translateCoordinate(rect.y, origin.y),
        .width = rect.width,
        .height = rect.height,
    };
}

fn translateCoordinate(value: i32, origin: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, value) - origin,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleCommand(command: render_types.Command, scale: render_types.Scale) render_types.Command {
    std.debug.assert(scale.numerator > 0 and scale.numerator <= std.math.maxInt(i32));
    return switch (command) {
        .clear => |color| .{ .clear = color },
        .solid_rect => |solid| .{ .solid_rect = .{
            .rect = scaleRect(solid.rect, scale),
            .color = solid.color,
            .clip = if (solid.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .shadow => |shadow| .{ .shadow = .{
            .rect = scaleRect(shadow.rect, scale),
            .corner_radius = scaleUnsigned(shadow.corner_radius, scale),
            .blur_radius = scaleUnsigned(shadow.blur_radius, scale),
            .spread = scaleSigned(shadow.spread, scale),
            .color = shadow.color,
            .cutout = if (shadow.cutout) |cutout| .{
                .rect = scaleRect(cutout.rect, scale),
                .radius = scaleUnsigned(cutout.radius, scale),
            } else null,
            .clip = if (shadow.clip) |clip| scaleRect(clip, scale) else null,
        } },
        .backdrop_blur => |blur| .{ .backdrop_blur = .{
            .rect = scaleRect(blur.rect, scale),
            .corner_radius = scaleUnsigned(blur.corner_radius, scale),
            .radius = scaleUnsigned(blur.radius, scale),
            .downsample_level = blur.downsample_level,
            .clip = if (blur.clip) |clip| scaleRect(clip, scale) else null,
            .cache_only = blur.cache_only,
        } },
        .image => |image| scaled: {
            const rect = scaleRect(.{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            }, scale);
            break :scaled .{ .image = .{
                .x = rect.x,
                .y = rect.y,
                .size = .{ .width = rect.width, .height = rect.height },
                .buffer = image.buffer,
                .source = image.source,
                .transform = image.transform,
                .is_opaque = image.is_opaque,
                .alpha_multiplier = image.alpha_multiplier,
                .rounded_clip = if (image.rounded_clip) |clip| .{
                    .rect = scaleRect(clip.rect, scale),
                    .radius = scaleUnsigned(clip.radius, scale),
                } else null,
                .clip = if (image.clip) |clip| scaleRect(clip, scale) else null,
            } };
        },
    };
}

fn scaleRect(rect: render_types.Rect, scale: render_types.Scale) render_types.Rect {
    const left = scaleSigned(rect.x, scale);
    const top = scaleSigned(rect.y, scale);
    const right = scaleSigned(@as(i64, rect.x) + rect.width, scale);
    const bottom = scaleSigned(@as(i64, rect.y) + rect.height, scale);
    return .{
        .x = left,
        .y = top,
        .width = @intCast(@max(@as(i64, right) - left, 0)),
        .height = @intCast(@max(@as(i64, bottom) - top, 0)),
    };
}

fn scaleSigned(value: i64, scale: render_types.Scale) i32 {
    const product = @as(i128, value) * scale.numerator;
    const rounded = if (product >= 0)
        @divTrunc(
            product + render_types.Scale.denominator / 2,
            render_types.Scale.denominator,
        )
    else
        -@divTrunc(
            -product + render_types.Scale.denominator / 2,
            render_types.Scale.denominator,
        );
    return @intCast(std.math.clamp(
        rounded,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn scaleUnsigned(value: u32, scale: render_types.Scale) u32 {
    const product = @as(u64, value) * scale.numerator;
    return @intCast(@min(
        (product + render_types.Scale.denominator / 2) / render_types.Scale.denominator,
        std.math.maxInt(u32),
    ));
}

test "renderer dispatches to the selected implementation" {
    const size: render_types.Size = .{ .width = 2, .height = 2 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();

    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(10, 20, 30, 255) },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{ .size = size, .commands = &commands },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(1, 1));
}

test "renderer submits accumulated commands as one frame" {
    const size: render_types.Size = .{ .width = 2, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();

    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{.{ .clear = render_types.Color.rgba(10, 20, 30, 255) }});
    try std.testing.expectEqual(@as(u32, 0), output.pixel(0, 0));
    try renderer.append(&.{.{ .solid_rect = .{
        .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        .color = render_types.Color.rgba(40, 50, 60, 255),
    } }});
    try renderer.finishFrame();

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff28323c), output.pixel(1, 0));
}

test "cancelled renderer frame does not leak commands" {
    const size: render_types.Size = .{ .width = 1, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();

    try renderer.beginFrame(.{ .pixels = output.target() }, .{}, .{}, null, .{});
    try renderer.append(&.{.{ .clear = render_types.Color.rgba(255, 0, 0, 255) }});
    renderer.cancelFrame();
    try renderer.render(
        .{ .size = size, .commands = &.{.{ .clear = render_types.Color.rgba(0, 0, 255, 255) }} },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff0000ff), output.pixel(0, 0));
}

test "direct scanout candidate requires a final exact opaque DMA-BUF image" {
    const NoopSource = struct {
        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}
        fn begin(_: *anyopaque) bool {
            return true;
        }
        fn end(_: *anyopaque) bool {
            return true;
        }
        fn exportFence(_: *anyopaque) ?std.posix.fd_t {
            return null;
        }
    };

    const size: render_types.Size = .{ .width = 2, .height = 2 };
    var target_pixels = [_]u32{0} ** 4;
    var source_context: u8 = 0;
    const source_buffer: render_types.PixelBuffer = .{
        .size = size,
        .stride_pixels = size.width,
        .dmabuf = .{
            .context = &source_context,
            .fd = -1,
            .format = 0,
            .modifier = 0,
            .stride = size.width * @sizeOf(u32),
            .offset = 0,
            .required_bytes = target_pixels.len * @sizeOf(u32),
            .y_inverted = false,
            .force_opaque = true,
            .retain = NoopSource.retain,
            .release = NoopSource.release,
            .begin_cpu_read = NoopSource.begin,
            .end_cpu_read = NoopSource.end,
            .export_read_fence = NoopSource.exportFence,
        },
        .source_cache = .{ .id = 1, .version = 1 },
    };
    const target: render_types.Target = .{ .pixels = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &target_pixels,
    } };
    const direct_commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = source_buffer,
            .is_opaque = true,
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&direct_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    renderer.cancelFrame();

    const p3: render_types.ColorDescription = .{
        .primaries = render_types.display_p3_chromaticities,
        .named_primaries = .display_p3,
    };
    try renderer.beginFrame(target, .{}, .{}, null, p3);
    try renderer.append(&direct_commands);
    try expectDirectScanoutRejection(.color_conversion, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var matching_color_commands = direct_commands;
    matching_color_commands[1].image.buffer.color_description = p3;
    try renderer.beginFrame(target, .{}, .{}, null, p3);
    try renderer.append(&matching_color_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    renderer.cancelFrame();

    const covered_commands = [_]render_types.Command{
        .{ .solid_rect = .{
            .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 255, 255, 255),
        } },
        direct_commands[1],
    };
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&covered_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var scaled_commands = direct_commands;
    scaled_commands[1].image.buffer.size = .{ .width = 3, .height = 3 };
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&scaled_commands);
    try expectDirectScanoutCandidate(renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var transparent_commands = direct_commands;
    transparent_commands[1].image.is_opaque = false;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&transparent_commands);
    try expectDirectScanoutRejection(.non_opaque_surface, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var alpha_commands = direct_commands;
    alpha_commands[1].image.alpha_multiplier = 0x8000_0000;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&alpha_commands);
    try expectDirectScanoutRejection(.non_opaque_surface, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var transformed_commands = direct_commands;
    transformed_commands[1].image.transform = .rotate_90;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&transformed_commands);
    try expectDirectScanoutRejection(.surface_transform, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var non_dmabuf_commands = direct_commands;
    non_dmabuf_commands[1].image.buffer.dmabuf = null;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&non_dmabuf_commands);
    try expectDirectScanoutRejection(.non_dmabuf, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var inverted_commands = direct_commands;
    inverted_commands[1].image.buffer.dmabuf.?.y_inverted = true;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&inverted_commands);
    try expectDirectScanoutRejection(.y_inverted, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    var unidentified_commands = direct_commands;
    unidentified_commands[1].image.buffer.source_cache = null;
    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&unidentified_commands);
    try expectDirectScanoutRejection(.missing_buffer_identity, renderer.directScanoutCandidate());
    renderer.cancelFrame();

    try renderer.beginFrame(target, .{}, .{}, null, .{});
    try renderer.append(&direct_commands);
    try renderer.append(&.{.{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = render_types.Color.rgba(255, 255, 255, 255),
    } }});
    try expectDirectScanoutRejection(.no_fullscreen_surface, renderer.directScanoutCandidate());
    renderer.cancelFrame();
}

fn expectDirectScanoutCandidate(candidate: render_types.DirectScanoutCandidate) !void {
    switch (candidate) {
        .candidate => {},
        .rejected => |reason| {
            std.debug.print("unexpected direct scanout rejection: {t}\n", .{reason});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectDirectScanoutRejection(
    expected: render_types.DirectScanoutRejection,
    candidate: render_types.DirectScanoutCandidate,
) !void {
    switch (candidate) {
        .candidate => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(expected, reason),
    }
}

test "renderer scales logical commands into a physical target" {
    const logical_size: render_types.Size = .{ .width = 2, .height = 2 };
    var output = try headless.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 0, 0, 255),
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{ .size = logical_size, .commands = &commands, .scale = .{ .numerator = 180 } },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(1, 1));
    try std.testing.expectEqual(@as(u32, 0xffff0000), output.pixel(2, 1));
    try std.testing.expectEqual(@as(u32, 0xff000000), output.pixel(2, 2));
}

test "renderer fills a physical target when fractional logical size is truncated" {
    var output = try headless.init(std.testing.allocator, .{ .width = 10, .height = 1 });
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(10, 20, 30, 255) },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{
            .size = .{ .width = 7, .height = 1 },
            .commands = &commands,
            .scale = .{ .numerator = 156 },
        },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xff0a141e), output.pixel(9, 0));
}

test "renderer translates global commands into an output-local target" {
    const size: render_types.Size = .{ .width = 2, .height = 1 };
    var output = try headless.init(std.testing.allocator, size);
    defer output.deinit();
    const commands = [_]render_types.Command{
        .{ .clear = render_types.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 10, .y = -4, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(255, 0, 0, 255),
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 11, .y = -4, .width = 1, .height = 1 },
            .color = render_types.Color.rgba(0, 255, 0, 255),
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{
            .size = size,
            .commands = &commands,
            .origin = .{ .x = 10, .y = -4 },
        },
        output.target(),
    );

    try std.testing.expectEqual(@as(u32, 0xffff0000), output.pixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff00ff00), output.pixel(1, 0));
}

test "fractional rendering preserves an exact-scale image" {
    var output = try headless.init(std.testing.allocator, .{ .width = 3, .height = 3 });
    defer output.deinit();
    var source_pixels = [_]u32{
        0xffff0000, 0xff00ff00, 0xff0000ff,
        0xffffffff, 0xff808080, 0xff000000,
        0xff102030, 0xff405060, 0xff708090,
    };
    const commands = [_]render_types.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = .{ .width = 2, .height = 2 },
            .buffer = .{
                .size = .{ .width = 3, .height = 3 },
                .stride_pixels = 3,
                .pixels = &source_pixels,
            },
        } },
    };

    var renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer renderer.deinit();
    try renderer.render(
        .{
            .size = .{ .width = 2, .height = 2 },
            .commands = &commands,
            .scale = .{ .numerator = 180 },
        },
        output.target(),
    );

    try std.testing.expectEqualSlices(u32, &source_pixels, output.target().pixels);
}

test "fractional rendering scales rounded clips independently from images" {
    var source_pixels = [_]u32{0xffffffff} ** 16;
    const scaled = scaleCommand(.{ .image = .{
        .x = 0,
        .y = 0,
        .size = .{ .width = 4, .height = 4 },
        .buffer = .{
            .size = .{ .width = 4, .height = 4 },
            .stride_pixels = 4,
            .pixels = &source_pixels,
        },
        .rounded_clip = .{
            .rect = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
            .radius = 1,
        },
    } }, .{ .numerator = 180 });

    try std.testing.expectEqual(render_types.Rect{
        .x = 2,
        .y = 2,
        .width = 3,
        .height = 3,
    }, scaled.image.rounded_clip.?.rect);
    try std.testing.expectEqual(@as(u32, 2), scaled.image.rounded_clip.?.radius);
}
