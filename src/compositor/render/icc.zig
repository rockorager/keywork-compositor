//! ICC display-profile validation and matrix/shaper extraction.

const std = @import("std");
const render = @import("types.zig");

const c = @cImport({
    @cInclude("lcms2.h");
});

pub const Profile = struct {
    primaries: render.Chromaticities,
    transfer_function: render.TransferFunction,
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Profile {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const profile = c.cmsOpenProfileFromFile(path_z.ptr, "r") orelse
        return error.InvalidIccProfile;
    defer _ = c.cmsCloseProfile(profile);
    return parse(profile);
}

fn parse(profile: c.cmsHPROFILE) !Profile {
    if (c.cmsGetDeviceClass(profile) != c.cmsSigDisplayClass or
        c.cmsGetColorSpace(profile) != c.cmsSigRgbData or
        c.cmsGetPCS(profile) != c.cmsSigXYZData or
        c.cmsIsMatrixShaper(profile) == 0)
    {
        return error.UnsupportedIccProfile;
    }

    const red = readTag(c.cmsCIEXYZ, profile, c.cmsSigRedColorantTag) orelse
        return error.InvalidIccProfile;
    const green = readTag(c.cmsCIEXYZ, profile, c.cmsSigGreenColorantTag) orelse
        return error.InvalidIccProfile;
    const blue = readTag(c.cmsCIEXYZ, profile, c.cmsSigBlueColorantTag) orelse
        return error.InvalidIccProfile;
    const red_xy = try xyzChromaticity(red.*);
    const green_xy = try xyzChromaticity(green.*);
    const blue_xy = try xyzChromaticity(blue.*);
    const white_xy = try xyzChromaticity(.{
        .X = red.X + green.X + blue.X,
        .Y = red.Y + green.Y + blue.Y,
        .Z = red.Z + green.Z + blue.Z,
    });

    const red_trc = readTag(c.cmsToneCurve, profile, c.cmsSigRedTRCTag) orelse
        return error.InvalidIccProfile;
    const green_trc = readTag(c.cmsToneCurve, profile, c.cmsSigGreenTRCTag) orelse
        return error.InvalidIccProfile;
    const blue_trc = readTag(c.cmsToneCurve, profile, c.cmsSigBlueTRCTag) orelse
        return error.InvalidIccProfile;
    const gamma = [_]f64{
        c.cmsEstimateGamma(red_trc, 0.001),
        c.cmsEstimateGamma(green_trc, 0.001),
        c.cmsEstimateGamma(blue_trc, 0.001),
    };
    for (gamma) |value| {
        if (!std.math.isFinite(value) or value < 1 or value > 10 or
            @abs(value - gamma[0]) > 0.01)
        {
            return error.UnsupportedIccProfile;
        }
    }

    return .{
        .primaries = .{
            .red_x = red_xy.x,
            .red_y = red_xy.y,
            .green_x = green_xy.x,
            .green_y = green_xy.y,
            .blue_x = blue_xy.x,
            .blue_y = blue_xy.y,
            .white_x = white_xy.x,
            .white_y = white_xy.y,
        },
        .transfer_function = .{
            .power = @intFromFloat(@round(gamma[0] * 10000.0)),
        },
    };
}

fn readTag(
    comptime T: type,
    profile: c.cmsHPROFILE,
    signature: c.cmsTagSignature,
) ?*const T {
    const value = c.cmsReadTag(profile, signature) orelse return null;
    return @ptrCast(@alignCast(value));
}

fn xyzChromaticity(value: c.cmsCIEXYZ) !struct { x: i32, y: i32 } {
    const sum = value.X + value.Y + value.Z;
    if (!std.math.isFinite(sum) or sum <= 0) return error.InvalidIccProfile;
    const x = value.X / sum;
    const y = value.Y / sum;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        x < 0 or x > 1 or y <= 0 or y > 1)
    {
        return error.InvalidIccProfile;
    }
    return .{
        .x = @intFromFloat(@round(x * 1_000_000.0)),
        .y = @intFromFloat(@round(y * 1_000_000.0)),
    };
}

test "ICC matrix profiles expose primaries and a shared transfer curve" {
    const white: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = 1 };
    const primaries: c.cmsCIExyYTRIPLE = .{
        .Red = .{ .x = 0.64, .y = 0.33, .Y = 1 },
        .Green = .{ .x = 0.30, .y = 0.60, .Y = 1 },
        .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1 },
    };
    const curve = c.cmsBuildGamma(null, 2.4) orelse return error.OutOfMemory;
    defer c.cmsFreeToneCurve(curve);
    var curves = [_]*c.cmsToneCurve{ curve, curve, curve };
    const profile = c.cmsCreateRGBProfile(&white, &primaries, &curves) orelse
        return error.OutOfMemory;
    defer _ = c.cmsCloseProfile(profile);

    const parsed = try parse(profile);
    try std.testing.expectEqual(render.TransferFunction{ .power = 24000 }, parsed.transfer_function);
    try std.testing.expect(parsed.primaries.red_y > 0);
    try std.testing.expect(parsed.primaries.green_y > 0);
    try std.testing.expect(parsed.primaries.blue_y > 0);
    try std.testing.expect(parsed.primaries.white_y > 0);
}

test "ICC LUT profiles are rejected by the matrix profile path" {
    const profile = c.cmsCreateLab4Profile(null) orelse return error.OutOfMemory;
    defer _ = c.cmsCloseProfile(profile);
    try std.testing.expectError(error.UnsupportedIccProfile, parse(profile));
}
