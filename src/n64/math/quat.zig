const Vec3 = @import("vec.zig").Vec3;

pub const Quat = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const identity: Quat = .{ .x = 0, .y = 0, .z = 0, .w = 1 };

    pub fn fromEuler(euler: Vec3) Quat {
        const c1 = @cos(euler.x * 0.5);
        const s1 = @sin(euler.x * 0.5);
        const c2 = @cos(euler.y * 0.5);
        const s2 = @sin(euler.y * 0.5);
        const c3 = @cos(euler.z * 0.5);
        const s3 = @sin(euler.z * 0.5);
        return .{
            .x = c1 * c2 * s3 - s1 * s2 * c3,
            .y = s1 * c2 * c3 - c1 * s2 * s3,
            .z = c1 * s2 * c3 + s1 * c2 * s3,
            .w = c1 * c2 * c3 + s1 * s2 * s3,
        };
    }
    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const sine = @sin(angle * 0.5);
        return .{ .x = axis.x * sine, .y = axis.y * sine, .z = axis.z * sine, .w = @cos(angle * 0.5) };
    }
    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }
    pub fn dot(a: Quat, b: Quat) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
    /// VR4300 cannot calculate subnormal products. Components below 1e-18
    /// contribute less than f32 precision to a unit quaternion and are zeroed
    /// before multiplying. Integer comparisons also accept subnormal inputs.
    pub fn canonicalized(self: Quat) Quat {
        return .{ .x = canonicalComponent(self.x), .y = canonicalComponent(self.y), .z = canonicalComponent(self.z), .w = canonicalComponent(self.w) };
    }
    pub fn normalized(self: Quat) Quat {
        const value = self.canonicalized();
        const length_squared = value.dot(value);
        if (length_squared == 0) return .identity;
        const scale = 1.0 / @sqrt(length_squared);
        return .{ .x = value.x * scale, .y = value.y * scale, .z = value.z * scale, .w = value.w * scale };
    }
    pub fn normalize(self: *Quat) void {
        self.* = self.normalized();
    }
    pub fn nlerp(a: Quat, b: Quat, t: f32) Quat {
        const blend = if (a.dot(b) < 0) -(1.0 - t) else 1.0 - t;
        return (Quat{
            .x = blend * a.x + t * b.x,
            .y = blend * a.y + t * b.y,
            .z = blend * a.z + t * b.z,
            .w = blend * a.w + t * b.w,
        }).normalized();
    }
};

fn canonicalComponent(value: f32) f32 {
    const bits: u32 = @bitCast(value);
    return if ((bits & 0x7fff_ffff) < @as(u32, @bitCast(@as(f32, 1e-18)))) 0 else value;
}

test "quaternions remove values whose squares trap the VR4300 FPU" {
    const std = @import("std");
    const quaternion: Quat = .{ .x = 0.70710677, .y = -3.3897e-21, .z = 7.1077e-21, .w = 0.70710677 };
    const normalized = quaternion.normalized();
    try std.testing.expectEqual(@as(f32, 0), normalized.y);
    try std.testing.expectEqual(@as(f32, 0), normalized.z);
    try std.testing.expectApproxEqAbs(@as(f32, 1), normalized.dot(normalized), 0.000001);
    const subnormal: Quat = .{ .x = @bitCast(@as(u32, 1)), .y = 0, .z = 0, .w = 0 };
    try std.testing.expectEqualDeep(Quat.identity, subnormal.normalized());
}
