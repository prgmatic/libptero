const std = @import("std");
const math = @import("math.zig");

test "Tiny3D-compatible layouts" {
    try std.testing.expectEqual(12, @sizeOf(math.Vec3));
    try std.testing.expectEqual(16, @sizeOf(math.Vec4));
    try std.testing.expectEqual(16, @sizeOf(math.Quat));
    try std.testing.expectEqual(64, @sizeOf(math.Mat4));
    try std.testing.expectEqual(16, @sizeOf(math.FixedVec4));
    try std.testing.expectEqual(64, @sizeOf(math.FixedMat4));
    try std.testing.expectEqual(16, @alignOf(math.FixedMat4));
    try std.testing.expectEqual(96, @sizeOf(math.Frustum));
}

test "Vec3 operations use value semantics" {
    const a = math.Vec3.init(1, 2, 3);
    const b = math.Vec3.init(4, 5, 6);
    try std.testing.expectEqual(math.Vec3.init(5, 7, 9), a.add(b));
    try std.testing.expectEqual(@as(f32, 32), a.dot(b));
    try std.testing.expectEqual(math.Vec3.init(-3, 6, -3), a.cross(b));
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.normalized().length(), 0.00001);
}

test "matrix operations preserve Tiny3D column-major layout" {
    const matrix = math.Mat4.fromSrt(math.Vec3.one, math.Quat.identity, .init(10, 20, 30));
    try std.testing.expectEqual(math.Vec4.init(11, 22, 33, 1), matrix.transformPoint(.init(1, 2, 3)));
    const product = math.Mat4.identity.mul(&matrix);
    try std.testing.expectEqual(matrix.m, product.m);
    const fixed = matrix.toFixed();
    try std.testing.expectApproxEqAbs(@as(f32, 20), fixed.get(3, 1), 0.00001);
}

test "quaternion interpolation returns a normalized value" {
    const rotation = math.Quat.fromAxisAngle(.init(0, 1, 0), std.math.pi);
    const halfway = math.Quat.identity.nlerp(rotation, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), halfway.dot(halfway), 0.00001);
}

test "projection matrix produces usable frustum planes" {
    const projection = math.Mat4.perspective(math.degreesToRadians(60), 4.0 / 3.0, 1, 100);
    const frustum = math.Frustum.fromMatrix(&projection);
    try std.testing.expect(frustum.containsSphere(.init(0, 0, -5), 1));
    try std.testing.expect(!frustum.containsSphere(.init(1000, 0, -5), 1));
}
