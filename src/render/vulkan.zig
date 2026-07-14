//! Vulkan-backed renderer with CPU fallbacks for commands not yet ported.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan");
const CpuRenderer = @import("cpu.zig");
const render = @import("types.zig");

loader: std.DynLib,
instance_wrapper: vk.InstanceWrapper,
device_wrapper: vk.DeviceWrapper,
instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,
queue: vk.Queue,
command_pool: vk.CommandPool,
fallback: CpuRenderer,

pub const Target = struct {
    readback: render.PixelBuffer,
};

pub const InitError = error{
    OutOfMemory,
    VulkanUnavailable,
    NoPhysicalDevice,
    NoQueueFamily,
};

pub const Error = CpuRenderer.Error || error{
    InvalidTarget,
    OutOfMemory,
    VulkanFailure,
};

pub fn init(allocator: std.mem.Allocator) InitError!Self {
    var loader = std.DynLib.open("libvulkan.so.1") catch return error.VulkanUnavailable;
    errdefer loader.close();
    const get_instance_proc_addr = loader.lookup(
        vk.PfnGetInstanceProcAddr,
        "vkGetInstanceProcAddr",
    ) orelse return error.VulkanUnavailable;
    const base_wrapper = vk.BaseWrapper.load(get_instance_proc_addr);
    const application_info: vk.ApplicationInfo = .{
        .p_application_name = "keywork-compositor",
        .application_version = 0,
        .p_engine_name = "keywork",
        .engine_version = 0,
        .api_version = vk.API_VERSION_1_0.toU32(),
    };
    const instance = base_wrapper.createInstance(&.{
        .p_application_info = &application_info,
    }, null) catch return error.VulkanUnavailable;
    errdefer {
        const wrapper = vk.InstanceWrapper.load(
            instance,
            base_wrapper.dispatch.vkGetInstanceProcAddr.?,
        );
        wrapper.destroyInstance(instance, null);
    }

    const instance_wrapper = vk.InstanceWrapper.load(
        instance,
        base_wrapper.dispatch.vkGetInstanceProcAddr.?,
    );
    const physical_devices = instance_wrapper.enumeratePhysicalDevicesAlloc(
        instance,
        allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.VulkanUnavailable,
    };
    defer allocator.free(physical_devices);
    const physical_device = if (physical_devices.len > 0)
        physical_devices[0]
    else
        return error.NoPhysicalDevice;

    const queue_families = instance_wrapper.getPhysicalDeviceQueueFamilyPropertiesAlloc(
        physical_device,
        allocator,
    ) catch return error.OutOfMemory;
    defer allocator.free(queue_families);
    const queue_family_index = for (queue_families, 0..) |family, index| {
        if (family.queue_count > 0 and
            (family.queue_flags.transfer_bit or
                family.queue_flags.graphics_bit or
                family.queue_flags.compute_bit))
        {
            break @as(u32, @intCast(index));
        }
    } else return error.NoQueueFamily;

    const queue_priority: f32 = 1.0;
    const queue_create_info: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = queue_family_index,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&queue_priority),
    };
    const device = instance_wrapper.createDevice(physical_device, &.{
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_create_info),
    }, null) catch return error.VulkanUnavailable;
    errdefer {
        const wrapper = vk.DeviceWrapper.load(
            device,
            instance_wrapper.dispatch.vkGetDeviceProcAddr.?,
        );
        wrapper.destroyDevice(device, null);
    }

    const device_wrapper = vk.DeviceWrapper.load(
        device,
        instance_wrapper.dispatch.vkGetDeviceProcAddr.?,
    );
    const command_pool = device_wrapper.createCommandPool(device, &.{
        .flags = .{ .transient_bit = true },
        .queue_family_index = queue_family_index,
    }, null) catch return error.VulkanUnavailable;

    return .{
        .loader = loader,
        .instance_wrapper = instance_wrapper,
        .device_wrapper = device_wrapper,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = device_wrapper.getDeviceQueue(device, queue_family_index, 0),
        .command_pool = command_pool,
        .fallback = CpuRenderer.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.device_wrapper.deviceWaitIdle(self.device) catch {};
    self.fallback.deinit();
    self.device_wrapper.destroyCommandPool(self.device, self.command_pool, null);
    self.device_wrapper.destroyDevice(self.device, null);
    self.instance_wrapper.destroyInstance(self.instance, null);
    self.loader.close();
    self.* = undefined;
}

pub fn renderFrame(self: *Self, frame: render.Frame, target: Target) Error!void {
    if (!supports(frame.commands)) {
        return self.fallback.render(frame, target.readback);
    }

    const required_pixels = try validateTarget(frame, target.readback);
    const byte_size = std.math.mul(u64, required_pixels, @sizeOf(u32)) catch
        return error.InvalidTarget;
    const buffer = self.device_wrapper.createBuffer(self.device, &.{
        .size = byte_size,
        .usage = .{ .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch return error.VulkanFailure;
    defer self.device_wrapper.destroyBuffer(self.device, buffer, null);

    const requirements = self.device_wrapper.getBufferMemoryRequirements(self.device, buffer);
    const memory_type_index = self.hostMemoryType(requirements.memory_type_bits) orelse
        return error.VulkanFailure;
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type_index,
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => return error.VulkanFailure,
    };
    defer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindBufferMemory(self.device, buffer, memory, 0) catch
        return error.VulkanFailure;

    const mapped_opaque = self.device_wrapper.mapMemory(
        self.device,
        memory,
        0,
        byte_size,
        .{},
    ) catch return error.VulkanFailure;
    const mapped: [*]u32 = @ptrCast(@alignCast(mapped_opaque orelse return error.VulkanFailure));
    defer self.device_wrapper.unmapMemory(self.device, memory);
    @memcpy(mapped[0..required_pixels], target.readback.pixels[0..required_pixels]);

    var command_buffer: vk.CommandBuffer = undefined;
    self.device_wrapper.allocateCommandBuffers(self.device, &.{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer)) catch return error.VulkanFailure;
    defer self.device_wrapper.freeCommandBuffers(
        self.device,
        self.command_pool,
        &.{command_buffer},
    );

    self.device_wrapper.beginCommandBuffer(command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    }) catch return error.VulkanFailure;
    self.hostToTransferBarrier(command_buffer);
    for (frame.commands) |command| {
        switch (command) {
            .clear => |color| self.fillRect(
                command_buffer,
                buffer,
                target.readback.stride_pixels,
                .{ .x = 0, .y = 0, .width = frame.size.width, .height = frame.size.height },
                color.argb8888(),
            ),
            .solid_rect => |solid| {
                var clipped = solid.rect.clipTo(frame.size) orelse continue;
                if (solid.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
                self.fillRect(
                    command_buffer,
                    buffer,
                    target.readback.stride_pixels,
                    clipped,
                    solid.color.argb8888(),
                );
            },
            else => unreachable,
        }
        self.transferBarrier(command_buffer);
    }
    self.transferToHostBarrier(command_buffer);
    self.device_wrapper.endCommandBuffer(command_buffer) catch return error.VulkanFailure;

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&command_buffer),
    };
    self.device_wrapper.queueSubmit(self.queue, &.{submit_info}, .null_handle) catch
        return error.VulkanFailure;
    self.device_wrapper.queueWaitIdle(self.queue) catch {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        return error.VulkanFailure;
    };
    @memcpy(target.readback.pixels[0..required_pixels], mapped[0..required_pixels]);
}

fn supports(commands: []const render.Command) bool {
    for (commands) |command| switch (command) {
        .clear => {},
        .solid_rect => |solid| if (solid.color.alpha != 255) return false,
        else => return false,
    };
    return true;
}

fn validateTarget(frame: render.Frame, target: render.PixelBuffer) Error!usize {
    if (frame.size.width == 0 or frame.size.height == 0) return error.InvalidTarget;
    if (!std.meta.eql(frame.size, target.size)) return error.InvalidTarget;
    if (target.stride_pixels < target.size.width) return error.InvalidTarget;
    const last_row = std.math.mul(
        usize,
        target.size.height - 1,
        target.stride_pixels,
    ) catch return error.InvalidTarget;
    const required_pixels = std.math.add(usize, last_row, target.size.width) catch
        return error.InvalidTarget;
    if (target.pixels.len < required_pixels) return error.InvalidTarget;
    return required_pixels;
}

fn hostMemoryType(self: *Self, memory_type_bits: u32) ?u32 {
    const properties = self.instance_wrapper.getPhysicalDeviceMemoryProperties(self.physical_device);
    for (0..properties.memory_type_count) |index| {
        const index_u5: u5 = @intCast(index);
        if (memory_type_bits & (@as(u32, 1) << index_u5) == 0) continue;
        const flags = properties.memory_types[index].property_flags;
        if (flags.host_visible_bit and flags.host_coherent_bit) return @intCast(index);
    }
    return null;
}

fn fillRect(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    buffer: vk.Buffer,
    stride_pixels: u32,
    rect: render.Rect,
    color: u32,
) void {
    std.debug.assert(rect.x >= 0);
    std.debug.assert(rect.y >= 0);
    if (rect.x == 0 and rect.width == stride_pixels) {
        self.device_wrapper.cmdFillBuffer(
            command_buffer,
            buffer,
            @as(u64, @intCast(rect.y)) * stride_pixels * @sizeOf(u32),
            @as(u64, rect.height) * stride_pixels * @sizeOf(u32),
            color,
        );
        return;
    }
    for (0..rect.height) |row| {
        const pixel_offset = (@as(u64, @intCast(rect.y)) + row) * stride_pixels +
            @as(u32, @intCast(rect.x));
        self.device_wrapper.cmdFillBuffer(
            command_buffer,
            buffer,
            pixel_offset * @sizeOf(u32),
            @as(u64, rect.width) * @sizeOf(u32),
            color,
        );
    }
}

fn hostToTransferBarrier(self: *Self, command_buffer: vk.CommandBuffer) void {
    const barrier: vk.MemoryBarrier = .{
        .src_access_mask = .{ .host_write_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        .{ .host_bit = true },
        .{ .transfer_bit = true },
        .{},
        &.{barrier},
        null,
        null,
    );
}

fn transferBarrier(self: *Self, command_buffer: vk.CommandBuffer) void {
    const barrier: vk.MemoryBarrier = .{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        .{ .transfer_bit = true },
        .{ .transfer_bit = true },
        .{},
        &.{barrier},
        null,
        null,
    );
}

fn transferToHostBarrier(self: *Self, command_buffer: vk.CommandBuffer) void {
    const barrier: vk.MemoryBarrier = .{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .host_read_bit = true },
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        .{ .transfer_bit = true },
        .{ .host_bit = true },
        .{},
        &.{barrier},
        null,
        null,
    );
}

test "Vulkan transfer commands reject rectangles that require blending" {
    try std.testing.expect(supports(&.{.{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = render.Color.rgba(1, 2, 3, 255),
    } }}));
    try std.testing.expect(!supports(&.{.{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = render.Color.rgba(1, 2, 3, 128),
    } }}));
}

test "Vulkan renderer clears and clips solid rectangles" {
    var renderer = Self.init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{0} ** 12;
    const target: Target = .{ .readback = .{
        .size = .{ .width = 4, .height = 3 },
        .stride_pixels = 4,
        .pixels = &pixels,
    } };
    const commands = [_]render.Command{
        .{ .clear = render.Color.rgba(1, 2, 3, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 1, .width = 3, .height = 2 },
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 3 },
            .color = render.Color.rgba(20, 30, 40, 255),
        } },
    };

    try renderer.renderFrame(
        .{ .size = target.readback.size, .commands = &commands },
        target,
    );

    try std.testing.expectEqual(@as(u32, 0xff010203), pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xff141e28), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0xff010203), pixels[7]);
    try std.testing.expectEqual(@as(u32, 0xff141e28), pixels[10]);
}

test "Vulkan renderer falls back for image commands" {
    var renderer = Self.init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var source_pixels = [_]u32{0xffabcdef};
    var target_pixels = [_]u32{0};
    const size: render.Size = .{ .width = 1, .height = 1 };
    try renderer.renderFrame(.{ .size = size, .commands = &.{.{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{ .size = size, .stride_pixels = 1, .pixels = &source_pixels },
    } }} }, .{ .readback = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixels,
    } });

    try std.testing.expectEqual(source_pixels[0], target_pixels[0]);
}
