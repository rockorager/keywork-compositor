//! Vulkan-backed renderer with CPU fallbacks for commands not yet ported.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan");
const CpuRenderer = @import("cpu.zig");
const render = @import("types.zig");
const shaders = @import("vulkan_shaders.zig");
const sync = @cImport({
    @cInclude("linux/dma-buf.h");
    @cInclude("sys/ioctl.h");
});
const log = std.log.scoped(.vulkan);

allocator: std.mem.Allocator,
loader: std.DynLib,
instance_wrapper: vk.InstanceWrapper,
device_wrapper: vk.DeviceWrapper,
instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,
queue: vk.Queue,
queue_family_index: u32,
command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
fence: vk.Fence,
scanout_semaphore: vk.Semaphore,
fence_pending: bool,
format: vk.Format,
swap_red_blue: bool,
render_pass: vk.RenderPass,
scratch_render_pass: vk.RenderPass,
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_pool: vk.DescriptorPool,
pipeline_layout: vk.PipelineLayout,
replace_pipeline: vk.Pipeline,
blend_pipeline: vk.Pipeline,
image_pipeline: vk.Pipeline,
shadow_pipeline: vk.Pipeline,
downsample_pipeline: vk.Pipeline,
blur_horizontal_pipeline: vk.Pipeline,
blur_vertical_pipeline: vk.Pipeline,
blur_composite_pipeline: vk.Pipeline,
sampler: vk.Sampler,
work_buffer: vk.Buffer,
work_memory: vk.DeviceMemory,
work_mapped: ?[*]u8,
work_capacity: usize,
instance_buffer: vk.Buffer,
instance_memory: vk.DeviceMemory,
instance_mapped: ?[*]u8,
instance_capacity: usize,
instances: std.ArrayList(Instance) = .empty,
draw_runs: std.ArrayList(DrawRun) = .empty,
blur_ops: std.ArrayList(BlurOp) = .empty,
prepared_images: std.ArrayList(PreparedImage) = .empty,
pending_wait_semaphores: std.ArrayList(vk.Semaphore) = .empty,
pending_textures: std.ArrayList(Texture) = .empty,
dmabuf_modifiers: []u64,
dmabuf_sampled_modifiers: []u64,
dmabuf_source_modifiers: []u64,
dmabuf_device_id: ?render.DrmDeviceId,
outputs: std.AutoHashMapUnmanaged(TargetKey, Output) = .empty,
textures: std.AutoHashMapUnmanaged(u64, Texture) = .empty,
frame_number: u64,
resource_epoch: u64,
fallback: CpuRenderer,

const max_cached_textures = 4096;
const descriptor_set_capacity = max_cached_textures + 512;
const stale_frame_count = 120;
const drm_format_argb8888: u32 = 0x34325241;
const drm_format_xrgb8888: u32 = 0x34325258;

const TargetKey = union(enum) {
    pixels: struct {
        pointer: usize,
        width: u32,
        height: u32,
        stride_pixels: u32,
    },
    offscreen: u64,
    dmabuf: u64,
};

const OutputKind = enum {
    pixels,
    offscreen,
    dmabuf,
};

const Output = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    descriptor_set: vk.DescriptorSet,
    framebuffer: vk.Framebuffer,
    size: render.Size,
    kind: OutputKind = .pixels,
    initialized: bool = false,
    last_used: u64,
    command_buffer: vk.CommandBuffer = .null_handle,
    recorded_frame: RecordedFrame = .{},
    blur: ?BlurScratch = null,
    blur_initialized: u16 = 0,
};

const BlurImage = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    descriptor_set: vk.DescriptorSet,
};

const BlurScratch = struct {
    levels: [blur_level_count]?BlurLevel = @splat(null),
};

const BlurLevel = struct {
    size: render.Size,
    a: BlurImage,
    b: BlurImage,
    a_framebuffer: vk.Framebuffer,
    b_framebuffer: vk.Framebuffer,
};

const blur_level_count = 6;

const Texture = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    descriptor_set: vk.DescriptorSet,
    size: render.Size,
    version: u64 = 0,
    initialized: bool = false,
    imported: bool = false,
    last_used: u64,
};

const PreparedImage = struct {
    texture: Texture,
    buffer: render.PixelBuffer,
    upload_offset: ?usize,
    upload_damage: ?[]const render.Rect,
    cache_id: ?u64,
    desired_version: u64,
};

const Instance = extern struct {
    destination: [4]f32,
    source: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    rounded: [4]f32,
    parameters: [4]f32,
};

const FramePush = extern struct {
    target_size: [2]f32,
    texture_size: [2]f32,
    swap_red_blue: f32,
    padding: f32 = 0,
};

const PipelineKind = enum {
    replace,
    blend,
    image,
    shadow,
    downsample,
    blur_horizontal,
    blur_vertical,
    blur_composite,
};

const BlurOp = struct {
    run_index: u32,
    level: u8 = 0,
    low_radius: u8 = 0,
    downsample_instances: [blur_level_count - 1]u32 = @splat(0),
    upsample_instances: [blur_level_count - 1]u32 = @splat(0),
    horizontal_instance: u32,
    vertical_instance: u32 = 0,
    sample_rect: render.Rect,
    level_rects: [blur_level_count]render.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }),
    upsample_rects: [blur_level_count]render.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }),
    horizontal_rect: render.Rect,
    vertical_rect: render.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

const DrawRun = struct {
    pipeline: PipelineKind,
    descriptor_set: ?vk.DescriptorSet,
    texture_size: render.Size,
    first_instance: u32,
    instance_count: u32,
};

const UploadRun = struct {
    image: vk.Image,
    initialized: bool,
    buffer_size: render.Size,
    stride_pixels: u32,
    offset: usize,
    first_rectangle: usize,
    rectangle_count: usize,
};

const RecordedFrame = struct {
    // Mapped pixels and instances may change between submissions. Everything
    // stored here is state baked into the Vulkan command buffer itself.
    valid: bool = false,
    resource_epoch: u64 = 0,
    output_initialized: bool = false,
    blur_initialized: u16 = 0,
    render_area: render.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    work_buffer: vk.Buffer = .null_handle,
    instance_buffer: vk.Buffer = .null_handle,
    uploads: std.ArrayList(UploadRun) = .empty,
    upload_rectangles: std.ArrayList(render.Rect) = .empty,
    draw_runs: std.ArrayList(DrawRun) = .empty,
    blur_ops: std.ArrayList(BlurOp) = .empty,

    fn deinit(self: *RecordedFrame, allocator: std.mem.Allocator) void {
        self.uploads.deinit(allocator);
        self.upload_rectangles.deinit(allocator);
        self.draw_runs.deinit(allocator);
        self.blur_ops.deinit(allocator);
        self.* = undefined;
    }
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 96);
    std.debug.assert(@sizeOf(FramePush) == 24);
}

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

const Graphics = struct {
    render_pass: vk.RenderPass,
    scratch_render_pass: vk.RenderPass,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    pipeline_layout: vk.PipelineLayout,
    replace_pipeline: vk.Pipeline,
    blend_pipeline: vk.Pipeline,
    image_pipeline: vk.Pipeline,
    shadow_pipeline: vk.Pipeline,
    downsample_pipeline: vk.Pipeline,
    blur_horizontal_pipeline: vk.Pipeline,
    blur_vertical_pipeline: vk.Pipeline,
    blur_composite_pipeline: vk.Pipeline,
    sampler: vk.Sampler,
};

fn chooseFormat(
    wrapper: vk.InstanceWrapper,
    physical_device: vk.PhysicalDevice,
) ?vk.Format {
    for ([_]vk.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm }) |format| {
        const features = wrapper.getPhysicalDeviceFormatProperties(
            physical_device,
            format,
        ).optimal_tiling_features;
        if (features.color_attachment_bit and
            features.color_attachment_blend_bit and
            features.sampled_image_bit and
            features.sampled_image_filter_linear_bit and
            features.transfer_src_bit and
            features.transfer_dst_bit)
        {
            return format;
        }
    }
    return null;
}

fn initGraphics(
    wrapper: vk.DeviceWrapper,
    device: vk.Device,
    format: vk.Format,
) !Graphics {
    const binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
    };
    const descriptor_set_layout = try wrapper.createDescriptorSetLayout(device, &.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&binding),
    }, null);
    errdefer wrapper.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

    const pool_size: vk.DescriptorPoolSize = .{
        .type = .combined_image_sampler,
        .descriptor_count = descriptor_set_capacity,
    };
    const descriptor_pool = try wrapper.createDescriptorPool(device, &.{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = descriptor_set_capacity,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
    errdefer wrapper.destroyDescriptorPool(device, descriptor_pool, null);

    const push_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(FramePush),
    };
    const pipeline_layout = try wrapper.createPipelineLayout(device, &.{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_range),
    }, null);
    errdefer wrapper.destroyPipelineLayout(device, pipeline_layout, null);

    const attachment: vk.AttachmentDescription = .{
        .format = format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .load,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .color_attachment_optimal,
        .final_layout = .color_attachment_optimal,
    };
    const attachment_reference: vk.AttachmentReference = .{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&attachment_reference),
    };
    const render_pass = try wrapper.createRenderPass(device, &.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
    errdefer wrapper.destroyRenderPass(device, render_pass, null);
    var scratch_attachment = attachment;
    scratch_attachment.load_op = .dont_care;
    const scratch_render_pass = try wrapper.createRenderPass(device, &.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&scratch_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
    errdefer wrapper.destroyRenderPass(device, scratch_render_pass, null);

    const sampler = try wrapper.createSampler(device, &.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    }, null);
    errdefer wrapper.destroySampler(device, sampler, null);

    const vertex_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.quad_instanced)),
        .p_code = &shaders.quad_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, vertex_shader, null);
    const solid_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.solid_instanced)),
        .p_code = &shaders.solid_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, solid_shader, null);
    const image_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.image_instanced)),
        .p_code = &shaders.image_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, image_shader, null);
    const shadow_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.shadow_instanced)),
        .p_code = &shaders.shadow_instanced,
    }, null);
    defer wrapper.destroyShaderModule(device, shadow_shader, null);
    const blur_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.blur_horizontal_paired)),
        .p_code = &shaders.blur_horizontal_paired,
    }, null);
    defer wrapper.destroyShaderModule(device, blur_shader, null);
    const blur_vertical_shader = try wrapper.createShaderModule(device, &.{
        .code_size = @sizeOf(@TypeOf(shaders.blur_vertical_paired)),
        .p_code = &shaders.blur_vertical_paired,
    }, null);
    defer wrapper.destroyShaderModule(device, blur_vertical_shader, null);

    const replace_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        solid_shader,
        false,
    ) catch |err| {
        log.err("failed to create Vulkan replace pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, replace_pipeline, null);
    const blend_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        solid_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan blend pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, blend_pipeline, null);
    const image_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        image_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan image pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, image_pipeline, null);
    const shadow_pipeline = createPipeline(
        wrapper,
        device,
        render_pass,
        pipeline_layout,
        vertex_shader,
        shadow_shader,
        true,
    ) catch |err| {
        log.err("failed to create Vulkan shadow pipeline: {t}", .{err});
        return err;
    };
    errdefer wrapper.destroyPipeline(device, shadow_pipeline, null);
    const downsample_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, image_shader, false);
    errdefer wrapper.destroyPipeline(device, downsample_pipeline, null);
    const blur_horizontal_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, blur_shader, false);
    errdefer wrapper.destroyPipeline(device, blur_horizontal_pipeline, null);
    const blur_vertical_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, blur_vertical_shader, false);
    errdefer wrapper.destroyPipeline(device, blur_vertical_pipeline, null);
    const blur_composite_pipeline = try createPipeline(wrapper, device, render_pass, pipeline_layout, vertex_shader, image_shader, true);
    errdefer wrapper.destroyPipeline(device, blur_composite_pipeline, null);

    return .{
        .render_pass = render_pass,
        .scratch_render_pass = scratch_render_pass,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_pool = descriptor_pool,
        .pipeline_layout = pipeline_layout,
        .replace_pipeline = replace_pipeline,
        .blend_pipeline = blend_pipeline,
        .image_pipeline = image_pipeline,
        .shadow_pipeline = shadow_pipeline,
        .downsample_pipeline = downsample_pipeline,
        .blur_horizontal_pipeline = blur_horizontal_pipeline,
        .blur_vertical_pipeline = blur_vertical_pipeline,
        .blur_composite_pipeline = blur_composite_pipeline,
        .sampler = sampler,
    };
}

fn createPipeline(
    wrapper: vk.DeviceWrapper,
    device: vk.Device,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    blend: bool,
) !vk.Pipeline {
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader,
            .p_name = "main",
        },
    };
    const vertex_binding: vk.VertexInputBindingDescription = .{
        .binding = 0,
        .stride = @sizeOf(Instance),
        .input_rate = .instance,
    };
    const vertex_attributes = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "destination") },
        .{ .location = 1, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "source") },
        .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "clip") },
        .{ .location = 3, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "color") },
        .{ .location = 4, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "rounded") },
        .{ .location = 5, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "parameters") },
    };
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&vertex_binding),
        .vertex_attribute_description_count = vertex_attributes.len,
        .p_vertex_attribute_descriptions = &vertex_attributes,
    };
    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_strip,
        .primitive_restart_enable = .false,
    };
    const viewport: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };
    const rasterization: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = if (blend) .true else .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };
    const color_blend: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_attachment),
        .blend_constants = @splat(0),
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };
    const create_info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &rasterization,
        .p_multisample_state = &multisample,
        .p_color_blend_state = &color_blend,
        .p_dynamic_state = &dynamic,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try wrapper.createGraphicsPipelines(
        device,
        .null_handle,
        &.{create_info},
        null,
        @ptrCast(&pipeline),
    );
    return pipeline;
}

fn destroyGraphics(wrapper: vk.DeviceWrapper, device: vk.Device, graphics: Graphics) void {
    wrapper.destroyPipeline(device, graphics.blur_composite_pipeline, null);
    wrapper.destroyPipeline(device, graphics.blur_vertical_pipeline, null);
    wrapper.destroyPipeline(device, graphics.blur_horizontal_pipeline, null);
    wrapper.destroyPipeline(device, graphics.downsample_pipeline, null);
    wrapper.destroyPipeline(device, graphics.shadow_pipeline, null);
    wrapper.destroyPipeline(device, graphics.image_pipeline, null);
    wrapper.destroyPipeline(device, graphics.blend_pipeline, null);
    wrapper.destroyPipeline(device, graphics.replace_pipeline, null);
    wrapper.destroySampler(device, graphics.sampler, null);
    wrapper.destroyRenderPass(device, graphics.scratch_render_pass, null);
    wrapper.destroyRenderPass(device, graphics.render_pass, null);
    wrapper.destroyPipelineLayout(device, graphics.pipeline_layout, null);
    wrapper.destroyDescriptorPool(device, graphics.descriptor_pool, null);
    wrapper.destroyDescriptorSetLayout(device, graphics.descriptor_set_layout, null);
}

const instance_extensions = [_][*:0]const u8{
    "VK_KHR_get_physical_device_properties2",
    "VK_KHR_external_memory_capabilities",
    "VK_KHR_external_semaphore_capabilities",
};
const dmabuf_device_extensions = [_][*:0]const u8{
    "VK_EXT_physical_device_drm",
    "VK_KHR_maintenance1",
    "VK_KHR_get_memory_requirements2",
    "VK_KHR_bind_memory2",
    "VK_KHR_sampler_ycbcr_conversion",
    "VK_KHR_image_format_list",
    "VK_KHR_external_memory",
    "VK_KHR_external_memory_fd",
    "VK_KHR_external_semaphore",
    "VK_KHR_external_semaphore_fd",
    "VK_EXT_external_memory_dma_buf",
    "VK_KHR_dedicated_allocation",
    "VK_EXT_queue_family_foreign",
    "VK_EXT_image_drm_format_modifier",
};

fn hasExtension(properties: []const vk.ExtensionProperties, name: []const u8) bool {
    for (properties) |property| {
        const extension_name = std.mem.sliceTo(&property.extension_name, 0);
        if (std.mem.eql(u8, extension_name, name)) return true;
    }
    return false;
}

pub fn init(allocator: std.mem.Allocator, drm_device_id: ?render.DrmDeviceId) InitError!Self {
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
    const available_instance_extensions = base_wrapper.enumerateInstanceExtensionPropertiesAlloc(
        null,
        allocator,
    ) catch return error.VulkanUnavailable;
    defer allocator.free(available_instance_extensions);
    const dmabuf_instance_capable =
        hasExtension(available_instance_extensions, std.mem.span(instance_extensions[0])) and
        hasExtension(available_instance_extensions, std.mem.span(instance_extensions[1])) and
        hasExtension(available_instance_extensions, std.mem.span(instance_extensions[2]));
    const enabled_instance_extensions: []const [*:0]const u8 = if (dmabuf_instance_capable)
        &instance_extensions
    else
        &.{};
    const instance = base_wrapper.createInstance(&.{
        .p_application_info = &application_info,
        .enabled_extension_count = @intCast(enabled_instance_extensions.len),
        .pp_enabled_extension_names = enabled_instance_extensions.ptr,
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
    if (physical_devices.len == 0) return error.NoPhysicalDevice;
    var physical_device = physical_devices[0];
    var dmabuf_capable = false;
    var dmabuf_device_id: ?render.DrmDeviceId = null;
    if (dmabuf_instance_capable) find: for (physical_devices) |candidate| {
        const extensions = instance_wrapper.enumerateDeviceExtensionPropertiesAlloc(
            candidate,
            null,
            allocator,
        ) catch continue;
        defer allocator.free(extensions);
        for (dmabuf_device_extensions) |name| {
            if (!hasExtension(extensions, std.mem.span(name))) continue :find;
        }
        var drm_properties: vk.PhysicalDeviceDrmPropertiesEXT = undefined;
        drm_properties.s_type = .physical_device_drm_properties_ext;
        drm_properties.p_next = null;
        var properties: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        properties.p_next = &drm_properties;
        instance_wrapper.getPhysicalDeviceProperties2KHR(candidate, &properties);
        if (drm_device_id) |wanted| {
            const primary_matches = drm_properties.has_primary == .true and
                drm_properties.primary_major == wanted.major and
                drm_properties.primary_minor == wanted.minor;
            const render_matches = drm_properties.has_render == .true and
                drm_properties.render_major == wanted.major and
                drm_properties.render_minor == wanted.minor;
            if (!primary_matches and !render_matches) continue;
        } else if (drm_properties.has_render != .true) {
            // Headless rendering needs an unprivileged render node to identify
            // the same device to DMA-BUF clients.
            continue;
        }
        physical_device = candidate;
        dmabuf_capable = true;
        dmabuf_device_id = if (drm_properties.has_render == .true) .{
            .major = @intCast(drm_properties.render_major),
            .minor = @intCast(drm_properties.render_minor),
        } else .{
            .major = @intCast(drm_properties.primary_major),
            .minor = @intCast(drm_properties.primary_minor),
        };
        break;
    };

    const queue_families = instance_wrapper.getPhysicalDeviceQueueFamilyPropertiesAlloc(
        physical_device,
        allocator,
    ) catch return error.OutOfMemory;
    defer allocator.free(queue_families);
    const queue_family_index = for (queue_families, 0..) |family, index| {
        if (family.queue_count > 0 and family.queue_flags.graphics_bit) {
            break @as(u32, @intCast(index));
        }
    } else return error.NoQueueFamily;

    const queue_priority: f32 = 1.0;
    const queue_create_info: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = queue_family_index,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&queue_priority),
    };
    const enabled_device_extensions: []const [*:0]const u8 = if (dmabuf_capable)
        &dmabuf_device_extensions
    else
        &.{};
    const device = instance_wrapper.createDevice(physical_device, &.{
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_create_info),
        .enabled_extension_count = @intCast(enabled_device_extensions.len),
        .pp_enabled_extension_names = enabled_device_extensions.ptr,
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
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_family_index,
    }, null) catch return error.VulkanUnavailable;
    errdefer device_wrapper.destroyCommandPool(device, command_pool, null);

    var command_buffer: vk.CommandBuffer = undefined;
    device_wrapper.allocateCommandBuffers(device, &.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer)) catch return error.VulkanUnavailable;
    const fence = device_wrapper.createFence(device, &.{}, null) catch
        return error.VulkanUnavailable;
    errdefer device_wrapper.destroyFence(device, fence, null);

    var sync_fd_properties: vk.ExternalSemaphoreProperties = .{
        .export_from_imported_handle_types = .{},
        .compatible_handle_types = .{},
    };
    if (dmabuf_capable) instance_wrapper.getPhysicalDeviceExternalSemaphorePropertiesKHR(
        physical_device,
        &.{ .handle_type = .{ .sync_fd_bit = true } },
        &sync_fd_properties,
    );
    const sync_fd_capable = dmabuf_capable and
        sync_fd_properties.external_semaphore_features.exportable_bit and
        sync_fd_properties.external_semaphore_features.importable_bit;
    var scanout_semaphore = vk.Semaphore.null_handle;
    if (sync_fd_capable) {
        const export_info: vk.ExportSemaphoreCreateInfo = .{
            .handle_types = .{ .sync_fd_bit = true },
        };
        scanout_semaphore = device_wrapper.createSemaphore(device, &.{
            .p_next = &export_info,
        }, null) catch .null_handle;
    }
    errdefer if (scanout_semaphore != .null_handle) {
        device_wrapper.destroySemaphore(device, scanout_semaphore, null);
    };

    const format = chooseFormat(instance_wrapper, physical_device) orelse
        return error.VulkanUnavailable;
    if (format != .b8g8r8a8_unorm) {
        dmabuf_capable = false;
        dmabuf_device_id = null;
    }
    var dmabuf_modifiers: []u64 = &.{};
    var dmabuf_sampled_modifiers: []u64 = &.{};
    var dmabuf_source_modifiers: []u64 = &.{};
    if (dmabuf_capable) {
        var modifier_list: vk.DrmFormatModifierPropertiesListEXT = .{};
        var format_properties: vk.FormatProperties2 = .{ .format_properties = undefined };
        format_properties.p_next = &modifier_list;
        instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
            physical_device,
            .b8g8r8a8_unorm,
            &format_properties,
        );
        const properties = allocator.alloc(
            vk.DrmFormatModifierPropertiesEXT,
            modifier_list.drm_format_modifier_count,
        ) catch return error.OutOfMemory;
        defer allocator.free(properties);
        modifier_list.p_drm_format_modifier_properties = properties.ptr;
        instance_wrapper.getPhysicalDeviceFormatProperties2KHR(
            physical_device,
            .b8g8r8a8_unorm,
            &format_properties,
        );
        var modifiers: std.ArrayList(u64) = .empty;
        defer modifiers.deinit(allocator);
        var fallback_modifiers: std.ArrayList(u64) = .empty;
        defer fallback_modifiers.deinit(allocator);
        var sampled_modifiers: std.ArrayList(u64) = .empty;
        defer sampled_modifiers.deinit(allocator);
        var source_modifiers: std.ArrayList(u64) = .empty;
        defer source_modifiers.deinit(allocator);
        for (properties) |property| {
            const features = property.drm_format_modifier_tiling_features;
            if (property.drm_format_modifier_plane_count == 1 and
                features.color_attachment_bit and features.color_attachment_blend_bit and
                features.transfer_dst_bit and (features.transfer_src_bit or
                (features.sampled_image_bit and features.sampled_image_filter_linear_bit)))
            {
                if (features.sampled_image_bit and features.sampled_image_filter_linear_bit) {
                    modifiers.append(allocator, property.drm_format_modifier) catch
                        return error.OutOfMemory;
                    sampled_modifiers.append(allocator, property.drm_format_modifier) catch
                        return error.OutOfMemory;
                } else {
                    fallback_modifiers.append(allocator, property.drm_format_modifier) catch
                        return error.OutOfMemory;
                }
            }
            if (property.drm_format_modifier_plane_count == 1 and
                features.sampled_image_bit and features.sampled_image_filter_linear_bit)
            {
                source_modifiers.append(allocator, property.drm_format_modifier) catch
                    return error.OutOfMemory;
            }
        }
        modifiers.appendSlice(allocator, fallback_modifiers.items) catch return error.OutOfMemory;
        dmabuf_modifiers = modifiers.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer if (dmabuf_modifiers.len != 0) allocator.free(dmabuf_modifiers);
        dmabuf_sampled_modifiers = sampled_modifiers.toOwnedSlice(allocator) catch
            return error.OutOfMemory;
        errdefer if (dmabuf_sampled_modifiers.len != 0) allocator.free(dmabuf_sampled_modifiers);
        dmabuf_source_modifiers = source_modifiers.toOwnedSlice(allocator) catch
            return error.OutOfMemory;
    }
    errdefer if (dmabuf_modifiers.len != 0) allocator.free(dmabuf_modifiers);
    errdefer if (dmabuf_sampled_modifiers.len != 0) allocator.free(dmabuf_sampled_modifiers);
    errdefer if (dmabuf_source_modifiers.len != 0) allocator.free(dmabuf_source_modifiers);
    const graphics = initGraphics(device_wrapper, device, format) catch |err| {
        log.err("failed to initialize Vulkan graphics pipelines: {t}", .{err});
        return error.VulkanUnavailable;
    };
    errdefer destroyGraphics(device_wrapper, device, graphics);

    return .{
        .allocator = allocator,
        .loader = loader,
        .instance_wrapper = instance_wrapper,
        .device_wrapper = device_wrapper,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = device_wrapper.getDeviceQueue(device, queue_family_index, 0),
        .queue_family_index = queue_family_index,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .fence = fence,
        .scanout_semaphore = scanout_semaphore,
        .fence_pending = false,
        .format = format,
        .swap_red_blue = format == .r8g8b8a8_unorm,
        .render_pass = graphics.render_pass,
        .scratch_render_pass = graphics.scratch_render_pass,
        .descriptor_set_layout = graphics.descriptor_set_layout,
        .descriptor_pool = graphics.descriptor_pool,
        .pipeline_layout = graphics.pipeline_layout,
        .replace_pipeline = graphics.replace_pipeline,
        .blend_pipeline = graphics.blend_pipeline,
        .image_pipeline = graphics.image_pipeline,
        .shadow_pipeline = graphics.shadow_pipeline,
        .downsample_pipeline = graphics.downsample_pipeline,
        .blur_horizontal_pipeline = graphics.blur_horizontal_pipeline,
        .blur_vertical_pipeline = graphics.blur_vertical_pipeline,
        .blur_composite_pipeline = graphics.blur_composite_pipeline,
        .sampler = graphics.sampler,
        .work_buffer = .null_handle,
        .work_memory = .null_handle,
        .work_mapped = null,
        .work_capacity = 0,
        .instance_buffer = .null_handle,
        .instance_memory = .null_handle,
        .instance_mapped = null,
        .instance_capacity = 0,
        .dmabuf_modifiers = if (dmabuf_capable) dmabuf_modifiers else &.{},
        .dmabuf_sampled_modifiers = if (dmabuf_capable) dmabuf_sampled_modifiers else &.{},
        .dmabuf_source_modifiers = if (dmabuf_capable) dmabuf_source_modifiers else &.{},
        .dmabuf_device_id = dmabuf_device_id,
        .frame_number = 0,
        .resource_epoch = 1,
        .fallback = CpuRenderer.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.device_wrapper.deviceWaitIdle(self.device) catch {};
    self.fence_pending = false;
    self.releasePendingResources();
    self.fallback.deinit();
    self.destroyCachedResources();
    if (self.dmabuf_modifiers.len != 0) self.allocator.free(self.dmabuf_modifiers);
    if (self.dmabuf_sampled_modifiers.len != 0) self.allocator.free(self.dmabuf_sampled_modifiers);
    if (self.dmabuf_source_modifiers.len != 0) self.allocator.free(self.dmabuf_source_modifiers);
    self.instances.deinit(self.allocator);
    self.draw_runs.deinit(self.allocator);
    self.blur_ops.deinit(self.allocator);
    self.prepared_images.deinit(self.allocator);
    self.pending_wait_semaphores.deinit(self.allocator);
    self.pending_textures.deinit(self.allocator);
    self.destroyInstanceBuffer();
    self.destroyWorkBuffer();
    destroyGraphics(self.device_wrapper, self.device, .{
        .render_pass = self.render_pass,
        .scratch_render_pass = self.scratch_render_pass,
        .descriptor_set_layout = self.descriptor_set_layout,
        .descriptor_pool = self.descriptor_pool,
        .pipeline_layout = self.pipeline_layout,
        .replace_pipeline = self.replace_pipeline,
        .blend_pipeline = self.blend_pipeline,
        .image_pipeline = self.image_pipeline,
        .shadow_pipeline = self.shadow_pipeline,
        .downsample_pipeline = self.downsample_pipeline,
        .blur_horizontal_pipeline = self.blur_horizontal_pipeline,
        .blur_vertical_pipeline = self.blur_vertical_pipeline,
        .blur_composite_pipeline = self.blur_composite_pipeline,
        .sampler = self.sampler,
    });
    if (self.scanout_semaphore != .null_handle) {
        self.device_wrapper.destroySemaphore(self.device, self.scanout_semaphore, null);
    }
    self.device_wrapper.destroyFence(self.device, self.fence, null);
    self.device_wrapper.destroyCommandPool(self.device, self.command_pool, null);
    self.device_wrapper.destroyDevice(self.device, null);
    self.instance_wrapper.destroyInstance(self.instance, null);
    self.loader.close();
    self.* = undefined;
}

pub fn dmabufAccess(self: *Self) ?render.DmabufRenderer {
    if (self.dmabuf_modifiers.len == 0) return null;
    return .{
        .context = self,
        .modifiers = self.dmabuf_modifiers,
        .supports_target = supportsTargetCallback,
        .import_target = importTargetCallback,
        .release_target = releaseTargetCallback,
    };
}

pub fn dmabufDeviceId(self: *const Self) ?render.DrmDeviceId {
    if (self.dmabuf_source_modifiers.len == 0) return null;
    return self.dmabuf_device_id;
}

pub fn offscreenAccess(self: *Self) render.OffscreenRenderer {
    return .{
        .context = self,
        .create_target = createOffscreenTargetCallback,
        .release_target = releaseOffscreenTargetCallback,
    };
}

fn createOffscreenTargetCallback(context: *anyopaque, size: render.Size) anyerror!render.OffscreenTarget {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.createOffscreenTarget(size);
}

fn releaseOffscreenTargetCallback(context: *anyopaque, id: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.releaseOutput(.{ .offscreen = id });
}

fn createOffscreenTarget(self: *Self, size: render.Size) Error!render.OffscreenTarget {
    if (size.width == 0 or size.height == 0) return error.InvalidTarget;
    const id = render.allocateRenderTargetId();
    const key: TargetKey = .{ .offscreen = id };
    std.debug.assert(!self.outputs.contains(key));
    var output = try self.createOutput(size);
    errdefer self.destroyOutput(output);
    output.kind = .offscreen;
    output.command_buffer = try self.allocateCommandBuffer();
    self.outputs.put(self.allocator, key, output) catch return error.OutOfMemory;
    return .{ .id = id, .size = size };
}

fn supportsTargetCallback(context: *anyopaque, size: render.Size, modifier: u64) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.supportsDmabufTarget(size, modifier);
}

fn importTargetCallback(context: *anyopaque, descriptor: render.DmabufDescriptor) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(context));
    try self.importTarget(descriptor);
}

fn releaseTargetCallback(context: *anyopaque, id: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.releaseTarget(id);
}

fn importTarget(self: *Self, descriptor: render.DmabufDescriptor) Error!void {
    if (descriptor.id == 0 or descriptor.format != 0x34325258 or
        descriptor.size.width == 0 or descriptor.size.height == 0 or
        descriptor.stride < descriptor.size.width * @sizeOf(u32) or
        self.outputs.contains(.{ .dmabuf = descriptor.id }) or
        !self.supportsDmabufTarget(descriptor.size, descriptor.modifier))
        return error.InvalidTarget;

    const sampleable = self.dmabufTargetSampleable(descriptor.modifier);
    const image_usage = dmabufTargetUsage(sampleable);

    const duplicate_fd = std.c.dup(descriptor.fd);
    if (duplicate_fd < 0) return error.VulkanFailure;
    var fd_owned = true;
    defer if (fd_owned) {
        _ = std.c.close(duplicate_fd);
    };
    const plane: vk.SubresourceLayout = .{
        .offset = descriptor.offset,
        .size = 0,
        .row_pitch = descriptor.stride,
        .array_pitch = 0,
        .depth_pitch = 0,
    };
    var modifier_info: vk.ImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .drm_format_modifier = descriptor.modifier,
        .drm_format_modifier_plane_count = 1,
        .p_plane_layouts = @ptrCast(&plane),
    };
    const external_info: vk.ExternalMemoryImageCreateInfo = .{
        .p_next = &modifier_info,
        .handle_types = .{ .dma_buf_bit_ext = true },
    };
    const image = self.device_wrapper.createImage(self.device, &.{
        .p_next = &external_info,
        .image_type = .@"2d",
        .format = .b8g8r8a8_unorm,
        .extent = extent(descriptor.size),
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .drm_format_modifier_ext,
        .usage = image_usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImage(self.device, image, null);
    const requirements = self.device_wrapper.getImageMemoryRequirements(self.device, image);
    var fd_properties: vk.MemoryFdPropertiesKHR = .{ .memory_type_bits = 0 };
    self.device_wrapper.getMemoryFdPropertiesKHR(
        self.device,
        .{ .dma_buf_bit_ext = true },
        duplicate_fd,
        &fd_properties,
    ) catch return error.VulkanFailure;
    const memory_type = self.deviceMemoryType(
        requirements.memory_type_bits & fd_properties.memory_type_bits,
    ) orelse
        return error.VulkanFailure;
    const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .image = image };
    const import_info: vk.ImportMemoryFdInfoKHR = .{
        .p_next = &dedicated,
        .handle_type = .{ .dma_buf_bit_ext = true },
        .fd = duplicate_fd,
    };
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .p_next = &import_info,
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null) catch return error.VulkanFailure;
    fd_owned = false;
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindImageMemory(self.device, image, memory, 0) catch
        return error.VulkanFailure;
    const view = self.device_wrapper.createImageView(self.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = .b8g8r8a8_unorm,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = colorSubresourceRange(),
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImageView(self.device, view, null);
    const descriptor_set = if (sampleable) try self.createImageDescriptor(view) else vk.DescriptorSet.null_handle;
    errdefer if (descriptor_set != .null_handle) self.destroyImageDescriptor(descriptor_set);
    const framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{
        .render_pass = self.render_pass,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&view),
        .width = descriptor.size.width,
        .height = descriptor.size.height,
        .layers = 1,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyFramebuffer(self.device, framebuffer, null);
    const command_buffer = try self.allocateCommandBuffer();
    errdefer self.device_wrapper.freeCommandBuffers(
        self.device,
        self.command_pool,
        &.{command_buffer},
    );
    self.outputs.put(self.allocator, .{ .dmabuf = descriptor.id }, .{
        .image = image,
        .memory = memory,
        .view = view,
        .descriptor_set = descriptor_set,
        .framebuffer = framebuffer,
        .size = descriptor.size,
        .kind = .dmabuf,
        .last_used = self.frame_number,
        .command_buffer = command_buffer,
    }) catch return error.OutOfMemory;
}

fn allocateCommandBuffer(self: *Self) Error!vk.CommandBuffer {
    var command_buffer: vk.CommandBuffer = undefined;
    self.device_wrapper.allocateCommandBuffers(self.device, &.{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer)) catch return error.VulkanFailure;
    return command_buffer;
}

fn supportsDmabufTarget(self: *Self, size: render.Size, modifier: u64) bool {
    if (size.width == 0 or size.height == 0 or
        std.mem.indexOfScalar(u64, self.dmabuf_modifiers, modifier) == null)
        return false;

    const modifier_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .drm_format_modifier = modifier,
        .sharing_mode = .exclusive,
    };
    const external_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .p_next = &modifier_info,
        .handle_type = .{ .dma_buf_bit_ext = true },
    };
    const sampleable = self.dmabufTargetSampleable(modifier);
    const format_info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .p_next = &external_info,
        .format = .b8g8r8a8_unorm,
        .type = .@"2d",
        .tiling = .drm_format_modifier_ext,
        .usage = dmabufTargetUsage(sampleable),
    };
    var external_properties: vk.ExternalImageFormatProperties = .{
        .external_memory_properties = undefined,
    };
    var format_properties: vk.ImageFormatProperties2 = .{
        .p_next = &external_properties,
        .image_format_properties = undefined,
    };
    self.instance_wrapper.getPhysicalDeviceImageFormatProperties2KHR(
        self.physical_device,
        &format_info,
        &format_properties,
    ) catch return false;
    const maximum = format_properties.image_format_properties.max_extent;
    return external_properties.external_memory_properties.external_memory_features.importable_bit and
        size.width <= maximum.width and size.height <= maximum.height;
}

fn dmabufTargetSampleable(self: *const Self, modifier: u64) bool {
    return std.mem.indexOfScalar(u64, self.dmabuf_sampled_modifiers, modifier) != null;
}

fn dmabufTargetUsage(sampleable: bool) vk.ImageUsageFlags {
    return if (sampleable)
        .{ .color_attachment_bit = true, .transfer_dst_bit = true, .sampled_bit = true }
    else
        .{ .color_attachment_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true };
}

fn supportsDmabufSource(self: *Self, size: render.Size, source: render.DmabufSource) bool {
    if (size.width == 0 or size.height == 0 or
        (source.format != drm_format_argb8888 and source.format != drm_format_xrgb8888) or
        std.mem.indexOfScalar(u64, self.dmabuf_source_modifiers, source.modifier) == null)
    {
        return false;
    }

    const modifier_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .drm_format_modifier = source.modifier,
        .sharing_mode = .exclusive,
    };
    const external_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .p_next = &modifier_info,
        .handle_type = .{ .dma_buf_bit_ext = true },
    };
    const format_info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .p_next = &external_info,
        .format = .b8g8r8a8_unorm,
        .type = .@"2d",
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .sampled_bit = true },
    };
    var external_properties: vk.ExternalImageFormatProperties = .{
        .external_memory_properties = undefined,
    };
    var format_properties: vk.ImageFormatProperties2 = .{
        .p_next = &external_properties,
        .image_format_properties = undefined,
    };
    self.instance_wrapper.getPhysicalDeviceImageFormatProperties2KHR(
        self.physical_device,
        &format_info,
        &format_properties,
    ) catch return false;
    const maximum = format_properties.image_format_properties.max_extent;
    return external_properties.external_memory_properties.external_memory_features.importable_bit and
        size.width <= maximum.width and size.height <= maximum.height;
}

fn releaseTarget(self: *Self, id: u64) void {
    self.releaseOutput(.{ .dmabuf = id });
}

fn releaseOutput(self: *Self, key: TargetKey) void {
    self.drainPending() catch {};
    if (self.outputs.fetchRemove(key)) |removed| self.destroyOutput(removed.value);
}

fn drainPending(self: *Self) Error!void {
    if (!self.fence_pending) {
        std.debug.assert(self.pending_wait_semaphores.items.len == 0);
        std.debug.assert(self.pending_textures.items.len == 0);
        return;
    }
    const result = self.device_wrapper.waitForFences(
        self.device,
        &.{self.fence},
        .true,
        std.math.maxInt(u64),
    ) catch {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        self.fence_pending = false;
        self.releasePendingResources();
        return error.VulkanFailure;
    };
    if (result != .success) {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        self.fence_pending = false;
        self.releasePendingResources();
        return error.VulkanFailure;
    }
    self.fence_pending = false;
    self.releasePendingResources();
}

fn releasePendingResources(self: *Self) void {
    for (self.pending_wait_semaphores.items) |semaphore| {
        self.device_wrapper.destroySemaphore(self.device, semaphore, null);
    }
    self.pending_wait_semaphores.clearRetainingCapacity();
    for (self.pending_textures.items) |texture| self.destroyTexture(texture);
    self.pending_textures.clearRetainingCapacity();
}

fn disableScanoutSemaphore(self: *Self) void {
    if (self.scanout_semaphore == .null_handle) return;
    self.device_wrapper.destroySemaphore(self.device, self.scanout_semaphore, null);
    self.scanout_semaphore = .null_handle;
}

pub fn renderFrame(self: *Self, frame: render.Frame, target: render.Target) Error!void {
    _ = try self.renderFrameWithCompletion(frame, target, .wait);
}

pub fn renderFrameScanout(
    self: *Self,
    frame: render.Frame,
    target: render.Target,
) Error!?std.posix.fd_t {
    return self.renderFrameWithCompletion(frame, target, .sync_fd);
}

const CompletionMode = enum {
    wait,
    sync_fd,
};

fn renderFrameWithCompletion(
    self: *Self,
    frame: render.Frame,
    target: render.Target,
    completion_mode: CompletionMode,
) Error!?std.posix.fd_t {
    try self.drainPending();
    const required_pixels = try validateTarget(frame, target);
    const target_key = targetKey(target);
    if (!supports(frame.commands)) {
        switch (target) {
            .pixels => |pixels| {
                self.invalidateOutput(target_key);
                try self.fallback.render(frame, pixels);
            },
            .offscreen, .dmabuf => try self.renderGpuFallback(frame, target_key),
        }
        return null;
    }

    self.frame_number +%= 1;
    self.reclaimStaleResources();
    std.debug.assert(
        self.instances.items.len == 0 and
            self.draw_runs.items.len == 0 and
            self.blur_ops.items.len == 0 and
            self.prepared_images.items.len == 0,
    );
    var temporary_textures_pending = false;
    defer {
        self.instances.clearRetainingCapacity();
        self.draw_runs.clearRetainingCapacity();
        self.blur_ops.clearRetainingCapacity();
        if (!temporary_textures_pending) {
            for (self.prepared_images.items) |prepared| {
                if (prepared.cache_id == null) self.destroyTexture(prepared.texture);
            }
        }
        self.prepared_images.clearRetainingCapacity();
    }

    var frame_succeeded = false;
    defer if (!frame_succeeded) {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        self.fence_pending = false;
        self.releasePendingResources();
        self.resetCommandBufferForTarget(target_key);
        self.invalidateOutput(target_key);
        self.invalidatePreparedTextures(self.prepared_images.items);
    };
    var work_size = switch (target) {
        .pixels => std.math.mul(usize, required_pixels, @sizeOf(u32)) catch
            return error.InvalidTarget,
        .offscreen, .dmabuf => 0,
    };
    for (frame.commands) |command| switch (command) {
        .image => |image| {
            try validateImage(image);
            try self.prepared_images.append(
                self.allocator,
                try self.prepareTexture(image.buffer, self.prepared_images.items, &work_size),
            );
        },
        else => {},
    };

    try self.compileDrawRuns(frame, self.prepared_images.items);
    const instance_bytes = std.mem.sliceAsBytes(self.instances.items);
    try self.ensureInstanceBuffer(instance_bytes.len);
    if (instance_bytes.len > 0) {
        @memcpy(self.instance_mapped.?[0..instance_bytes.len], instance_bytes);
    }
    try self.ensureWorkBuffer(work_size);
    const output = try self.getOutput(target_key);
    if (!std.meta.eql(output.size, frame.size)) return error.InvalidTarget;
    output.last_used = self.frame_number;
    if (self.blur_ops.items.len != 0) {
        if (output.blur == null) output.blur = .{};
        for (self.blur_ops.items) |blur_op| {
            if (output.descriptor_set == .null_handle or blur_op.level == 0) {
                try self.ensureBlurLevel(&output.blur.?, output.size, 0);
            }
            for (1..@as(usize, blur_op.level) + 1) |level| {
                try self.ensureBlurLevel(&output.blur.?, output.size, level);
            }
        }
    }
    var blur_initialized = output.blur_initialized;
    if (!output.initialized and output.kind == .pixels) {
        const pixels = switch (target) {
            .pixels => |value| value,
            else => unreachable,
        };
        copyPixelsToMapped(self.work_mapped.?, 0, pixels, null);
    }
    var prepared_index: usize = 0;
    for (frame.commands) |command| switch (command) {
        .image => |image| {
            const prepared = &self.prepared_images.items[prepared_index];
            prepared_index += 1;
            if (prepared.upload_offset) |offset| {
                try copySourceToMapped(
                    self.work_mapped.?,
                    offset,
                    image.buffer,
                    prepared.upload_damage,
                );
            }
        },
        else => {},
    };

    std.debug.assert(!self.fence_pending);
    self.device_wrapper.resetFences(self.device, &.{self.fence}) catch
        return error.VulkanFailure;
    const reusable = output.kind != .pixels;
    const full_output: render.Rect = .{ .x = 0, .y = 0, .width = frame.size.width, .height = frame.size.height };
    const frame_render_area = damageBounds(frame.damage, full_output) orelse full_output;
    const cache_hit = reusable and self.recordedFrameMatches(
        &output.recorded_frame,
        output.initialized,
        output.blur_initialized,
        frame_render_area,
        self.prepared_images.items,
    );
    std.debug.assert(!reusable or output.command_buffer != .null_handle);
    const command_buffer = if (reusable) output.command_buffer else self.command_buffer;
    if (!cache_hit) {
        self.device_wrapper.beginCommandBuffer(command_buffer, &.{
            .flags = if (reusable) .{} else .{ .one_time_submit_bit = true },
        }) catch return error.VulkanFailure;

        if (output.kind == .dmabuf) {
            self.transitionExternalToRender(command_buffer, output.*);
        } else if (!output.initialized) {
            if (output.kind == .pixels) {
                const pixels = switch (target) {
                    .pixels => |value| value,
                    else => unreachable,
                };
                self.transitionImage(
                    command_buffer,
                    output.image,
                    .undefined,
                    .transfer_dst_optimal,
                    .{},
                    .{ .transfer_write_bit = true },
                    .{ .top_of_pipe_bit = true },
                    .{ .transfer_bit = true },
                );
                const upload: vk.BufferImageCopy = .{
                    .buffer_offset = 0,
                    .buffer_row_length = pixels.stride_pixels,
                    .buffer_image_height = pixels.size.height,
                    .image_subresource = colorSubresourceLayers(),
                    .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                    .image_extent = extent(pixels.size),
                };
                self.device_wrapper.cmdCopyBufferToImage(
                    command_buffer,
                    self.work_buffer,
                    output.image,
                    .transfer_dst_optimal,
                    &.{upload},
                );
                self.transitionImage(
                    command_buffer,
                    output.image,
                    .transfer_dst_optimal,
                    .color_attachment_optimal,
                    .{ .transfer_write_bit = true },
                    .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
                    .{ .transfer_bit = true },
                    .{ .color_attachment_output_bit = true },
                );
            } else {
                std.debug.assert(output.kind == .offscreen);
                self.transitionImage(
                    command_buffer,
                    output.image,
                    .undefined,
                    .color_attachment_optimal,
                    .{},
                    .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
                    .{ .top_of_pipe_bit = true },
                    .{ .color_attachment_output_bit = true },
                );
            }
        }

        for (self.prepared_images.items, 0..) |prepared, index| {
            if (!prepared.texture.imported or
                !isFirstImportedTexture(self.prepared_images.items, index)) continue;
            self.transitionExternalSourceToSample(command_buffer, prepared.texture.image);
        }

        for (self.prepared_images.items) |prepared| {
            const offset = prepared.upload_offset orelse continue;
            const old_layout: vk.ImageLayout = if (prepared.texture.initialized)
                .shader_read_only_optimal
            else
                .undefined;
            self.transitionImage(
                command_buffer,
                prepared.texture.image,
                old_layout,
                .transfer_dst_optimal,
                if (prepared.texture.initialized) .{ .shader_read_bit = true } else .{},
                .{ .transfer_write_bit = true },
                if (prepared.texture.initialized)
                    .{ .fragment_shader_bit = true }
                else
                    .{ .top_of_pipe_bit = true },
                .{ .transfer_bit = true },
            );
            const source_buffer = prepared.buffer;
            if (prepared.upload_damage) |damage| {
                for (damage) |rect| self.copyTextureRect(
                    command_buffer,
                    prepared.texture.image,
                    source_buffer,
                    offset,
                    rect,
                );
            } else {
                self.copyTextureRect(command_buffer, prepared.texture.image, source_buffer, offset, .{
                    .x = 0,
                    .y = 0,
                    .width = source_buffer.size.width,
                    .height = source_buffer.size.height,
                });
            }
            self.transitionImage(
                command_buffer,
                prepared.texture.image,
                .transfer_dst_optimal,
                .shader_read_only_optimal,
                .{ .transfer_write_bit = true },
                .{ .shader_read_bit = true },
                .{ .transfer_bit = true },
                .{ .fragment_shader_bit = true },
            );
        }

        const render_pass_info: vk.RenderPassBeginInfo = .{
            .render_pass = self.render_pass,
            .framebuffer = output.framebuffer,
            .render_area = rect2D(frame_render_area),
        };
        self.device_wrapper.cmdBeginRenderPass(
            command_buffer,
            &render_pass_info,
            .@"inline",
        );
        self.device_wrapper.cmdSetViewport(command_buffer, 0, &.{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(frame.size.width),
            .height = @floatFromInt(frame.size.height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        self.device_wrapper.cmdSetScissor(command_buffer, 0, &.{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = frame.size.width, .height = frame.size.height },
        }});
        if (self.instances.items.len > 0) {
            self.device_wrapper.cmdBindVertexBuffers(
                command_buffer,
                0,
                &.{self.instance_buffer},
                &.{0},
            );
        }
        var bound_pipeline: ?PipelineKind = null;
        var bound_descriptor: ?vk.DescriptorSet = null;
        for (self.draw_runs.items, 0..) |run, run_index| {
            if (self.blurOpAt(run_index)) |blur_op| {
                const scratch = output.blur.?;
                self.device_wrapper.cmdEndRenderPass(command_buffer);
                const sample_output = output.descriptor_set != .null_handle;
                if (sample_output) {
                    self.transitionImage(command_buffer, output.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_write_bit = true }, .{ .shader_read_bit = true }, .{ .color_attachment_output_bit = true }, .{ .fragment_shader_bit = true });
                } else {
                    self.transitionImage(command_buffer, output.image, .color_attachment_optimal, .transfer_src_optimal, .{ .color_attachment_write_bit = true }, .{ .transfer_read_bit = true }, .{ .color_attachment_output_bit = true }, .{ .transfer_bit = true });
                    const level_zero = scratch.levels[0].?;
                    const level_zero_bit: u16 = 1;
                    self.transitionScratchForWrite(command_buffer, level_zero.a.image, blur_initialized & level_zero_bit != 0, .transfer_dst_optimal, .{ .transfer_write_bit = true }, .{ .transfer_bit = true });
                    const offset: vk.Offset3D = .{ .x = blur_op.sample_rect.x, .y = blur_op.sample_rect.y, .z = 0 };
                    self.device_wrapper.cmdCopyImage(command_buffer, output.image, .transfer_src_optimal, level_zero.a.image, .transfer_dst_optimal, &.{.{
                        .src_subresource = colorSubresourceLayers(),
                        .src_offset = offset,
                        .dst_subresource = colorSubresourceLayers(),
                        .dst_offset = offset,
                        .extent = extent(.{ .width = blur_op.sample_rect.width, .height = blur_op.sample_rect.height }),
                    }});
                    self.transitionScratchToRead(command_buffer, level_zero.a.image, .transfer_dst_optimal, .{ .transfer_write_bit = true }, .{ .transfer_bit = true });
                    blur_initialized |= level_zero_bit;
                }

                for (0..blur_op.level) |index| {
                    const destination_level = scratch.levels[index + 1].?;
                    const destination_bit: u16 = @as(u16, 1) << @intCast((index + 1) * 2);
                    self.transitionScratchForWrite(command_buffer, destination_level.a.image, blur_initialized & destination_bit != 0, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                    const source_descriptor = if (index == 0)
                        if (sample_output) output.descriptor_set else scratch.levels[0].?.a.descriptor_set
                    else
                        scratch.levels[index].?.a.descriptor_set;
                    const source_size = if (index == 0)
                        frame.size
                    else
                        scratch.levels[index].?.size;
                    self.drawScratchPass(command_buffer, destination_level.a_framebuffer, destination_level.size, blur_op.level_rects[index + 1], .downsample, source_descriptor, source_size, blur_op.downsample_instances[index]);
                    self.transitionScratchToRead(command_buffer, destination_level.a.image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                    blur_initialized |= destination_bit;
                }

                const final_level = scratch.levels[blur_op.level].?;
                const blur_source_descriptor = if (blur_op.level == 0)
                    if (sample_output) output.descriptor_set else scratch.levels[0].?.a.descriptor_set
                else
                    final_level.a.descriptor_set;
                const b_bit: u16 = @as(u16, 1) << @intCast(@as(usize, blur_op.level) * 2 + 1);
                self.transitionScratchForWrite(command_buffer, final_level.b.image, blur_initialized & b_bit != 0, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                self.drawScratchPass(command_buffer, final_level.b_framebuffer, final_level.size, blur_op.horizontal_rect, .blur_horizontal, blur_source_descriptor, final_level.size, blur_op.horizontal_instance);
                self.transitionScratchToRead(command_buffer, final_level.b.image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                blur_initialized |= b_bit;

                const a_bit: u16 = @as(u16, 1) << @intCast(@as(usize, blur_op.level) * 2);
                self.transitionScratchForWrite(command_buffer, final_level.a.image, blur_initialized & a_bit != 0, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                self.drawScratchPass(command_buffer, final_level.a_framebuffer, final_level.size, blur_op.vertical_rect, .blur_vertical, final_level.b.descriptor_set, final_level.size, blur_op.vertical_instance);
                self.transitionScratchToRead(command_buffer, final_level.a.image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                blur_initialized |= a_bit;

                var source_level: usize = blur_op.level;
                while (source_level > 1) : (source_level -= 1) {
                    const destination_index = source_level - 1;
                    const destination_level = scratch.levels[destination_index].?;
                    const destination_bit: u16 = @as(u16, 1) << @intCast(destination_index * 2 + 1);
                    self.transitionScratchForWrite(command_buffer, destination_level.b.image, blur_initialized & destination_bit != 0, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                    const source_descriptor = if (source_level == blur_op.level)
                        final_level.a.descriptor_set
                    else
                        scratch.levels[source_level].?.b.descriptor_set;
                    self.drawScratchPass(command_buffer, destination_level.b_framebuffer, destination_level.size, blur_op.upsample_rects[destination_index], .downsample, source_descriptor, scratch.levels[source_level].?.size, blur_op.upsample_instances[destination_index]);
                    self.transitionScratchToRead(command_buffer, destination_level.b.image, .color_attachment_optimal, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true });
                    blur_initialized |= destination_bit;
                }
                if (sample_output) {
                    self.transitionImage(command_buffer, output.image, .shader_read_only_optimal, .color_attachment_optimal, .{ .shader_read_bit = true }, .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .color_attachment_output_bit = true });
                } else {
                    self.transitionImage(command_buffer, output.image, .transfer_src_optimal, .color_attachment_optimal, .{ .transfer_read_bit = true }, .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true }, .{ .transfer_bit = true }, .{ .color_attachment_output_bit = true });
                }
                self.device_wrapper.cmdBeginRenderPass(command_buffer, &render_pass_info, .@"inline");
                self.setViewportAndScissor(command_buffer, frame.size);
                bound_pipeline = null;
                bound_descriptor = null;
            }
            if (bound_pipeline != run.pipeline) {
                self.device_wrapper.cmdBindPipeline(
                    command_buffer,
                    .graphics,
                    self.pipelineForKind(run.pipeline),
                );
                bound_pipeline = run.pipeline;
            }
            const run_descriptor = if (run.pipeline == .blur_composite) blk: {
                const blur_op = self.blurOpAt(run_index).?;
                break :blk if (blur_op.level > 1)
                    output.blur.?.levels[1].?.b.descriptor_set
                else
                    output.blur.?.levels[blur_op.level].?.a.descriptor_set;
            } else run.descriptor_set;
            if (run_descriptor) |descriptor_set| {
                if (bound_descriptor != descriptor_set) {
                    self.device_wrapper.cmdBindDescriptorSets(
                        command_buffer,
                        .graphics,
                        self.pipeline_layout,
                        0,
                        &.{descriptor_set},
                        null,
                    );
                    bound_descriptor = descriptor_set;
                }
            }
            const push: FramePush = .{
                .target_size = sizeFloats(frame.size),
                .texture_size = sizeFloats(run.texture_size),
                // Scratch images use the output's format, so their sampled and
                // attachment component order already agrees on every device.
                .swap_red_blue = if (run.pipeline == .blur_composite)
                    0
                else
                    @floatFromInt(@intFromBool(self.swap_red_blue)),
            };
            self.device_wrapper.cmdPushConstants(
                command_buffer,
                self.pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(FramePush),
                &push,
            );
            self.device_wrapper.cmdDraw(
                command_buffer,
                4,
                run.instance_count,
                0,
                run.first_instance,
            );
        }
        self.device_wrapper.cmdEndRenderPass(command_buffer);

        for (self.prepared_images.items, 0..) |prepared, index| {
            if (!prepared.texture.imported or
                !isFirstImportedTexture(self.prepared_images.items, index)) continue;
            self.transitionSampleToExternal(command_buffer, prepared.texture.image);
        }

        if (output.kind == .dmabuf) self.transitionRenderToExternal(command_buffer, output.image);

        if (output.kind == .pixels) self.transitionImage(
            command_buffer,
            output.image,
            .color_attachment_optimal,
            .transfer_src_optimal,
            .{ .color_attachment_write_bit = true },
            .{ .transfer_read_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .transfer_bit = true },
        );
        if (output.kind == .pixels) self.copyOutputDamage(
            command_buffer,
            frame,
            target.pixels,
            output.image,
        );
        if (output.kind == .pixels) self.transitionImage(
            command_buffer,
            output.image,
            .transfer_src_optimal,
            .color_attachment_optimal,
            .{ .transfer_read_bit = true },
            .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .{ .transfer_bit = true },
            .{ .color_attachment_output_bit = true },
        );
        if (output.kind == .pixels) self.transferToHostBarrier(command_buffer);
        self.device_wrapper.endCommandBuffer(command_buffer) catch return error.VulkanFailure;
        if (reusable) try self.rememberRecordedFrame(
            &output.recorded_frame,
            output.initialized,
            output.blur_initialized,
            frame_render_area,
            self.prepared_images.items,
        );
    }

    var wait_stages: std.ArrayList(vk.PipelineStageFlags) = .empty;
    defer wait_stages.deinit(self.allocator);
    self.pending_wait_semaphores.ensureTotalCapacity(
        self.allocator,
        self.prepared_images.items.len,
    ) catch return error.OutOfMemory;
    wait_stages.ensureTotalCapacity(self.allocator, self.prepared_images.items.len) catch
        return error.OutOfMemory;
    var temporary_texture_count: usize = 0;
    for (self.prepared_images.items) |prepared| {
        if (prepared.cache_id == null) temporary_texture_count += 1;
    }
    self.pending_textures.ensureTotalCapacity(self.allocator, temporary_texture_count) catch
        return error.OutOfMemory;
    for (self.prepared_images.items, 0..) |prepared, index| {
        if (!prepared.texture.imported or
            !isFirstImportedTexture(self.prepared_images.items, index)) continue;
        const source = prepared.buffer.dmabuf.?;
        const sync_fd = (source.export_read_fence)(source.context) orelse {
            if (!(source.begin_cpu_read)(source.context)) return error.VulkanFailure;
            if (!(source.end_cpu_read)(source.context)) return error.VulkanFailure;
            continue;
        };
        const semaphore = self.device_wrapper.createSemaphore(self.device, &.{}, null) catch {
            _ = std.c.close(sync_fd);
            if (!(source.begin_cpu_read)(source.context)) return error.VulkanFailure;
            if (!(source.end_cpu_read)(source.context)) return error.VulkanFailure;
            continue;
        };
        self.device_wrapper.importSemaphoreFdKHR(self.device, &.{
            .semaphore = semaphore,
            .flags = .{ .temporary_bit = true },
            .handle_type = .{ .sync_fd_bit = true },
            .fd = sync_fd,
        }) catch {
            _ = std.c.close(sync_fd);
            self.device_wrapper.destroySemaphore(self.device, semaphore, null);
            if (!(source.begin_cpu_read)(source.context)) return error.VulkanFailure;
            if (!(source.end_cpu_read)(source.context)) return error.VulkanFailure;
            continue;
        };
        self.pending_wait_semaphores.appendAssumeCapacity(semaphore);
        wait_stages.appendAssumeCapacity(.{ .all_commands_bit = true });
    }

    const async_submission = completion_mode == .sync_fd and
        output.kind == .dmabuf and self.scanout_semaphore != .null_handle;
    // Queue submission makes prior coherent mapped writes visible to every
    // device access in the submission; no host pipeline barrier is needed.
    const submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = @intCast(self.pending_wait_semaphores.items.len),
        .p_wait_semaphores = self.pending_wait_semaphores.items.ptr,
        .p_wait_dst_stage_mask = wait_stages.items.ptr,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&command_buffer),
        .signal_semaphore_count = @intFromBool(async_submission),
        .p_signal_semaphores = if (async_submission)
            @ptrCast(&self.scanout_semaphore)
        else
            null,
    };
    self.device_wrapper.queueSubmit(self.queue, &.{submit_info}, self.fence) catch
        return error.VulkanFailure;
    self.fence_pending = true;
    for (self.prepared_images.items) |prepared| {
        if (prepared.cache_id == null) {
            self.pending_textures.appendAssumeCapacity(prepared.texture);
        }
    }
    temporary_textures_pending = true;
    output.initialized = true;
    if (self.blur_ops.items.len != 0) output.blur_initialized = blur_initialized;
    for (self.prepared_images.items) |prepared| {
        if (prepared.cache_id) |cache_id| {
            const texture = self.textures.getPtr(cache_id) orelse continue;
            texture.initialized = true;
            texture.version = prepared.desired_version;
        }
    }

    if (async_submission) {
        const completion_fd = self.device_wrapper.getSemaphoreFdKHR(self.device, &.{
            .semaphore = self.scanout_semaphore,
            .handle_type = .{ .sync_fd_bit = true },
        }) catch {
            try self.drainPending();
            self.disableScanoutSemaphore();
            log.warn("Vulkan sync-file export failed; using blocking scanout", .{});
            frame_succeeded = true;
            return null;
        };
        if (completion_fd < 0) {
            try self.drainPending();
            frame_succeeded = true;
            return null;
        }
        var completion_fd_owned = true;
        defer if (completion_fd_owned) {
            _ = std.c.close(completion_fd);
        };
        for (self.prepared_images.items, 0..) |prepared, index| {
            if (!prepared.texture.imported or
                !isFirstImportedTexture(self.prepared_images.items, index)) continue;
            if (!importDmaBufSyncFile(
                prepared.buffer.dmabuf.?.fd,
                completion_fd,
                sync.DMA_BUF_SYNC_READ,
            )) {
                try self.drainPending();
                self.disableScanoutSemaphore();
                log.warn("DMA-BUF sync-file import failed; using blocking scanout", .{});
                frame_succeeded = true;
                return null;
            }
        }
        frame_succeeded = true;
        completion_fd_owned = false;
        return completion_fd;
    }

    try self.drainPending();
    frame_succeeded = true;
    if (output.kind == .pixels) copyDamageToTarget(frame, target.pixels, self.work_mapped.?);
    return null;
}

fn importDmaBufSyncFile(
    dmabuf_fd: std.posix.fd_t,
    sync_file_fd: std.posix.fd_t,
    flags: u32,
) bool {
    var import_sync_file: sync.dma_buf_import_sync_file = .{
        .flags = flags,
        .fd = sync_file_fd,
    };
    while (true) {
        const result = sync.ioctl(
            dmabuf_fd,
            sync.DMA_BUF_IOCTL_IMPORT_SYNC_FILE,
            &import_sync_file,
        );
        if (result >= 0) return true;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

fn isFirstImportedTexture(prepared_images: []const PreparedImage, index: usize) bool {
    const image = prepared_images[index].texture.image;
    for (prepared_images[0..index]) |prepared| {
        if (prepared.texture.imported and prepared.texture.image == image) return false;
    }
    return true;
}

fn supports(commands: []const render.Command) bool {
    for (commands) |command| switch (command) {
        .clear => {},
        .solid_rect, .image, .shadow, .backdrop_blur => {},
    };
    return true;
}

fn renderGpuFallback(self: *Self, frame: render.Frame, key: TargetKey) Error!void {
    const output = self.outputs.getPtr(key) orelse return error.InvalidTarget;
    if (output.kind == .pixels or !std.meta.eql(output.size, frame.size)) return error.InvalidTarget;
    const pixel_count = frame.size.pixelCount() catch return error.InvalidTarget;
    const byte_count = std.math.mul(usize, pixel_count, @sizeOf(u32)) catch
        return error.InvalidTarget;
    try self.ensureWorkBuffer(byte_count);
    const pixels: [*]u32 = @ptrCast(@alignCast(self.work_mapped.?));
    const cpu_target: render.PixelBuffer = .{
        .size = frame.size,
        .stride_pixels = frame.size.width,
        .pixels = pixels[0..pixel_count],
    };
    try self.fallback.render(frame, cpu_target);

    std.debug.assert(output.command_buffer != .null_handle);
    output.recorded_frame.valid = false;
    self.device_wrapper.resetCommandBuffer(output.command_buffer, .{}) catch
        return error.VulkanFailure;
    self.device_wrapper.resetFences(self.device, &.{self.fence}) catch
        return error.VulkanFailure;
    self.device_wrapper.beginCommandBuffer(output.command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
    }) catch return error.VulkanFailure;
    if (output.kind == .dmabuf) {
        self.transitionExternal(
            output.command_buffer,
            output.*,
            if (output.initialized) .general else .undefined,
            .transfer_dst_optimal,
            if (output.initialized) vk.QUEUE_FAMILY_FOREIGN_EXT else vk.QUEUE_FAMILY_IGNORED,
            self.queue_family_index,
            .{},
            .{ .transfer_write_bit = true },
            if (output.initialized) .{ .all_commands_bit = true } else .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
        );
    } else {
        std.debug.assert(output.kind == .offscreen);
        self.transitionImage(
            output.command_buffer,
            output.image,
            if (output.initialized) .color_attachment_optimal else .undefined,
            .transfer_dst_optimal,
            if (output.initialized) .{ .color_attachment_write_bit = true } else .{},
            .{ .transfer_write_bit = true },
            if (output.initialized) .{ .color_attachment_output_bit = true } else .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
        );
    }
    if (frame.damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(frame.size) orelse continue;
            self.copyTextureRect(output.command_buffer, output.image, cpu_target, 0, clipped);
        }
    } else self.copyTextureRect(output.command_buffer, output.image, cpu_target, 0, .{
        .x = 0,
        .y = 0,
        .width = frame.size.width,
        .height = frame.size.height,
    });
    if (output.kind == .dmabuf) {
        self.transitionExternal(
            output.command_buffer,
            output.*,
            .transfer_dst_optimal,
            .general,
            self.queue_family_index,
            vk.QUEUE_FAMILY_FOREIGN_EXT,
            .{ .transfer_write_bit = true },
            .{},
            .{ .transfer_bit = true },
            .{ .bottom_of_pipe_bit = true },
        );
    } else {
        self.transitionImage(
            output.command_buffer,
            output.image,
            .transfer_dst_optimal,
            .color_attachment_optimal,
            .{ .transfer_write_bit = true },
            .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
            .{ .transfer_bit = true },
            .{ .color_attachment_output_bit = true },
        );
    }
    self.device_wrapper.endCommandBuffer(output.command_buffer) catch return error.VulkanFailure;
    const submit: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&output.command_buffer),
    };
    self.device_wrapper.queueSubmit(self.queue, &.{submit}, self.fence) catch
        return error.VulkanFailure;
    self.fence_pending = true;
    const result = self.device_wrapper.waitForFences(
        self.device,
        &.{self.fence},
        .true,
        std.math.maxInt(u64),
    ) catch {
        self.device_wrapper.deviceWaitIdle(self.device) catch {};
        self.fence_pending = false;
        return error.VulkanFailure;
    };
    self.fence_pending = false;
    if (result != .success) return error.VulkanFailure;
    output.initialized = true;
}

fn validateTarget(frame: render.Frame, target: render.Target) Error!usize {
    if (frame.size.width == 0 or frame.size.height == 0) return error.InvalidTarget;
    if (!std.meta.eql(frame.size, target.size())) return error.InvalidTarget;
    const pixels = switch (target) {
        .offscreen => |offscreen| {
            if (offscreen.id == 0) return error.InvalidTarget;
            return frame.size.pixelCount() catch return error.InvalidTarget;
        },
        .dmabuf => |dmabuf| {
            if (dmabuf.id == 0) return error.InvalidTarget;
            return frame.size.pixelCount() catch return error.InvalidTarget;
        },
        .pixels => |pixels| pixels,
    };
    if (pixels.stride_pixels < pixels.size.width) return error.InvalidTarget;
    if (pixels.dmabuf != null) return error.InvalidTarget;
    const last_row = std.math.mul(
        usize,
        pixels.size.height - 1,
        pixels.stride_pixels,
    ) catch return error.InvalidTarget;
    const required_pixels = std.math.add(usize, last_row, pixels.size.width) catch
        return error.InvalidTarget;
    if (pixels.pixels.len < required_pixels) return error.InvalidTarget;
    return required_pixels;
}

fn validateImage(image: render.Image) Error!void {
    if (image.size.width == 0 or image.size.height == 0) return error.InvalidTarget;
    _ = try requiredBufferPixels(image.buffer);
    if (image.buffer.source_damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(image.buffer.size) orelse return error.InvalidTarget;
            if (!std.meta.eql(rect, clipped)) return error.InvalidTarget;
        }
    }
    const transformed_size = image.transform.applyToSize(image.buffer.size);
    const source = image.source orelse render.SourceRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(transformed_size.width),
        .height = @floatFromInt(transformed_size.height),
    };
    if (!std.math.isFinite(source.x) or !std.math.isFinite(source.y) or
        !std.math.isFinite(source.width) or !std.math.isFinite(source.height) or
        source.x < 0 or source.y < 0 or source.width <= 0 or source.height <= 0 or
        source.x + source.width > @as(f64, @floatFromInt(transformed_size.width)) or
        source.y + source.height > @as(f64, @floatFromInt(transformed_size.height)))
    {
        return error.InvalidTarget;
    }
}

fn requiredBufferPixels(buffer: render.PixelBuffer) Error!usize {
    if (buffer.size.width == 0 or buffer.size.height == 0 or
        buffer.stride_pixels < buffer.size.width)
    {
        return error.InvalidTarget;
    }
    const last_row = std.math.mul(
        usize,
        buffer.size.height - 1,
        buffer.stride_pixels,
    ) catch return error.InvalidTarget;
    const required = std.math.add(usize, last_row, buffer.size.width) catch
        return error.InvalidTarget;
    if (buffer.dmabuf) |dmabuf| {
        const stride_bytes = std.math.mul(u64, buffer.stride_pixels, @sizeOf(u32)) catch
            return error.InvalidTarget;
        const last_row_bytes = std.math.mul(u64, buffer.size.height - 1, stride_bytes) catch
            return error.InvalidTarget;
        const required_bytes = std.math.add(
            u64,
            std.math.add(u64, dmabuf.offset, last_row_bytes) catch return error.InvalidTarget,
            @as(u64, buffer.size.width) * @sizeOf(u32),
        ) catch return error.InvalidTarget;
        if (dmabuf.stride != stride_bytes or required_bytes > dmabuf.required_bytes or
            dmabuf.offset % @alignOf(u32) != 0)
        {
            return error.InvalidTarget;
        }
        return required;
    }
    if (buffer.pixels.len < required) return error.InvalidTarget;
    return required;
}

fn targetKey(target: render.Target) TargetKey {
    return switch (target) {
        .pixels => |pixels| .{ .pixels = .{
            .pointer = @intFromPtr(pixels.pixels.ptr),
            .width = pixels.size.width,
            .height = pixels.size.height,
            .stride_pixels = pixels.stride_pixels,
        } },
        .offscreen => |offscreen| .{ .offscreen = offscreen.id },
        .dmabuf => |dmabuf| .{ .dmabuf = dmabuf.id },
    };
}

fn getOutput(self: *Self, key: TargetKey) Error!*Output {
    if (self.outputs.getPtr(key)) |output| return output;
    const pixels = switch (key) {
        .pixels => |pixels| pixels,
        .offscreen, .dmabuf => return error.InvalidTarget,
    };
    const output = try self.createOutput(.{ .width = pixels.width, .height = pixels.height });
    errdefer self.destroyOutput(output);
    self.outputs.put(self.allocator, key, output) catch return error.OutOfMemory;
    return self.outputs.getPtr(key).?;
}

fn createOutput(self: *Self, size: render.Size) Error!Output {
    const allocation = try self.createImage(size, .{
        .transfer_src_bit = true,
        .transfer_dst_bit = true,
        .color_attachment_bit = true,
        .sampled_bit = true,
    });
    errdefer self.destroyImageAllocation(allocation);
    const descriptor_set = try self.createImageDescriptor(allocation.view);
    errdefer self.destroyImageDescriptor(descriptor_set);
    const attachments = [_]vk.ImageView{allocation.view};
    const framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{
        .render_pass = self.render_pass,
        .attachment_count = 1,
        .p_attachments = &attachments,
        .width = size.width,
        .height = size.height,
        .layers = 1,
    }, null) catch return error.VulkanFailure;
    return .{
        .image = allocation.image,
        .memory = allocation.memory,
        .view = allocation.view,
        .descriptor_set = descriptor_set,
        .framebuffer = framebuffer,
        .size = size,
        .last_used = self.frame_number,
    };
}

fn invalidateOutput(self: *Self, key: TargetKey) void {
    if (self.outputs.getPtr(key)) |output| {
        if (output.kind != .pixels) {
            output.initialized = false;
            output.blur_initialized = 0;
            output.recorded_frame.valid = false;
            return;
        }
    }
    if (self.outputs.fetchRemove(key)) |entry| self.destroyOutput(entry.value);
}

fn resetCommandBufferForTarget(self: *Self, key: TargetKey) void {
    if (self.outputs.getPtr(key)) |output| {
        if (output.kind != .pixels) {
            self.device_wrapper.resetCommandBuffer(output.command_buffer, .{}) catch {};
            output.recorded_frame.valid = false;
            return;
        }
    }
    self.device_wrapper.resetCommandBuffer(self.command_buffer, .{}) catch {};
}

fn destroyOutput(self: *Self, value: Output) void {
    var output = value;
    if (output.blur) |blur| self.destroyBlurScratch(blur);
    output.recorded_frame.deinit(self.allocator);
    if (output.command_buffer != .null_handle) {
        self.device_wrapper.freeCommandBuffers(
            self.device,
            self.command_pool,
            &.{output.command_buffer},
        );
    }
    self.device_wrapper.destroyFramebuffer(self.device, output.framebuffer, null);
    if (output.descriptor_set != .null_handle) self.destroyImageDescriptor(output.descriptor_set);
    self.destroyImageAllocation(.{
        .image = output.image,
        .memory = output.memory,
        .view = output.view,
    });
}

fn createBlurImage(self: *Self, size: render.Size, usage: vk.ImageUsageFlags) Error!BlurImage {
    const allocation = try self.createImage(size, usage);
    errdefer self.destroyImageAllocation(allocation);
    const descriptor_set = try self.createImageDescriptor(allocation.view);
    return .{ .image = allocation.image, .memory = allocation.memory, .view = allocation.view, .descriptor_set = descriptor_set };
}

fn createImageDescriptor(self: *Self, view: vk.ImageView) Error!vk.DescriptorSet {
    var descriptor_set: vk.DescriptorSet = undefined;
    self.device_wrapper.allocateDescriptorSets(self.device, &.{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
    }, @ptrCast(&descriptor_set)) catch return error.VulkanFailure;
    const image_info: vk.DescriptorImageInfo = .{ .sampler = self.sampler, .image_view = view, .image_layout = .shader_read_only_optimal };
    self.device_wrapper.updateDescriptorSets(self.device, &.{.{
        .dst_set = descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }}, null);
    return descriptor_set;
}

fn destroyImageDescriptor(self: *Self, descriptor_set: vk.DescriptorSet) void {
    _ = self.device_wrapper.freeDescriptorSets(self.device, self.descriptor_pool, &.{descriptor_set}) catch {};
}

fn ensureBlurLevel(self: *Self, scratch: *BlurScratch, output_size: render.Size, index: usize) Error!void {
    std.debug.assert(index < blur_level_count);
    if (scratch.levels[index] != null) return;
    const level_size = blurLevelSize(output_size, @intCast(index));
    const a = try self.createBlurImage(level_size, .{ .color_attachment_bit = true, .sampled_bit = true, .transfer_dst_bit = true });
    errdefer self.destroyBlurImage(a);
    const b = try self.createBlurImage(level_size, .{ .color_attachment_bit = true, .sampled_bit = true });
    errdefer self.destroyBlurImage(b);
    const a_framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{ .render_pass = self.scratch_render_pass, .attachment_count = 1, .p_attachments = @ptrCast(&a.view), .width = level_size.width, .height = level_size.height, .layers = 1 }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyFramebuffer(self.device, a_framebuffer, null);
    const b_framebuffer = self.device_wrapper.createFramebuffer(self.device, &.{ .render_pass = self.scratch_render_pass, .attachment_count = 1, .p_attachments = @ptrCast(&b.view), .width = level_size.width, .height = level_size.height, .layers = 1 }, null) catch return error.VulkanFailure;
    scratch.levels[index] = .{ .size = level_size, .a = a, .b = b, .a_framebuffer = a_framebuffer, .b_framebuffer = b_framebuffer };
}

fn destroyBlurImage(self: *Self, image: BlurImage) void {
    self.destroyImageDescriptor(image.descriptor_set);
    self.destroyImageAllocation(.{ .image = image.image, .memory = image.memory, .view = image.view });
}

fn destroyBlurScratch(self: *Self, blur: BlurScratch) void {
    for (blur.levels) |level| if (level) |value| self.destroyBlurLevel(value);
}

fn destroyBlurLevel(self: *Self, level: BlurLevel) void {
    self.device_wrapper.destroyFramebuffer(self.device, level.b_framebuffer, null);
    self.device_wrapper.destroyFramebuffer(self.device, level.a_framebuffer, null);
    self.destroyBlurImage(level.b);
    self.destroyBlurImage(level.a);
}

const ImageAllocation = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
};

fn createImage(
    self: *Self,
    size: render.Size,
    usage: vk.ImageUsageFlags,
) Error!ImageAllocation {
    const image = self.device_wrapper.createImage(self.device, &.{
        .image_type = .@"2d",
        .format = self.format,
        .extent = extent(size),
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImage(self.device, image, null);
    const requirements = self.device_wrapper.getImageMemoryRequirements(self.device, image);
    const memory_type = self.deviceMemoryType(requirements.memory_type_bits) orelse
        return error.VulkanFailure;
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => return error.VulkanFailure,
    };
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindImageMemory(self.device, image, memory, 0) catch
        return error.VulkanFailure;
    const view = self.device_wrapper.createImageView(self.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = self.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = colorSubresourceRange(),
    }, null) catch return error.VulkanFailure;
    return .{ .image = image, .memory = memory, .view = view };
}

fn destroyImageAllocation(self: *Self, allocation: ImageAllocation) void {
    self.device_wrapper.destroyImageView(self.device, allocation.view, null);
    self.device_wrapper.destroyImage(self.device, allocation.image, null);
    self.device_wrapper.freeMemory(self.device, allocation.memory, null);
}

fn prepareTexture(
    self: *Self,
    buffer: render.PixelBuffer,
    previously_prepared: []const PreparedImage,
    work_size: *usize,
) Error!PreparedImage {
    const required_pixels = try requiredBufferPixels(buffer);
    const byte_size = std.math.mul(usize, required_pixels, @sizeOf(u32)) catch
        return error.InvalidTarget;
    if (buffer.dmabuf) |dmabuf| {
        if (self.supportsDmabufSource(buffer.size, dmabuf)) {
            const imported = self.prepareImportedTexture(buffer, previously_prepared) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                log.warn("Vulkan DMA-BUF source import failed; using CPU upload fallback: {t}", .{err});
                break :blk null;
            };
            if (imported) |prepared| return prepared;
        }
    }
    if (buffer.source_cache) |source| {
        for (previously_prepared) |prepared| {
            if (prepared.cache_id == source.id) {
                std.debug.assert(prepared.desired_version == source.version);
                return .{
                    .texture = prepared.texture,
                    .buffer = buffer,
                    .upload_offset = null,
                    .upload_damage = null,
                    .cache_id = source.id,
                    .desired_version = source.version,
                };
            }
        }
        if (self.textures.get(source.id)) |existing| {
            if (existing.imported or !std.meta.eql(existing.size, buffer.size)) {
                const removed = self.textures.fetchRemove(source.id).?;
                self.destroyTexture(removed.value);
            }
        }
        if (self.textures.getPtr(source.id)) |texture| {
            texture.last_used = self.frame_number;
            const unchanged = texture.initialized and texture.version == source.version;
            const upload_damage = if (!unchanged and texture.initialized and
                texture.version +% 1 == source.version)
                buffer.source_damage
            else
                null;
            const upload_offset = if (unchanged or
                (upload_damage != null and upload_damage.?.len == 0))
                null
            else
                try reserveWork(work_size, byte_size);
            return .{
                .texture = texture.*,
                .buffer = buffer,
                .upload_offset = upload_offset,
                .upload_damage = upload_damage,
                .cache_id = source.id,
                .desired_version = source.version,
            };
        }

        self.makeTextureRoom() catch return error.VulkanFailure;
        const texture = try self.createTexture(buffer.size);
        errdefer self.destroyTexture(texture);
        self.textures.put(self.allocator, source.id, texture) catch return error.OutOfMemory;
        return .{
            .texture = texture,
            .buffer = buffer,
            .upload_offset = try reserveWork(work_size, byte_size),
            .upload_damage = null,
            .cache_id = source.id,
            .desired_version = source.version,
        };
    }

    const texture = try self.createTexture(buffer.size);
    return .{
        .texture = texture,
        .buffer = buffer,
        .upload_offset = try reserveWork(work_size, byte_size),
        .upload_damage = null,
        .cache_id = null,
        .desired_version = 0,
    };
}

fn prepareImportedTexture(
    self: *Self,
    buffer: render.PixelBuffer,
    previously_prepared: []const PreparedImage,
) Error!PreparedImage {
    const source = buffer.source_cache orelse return error.InvalidTarget;
    for (previously_prepared) |prepared| {
        if (prepared.cache_id == source.id) {
            if (!prepared.texture.imported) return error.InvalidTarget;
            return .{
                .texture = prepared.texture,
                .buffer = buffer,
                .upload_offset = null,
                .upload_damage = null,
                .cache_id = source.id,
                .desired_version = source.version,
            };
        }
    }
    if (self.textures.get(source.id)) |existing| {
        if (!existing.imported or !std.meta.eql(existing.size, buffer.size)) {
            const removed = self.textures.fetchRemove(source.id).?;
            self.destroyTexture(removed.value);
        }
    }
    if (self.textures.getPtr(source.id)) |texture| {
        texture.last_used = self.frame_number;
        return .{
            .texture = texture.*,
            .buffer = buffer,
            .upload_offset = null,
            .upload_damage = null,
            .cache_id = source.id,
            .desired_version = source.version,
        };
    }

    self.makeTextureRoom() catch return error.VulkanFailure;
    const texture = try self.createImportedTexture(buffer.size, buffer.dmabuf.?);
    errdefer self.destroyTexture(texture);
    self.textures.put(self.allocator, source.id, texture) catch return error.OutOfMemory;
    return .{
        .texture = texture,
        .buffer = buffer,
        .upload_offset = null,
        .upload_damage = null,
        .cache_id = source.id,
        .desired_version = source.version,
    };
}

fn recordedFrameMatches(
    self: *const Self,
    recorded: *const RecordedFrame,
    output_initialized: bool,
    blur_initialized: u16,
    render_area: render.Rect,
    prepared_images: []const PreparedImage,
) bool {
    if (!recorded.valid or
        recorded.resource_epoch != self.resource_epoch or
        recorded.output_initialized != output_initialized or
        recorded.blur_initialized != blur_initialized or
        !std.meta.eql(recorded.render_area, render_area) or
        recorded.work_buffer != self.work_buffer or
        recorded.instance_buffer != self.instance_buffer or
        recorded.draw_runs.items.len != self.draw_runs.items.len or
        recorded.blur_ops.items.len != self.blur_ops.items.len)
    {
        return false;
    }
    for (recorded.draw_runs.items, self.draw_runs.items) |recorded_run, run| {
        if (!std.meta.eql(recorded_run, run)) return false;
    }
    for (recorded.blur_ops.items, self.blur_ops.items) |recorded_op, op| {
        if (!std.meta.eql(recorded_op, op)) return false;
    }

    var upload_index: usize = 0;
    var rectangle_index: usize = 0;
    for (prepared_images) |prepared| {
        const offset = prepared.upload_offset orelse continue;
        if (upload_index >= recorded.uploads.items.len) return false;
        const upload = recorded.uploads.items[upload_index];
        upload_index += 1;
        const rectangle_count = uploadRectangleCount(prepared);
        if (upload.image != prepared.texture.image or
            upload.initialized != prepared.texture.initialized or
            !std.meta.eql(upload.buffer_size, prepared.buffer.size) or
            upload.stride_pixels != prepared.buffer.stride_pixels or
            upload.offset != offset or
            upload.first_rectangle != rectangle_index or
            upload.rectangle_count != rectangle_count)
        {
            return false;
        }
        for (0..rectangle_count) |index| {
            if (rectangle_index >= recorded.upload_rectangles.items.len or
                !std.meta.eql(
                    recorded.upload_rectangles.items[rectangle_index],
                    uploadRectangle(prepared, index),
                ))
            {
                return false;
            }
            rectangle_index += 1;
        }
    }
    return upload_index == recorded.uploads.items.len and
        rectangle_index == recorded.upload_rectangles.items.len;
}

fn rememberRecordedFrame(
    self: *Self,
    recorded: *RecordedFrame,
    output_initialized: bool,
    blur_initialized: u16,
    render_area: render.Rect,
    prepared_images: []const PreparedImage,
) error{OutOfMemory}!void {
    recorded.valid = false;
    recorded.uploads.clearRetainingCapacity();
    recorded.upload_rectangles.clearRetainingCapacity();
    recorded.draw_runs.clearRetainingCapacity();
    recorded.blur_ops.clearRetainingCapacity();

    for (prepared_images) |prepared| {
        const offset = prepared.upload_offset orelse continue;
        const first_rectangle = recorded.upload_rectangles.items.len;
        const rectangle_count = uploadRectangleCount(prepared);
        for (0..rectangle_count) |index| {
            try recorded.upload_rectangles.append(self.allocator, uploadRectangle(prepared, index));
        }
        try recorded.uploads.append(self.allocator, .{
            .image = prepared.texture.image,
            .initialized = prepared.texture.initialized,
            .buffer_size = prepared.buffer.size,
            .stride_pixels = prepared.buffer.stride_pixels,
            .offset = offset,
            .first_rectangle = first_rectangle,
            .rectangle_count = rectangle_count,
        });
    }
    try recorded.draw_runs.appendSlice(self.allocator, self.draw_runs.items);
    try recorded.blur_ops.appendSlice(self.allocator, self.blur_ops.items);
    recorded.resource_epoch = self.resource_epoch;
    recorded.output_initialized = output_initialized;
    recorded.blur_initialized = blur_initialized;
    recorded.render_area = render_area;
    recorded.work_buffer = self.work_buffer;
    recorded.instance_buffer = self.instance_buffer;
    recorded.valid = true;
}

fn uploadRectangleCount(prepared: PreparedImage) usize {
    if (prepared.upload_damage) |damage| {
        std.debug.assert(damage.len > 0);
        return damage.len;
    }
    return 1;
}

fn uploadRectangle(prepared: PreparedImage, index: usize) render.Rect {
    if (prepared.upload_damage) |damage| return damage[index];
    std.debug.assert(index == 0);
    return .{
        .x = 0,
        .y = 0,
        .width = prepared.buffer.size.width,
        .height = prepared.buffer.size.height,
    };
}

fn reserveWork(work_size: *usize, byte_size: usize) Error!usize {
    const aligned = std.mem.alignForward(usize, work_size.*, @alignOf(u32));
    work_size.* = std.math.add(usize, aligned, byte_size) catch return error.InvalidTarget;
    return aligned;
}

fn createTexture(self: *Self, size: render.Size) Error!Texture {
    const allocation = try self.createImage(size, .{
        .transfer_dst_bit = true,
        .sampled_bit = true,
    });
    errdefer self.destroyImageAllocation(allocation);
    var descriptor_set: vk.DescriptorSet = undefined;
    self.device_wrapper.allocateDescriptorSets(self.device, &.{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
    }, @ptrCast(&descriptor_set)) catch return error.VulkanFailure;
    errdefer self.device_wrapper.freeDescriptorSets(
        self.device,
        self.descriptor_pool,
        &.{descriptor_set},
    ) catch {};
    const image_info: vk.DescriptorImageInfo = .{
        .sampler = self.sampler,
        .image_view = allocation.view,
        .image_layout = .shader_read_only_optimal,
    };
    self.device_wrapper.updateDescriptorSets(self.device, &.{.{
        .dst_set = descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }}, null);
    const texture: Texture = .{
        .image = allocation.image,
        .memory = allocation.memory,
        .view = allocation.view,
        .descriptor_set = descriptor_set,
        .size = size,
        .last_used = self.frame_number,
    };
    self.advanceResourceEpoch();
    return texture;
}

fn createImportedTexture(
    self: *Self,
    size: render.Size,
    source: render.DmabufSource,
) Error!Texture {
    if (!self.supportsDmabufSource(size, source)) return error.InvalidTarget;
    const duplicate_fd = std.c.dup(source.fd);
    if (duplicate_fd < 0) return error.VulkanFailure;
    var fd_owned = true;
    defer if (fd_owned) {
        _ = std.c.close(duplicate_fd);
    };
    const plane: vk.SubresourceLayout = .{
        .offset = source.offset,
        .size = 0,
        .row_pitch = source.stride,
        .array_pitch = 0,
        .depth_pitch = 0,
    };
    const modifier_info: vk.ImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .drm_format_modifier = source.modifier,
        .drm_format_modifier_plane_count = 1,
        .p_plane_layouts = @ptrCast(&plane),
    };
    const external_info: vk.ExternalMemoryImageCreateInfo = .{
        .p_next = &modifier_info,
        .handle_types = .{ .dma_buf_bit_ext = true },
    };
    const image = self.device_wrapper.createImage(self.device, &.{
        .p_next = &external_info,
        .image_type = .@"2d",
        .format = .b8g8r8a8_unorm,
        .extent = extent(size),
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImage(self.device, image, null);
    const requirements = self.device_wrapper.getImageMemoryRequirements(self.device, image);
    var fd_properties: vk.MemoryFdPropertiesKHR = .{ .memory_type_bits = 0 };
    self.device_wrapper.getMemoryFdPropertiesKHR(
        self.device,
        .{ .dma_buf_bit_ext = true },
        duplicate_fd,
        &fd_properties,
    ) catch return error.VulkanFailure;
    const memory_type = self.deviceMemoryType(
        requirements.memory_type_bits & fd_properties.memory_type_bits,
    ) orelse return error.VulkanFailure;
    const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .image = image };
    const import_info: vk.ImportMemoryFdInfoKHR = .{
        .p_next = &dedicated,
        .handle_type = .{ .dma_buf_bit_ext = true },
        .fd = duplicate_fd,
    };
    const memory = self.device_wrapper.allocateMemory(self.device, &.{
        .p_next = &import_info,
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    }, null) catch return error.VulkanFailure;
    fd_owned = false;
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindImageMemory(self.device, image, memory, 0) catch
        return error.VulkanFailure;
    const view = self.device_wrapper.createImageView(self.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = .b8g8r8a8_unorm,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = if (source.force_opaque) .one else .identity,
        },
        .subresource_range = colorSubresourceRange(),
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyImageView(self.device, view, null);
    var descriptor_set: vk.DescriptorSet = undefined;
    self.device_wrapper.allocateDescriptorSets(self.device, &.{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
    }, @ptrCast(&descriptor_set)) catch return error.VulkanFailure;
    errdefer self.device_wrapper.freeDescriptorSets(
        self.device,
        self.descriptor_pool,
        &.{descriptor_set},
    ) catch {};
    const image_info: vk.DescriptorImageInfo = .{
        .sampler = self.sampler,
        .image_view = view,
        .image_layout = .shader_read_only_optimal,
    };
    self.device_wrapper.updateDescriptorSets(self.device, &.{.{
        .dst_set = descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }}, null);
    const texture: Texture = .{
        .image = image,
        .memory = memory,
        .view = view,
        .descriptor_set = descriptor_set,
        .size = size,
        .initialized = true,
        .imported = true,
        .last_used = self.frame_number,
    };
    self.advanceResourceEpoch();
    return texture;
}

fn destroyTexture(self: *Self, texture: Texture) void {
    self.advanceResourceEpoch();
    self.device_wrapper.freeDescriptorSets(
        self.device,
        self.descriptor_pool,
        &.{texture.descriptor_set},
    ) catch {};
    self.destroyImageAllocation(.{
        .image = texture.image,
        .memory = texture.memory,
        .view = texture.view,
    });
}

fn makeTextureRoom(self: *Self) !void {
    if (self.textures.count() < max_cached_textures) return;
    var oldest_id: ?u64 = null;
    var oldest_frame: u64 = std.math.maxInt(u64);
    var iterator = self.textures.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.last_used < oldest_frame and
            entry.value_ptr.last_used != self.frame_number)
        {
            oldest_id = entry.key_ptr.*;
            oldest_frame = entry.value_ptr.last_used;
        }
    }
    const id = oldest_id orelse return error.CacheFull;
    const removed = self.textures.fetchRemove(id).?;
    self.destroyTexture(removed.value);
}

fn reclaimStaleResources(self: *Self) void {
    const oldest = self.frame_number -| stale_frame_count;
    while (true) {
        var stale: ?u64 = null;
        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_used < oldest) {
                stale = entry.key_ptr.*;
                break;
            }
        }
        const id = stale orelse break;
        self.destroyTexture(self.textures.fetchRemove(id).?.value);
    }
    while (true) {
        var stale: ?TargetKey = null;
        var iterator = self.outputs.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.kind == .pixels and entry.value_ptr.last_used < oldest) {
                stale = entry.key_ptr.*;
                break;
            }
        }
        const key = stale orelse break;
        self.destroyOutput(self.outputs.fetchRemove(key).?.value);
    }
}

fn destroyCachedResources(self: *Self) void {
    var output_iterator = self.outputs.valueIterator();
    while (output_iterator.next()) |output| self.destroyOutput(output.*);
    self.outputs.deinit(self.allocator);
    var texture_iterator = self.textures.valueIterator();
    while (texture_iterator.next()) |texture| self.destroyTexture(texture.*);
    self.textures.deinit(self.allocator);
}

fn invalidatePreparedTextures(self: *Self, prepared_images: []const PreparedImage) void {
    for (prepared_images) |prepared| {
        const cache_id = prepared.cache_id orelse continue;
        if (self.textures.fetchRemove(cache_id)) |removed| {
            self.destroyTexture(removed.value);
        }
    }
    while (true) {
        var uninitialized_id: ?u64 = null;
        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.initialized) {
                uninitialized_id = entry.key_ptr.*;
                break;
            }
        }
        const cache_id = uninitialized_id orelse break;
        self.destroyTexture(self.textures.fetchRemove(cache_id).?.value);
    }
}

fn deviceMemoryType(self: *Self, memory_type_bits: u32) ?u32 {
    const properties = self.instance_wrapper.getPhysicalDeviceMemoryProperties(self.physical_device);
    var compatible: ?u32 = null;
    for (0..properties.memory_type_count) |index| {
        const index_u5: u5 = @intCast(index);
        if (memory_type_bits & (@as(u32, 1) << index_u5) == 0) continue;
        compatible = @intCast(index);
        if (properties.memory_types[index].property_flags.device_local_bit) return @intCast(index);
    }
    return compatible;
}

fn ensureWorkBuffer(self: *Self, required_size: usize) Error!void {
    if (self.work_capacity >= required_size) return;
    std.debug.assert(!self.fence_pending);
    self.destroyWorkBuffer();

    const buffer = self.device_wrapper.createBuffer(self.device, &.{
        .size = required_size,
        .usage = .{ .transfer_src_bit = true, .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyBuffer(self.device, buffer, null);

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
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindBufferMemory(self.device, buffer, memory, 0) catch
        return error.VulkanFailure;
    const mapped_opaque = self.device_wrapper.mapMemory(
        self.device,
        memory,
        0,
        required_size,
        .{},
    ) catch return error.VulkanFailure;
    const mapped: [*]u8 = @ptrCast(mapped_opaque orelse return error.VulkanFailure);
    errdefer self.device_wrapper.unmapMemory(self.device, memory);

    self.work_buffer = buffer;
    self.work_memory = memory;
    self.work_mapped = mapped;
    self.work_capacity = required_size;
    self.advanceResourceEpoch();
}

fn destroyWorkBuffer(self: *Self) void {
    std.debug.assert(!self.fence_pending);
    if (self.work_mapped != null) self.device_wrapper.unmapMemory(self.device, self.work_memory);
    if (self.work_buffer != .null_handle) {
        self.device_wrapper.destroyBuffer(self.device, self.work_buffer, null);
    }
    if (self.work_memory != .null_handle) {
        self.device_wrapper.freeMemory(self.device, self.work_memory, null);
    }
    self.work_buffer = .null_handle;
    self.work_memory = .null_handle;
    self.work_mapped = null;
    self.work_capacity = 0;
}

fn ensureInstanceBuffer(self: *Self, required_size: usize) Error!void {
    if (self.instance_capacity >= required_size) return;
    std.debug.assert(!self.fence_pending);
    self.destroyInstanceBuffer();

    const buffer = self.device_wrapper.createBuffer(self.device, &.{
        .size = required_size,
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch return error.VulkanFailure;
    errdefer self.device_wrapper.destroyBuffer(self.device, buffer, null);

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
    errdefer self.device_wrapper.freeMemory(self.device, memory, null);
    self.device_wrapper.bindBufferMemory(self.device, buffer, memory, 0) catch
        return error.VulkanFailure;
    const mapped_opaque = self.device_wrapper.mapMemory(
        self.device,
        memory,
        0,
        required_size,
        .{},
    ) catch return error.VulkanFailure;
    const mapped: [*]u8 = @ptrCast(mapped_opaque orelse return error.VulkanFailure);
    errdefer self.device_wrapper.unmapMemory(self.device, memory);

    self.instance_buffer = buffer;
    self.instance_memory = memory;
    self.instance_mapped = mapped;
    self.instance_capacity = required_size;
    self.advanceResourceEpoch();
}

fn destroyInstanceBuffer(self: *Self) void {
    std.debug.assert(!self.fence_pending);
    if (self.instance_mapped != null) {
        self.device_wrapper.unmapMemory(self.device, self.instance_memory);
    }
    if (self.instance_buffer != .null_handle) {
        self.device_wrapper.destroyBuffer(self.device, self.instance_buffer, null);
    }
    if (self.instance_memory != .null_handle) {
        self.device_wrapper.freeMemory(self.device, self.instance_memory, null);
    }
    self.instance_buffer = .null_handle;
    self.instance_memory = .null_handle;
    self.instance_mapped = null;
    self.instance_capacity = 0;
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

fn advanceResourceEpoch(self: *Self) void {
    self.resource_epoch +%= 1;
    if (self.resource_epoch == 0) self.resource_epoch = 1;
}

fn compileDrawRuns(
    self: *Self,
    frame: render.Frame,
    prepared_images: []const PreparedImage,
) Error!void {
    var prepared_index: usize = 0;
    for (frame.commands) |command| switch (command) {
        .clear => |color| {
            const rect: render.Rect = .{
                .x = 0,
                .y = 0,
                .width = frame.size.width,
                .height = frame.size.height,
            };
            try self.emitDamaged(frame, rect, .replace, null, .{ .width = 1, .height = 1 }, .{
                .destination = rectFloats(rect),
                .source = .{ 0, 0, 1, 1 },
                .clip = undefined,
                .color = colorFloats(color),
                .rounded = .{ 0, 0, 0, 0 },
                .parameters = .{ 0, 0, 0, 0 },
            });
        },
        .solid_rect => |solid| {
            var clipped = solid.rect.clipTo(frame.size) orelse continue;
            if (solid.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            try self.emitDamaged(frame, clipped, .blend, null, .{ .width = 1, .height = 1 }, .{
                .destination = rectFloats(clipped),
                .source = .{ 0, 0, 1, 1 },
                .clip = undefined,
                .color = colorFloats(solid.color),
                .rounded = .{ 0, 0, 0, 0 },
                .parameters = .{ 0, 0, 0, 0 },
            });
        },
        .image => |image| {
            const prepared = prepared_images[prepared_index];
            prepared_index += 1;
            const destination: render.Rect = .{
                .x = image.x,
                .y = image.y,
                .width = image.size.width,
                .height = image.size.height,
            };
            var clipped = destination.clipTo(frame.size) orelse continue;
            if (image.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            if (image.rounded_clip) |rounded_clip| {
                clipped = clipped.intersection(rounded_clip.rect) orelse continue;
            }
            const transformed_size = image.transform.applyToSize(image.buffer.size);
            const source = image.source orelse render.SourceRect{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(transformed_size.width),
                .height = @floatFromInt(transformed_size.height),
            };
            const rounded = image.rounded_clip orelse render.RoundedClip{
                .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .radius = 0,
            };
            const radius = @min(rounded.radius, @min(rounded.rect.width, rounded.rect.height) / 2);
            const dmabuf = image.buffer.dmabuf;
            try self.emitDamaged(
                frame,
                clipped,
                .image,
                prepared.texture.descriptor_set,
                image.buffer.size,
                .{
                    .destination = rectFloats(destination),
                    .source = .{
                        @floatCast(source.x),
                        @floatCast(source.y),
                        @floatCast(source.width),
                        @floatCast(source.height),
                    },
                    .clip = undefined,
                    .color = .{ 1, 1, 1, 1 },
                    .rounded = rectFloats(rounded.rect),
                    .parameters = .{
                        @floatFromInt(radius),
                        @floatFromInt(@intFromEnum(image.transform)),
                        @floatFromInt(@intFromBool(dmabuf != null and dmabuf.?.y_inverted)),
                        0,
                    },
                },
            );
        },
        .shadow => |shadow| {
            if (shadow.color.alpha == 0 or shadow.rect.width == 0 or shadow.rect.height == 0) {
                continue;
            }
            const spread: i64 = shadow.spread;
            const shape_x = @as(i64, shadow.rect.x) - spread;
            const shape_y = @as(i64, shadow.rect.y) - spread;
            const shape_width = @as(i64, shadow.rect.width) + 2 * spread;
            const shape_height = @as(i64, shadow.rect.height) + 2 * spread;
            if (shape_width <= 0 or shape_height <= 0) continue;

            const blur: i64 = shadow.blur_radius;
            const left = @max(shape_x - blur, 0);
            const top = @max(shape_y - blur, 0);
            const right = @min(shape_x + shape_width + blur, frame.size.width);
            const bottom = @min(shape_y + shape_height + blur, frame.size.height);
            if (left >= right or top >= bottom) continue;
            var clipped: render.Rect = .{
                .x = @intCast(left),
                .y = @intCast(top),
                .width = @intCast(right - left),
                .height = @intCast(bottom - top),
            };
            if (shadow.clip) |clip| clipped = clipped.intersection(clip) orelse continue;

            const requested_radius = @max(@as(i64, shadow.corner_radius) + spread, 0);
            const radius = @min(requested_radius, @divTrunc(@min(shape_width, shape_height), 2));
            try self.emitDamaged(frame, clipped, .shadow, null, .{ .width = 1, .height = 1 }, .{
                .destination = rectFloats(clipped),
                .source = .{ 0, 0, 1, 1 },
                .clip = undefined,
                .color = colorFloats(shadow.color),
                .rounded = .{
                    @floatFromInt(shape_x),
                    @floatFromInt(shape_y),
                    @floatFromInt(shape_width),
                    @floatFromInt(shape_height),
                },
                .parameters = .{
                    @floatFromInt(radius),
                    @floatFromInt(shadow.blur_radius),
                    0,
                    0,
                },
            });
        },
        .backdrop_blur => |blur| {
            if (blur.radius == 0 or blur.rect.width == 0 or blur.rect.height == 0) continue;
            var clipped = blur.rect.clipTo(frame.size) orelse continue;
            if (blur.clip) |clip| clipped = clipped.intersection(clip) orelse continue;
            clipped = damageBounds(frame.damage, clipped) orelse continue;
            const level = blurLevel(blur.radius);
            const scale: u32 = @as(u32, 1) << @intCast(level);
            const low_radius: u8 = @intCast(ceilDiv(blur.radius, scale));
            const sample_radius = (@as(u32, low_radius) + 2) * scale;
            const sample_rect = blurSampleRect(clipped, sample_radius, level, frame.size);
            var level_rects: [blur_level_count]render.Rect = undefined;
            for (&level_rects, 0..) |*rect, index| rect.* = scaleRect(sample_rect, @intCast(index));
            const low_clipped = scaleRect(clipped, level);
            var upsample_rects: [blur_level_count]render.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 });
            if (level > 1) {
                upsample_rects[1] = expandRectWithin(scaleRect(clipped, 1), 1, level_rects[1]);
                for (2..@as(usize, level) + 1) |index| {
                    upsample_rects[index] = expandRectWithin(scaleRect(upsample_rects[index - 1], 1), 1, level_rects[index]);
                }
            }
            const vertical_rect = if (level > 1)
                upsample_rects[level]
            else if (level == 1)
                expandRectWithin(low_clipped, 1, level_rects[1])
            else
                low_clipped;
            const horizontal_rect: render.Rect = .{
                .x = vertical_rect.x,
                .y = level_rects[level].y,
                .width = vertical_rect.width,
                .height = level_rects[level].height,
            };
            var downsample_instances: [blur_level_count - 1]u32 = @splat(0);
            for (0..level) |index| {
                const source_rect = level_rects[index];
                const destination_rect = level_rects[index + 1];
                downsample_instances[index] = @intCast(self.instances.items.len);
                try self.instances.append(self.allocator, imageInstance(destination_rect, source_rect));
            }
            const horizontal_instance: u32 = @intCast(self.instances.items.len);
            try self.instances.append(self.allocator, blurInstance(horizontal_rect, low_radius));
            const vertical_instance: u32 = @intCast(self.instances.items.len);
            try self.instances.append(self.allocator, blurInstance(vertical_rect, low_radius));
            var upsample_instances: [blur_level_count - 1]u32 = @splat(0);
            if (level > 1) for (1..level) |index| {
                upsample_instances[index] = @intCast(self.instances.items.len);
                try self.instances.append(self.allocator, upsampleInstance(upsample_rects[index]));
            };
            const radius = @min(blur.corner_radius, @min(blur.rect.width, blur.rect.height) / 2);
            const composite_instance: u32 = @intCast(self.instances.items.len);
            const composite_level: u8 = @min(level, 1);
            const composite_scale: u32 = @as(u32, 1) << @intCast(composite_level);
            const inverse_scale: f32 = 1.0 / @as(f32, @floatFromInt(composite_scale));
            const blur_rect = rectFloats(blur.rect);
            const composite: Instance = .{
                .destination = blur_rect,
                .source = .{ blur_rect[0] * inverse_scale, blur_rect[1] * inverse_scale, blur_rect[2] * inverse_scale, blur_rect[3] * inverse_scale },
                .clip = undefined,
                .color = .{ 1, 1, 1, 1 },
                .rounded = blur_rect,
                .parameters = .{ @floatFromInt(radius), 0, 0, 0 },
            };
            var composite_count: u32 = 0;
            if (frame.damage) |damage| {
                for (damage) |damaged| {
                    const damaged_clip = damaged.clipTo(frame.size) orelse continue;
                    const composite_clip = clipped.intersection(damaged_clip) orelse continue;
                    var instance = composite;
                    instance.clip = rectFloats(composite_clip);
                    try self.instances.append(self.allocator, instance);
                    composite_count = std.math.add(u32, composite_count, 1) catch
                        return error.InvalidTarget;
                }
            } else {
                var instance = composite;
                instance.clip = rectFloats(clipped);
                try self.instances.append(self.allocator, instance);
                composite_count = 1;
            }
            std.debug.assert(composite_count > 0);
            try self.blur_ops.append(self.allocator, .{
                .run_index = @intCast(self.draw_runs.items.len),
                .level = level,
                .low_radius = low_radius,
                .downsample_instances = downsample_instances,
                .upsample_instances = upsample_instances,
                .horizontal_instance = horizontal_instance,
                .vertical_instance = vertical_instance,
                .sample_rect = sample_rect,
                .level_rects = level_rects,
                .upsample_rects = upsample_rects,
                .horizontal_rect = horizontal_rect,
                .vertical_rect = vertical_rect,
            });
            try self.draw_runs.append(self.allocator, .{ .pipeline = .blur_composite, .descriptor_set = null, .texture_size = blurLevelSize(frame.size, composite_level), .first_instance = composite_instance, .instance_count = composite_count });
        },
    };
    std.debug.assert(prepared_index == prepared_images.len);
}

fn emitDamaged(
    self: *Self,
    frame: render.Frame,
    visible_rect: render.Rect,
    pipeline_kind: PipelineKind,
    descriptor_set: ?vk.DescriptorSet,
    texture_size: render.Size,
    instance: Instance,
) Error!void {
    if (frame.damage) |damage| {
        for (damage) |damaged| {
            const clipped_damage = damaged.clipTo(frame.size) orelse continue;
            const clipped = visible_rect.intersection(clipped_damage) orelse continue;
            try self.emitInstance(pipeline_kind, descriptor_set, texture_size, instance, clipped);
        }
    } else {
        try self.emitInstance(pipeline_kind, descriptor_set, texture_size, instance, visible_rect);
    }
}

fn damageBounds(damage: ?[]const render.Rect, visible: render.Rect) ?render.Rect {
    const rectangles = damage orelse return visible;
    var bounds: ?render.Rect = null;
    for (rectangles) |rectangle| {
        const clipped = visible.intersection(rectangle) orelse continue;
        bounds = if (bounds) |current| unionRect(current, clipped) else clipped;
    }
    return bounds;
}

fn unionRect(a: render.Rect, b: render.Rect) render.Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width);
    const bottom = @max(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height);
    return .{ .x = left, .y = top, .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

test "Vulkan blur bounds only cover damaged visible pixels" {
    const visible: render.Rect = .{ .x = 10, .y = 10, .width = 100, .height = 80 };
    try std.testing.expectEqual(visible, damageBounds(null, visible).?);
    try std.testing.expectEqual(
        render.Rect{ .x = 12, .y = 15, .width = 88, .height = 55 },
        damageBounds(&.{
            .{ .x = 12, .y = 15, .width = 8, .height = 5 },
            .{ .x = 90, .y = 60, .width = 10, .height = 10 },
        }, visible).?,
    );
    try std.testing.expectEqual(null, damageBounds(&.{.{ .x = 0, .y = 0, .width = 5, .height = 5 }}, visible));
}

fn emitInstance(
    self: *Self,
    pipeline_kind: PipelineKind,
    descriptor_set: ?vk.DescriptorSet,
    texture_size: render.Size,
    template: Instance,
    clip: render.Rect,
) Error!void {
    if (self.instances.items.len >= std.math.maxInt(u32)) return error.InvalidTarget;
    const instance_index: u32 = @intCast(self.instances.items.len);
    var instance = template;
    instance.clip = rectFloats(clip);
    try self.instances.append(self.allocator, instance);

    if (self.draw_runs.items.len > 0) {
        const last = &self.draw_runs.items[self.draw_runs.items.len - 1];
        if (last.pipeline == pipeline_kind and last.descriptor_set == descriptor_set and
            std.meta.eql(last.texture_size, texture_size))
        {
            last.instance_count = std.math.add(u32, last.instance_count, 1) catch
                return error.InvalidTarget;
            return;
        }
    }
    try self.draw_runs.append(self.allocator, .{
        .pipeline = pipeline_kind,
        .descriptor_set = descriptor_set,
        .texture_size = texture_size,
        .first_instance = instance_index,
        .instance_count = 1,
    });
}

fn pipelineForKind(self: *const Self, kind: PipelineKind) vk.Pipeline {
    return switch (kind) {
        .replace => self.replace_pipeline,
        .blend => self.blend_pipeline,
        .image => self.image_pipeline,
        .shadow => self.shadow_pipeline,
        .downsample => self.downsample_pipeline,
        .blur_horizontal => self.blur_horizontal_pipeline,
        .blur_vertical => self.blur_vertical_pipeline,
        .blur_composite => self.blur_composite_pipeline,
    };
}

fn blurLevel(radius: u32) u8 {
    var level: u8 = 0;
    while (level < blur_level_count - 1 and ceilDiv(radius, @as(u32, 1) << @intCast(level)) > 2) level += 1;
    return level;
}

pub fn backdropBlurFootprint(radius: u32) u32 {
    if (radius == 0) return 0;
    const level = blurLevel(radius);
    const scale: u32 = @as(u32, 1) << @intCast(level);
    return (ceilDiv(radius, scale) + 3) * scale;
}

fn ceilDiv(value: u32, divisor: u32) u32 {
    return value / divisor + @intFromBool(value % divisor != 0);
}

fn blurLevelSize(size: render.Size, level: u8) render.Size {
    const scale: u32 = @as(u32, 1) << @intCast(level);
    return .{ .width = ceilDiv(size.width, scale), .height = ceilDiv(size.height, scale) };
}

fn scaleRect(rect: render.Rect, level: u8) render.Rect {
    const scale: i64 = @as(i64, 1) << @intCast(level);
    const left = @divFloor(@as(i64, rect.x), scale);
    const top = @divFloor(@as(i64, rect.y), scale);
    const right = @divFloor(@as(i64, rect.x) + rect.width + scale - 1, scale);
    const bottom = @divFloor(@as(i64, rect.y) + rect.height + scale - 1, scale);
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

fn blurSampleRect(rect: render.Rect, radius: u32, level: u8, frame_size: render.Size) render.Rect {
    const alignment: i64 = @as(i64, 1) << @intCast(level);
    const left = @max(@divFloor(@as(i64, rect.x) - radius, alignment) * alignment, 0);
    const top = @max(@divFloor(@as(i64, rect.y) - radius, alignment) * alignment, 0);
    const raw_right = @as(i64, rect.x) + rect.width + radius;
    const raw_bottom = @as(i64, rect.y) + rect.height + radius;
    const right = @min(@divFloor(raw_right + alignment - 1, alignment) * alignment, frame_size.width);
    const bottom = @min(@divFloor(raw_bottom + alignment - 1, alignment) * alignment, frame_size.height);
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

fn imageInstance(destination: render.Rect, source: render.Rect) Instance {
    return .{ .destination = rectFloats(destination), .source = rectFloats(source), .clip = rectFloats(destination), .color = .{ 1, 1, 1, 1 }, .rounded = .{ 0, 0, 0, 0 }, .parameters = .{ 0, 0, 0, 0 } };
}

fn upsampleInstance(destination: render.Rect) Instance {
    const destination_floats = rectFloats(destination);
    return .{
        .destination = destination_floats,
        .source = .{ destination_floats[0] / 2, destination_floats[1] / 2, destination_floats[2] / 2, destination_floats[3] / 2 },
        .clip = destination_floats,
        .color = .{ 1, 1, 1, 1 },
        .rounded = .{ 0, 0, 0, 0 },
        .parameters = .{ 0, 0, 0, 0 },
    };
}

fn expandRectWithin(rect: render.Rect, amount: u32, bounds: render.Rect) render.Rect {
    const left = @max(@as(i64, rect.x) - amount, bounds.x);
    const top = @max(@as(i64, rect.y) - amount, bounds.y);
    const right = @min(@as(i64, rect.x) + rect.width + amount, @as(i64, bounds.x) + bounds.width);
    const bottom = @min(@as(i64, rect.y) + rect.height + amount, @as(i64, bounds.y) + bounds.height);
    std.debug.assert(left < right and top < bottom);
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

fn blurInstance(rect: render.Rect, radius: u8) Instance {
    return .{ .destination = rectFloats(rect), .source = rectFloats(rect), .clip = rectFloats(rect), .color = .{ 1, 1, 1, 1 }, .rounded = .{ 0, 0, 0, 0 }, .parameters = .{ @floatFromInt(radius), 0, 0, 0 } };
}

fn blurOpAt(self: *const Self, run_index: usize) ?BlurOp {
    for (self.blur_ops.items) |op| if (op.run_index == run_index) return op;
    return null;
}

fn drawScratchPass(self: *Self, command_buffer: vk.CommandBuffer, framebuffer: vk.Framebuffer, size: render.Size, area: render.Rect, kind: PipelineKind, descriptor: vk.DescriptorSet, texture_size: render.Size, instance: u32) void {
    const pass_info: vk.RenderPassBeginInfo = .{ .render_pass = self.scratch_render_pass, .framebuffer = framebuffer, .render_area = rect2D(area) };
    self.device_wrapper.cmdBeginRenderPass(command_buffer, &pass_info, .@"inline");
    self.setViewportAndScissor(command_buffer, size);
    self.device_wrapper.cmdBindPipeline(command_buffer, .graphics, self.pipelineForKind(kind));
    self.device_wrapper.cmdBindDescriptorSets(command_buffer, .graphics, self.pipeline_layout, 0, &.{descriptor}, null);
    const push: FramePush = .{ .target_size = sizeFloats(size), .texture_size = sizeFloats(texture_size), .swap_red_blue = 0 };
    self.device_wrapper.cmdPushConstants(command_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(FramePush), &push);
    self.device_wrapper.cmdDraw(command_buffer, 4, 1, 0, instance);
    self.device_wrapper.cmdEndRenderPass(command_buffer);
}

fn setViewportAndScissor(self: *Self, command_buffer: vk.CommandBuffer, size: render.Size) void {
    self.device_wrapper.cmdSetViewport(command_buffer, 0, &.{.{ .x = 0, .y = 0, .width = @floatFromInt(size.width), .height = @floatFromInt(size.height), .min_depth = 0, .max_depth = 1 }});
    self.device_wrapper.cmdSetScissor(command_buffer, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = size.width, .height = size.height } }});
}

fn transitionScratchForWrite(self: *Self, command_buffer: vk.CommandBuffer, image: vk.Image, initialized: bool, new_layout: vk.ImageLayout, destination_access: vk.AccessFlags, destination_stage: vk.PipelineStageFlags) void {
    self.transitionImage(command_buffer, image, if (initialized) .shader_read_only_optimal else .undefined, new_layout, if (initialized) .{ .shader_read_bit = true } else .{}, destination_access, if (initialized) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true }, destination_stage);
}

fn transitionScratchToRead(self: *Self, command_buffer: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, source_access: vk.AccessFlags, source_stage: vk.PipelineStageFlags) void {
    self.transitionImage(command_buffer, image, old_layout, .shader_read_only_optimal, source_access, .{ .shader_read_bit = true }, source_stage, .{ .fragment_shader_bit = true });
}

fn colorFloats(color: render.Color) [4]f32 {
    const inverse: f32 = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt(color.red)) * inverse,
        @as(f32, @floatFromInt(color.green)) * inverse,
        @as(f32, @floatFromInt(color.blue)) * inverse,
        @as(f32, @floatFromInt(color.alpha)) * inverse,
    };
}

fn copyOutputDamage(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    frame: render.Frame,
    target: render.PixelBuffer,
    image: vk.Image,
) void {
    if (frame.damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(frame.size) orelse continue;
            self.copyOutputRect(command_buffer, target, image, clipped);
        }
    } else {
        self.copyOutputRect(command_buffer, target, image, .{
            .x = 0,
            .y = 0,
            .width = frame.size.width,
            .height = frame.size.height,
        });
    }
}

fn copyOutputRect(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    target: render.PixelBuffer,
    image: vk.Image,
    rect: render.Rect,
) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const pixel_offset = @as(u64, @intCast(rect.y)) * target.stride_pixels +
        @as(u32, @intCast(rect.x));
    const copy: vk.BufferImageCopy = .{
        .buffer_offset = pixel_offset * @sizeOf(u32),
        .buffer_row_length = target.stride_pixels,
        .buffer_image_height = target.size.height,
        .image_subresource = colorSubresourceLayers(),
        .image_offset = .{ .x = rect.x, .y = rect.y, .z = 0 },
        .image_extent = extent(.{ .width = rect.width, .height = rect.height }),
    };
    self.device_wrapper.cmdCopyImageToBuffer(
        command_buffer,
        image,
        .transfer_src_optimal,
        self.work_buffer,
        &.{copy},
    );
}

fn copyTextureRect(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    buffer: render.PixelBuffer,
    base_offset: usize,
    rect: render.Rect,
) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const pixel_offset = @as(u64, @intCast(rect.y)) * buffer.stride_pixels +
        @as(u32, @intCast(rect.x));
    const upload: vk.BufferImageCopy = .{
        .buffer_offset = base_offset + pixel_offset * @sizeOf(u32),
        .buffer_row_length = buffer.stride_pixels,
        .buffer_image_height = buffer.size.height,
        .image_subresource = colorSubresourceLayers(),
        .image_offset = .{ .x = rect.x, .y = rect.y, .z = 0 },
        .image_extent = extent(.{ .width = rect.width, .height = rect.height }),
    };
    self.device_wrapper.cmdCopyBufferToImage(
        command_buffer,
        self.work_buffer,
        image,
        .transfer_dst_optimal,
        &.{upload},
    );
}

fn copySourceToMapped(
    mapped: [*]u8,
    base_offset: usize,
    buffer: render.PixelBuffer,
    damage: ?[]const render.Rect,
) Error!void {
    const dmabuf = buffer.dmabuf orelse {
        copyPixelsToMapped(mapped, base_offset, buffer, damage);
        return;
    };
    const mapping = std.posix.mmap(
        null,
        dmabuf.required_bytes,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        dmabuf.fd,
        0,
    ) catch return error.VulkanFailure;
    defer std.posix.munmap(mapping);
    if (!(dmabuf.begin_cpu_read)(dmabuf.context)) return error.VulkanFailure;
    defer _ = (dmabuf.end_cpu_read)(dmabuf.context);

    if (damage) |rectangles| {
        for (rectangles) |rect| copyDmabufRectToMapped(
            mapped,
            base_offset,
            buffer,
            dmabuf,
            mapping,
            rect,
        );
        return;
    }
    copyDmabufRectToMapped(mapped, base_offset, buffer, dmabuf, mapping, .{
        .x = 0,
        .y = 0,
        .width = buffer.size.width,
        .height = buffer.size.height,
    });
}

fn copyDmabufRectToMapped(
    mapped: [*]u8,
    base_offset: usize,
    buffer: render.PixelBuffer,
    dmabuf: render.DmabufSource,
    mapping: []align(std.heap.page_size_min) const u8,
    rect: render.Rect,
) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const x_bytes = @as(usize, @intCast(rect.x)) * @sizeOf(u32);
    const copy_bytes = @as(usize, rect.width) * @sizeOf(u32);
    const stride_bytes = @as(usize, buffer.stride_pixels) * @sizeOf(u32);
    for (0..rect.height) |row| {
        const row_offset = (@as(usize, @intCast(rect.y)) + row) * stride_bytes + x_bytes;
        @memcpy(
            mapped[base_offset + row_offset ..][0..copy_bytes],
            mapping[@as(usize, dmabuf.offset) + row_offset ..][0..copy_bytes],
        );
        if (dmabuf.force_opaque) {
            const row_pixels: [*]u32 = @ptrCast(@alignCast(
                mapped + base_offset + row_offset,
            ));
            for (row_pixels[0..rect.width]) |*pixel| pixel.* |= 0xff00_0000;
        }
    }
}

fn copyPixelsToMapped(
    mapped: [*]u8,
    base_offset: usize,
    buffer: render.PixelBuffer,
    damage: ?[]const render.Rect,
) void {
    const pixels = std.mem.sliceAsBytes(buffer.pixels);
    const row_bytes = @as(usize, buffer.size.width) * @sizeOf(u32);
    const stride_bytes = @as(usize, buffer.stride_pixels) * @sizeOf(u32);
    if (damage) |rectangles| {
        for (rectangles) |rect| {
            const x_bytes = @as(usize, @intCast(rect.x)) * @sizeOf(u32);
            const damaged_row_bytes = @as(usize, rect.width) * @sizeOf(u32);
            for (0..rect.height) |row| {
                const offset = (@as(usize, @intCast(rect.y)) + row) * stride_bytes + x_bytes;
                @memcpy(
                    mapped[base_offset + offset ..][0..damaged_row_bytes],
                    pixels[offset..][0..damaged_row_bytes],
                );
            }
        }
        return;
    }
    for (0..buffer.size.height) |row| {
        const offset = row * stride_bytes;
        @memcpy(mapped[base_offset + offset ..][0..row_bytes], pixels[offset..][0..row_bytes]);
    }
}

fn copyDamageToTarget(frame: render.Frame, target: render.PixelBuffer, mapped: [*]const u8) void {
    if (frame.damage) |damage| {
        for (damage) |rect| {
            const clipped = rect.clipTo(frame.size) orelse continue;
            copyMappedRect(target, mapped, clipped);
        }
    } else {
        copyMappedRect(target, mapped, .{
            .x = 0,
            .y = 0,
            .width = frame.size.width,
            .height = frame.size.height,
        });
    }
}

fn copyMappedRect(target: render.PixelBuffer, mapped: [*]const u8, rect: render.Rect) void {
    std.debug.assert(rect.x >= 0 and rect.y >= 0);
    const pixels = std.mem.sliceAsBytes(target.pixels);
    const row_bytes = @as(usize, rect.width) * @sizeOf(u32);
    const stride_bytes = @as(usize, target.stride_pixels) * @sizeOf(u32);
    const x_bytes = @as(usize, @intCast(rect.x)) * @sizeOf(u32);
    for (0..rect.height) |row| {
        const offset = (@as(usize, @intCast(rect.y)) + row) * stride_bytes + x_bytes;
        @memcpy(pixels[offset..][0..row_bytes], mapped[offset..][0..row_bytes]);
    }
}

fn transitionImage(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    source_access: vk.AccessFlags,
    destination_access: vk.AccessFlags,
    source_stage: vk.PipelineStageFlags,
    destination_stage: vk.PipelineStageFlags,
) void {
    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = source_access,
        .dst_access_mask = destination_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = colorSubresourceRange(),
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        .{},
        null,
        null,
        &.{barrier},
    );
}

fn transitionExternalToRender(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    output: Output,
) void {
    self.transitionExternal(
        command_buffer,
        output,
        if (output.initialized) .general else .undefined,
        .color_attachment_optimal,
        if (output.initialized) vk.QUEUE_FAMILY_FOREIGN_EXT else vk.QUEUE_FAMILY_IGNORED,
        self.queue_family_index,
        .{},
        .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
        if (output.initialized) .{ .all_commands_bit = true } else .{ .top_of_pipe_bit = true },
        .{ .color_attachment_output_bit = true },
    );
}

fn transitionRenderToExternal(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
) void {
    const output: Output = .{
        .image = image,
        .memory = .null_handle,
        .view = .null_handle,
        .descriptor_set = .null_handle,
        .framebuffer = .null_handle,
        .size = .{ .width = 0, .height = 0 },
        .last_used = 0,
    };
    self.transitionExternal(
        command_buffer,
        output,
        .color_attachment_optimal,
        .general,
        self.queue_family_index,
        vk.QUEUE_FAMILY_FOREIGN_EXT,
        .{ .color_attachment_write_bit = true },
        .{},
        .{ .color_attachment_output_bit = true },
        .{ .bottom_of_pipe_bit = true },
    );
}

fn transitionExternalSourceToSample(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
) void {
    const output: Output = .{
        .image = image,
        .memory = .null_handle,
        .view = .null_handle,
        .descriptor_set = .null_handle,
        .framebuffer = .null_handle,
        .size = .{ .width = 0, .height = 0 },
        .last_used = 0,
    };
    self.transitionExternal(
        command_buffer,
        output,
        .general,
        .shader_read_only_optimal,
        vk.QUEUE_FAMILY_FOREIGN_EXT,
        self.queue_family_index,
        .{},
        .{ .shader_read_bit = true },
        .{ .all_commands_bit = true },
        .{ .fragment_shader_bit = true },
    );
}

fn transitionSampleToExternal(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
) void {
    const output: Output = .{
        .image = image,
        .memory = .null_handle,
        .view = .null_handle,
        .descriptor_set = .null_handle,
        .framebuffer = .null_handle,
        .size = .{ .width = 0, .height = 0 },
        .last_used = 0,
    };
    self.transitionExternal(
        command_buffer,
        output,
        .shader_read_only_optimal,
        .general,
        self.queue_family_index,
        vk.QUEUE_FAMILY_FOREIGN_EXT,
        .{ .shader_read_bit = true },
        .{},
        .{ .fragment_shader_bit = true },
        .{ .bottom_of_pipe_bit = true },
    );
}

fn transitionExternal(
    self: *Self,
    command_buffer: vk.CommandBuffer,
    output: Output,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    source_queue: u32,
    destination_queue: u32,
    source_access: vk.AccessFlags,
    destination_access: vk.AccessFlags,
    source_stage: vk.PipelineStageFlags,
    destination_stage: vk.PipelineStageFlags,
) void {
    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = source_access,
        .dst_access_mask = destination_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = source_queue,
        .dst_queue_family_index = destination_queue,
        .image = output.image,
        .subresource_range = colorSubresourceRange(),
    };
    self.device_wrapper.cmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        .{},
        null,
        null,
        &.{barrier},
    );
}

fn rectFloats(rect: render.Rect) [4]f32 {
    return .{
        @floatFromInt(rect.x),
        @floatFromInt(rect.y),
        @floatFromInt(rect.width),
        @floatFromInt(rect.height),
    };
}

fn sizeFloats(size: render.Size) [2]f32 {
    return .{ @floatFromInt(size.width), @floatFromInt(size.height) };
}

fn rect2D(rect: render.Rect) vk.Rect2D {
    return .{
        .offset = .{ .x = rect.x, .y = rect.y },
        .extent = .{ .width = rect.width, .height = rect.height },
    };
}

fn extent(size: render.Size) vk.Extent3D {
    return .{ .width = size.width, .height = size.height, .depth = 1 };
}

fn colorSubresourceLayers() vk.ImageSubresourceLayers {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .base_array_layer = 0,
        .layer_count = 1,
    };
}

fn colorSubresourceRange() vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
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

test "Vulkan graphics path supports images, alpha blending, and backdrop blur" {
    try std.testing.expect(supports(&.{.{ .solid_rect = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = render.Color.rgba(1, 2, 3, 128),
    } }}));
    var pixels = [_]u32{0};
    try std.testing.expect(supports(&.{.{ .image = .{
        .x = 0,
        .y = 0,
        .size = .{ .width = 1, .height = 1 },
        .buffer = .{
            .size = .{ .width = 1, .height = 1 },
            .stride_pixels = 1,
            .pixels = &pixels,
        },
    } }}));
    try std.testing.expect(supports(&.{.{ .shadow = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .corner_radius = 0,
        .blur_radius = 1,
        .spread = 0,
        .color = render.Color.rgba(1, 2, 3, 128),
    } }}));
    try std.testing.expect(supports(&.{.{ .backdrop_blur = .{
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .corner_radius = 0,
        .radius = 1,
    } }}));
}

test "backdrop blur level keeps low resolution radius bounded" {
    const cases = [_]struct { radius: u32, level: u8 }{
        .{ .radius = 1, .level = 0 },
        .{ .radius = 2, .level = 0 },
        .{ .radius = 3, .level = 1 },
        .{ .radius = 4, .level = 1 },
        .{ .radius = 5, .level = 2 },
        .{ .radius = 8, .level = 2 },
        .{ .radius = 9, .level = 3 },
        .{ .radius = 16, .level = 3 },
        .{ .radius = 17, .level = 4 },
        .{ .radius = 32, .level = 4 },
        .{ .radius = 64, .level = 5 },
        .{ .radius = 128, .level = 5 },
        .{ .radius = 256, .level = 5 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.level, blurLevel(case.radius));
        try std.testing.expect(ceilDiv(case.radius, @as(u32, 1) << @intCast(case.level)) <= 2 or case.level == blur_level_count - 1);
    }

    try std.testing.expectEqual(@as(u32, 0), backdropBlurFootprint(0));
    try std.testing.expectEqual(@as(u32, 4), backdropBlurFootprint(1));
    try std.testing.expectEqual(@as(u32, 10), backdropBlurFootprint(3));
    try std.testing.expectEqual(@as(u32, 40), backdropBlurFootprint(16));
    try std.testing.expectEqual(@as(u32, 192), backdropBlurFootprint(65));
}

test "backdrop blur geometry scales odd rectangles and clips aligned edges" {
    try std.testing.expectEqual(render.Size{ .width = 5, .height = 4 }, blurLevelSize(.{ .width = 17, .height = 13 }, 2));
    try std.testing.expectEqual(render.Rect{ .x = 0, .y = 0, .width = 5, .height = 4 }, scaleRect(.{ .x = 1, .y = 3, .width = 16, .height = 10 }, 2));
    try std.testing.expectEqual(render.Rect{ .x = 0, .y = 0, .width = 17, .height = 13 }, blurSampleRect(.{ .x = 1, .y = 3, .width = 15, .height = 9 }, 9, 1, .{ .width = 17, .height = 13 }));
    try std.testing.expectEqual(render.Rect{ .x = 8, .y = 4, .width = 16, .height = 16 }, blurSampleRect(.{ .x = 13, .y = 9, .width = 5, .height = 5 }, 3, 2, .{ .width = 31, .height = 23 }));
    try std.testing.expectEqual(render.Rect{ .x = 4, .y = 0, .width = 27, .height = 23 }, blurSampleRect(.{ .x = 17, .y = 9, .width = 1, .height = 1 }, 12, 2, .{ .width = 31, .height = 23 }));
}

test "recorded Vulkan frames match only identical command topology" {
    var renderer: Self = undefined;
    renderer.allocator = std.testing.allocator;
    renderer.resource_epoch = 7;
    renderer.work_buffer = .null_handle;
    renderer.instance_buffer = .null_handle;
    renderer.draw_runs = .empty;
    defer renderer.draw_runs.deinit(std.testing.allocator);
    renderer.blur_ops = .empty;
    defer renderer.blur_ops.deinit(std.testing.allocator);
    try renderer.draw_runs.append(std.testing.allocator, .{
        .pipeline = .image,
        .descriptor_set = null,
        .texture_size = .{ .width = 2, .height = 1 },
        .first_instance = 0,
        .instance_count = 1,
    });

    var pixels = [_]u32{ 1, 2 };
    var damage = [_]render.Rect{.{ .x = 0, .y = 0, .width = 1, .height = 1 }};
    const prepared = [_]PreparedImage{.{
        .texture = .{
            .image = .null_handle,
            .memory = .null_handle,
            .view = .null_handle,
            .descriptor_set = .null_handle,
            .size = .{ .width = 2, .height = 1 },
            .initialized = true,
            .last_used = 1,
        },
        .buffer = .{
            .size = .{ .width = 2, .height = 1 },
            .stride_pixels = 2,
            .pixels = &pixels,
        },
        .upload_offset = 16,
        .upload_damage = &damage,
        .cache_id = 1,
        .desired_version = 2,
    }};
    var recorded: RecordedFrame = .{};
    defer recorded.deinit(std.testing.allocator);
    const render_area: render.Rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 };

    try renderer.rememberRecordedFrame(&recorded, true, 0, render_area, &prepared);
    try std.testing.expect(renderer.recordedFrameMatches(&recorded, true, 0, render_area, &prepared));
    try std.testing.expect(!renderer.recordedFrameMatches(&recorded, true, 1, render_area, &prepared));
    try std.testing.expect(!renderer.recordedFrameMatches(&recorded, true, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 }, &prepared));

    try renderer.blur_ops.append(std.testing.allocator, .{
        .run_index = 0,
        .horizontal_instance = 0,
        .sample_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .horizontal_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    });
    try std.testing.expect(!renderer.recordedFrameMatches(&recorded, true, 0, render_area, &prepared));
    renderer.blur_ops.clearRetainingCapacity();

    damage[0].x = 1;
    try std.testing.expect(!renderer.recordedFrameMatches(&recorded, true, 0, render_area, &prepared));
    damage[0].x = 0;
    renderer.draw_runs.items[0].instance_count = 2;
    try std.testing.expect(!renderer.recordedFrameMatches(&recorded, true, 0, render_area, &prepared));
    renderer.draw_runs.items[0].instance_count = 1;
    renderer.advanceResourceEpoch();
    try std.testing.expect(!renderer.recordedFrameMatches(&recorded, true, 0, render_area, &prepared));
}

test "Vulkan renderer clears and clips solid rectangles" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{0} ** 12;
    const target: render.PixelBuffer = .{
        .size = .{ .width = 4, .height = 3 },
        .stride_pixels = 4,
        .pixels = &pixels,
    };
    const commands = [_]render.Command{
        .{ .clear = render.Color.rgba(1, 2, 3, 255) },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 1, .width = 3, .height = 2 },
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 3 },
            .color = render.Color.rgba(20, 30, 40, 255),
        } },
    };

    try renderer.renderFrame(
        .{ .size = target.size, .commands = &commands },
        .{ .pixels = target },
    );

    try std.testing.expectEqual(@as(u32, 0xff010203), pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xff141e28), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0xff010203), pixels[7]);
    try std.testing.expectEqual(@as(u32, 0xff141e28), pixels[10]);
}

test "Vulkan renderer applies ordered backdrop blurs on GPU" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixels = [_]u32{ 0xff000000, 0xff000000, 0xffffffff, 0xff000000, 0xff000000 };
    const target: render.PixelBuffer = .{ .size = .{ .width = 5, .height = 1 }, .stride_pixels = 5, .pixels = &pixels };
    const commands = [_]render.Command{
        .{ .backdrop_blur = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
        } },
        .{ .backdrop_blur = .{
            .rect = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
            .corner_radius = 0,
            .radius = 1,
            .clip = .{ .x = 2, .y = 0, .width = 1, .height = 1 },
        } },
    };
    try renderer.renderFrame(.{ .size = target.size, .commands = &commands }, .{ .pixels = target });

    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[1]);
    const blurred = pixels[2] & 0xff;
    try std.testing.expect(blurred >= 27 and blurred <= 29);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[3]);
}

test "Vulkan partial backdrop blur matches a full redraw" {
    var partial_renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer partial_renderer.deinit();
    var full_renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer full_renderer.deinit();

    const size: render.Size = .{ .width = 32, .height = 16 };
    var partial_pixels = [_]u32{0} ** (size.width * size.height);
    var full_pixels = [_]u32{0} ** (size.width * size.height);
    const initial = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{ .rect = .{ .x = 8, .y = 7, .width = 1, .height = 1 }, .color = render.Color.rgba(255, 255, 255, 255) } },
        .{ .backdrop_blur = .{ .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height }, .corner_radius = 0, .radius = 8 } },
    };
    try partial_renderer.renderFrame(.{ .size = size, .commands = &initial }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &partial_pixels } });
    try full_renderer.renderFrame(.{ .size = size, .commands = &initial }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &full_pixels } });

    const updated = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .solid_rect = .{ .rect = .{ .x = 10, .y = 7, .width = 1, .height = 1 }, .color = render.Color.rgba(255, 255, 255, 255) } },
        .{ .backdrop_blur = .{ .rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height }, .corner_radius = 0, .radius = 8 } },
    };
    try partial_renderer.renderFrame(.{
        .size = size,
        .commands = &updated,
        .damage = &.{.{ .x = 0, .y = 0, .width = 28, .height = size.height }},
    }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &partial_pixels } });
    try full_renderer.renderFrame(.{ .size = size, .commands = &updated }, .{ .pixels = .{ .size = size, .stride_pixels = size.width, .pixels = &full_pixels } });

    try std.testing.expectEqualSlices(u32, &full_pixels, &partial_pixels);
}

test "Vulkan transfer commands preserve pixels outside frame damage" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const untouched = 0xfeedbeef;
    var pixels = [_]u32{untouched} ** 4;
    const size: render.Size = .{ .width = 4, .height = 1 };
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(1, 2, 3, 255) }},
        .damage = &.{.{ .x = 1, .y = 0, .width = 2, .height = 1 }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 4,
        .pixels = &pixels,
    } });

    try std.testing.expectEqualSlices(
        u32,
        &.{ untouched, 0xff010203, 0xff010203, untouched },
        &pixels,
    );
}

test "Vulkan renderer composites image commands" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
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
    } }} }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixels,
    } });

    try std.testing.expectEqual(source_pixels[0], target_pixels[0]);
}

test "Vulkan renderer preserves image orientation and source rectangles" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const source_size: render.Size = .{ .width = 2, .height = 2 };
    const source_pixels = [_]u32{
        0xffff0000, 0xff00ff00,
        0xff0000ff, 0xffffffff,
    };
    var target_pixels = [_]u32{0} ** 6;
    const commands = [_]render.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = source_size,
            .buffer = .{
                .size = source_size,
                .stride_pixels = 2,
                .pixels = @constCast(&source_pixels),
            },
        } },
        .{ .image = .{
            .x = 2,
            .y = 0,
            .size = .{ .width = 1, .height = 1 },
            .source = .{ .x = 1, .y = 1, .width = 1, .height = 1 },
            .buffer = .{
                .size = source_size,
                .stride_pixels = 2,
                .pixels = @constCast(&source_pixels),
            },
        } },
    };
    try renderer.renderFrame(.{
        .size = .{ .width = 3, .height = 2 },
        .commands = &commands,
    }, .{ .pixels = .{
        .size = .{ .width = 3, .height = 2 },
        .stride_pixels = 3,
        .pixels = &target_pixels,
    } });

    try std.testing.expectEqualSlices(
        u32,
        &.{ 0xffff0000, 0xff00ff00, 0xffffffff, 0xff0000ff, 0xffffffff, 0 },
        &target_pixels,
    );
}

test "Vulkan renderer keeps offscreen frames GPU-resident" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    const offscreen = try renderer.createOffscreenTarget(size);
    defer renderer.releaseOutput(.{ .offscreen = offscreen.id });
    var command: render.Command = .{ .clear = render.Color.rgba(12, 34, 56, 255) };
    const frame: render.Frame = .{
        .size = size,
        .commands = @as(*const [1]render.Command, @ptrCast(&command)),
    };

    try renderer.renderFrame(frame, .{ .offscreen = offscreen });
    const output = renderer.outputs.getPtr(.{ .offscreen = offscreen.id }).?;
    try std.testing.expectEqual(OutputKind.offscreen, output.kind);
    try std.testing.expect(output.initialized);
    try std.testing.expect(output.recorded_frame.valid);

    command.clear = render.Color.rgba(78, 90, 123, 255);
    try renderer.renderFrame(frame, .{ .offscreen = offscreen });
    try std.testing.expect(output.recorded_frame.valid);
}

test "Vulkan renderer imports and renders directly to a GBM dmabuf" {
    const fd = std.c.open("/dev/dri/renderD128", std.c.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    });
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    var renderer = Self.init(std.testing.allocator, .{ .major = 226, .minor = 128 }) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const access = renderer.dmabufAccess() orelse return error.SkipZigTest;
    const Gbm = @import("../backend/gbm.zig");
    var gbm = Gbm.init(fd) catch return error.SkipZigTest;
    defer gbm.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    var imported_buffer: ?Gbm.Buffer = null;
    const id = render.allocateRenderTargetId();
    for (access.modifiers) |modifier| {
        var buffer = gbm.createBuffer(size, 0x34325258, &.{modifier}) catch continue;
        renderer.importTarget(.{
            .id = id,
            .size = size,
            .fd = buffer.fd,
            .format = 0x34325258,
            .modifier = buffer.modifier,
            .stride = buffer.stride,
            .offset = buffer.offset,
        }) catch {
            buffer.deinit();
            continue;
        };
        imported_buffer = buffer;
        break;
    }
    if (imported_buffer == null) return error.SkipZigTest;
    defer imported_buffer.?.deinit();
    defer renderer.releaseTarget(id);

    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .clear = render.Color.rgba(12, 34, 56, 255) }},
    }, .{ .dmabuf = .{ .id = id, .size = size } });
}

test "Vulkan renderer samples a GBM dmabuf without a CPU upload" {
    const fd = std.c.open("/dev/dri/renderD128", std.c.O{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    });
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    var renderer = Self.init(std.testing.allocator, .{ .major = 226, .minor = 128 }) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    if (std.mem.indexOfScalar(u64, renderer.dmabuf_source_modifiers, 0) == null) {
        return error.SkipZigTest;
    }
    const Gbm = @import("../backend/gbm.zig");
    var gbm = Gbm.init(fd) catch return error.SkipZigTest;
    defer gbm.deinit();

    const size: render.Size = .{ .width = 64, .height = 64 };
    var source_buffer = gbm.createBuffer(size, drm_format_argb8888, &.{0}) catch
        return error.SkipZigTest;
    defer source_buffer.deinit();

    const NoopSync = struct {
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
    const cache_id = render.allocateSourceCacheId();
    var target_pixels = [_]u32{0} ** (64 * 64);
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{.{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{
                .size = size,
                .stride_pixels = source_buffer.stride / @sizeOf(u32),
                .dmabuf = .{
                    .context = &source_buffer,
                    .fd = source_buffer.fd,
                    .format = drm_format_argb8888,
                    .modifier = source_buffer.modifier,
                    .stride = source_buffer.stride,
                    .offset = source_buffer.offset,
                    .required_bytes = @intCast(
                        source_buffer.offset + source_buffer.stride * size.height,
                    ),
                    .y_inverted = false,
                    .force_opaque = false,
                    .retain = NoopSync.retain,
                    .release = NoopSync.release,
                    .begin_cpu_read = NoopSync.begin,
                    .end_cpu_read = NoopSync.end,
                    .export_read_fence = NoopSync.exportFence,
                },
                .source_cache = .{ .id = cache_id, .version = 1 },
            },
        } }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = &target_pixels,
    } });

    try std.testing.expect(renderer.textures.get(cache_id).?.imported);
}

test "Vulkan renderer blends premultiplied alpha" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var pixel = [_]u32{0};
    const size: render.Size = .{ .width = 1, .height = 1 };
    try renderer.renderFrame(.{
        .size = size,
        .commands = &.{
            .{ .clear = render.Color.rgba(0, 0, 255, 255) },
            .{ .solid_rect = .{
                .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
                .color = render.Color.rgba(255, 0, 0, 128),
            } },
            .{ .solid_rect = .{
                .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
                .color = render.Color.rgba(0, 255, 0, 128),
            } },
        },
    }, .{ .pixels = .{ .size = size, .stride_pixels = 1, .pixels = &pixel } });

    try std.testing.expectEqual(@as(u32, 0xff40803f), pixel[0]);
}

test "Vulkan renderer uploads cached image content only for a new version" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 1, .height = 1 };
    var source_pixel = [_]u32{0xffff0000};
    var target_pixel = [_]u32{0};
    var command: render.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = 1,
            .pixels = &source_pixel,
            .source_cache = .{ .id = 42, .version = 1 },
        },
    } };
    const frame: render.Frame = .{
        .size = size,
        .commands = @as(*const [1]render.Command, @ptrCast(&command)),
    };
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = 1,
        .pixels = &target_pixel,
    };
    try renderer.renderFrame(frame, .{ .pixels = target });
    try std.testing.expectEqual(@as(u32, 0xffff0000), target_pixel[0]);

    source_pixel[0] = 0xff00ff00;
    try renderer.renderFrame(frame, .{ .pixels = target });
    try std.testing.expectEqual(@as(u32, 0xffff0000), target_pixel[0]);

    command.image.buffer.source_cache.?.version = 2;
    try renderer.renderFrame(frame, .{ .pixels = target });
    try std.testing.expectEqual(@as(u32, 0xff00ff00), target_pixel[0]);
}

test "Vulkan renderer uploads only source-damaged texture pixels" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 2, .height = 1 };
    var source_pixels = [_]u32{ 0xffff0000, 0xff0000ff };
    var target_pixels = [_]u32{0} ** 2;
    var command: render.Command = .{ .image = .{
        .x = 0,
        .y = 0,
        .size = size,
        .buffer = .{
            .size = size,
            .stride_pixels = 2,
            .pixels = &source_pixels,
            .source_cache = .{ .id = 43, .version = 1 },
        },
    } };
    const frame: render.Frame = .{
        .size = size,
        .commands = @as(*const [1]render.Command, @ptrCast(&command)),
    };
    const target: render.PixelBuffer = .{
        .size = size,
        .stride_pixels = 2,
        .pixels = &target_pixels,
    };
    try renderer.renderFrame(frame, .{ .pixels = target });

    source_pixels = .{ 0xff00ff00, 0xffffffff };
    command.image.buffer.source_cache.?.version = 2;
    command.image.buffer.source_damage = &.{.{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 1,
    }};
    try renderer.renderFrame(frame, .{ .pixels = target });

    try std.testing.expectEqualSlices(
        u32,
        &.{ 0xffff0000, 0xffffffff },
        &target_pixels,
    );
}

test "Vulkan renderer preserves command order in a mixed GPU frame" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const size: render.Size = .{ .width = 2, .height = 1 };
    var source_pixels = [_]u32{0xffff0000} ** 2;
    const untouched = 0xfeedbeef;
    var target_pixels = [_]u32{untouched} ** 2;
    const commands = [_]render.Command{
        .{ .clear = render.Color.rgba(0, 0, 0, 255) },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{ .size = size, .stride_pixels = 2, .pixels = &source_pixels },
        } },
        .{ .solid_rect = .{
            .rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
            .color = render.Color.rgba(0, 255, 0, 255),
        } },
    };
    try renderer.renderFrame(.{
        .size = size,
        .commands = &commands,
        .damage = &.{.{ .x = 1, .y = 0, .width = 1, .height = 1 }},
    }, .{ .pixels = .{
        .size = size,
        .stride_pixels = 2,
        .pixels = &target_pixels,
    } });

    try std.testing.expectEqualSlices(u32, &.{ untouched, 0xff00ff00 }, &target_pixels);
}

test "Vulkan renderer reuses and grows frame resources" {
    var renderer = Self.init(std.testing.allocator, null) catch |err| switch (err) {
        error.VulkanUnavailable, error.NoPhysicalDevice, error.NoQueueFamily => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var small_pixels = [_]u32{0};
    const small: render.PixelBuffer = .{
        .size = .{ .width = 1, .height = 1 },
        .stride_pixels = 1,
        .pixels = &small_pixels,
    };
    try renderer.renderFrame(.{
        .size = small.size,
        .commands = &.{.{ .clear = render.Color.rgba(1, 2, 3, 255) }},
    }, .{ .pixels = small });
    const initial_buffer = renderer.work_buffer;
    try renderer.renderFrame(.{
        .size = small.size,
        .commands = &.{.{ .clear = render.Color.rgba(4, 5, 6, 255) }},
    }, .{ .pixels = small });
    try std.testing.expectEqual(initial_buffer, renderer.work_buffer);
    try std.testing.expectEqual(@as(u32, 0xff040506), small_pixels[0]);

    var large_pixels = [_]u32{0} ** 4;
    const large: render.PixelBuffer = .{
        .size = .{ .width = 2, .height = 2 },
        .stride_pixels = 2,
        .pixels = &large_pixels,
    };
    try renderer.renderFrame(.{
        .size = large.size,
        .commands = &.{.{ .clear = render.Color.rgba(7, 8, 9, 255) }},
    }, .{ .pixels = large });
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(u32)), renderer.work_capacity);
    try std.testing.expectEqualSlices(u32, &([_]u32{0xff070809} ** 4), &large_pixels);

    try renderer.renderFrame(.{
        .size = small.size,
        .commands = &.{.{ .clear = render.Color.rgba(10, 11, 12, 255) }},
    }, .{ .pixels = small });
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(u32)), renderer.work_capacity);
    try std.testing.expectEqual(@as(u32, 0xff0a0b0c), small_pixels[0]);
}
