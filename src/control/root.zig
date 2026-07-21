//! Private API contract shared by Keywork's control server and client.

pub const interface_name = "dev.rockorager.keywork.compositor";
pub const socket_name = interface_name;
pub const interface_description = @embedFile("control-interface");

pub const Direction = enum { next, previous, left, down, up, right };
pub const WindowTarget = enum { focused };
pub const Layout = enum { tiled };
pub const LogLevel = enum(u8) { @"error", warning, info, debug };

pub const Color = struct {
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
};

pub const Border = struct {
    width: i64,
    color: Color,
};

pub const LatencyStatistics = struct {
    samples: i64 = 0,
    p50_microseconds: i64 = 0,
    p95_microseconds: i64 = 0,
    p99_microseconds: i64 = 0,
    maximum_microseconds: i64 = 0,
};

pub const DirectScanoutRejections = struct {
    no_fullscreen_surface: i64,
    non_opaque_surface: i64,
    surface_transform: i64,
    non_dmabuf: i64,
    y_inverted: i64,
    missing_buffer_identity: i64,
    color_conversion: i64,
    unsupported_backend: i64,
    output_unavailable: i64,
    output_busy: i64,
    device_inactive: i64,
    unsupported_format_or_modifier: i64,
    unsupported_layout: i64,
    framebuffer_import_failed: i64,
    page_flip_failed: i64,
};

pub const OverlayScanoutRejections = struct {
    no_topmost_surface: i64 = 0,
    non_opaque_surface: i64 = 0,
    clipped_surface: i64 = 0,
    transformed_surface: i64 = 0,
    scaled_surface: i64 = 0,
    outside_output: i64 = 0,
    non_dmabuf: i64 = 0,
    non_rgb_surface: i64 = 0,
    y_inverted: i64 = 0,
    missing_buffer_identity: i64 = 0,
    color_conversion: i64 = 0,
    unsupported_backend: i64 = 0,
    output_unavailable: i64 = 0,
    output_busy: i64 = 0,
    device_inactive: i64 = 0,
    no_overlay_plane: i64 = 0,
    unsupported_format_or_modifier: i64 = 0,
    unsupported_layout: i64 = 0,
    synchronization_failed: i64 = 0,
    framebuffer_import_failed: i64 = 0,
    atomic_test_failed: i64 = 0,
    page_flip_failed: i64 = 0,
};

pub const FramePath = enum { none, composited, direct_scanout, overlay_scanout };
pub const BufferFormat = enum {
    none,
    argb8888,
    xrgb8888,
    abgr8888,
    xbgr8888,
    xrgb2101010,
    rgba16f_linear,
};
pub const OutputTransform = enum { normal };

pub const FrameDiagnostics = struct {
    path: FramePath,
    working_format: BufferFormat,
    scanout_format: BufferFormat,
    output_transform: OutputTransform,
    damage_rectangles: i64,
    damaged_pixels: i64,
};

pub const OutputStatistics = struct {
    name: []const u8,
    width: i64,
    height: i64,
    refresh_millihertz: i64,
    last_frame: FrameDiagnostics,
    frames_requested: i64,
    frames_started: i64,
    frames_presented: i64,
    frames_discarded: i64,
    acquire_retries: i64,
    composited_frames: i64,
    direct_scanout_candidates: i64,
    direct_scanout_frames: i64,
    direct_scanout_rejections: DirectScanoutRejections,
    overlay_scanout_candidates: i64 = 0,
    overlay_scanout_frames: i64 = 0,
    overlay_scanout_rejections: OverlayScanoutRejections = .{},
    cpu_uploads: i64,
    dmabuf_imports: i64,
    frames_over_budget: i64,
    gpu_execution: LatencyStatistics,
    gpu_composition: LatencyStatistics,
    gpu_preparation: LatencyStatistics,
    gpu_solid_composition: LatencyStatistics,
    gpu_image_composition: LatencyStatistics,
    gpu_shadow: LatencyStatistics,
    gpu_blur_downsample: LatencyStatistics,
    gpu_blur_upsample: LatencyStatistics,
    gpu_blur_composite: LatencyStatistics,
    gpu_composition_overhead: LatencyStatistics,
    gpu_output_encode: LatencyStatistics,
    gpu_frame_finish: LatencyStatistics,
    request_to_presentation: LatencyStatistics,
    request_to_render: LatencyStatistics,
    render_to_commit: LatencyStatistics,
    commit_to_presentation: LatencyStatistics,
    render_fence_samples: i64 = 0,
    render_fences_signaled_before_commit: i64 = 0,
    render_to_gpu_completion: LatencyStatistics = .{},
    gpu_completion_to_presentation: LatencyStatistics = .{},
};

pub const focus_method = interface_name ++ ".Focus";
pub const move_focused_method = interface_name ++ ".MoveFocused";
pub const close_method = interface_name ++ ".Close";
pub const toggle_fullscreen_method = interface_name ++ ".ToggleFullscreen";
pub const toggle_floating_method = interface_name ++ ".ToggleFloating";
pub const set_layout_method = interface_name ++ ".SetLayout";
pub const switch_workspace_method = interface_name ++ ".SwitchWorkspace";
pub const move_focused_to_workspace_method = interface_name ++ ".MoveFocusedToWorkspace";
pub const get_performance_statistics_method = interface_name ++ ".GetPerformanceStatistics";
pub const set_unfocused_border_method = interface_name ++ ".SetUnfocusedBorder";
pub const set_log_level_method = interface_name ++ ".SetLogLevel";
pub const reload_configuration_method = interface_name ++ ".ReloadConfiguration";
pub const quit_method = interface_name ++ ".Quit";
pub const configuration_reload_failed_error = interface_name ++ ".ConfigurationReloadFailed";

pub const minimum_workspace = 1;
pub const maximum_workspace = 10;

pub fn validWorkspace(workspace: i64) bool {
    return workspace >= minimum_workspace and workspace <= maximum_workspace;
}

pub fn validBorder(border: Border) bool {
    return border.width >= 0 and border.width <= 256 and
        validColorChannel(border.color.red) and
        validColorChannel(border.color.green) and
        validColorChannel(border.color.blue) and
        validColorChannel(border.color.alpha);
}

fn validColorChannel(channel: i64) bool {
    return channel >= 0 and channel <= 255;
}
