const Vec3 = @import("vec.zig").Vec3;
const Vec4 = @import("vec.zig").Vec4;
const Quat = @import("quat.zig").Quat;
const fast = @import("fast.zig");
const std = @import("std");

pub const Mat4 = extern struct {
    /// Column-major matrix coefficients, matching Tiny3D.
    m: [4][4]f32,

    pub const identity: Mat4 = .{ .m = .{
        .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 },
    } };

    pub fn fromSrt(scale: Vec3, input_rotation: Quat, translation: Vec3) Mat4 {
        const rotation = input_rotation.canonicalized();
        const x2 = rotation.x * rotation.x;
        const y2 = rotation.y * rotation.y;
        const z2 = rotation.z * rotation.z;
        const xy = rotation.x * rotation.y;
        const xz = rotation.x * rotation.z;
        const yz = rotation.y * rotation.z;
        const wx = rotation.w * rotation.x;
        const wy = rotation.w * rotation.y;
        const wz = rotation.w * rotation.z;
        return .{ .m = .{
            .{ scale.x * (1 - 2 * (y2 + z2)), scale.x * 2 * (xy + wz), scale.x * 2 * (xz - wy), 0 },
            .{ scale.y * 2 * (xy - wz), scale.y * (1 - 2 * (x2 + z2)), scale.y * 2 * (yz + wx), 0 },
            .{ scale.z * 2 * (xz + wy), scale.z * 2 * (yz - wx), scale.z * (1 - 2 * (x2 + y2)), 0 },
            .{ translation.x, translation.y, translation.z, 1 },
        } };
    }

    /// Build the same Euler SRT matrix as Tiny3D's
    /// `t3d_mat4_from_srt_euler` for angles `(x, y, z)`.
    pub fn fromSrtEuler(scale: Vec3, rotation: Vec3, translation: Vec3) Mat4 {
        const cx = fast.cos(rotation.x);
        const cy = fast.cos(rotation.y);
        const cz = fast.cos(rotation.z);
        const sx = fast.sin(rotation.x);
        const sy = fast.sin(rotation.y);
        const sz = fast.sin(rotation.z);
        return .{ .m = .{
            .{ scale.x * cz * cy, scale.x * (cz * sy * sx - sz * cx), scale.x * (cz * sy * cx + sz * sx), 0 },
            .{ scale.y * sz * cy, scale.y * (sz * sy * sx + cz * cx), scale.y * (sz * sy * cx - cz * sx), 0 },
            .{ -scale.z * sy, scale.z * cy * sx, scale.z * cy * cx, 0 },
            .{ translation.x, translation.y, translation.z, 1 },
        } };
    }
    pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half = @tan(fov * 0.5);
        var result: Mat4 = .{ .m = @splat(@splat(0)) };
        result.m[0][0] = 1.0 / (aspect * tan_half);
        result.m[1][1] = 1.0 / tan_half;
        result.m[2][2] = far / (near - far);
        result.m[2][3] = -1;
        result.m[3][2] = -2.0 * far * near / (far - near);
        return result;
    }
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var result = identity;
        result.m[0][0] = 2 / (right - left);
        result.m[1][1] = 2 / (top - bottom);
        result.m[2][2] = -2 / (far - near);
        result.m[3] = .{ -(right + left) / (right - left), -(top + bottom) / (top - bottom), -(far + near) / (far - near), 1 };
        return result;
    }
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const forward = target.sub(eye).normalized();
        const side = forward.cross(up).normalized();
        const actual_up = side.cross(forward);
        return .{ .m = .{
            .{ side.x, actual_up.x, -forward.x, 0 },
            .{ side.y, actual_up.y, -forward.y, 0 },
            .{ side.z, actual_up.z, -forward.z, 0 },
            .{ -side.dot(eye), -actual_up.dot(eye), forward.dot(eye), 1 },
        } };
    }
    pub fn mul(a: *const Mat4, b: *const Mat4) Mat4 {
        var result: Mat4 = undefined;
        for (0..4) |column| for (0..4) |row| {
            result.m[column][row] = a.m[0][row] * b.m[column][0] + a.m[1][row] * b.m[column][1] +
                a.m[2][row] * b.m[column][2] + a.m[3][row] * b.m[column][3];
        };
        return result;
    }
    /// Multiply affine transforms with final row `(0, 0, 0, 1)`.
    /// Skeleton SRT hierarchies need only the upper three rows.
    pub fn mulAffine(a: *const Mat4, b: *const Mat4) Mat4 {
        var result: Mat4 = undefined;
        a.writeAffineProduct(b, &result);
        return result;
    }
    /// Write an affine product without copying a returned matrix. Destination
    /// must be distinct from both inputs.
    pub fn writeAffineProduct(a: *const Mat4, b: *const Mat4, destination: *Mat4) void {
        for (0..4) |column| {
            inline for (0..3) |row| {
                destination.m[column][row] = a.m[0][row] * b.m[column][0] +
                    a.m[1][row] * b.m[column][1] + a.m[2][row] * b.m[column][2];
                if (column == 3) destination.m[column][row] += a.m[3][row];
            }
            destination.m[column][3] = if (column == 3) 1 else 0;
        }
    }
    pub fn transformPoint(self: *const Mat4, point: Vec3) Vec4 {
        return .init(
            self.m[0][0] * point.x + self.m[1][0] * point.y + self.m[2][0] * point.z + self.m[3][0],
            self.m[0][1] * point.x + self.m[1][1] * point.y + self.m[2][1] * point.z + self.m[3][1],
            self.m[0][2] * point.x + self.m[1][2] * point.y + self.m[2][2] * point.z + self.m[3][2],
            self.m[0][3] * point.x + self.m[1][3] * point.y + self.m[2][3] * point.z + self.m[3][3],
        );
    }
    pub fn transformDirection(self: *const Mat4, direction: Vec3) Vec3 {
        return .init(
            self.m[0][0] * direction.x + self.m[1][0] * direction.y + self.m[2][0] * direction.z,
            self.m[0][1] * direction.x + self.m[1][1] * direction.y + self.m[2][1] * direction.z,
            self.m[0][2] * direction.x + self.m[1][2] * direction.y + self.m[2][2] * direction.z,
        );
    }
    pub fn toFixed(self: *const Mat4) FixedMat4 {
        var result = FixedMat4.identity;
        self.writeFixed(&result);
        return result;
    }
    /// Pack a complete matrix directly into caller-owned GPU upload storage.
    pub fn writeFixed(self: *const Mat4, destination: *FixedMat4) void {
        for (0..4) |column| for (0..4) |row| destination.set(column, row, self.m[column][row]);
    }
    /// Convert an affine matrix whose final row is `(0, 0, 0, 1)`. Packing
    /// three coefficients at a time matches Tiny3D's optimized SRT path.
    pub fn toFixed3x4(self: *const Mat4) FixedMat4 {
        var result: FixedMat4 = undefined;
        self.writeFixed3x4(&result);
        return result;
    }
    /// Pack directly into caller-owned pose storage, avoiding aggregate copies
    /// in size-optimized freestanding builds.
    pub fn writeFixed3x4(self: *const Mat4, destination: *FixedMat4) void {
        for (0..4) |column| {
            const fixed0: i32 = @intFromFloat(self.m[column][0] * 65536.0);
            const fixed1: i32 = @intFromFloat(self.m[column][1] * 65536.0);
            const fixed2: i32 = @intFromFloat(self.m[column][2] * 65536.0);
            destination.columns[column] = .{
                .integer = .{
                    @truncate(fixed0 >> 16),
                    @truncate(fixed1 >> 16),
                    @truncate(fixed2 >> 16),
                    @intFromBool(column == 3),
                },
                .fraction = .{
                    @truncate(@as(u32, @bitCast(fixed0))),
                    @truncate(@as(u32, @bitCast(fixed1))),
                    @truncate(@as(u32, @bitCast(fixed2))),
                    0,
                },
            };
        }
    }
};

pub const FixedVec4 = extern struct { integer: [4]i16, fraction: [4]u16 };

pub const FixedMat4 = extern struct {
    columns: [4]FixedVec4 align(16),

    pub const identity: FixedMat4 = .{ .columns = .{
        .{ .integer = .{ 1, 0, 0, 0 }, .fraction = @splat(0) },
        .{ .integer = .{ 0, 1, 0, 0 }, .fraction = @splat(0) },
        .{ .integer = .{ 0, 0, 1, 0 }, .fraction = @splat(0) },
        .{ .integer = .{ 0, 0, 0, 1 }, .fraction = @splat(0) },
    } };
    pub fn set(self: *FixedMat4, column: usize, row: usize, value: f32) void {
        const fixed: i32 = @intFromFloat(value * 65536.0);
        self.columns[column].integer[row] = @truncate(fixed >> 16);
        self.columns[column].fraction[row] = @bitCast(@as(i16, @truncate(fixed)));
    }
    pub fn get(self: *const FixedMat4, column: usize, row: usize) f32 {
        return @as(f32, @floatFromInt(self.columns[column].integer[row])) +
            @as(f32, @floatFromInt(self.columns[column].fraction[row])) / 65536.0;
    }
};

test "optimized affine conversion matches the generic fixed matrix" {
    const matrix = Mat4.fromSrtEuler(.init(0.25, 0.5, 0.75), .init(0.1, 0.2, 0.3), .init(4, 5, 6));
    const generic = matrix.toFixed();
    const optimized = matrix.toFixed3x4();
    try std.testing.expectEqualDeep(generic, optimized);
}

test "affine multiplication preserves rotated nonuniform and reflected hierarchies" {
    const parent = Mat4.fromSrt(.init(2, -3, 0.5), .fromAxisAngle(.init(0, 1, 0), 0.7), .init(12, -8, 4));
    const local = Mat4.fromSrt(.init(0.25, 4, 2), .fromAxisAngle(.init(1, 0, 0), -0.3), .init(-3, 7, 2));
    const expected = parent.mul(&local);
    const actual = parent.mulAffine(&local);
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqualDeep(expected.toFixed(), actual.toFixed3x4());
    try std.testing.expectEqualDeep(parent, parent.mulAffine(&Mat4.identity));
    try std.testing.expectEqualDeep(local, Mat4.identity.mulAffine(&local));
}

test "SRT ignores tiny imported quaternion components before their products" {
    const rotation: Quat = .{ .x = 0.70710677, .y = -3.3897e-21, .z = 7.1077e-21, .w = 0.70710677 };
    const matrix = Mat4.fromSrt(.one, rotation, .zero);
    try std.testing.expectEqualDeep(Mat4.fromSrt(.one, rotation.canonicalized(), .zero), matrix);
    try std.testing.expectEqual(@as(f32, 0), matrix.m[0][1]);
}
