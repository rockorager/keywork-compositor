//! ICC display-profile validation and matrix/shaper extraction.

const std = @import("std");
const render = @import("types.zig");

const c = @cImport({
    @cInclude("lcms2.h");
});

pub const Profile = struct {
    primaries: render.Chromaticities,
    transfer_function: render.TransferFunction,

    pub fn applyTo(self: Profile, base: render.ColorDescription) render.ColorDescription {
        var description = base;
        description.primaries = self.primaries;
        description.named_primaries = null;
        description.transfer_function = self.transfer_function;
        return description;
    }
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
    for (0..4) |intent| {
        if (c.cmsIsCLUT(profile, @intCast(intent), c.LCMS_USED_AS_INPUT) != 0 or
            c.cmsIsCLUT(profile, @intCast(intent), c.LCMS_USED_AS_OUTPUT) != 0)
        {
            return error.UnsupportedIccProfile;
        }
    }
    if (c.cmsIsTag(profile, c.cmsSigVcgtTag) != 0) return error.UnsupportedIccProfile;

    const red_tag = readTag(c.cmsCIEXYZ, profile, c.cmsSigRedColorantTag) orelse
        return error.InvalidIccProfile;
    const green_tag = readTag(c.cmsCIEXYZ, profile, c.cmsSigGreenColorantTag) orelse
        return error.InvalidIccProfile;
    const blue_tag = readTag(c.cmsCIEXYZ, profile, c.cmsSigBlueColorantTag) orelse
        return error.InvalidIccProfile;
    const colorants = try nativeColorants(profile, .{ red_tag.*, green_tag.*, blue_tag.* });
    const red_xy = try xyzChromaticity(colorants[0]);
    const green_xy = try xyzChromaticity(colorants[1]);
    const blue_xy = try xyzChromaticity(colorants[2]);
    const white_xy = try xyzChromaticity(.{
        .X = colorants[0].X + colorants[1].X + colorants[2].X,
        .Y = colorants[0].Y + colorants[1].Y + colorants[2].Y,
        .Z = colorants[0].Z + colorants[1].Z + colorants[2].Z,
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

const Matrix3 = [3][3]f64;

fn nativeColorants(
    profile: c.cmsHPROFILE,
    pcs_colorants: [3]c.cmsCIEXYZ,
) ![3]c.cmsCIEXYZ {
    if (try readChromaticAdaptation(profile)) |adaptation| {
        const inverse = invertMatrix3(adaptation) orelse return error.InvalidIccProfile;
        var result: [3]c.cmsCIEXYZ = undefined;
        for (pcs_colorants, &result) |colorant, *native| native.* = multiplyXyz(inverse, colorant);
        return result;
    }

    const media_white = readTag(c.cmsCIEXYZ, profile, c.cmsSigMediaWhitePointTag) orelse
        return error.UnsupportedIccProfile;
    var result: [3]c.cmsCIEXYZ = undefined;
    for (pcs_colorants, &result) |colorant, *native| {
        if (c.cmsAdaptToIlluminant(native, c.cmsD50_XYZ(), media_white, &colorant) == 0) {
            return error.InvalidIccProfile;
        }
    }
    return result;
}

fn readChromaticAdaptation(profile: c.cmsHPROFILE) !?Matrix3 {
    const size = c.cmsReadRawTag(profile, c.cmsSigChromaticAdaptationTag, null, 0);
    if (size == 0) return null;
    if (size != 44) return error.InvalidIccProfile;
    var bytes: [44]u8 = undefined;
    if (c.cmsReadRawTag(profile, c.cmsSigChromaticAdaptationTag, &bytes, bytes.len) != bytes.len or
        !std.mem.eql(u8, bytes[0..4], "sf32") or !std.mem.allEqual(u8, bytes[4..8], 0))
    {
        return error.InvalidIccProfile;
    }
    var matrix: Matrix3 = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            const offset = 8 + (row * 3 + column) * 4;
            const fixed = std.mem.readInt(i32, bytes[offset..][0..4], .big);
            matrix[row][column] = @as(f64, @floatFromInt(fixed)) / 65536.0;
        }
    }
    return matrix;
}

fn invertMatrix3(matrix: Matrix3) ?Matrix3 {
    const determinant =
        matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) -
        matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0]) +
        matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 0.000000001) return null;
    const inverse_determinant = 1.0 / determinant;
    return .{
        .{
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * inverse_determinant,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * inverse_determinant,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * inverse_determinant,
        },
        .{
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * inverse_determinant,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * inverse_determinant,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * inverse_determinant,
        },
        .{
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * inverse_determinant,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * inverse_determinant,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * inverse_determinant,
        },
    };
}

fn multiplyXyz(matrix: Matrix3, value: c.cmsCIEXYZ) c.cmsCIEXYZ {
    const vector = [_]f64{ value.X, value.Y, value.Z };
    return .{
        .X = matrix[0][0] * vector[0] + matrix[0][1] * vector[1] + matrix[0][2] * vector[2],
        .Y = matrix[1][0] * vector[0] + matrix[1][1] * vector[1] + matrix[1][2] * vector[2],
        .Z = matrix[2][0] * vector[0] + matrix[2][1] * vector[1] + matrix[2][2] * vector[2],
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
    try expectNear(640000, parsed.primaries.red_x, 100);
    try expectNear(330000, parsed.primaries.red_y, 100);
    try expectNear(300000, parsed.primaries.green_x, 100);
    try expectNear(600000, parsed.primaries.green_y, 100);
    try expectNear(150000, parsed.primaries.blue_x, 100);
    try expectNear(60000, parsed.primaries.blue_y, 100);
    try expectNear(312700, parsed.primaries.white_x, 100);
    try expectNear(329000, parsed.primaries.white_y, 100);
}

fn expectNear(expected: i32, actual: i32, tolerance: i32) !void {
    try std.testing.expect(@abs(expected - actual) <= tolerance);
}

test "ICC LUT profiles are rejected by the matrix profile path" {
    const profile = c.cmsCreateLab4Profile(null) orelse return error.OutOfMemory;
    defer _ = c.cmsCloseProfile(profile);
    try std.testing.expectError(error.UnsupportedIccProfile, parse(profile));
}
