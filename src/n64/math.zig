const std = @import("std");

pub const Vec3 = @import("math/vec.zig").Vec3;
pub const Vec4 = @import("math/vec.zig").Vec4;
pub const Quat = @import("math/quat.zig").Quat;
pub const Mat4 = @import("math/mat.zig").Mat4;
pub const FixedVec4 = @import("math/mat.zig").FixedVec4;
pub const FixedMat4 = @import("math/mat.zig").FixedMat4;
pub const Frustum = @import("math/frustum.zig").Frustum;

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn degreesToRadians(degrees: f32) f32 {
    return degrees * (@as(f32, @floatCast(std.math.pi)) / 180.0);
}

test {
    std.testing.refAllDecls(@This());
}
