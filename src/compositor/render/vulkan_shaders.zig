//! Build-generated SPIR-V for the Vulkan compositor pipelines.

const std = @import("std");

pub const quad_instanced = spirvWords(@embedFile("vulkan-quad"));
pub const solid_instanced = spirvWords(@embedFile("vulkan-solid"));
pub const image_alpha_instanced = spirvWords(@embedFile("vulkan-image"));
pub const shadow_instanced = spirvWords(@embedFile("vulkan-shadow"));
pub const blur_horizontal_paired = spirvWords(@embedFile("vulkan-blur-horizontal"));
pub const blur_vertical_paired = spirvWords(@embedFile("vulkan-blur-vertical"));

fn spirvWords(comptime bytes: []const u8) [bytes.len / @sizeOf(u32)]u32 {
    @setEvalBranchQuota(10_000);
    comptime std.debug.assert(bytes.len >= @sizeOf(u32));
    comptime std.debug.assert(bytes.len % @sizeOf(u32) == 0);

    var words: [bytes.len / @sizeOf(u32)]u32 = undefined;
    for (&words, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }
    std.debug.assert(words[0] == 0x07230203);
    return words;
}
