const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    const river = b.dependency("river", .{});
    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("stable/presentation-time/presentation-time.xml");
    scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/input-method-unstable-v2.xml"));
    scanner.addCustomProtocol(river.path("protocol/upstream/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(river.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(river.path("protocol/river-layer-shell-v1.xml"));
    scanner.generate("wl_compositor", 7);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_fixes", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 10);
    scanner.generate("wl_data_device_manager", 4);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("zxdg_decoration_manager_v1", 2);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zwp_text_input_manager_v3", 2);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_presentation", 2);
    scanner.generate("zwp_linux_dmabuf_v1", 6);
    scanner.generate("xdg_activation_v1", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);
    scanner.generate("zxdg_output_manager_v1", 3);
    scanner.generate("zwp_input_method_manager_v2", 1);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("river_window_manager_v1", 5);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("wayland", wayland);
    root_module.addImport("vulkan", vulkan);
    root_module.linkSystemLibrary("pixman-1", .{});
    root_module.linkSystemLibrary("wayland-client", .{});
    root_module.linkSystemLibrary("wayland-server", .{});

    const exe = b.addExecutable(.{
        .name = "keywork_compositor",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = root_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}
