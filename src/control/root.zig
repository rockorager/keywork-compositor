//! Private API contract shared by Keywork's control server and client.

pub const interface_name = "dev.rockorager.keywork.compositor";
pub const socket_name = interface_name;
pub const interface_description = @embedFile("control-interface");

pub const Direction = enum { next, previous, left, down, up, right };
pub const WindowTarget = enum { focused };
pub const Layout = enum { master_stack, dwindle, scrolling };

pub const LatencyStatistics = struct {
    samples: i64,
    p50_microseconds: i64,
    p95_microseconds: i64,
    p99_microseconds: i64,
    maximum_microseconds: i64,
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

pub const FramePath = enum { none, composited, direct_scanout };
pub const BufferFormat = enum { none, argb8888, xrgb8888, abgr8888, xbgr8888, rgba16f_linear };
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
    cpu_uploads: i64,
    dmabuf_imports: i64,
    frames_over_budget: i64,
    gpu_execution: LatencyStatistics,
    gpu_composition: LatencyStatistics,
    gpu_output_encode: LatencyStatistics,
    request_to_presentation: LatencyStatistics,
    request_to_render: LatencyStatistics,
    render_to_commit: LatencyStatistics,
    commit_to_presentation: LatencyStatistics,
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
pub const reload_configuration_method = interface_name ++ ".ReloadConfiguration";
pub const quit_method = interface_name ++ ".Quit";
pub const configuration_reload_failed_error = interface_name ++ ".ConfigurationReloadFailed";

pub const minimum_workspace = 1;
pub const maximum_workspace = 10;

pub fn validWorkspace(workspace: i64) bool {
    return workspace >= minimum_workspace and workspace <= maximum_workspace;
}
