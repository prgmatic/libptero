const Quaternion = @This();
const Vector3 = @import("vector3.zig");
const std = @import("std");

x: f32,
y: f32,
z: f32,
w: f32,

pub fn lookRotation(forward: Vector3, up: Vector3) Quaternion {
    const f = forward.normalized();

    // Orthonormal basis
    var r = Vector3.cross(up, f);
    if (r.magnitude() < 1e-6) {
        // forward is parallel to up — choose fallback
        r = Vector3.cross(Vector3.init(1, 0, 0), f);
    }
    r = r.normalized();

    const u = Vector3.cross(f, r);

    // Rotation matrix → quaternion
    return fromBasis(r, u, f);
}

pub fn vectorMul(q: Quaternion, v: Vector3) Vector3 {
    const qX = 2.0 * (q.y * v.z - q.z * v.y);
    const qY = 2.0 * (q.z * v.x - q.x * v.z);
    const qZ = 2.0 * (q.x * v.y - q.y * v.x);

    return .{
        .x = (v.x + qX * q.w + (q.y * qZ - q.z * qY)),
        .y = (v.y + qY * q.w + (q.z * qX - q.x * qZ)),
        .z = (v.z + qZ * q.w + (q.x * qY - q.y * qX)),
    };
}

pub fn fromBasis(r: Vector3, u: Vector3, f: Vector3) Quaternion {
    const m00 = r.x;
    const m01 = u.x;
    const m02 = f.x;
    const m10 = r.y;
    const m11 = u.y;
    const m12 = f.y;
    const m20 = r.z;
    const m21 = u.z;
    const m22 = f.z;

    const trace = m00 + m11 + m22;

    if (trace > 0.0) {
        const s = @sqrt(trace + 1.0) * 2.0;
        return .{
            .w = 0.25 * s,
            .x = (m21 - m12) / s,
            .y = (m02 - m20) / s,
            .z = (m10 - m01) / s,
        };
    } else if (m00 > m11 and m00 > m22) {
        const s = @sqrt(1.0 + m00 - m11 - m22) * 2.0;
        return .{
            .w = (m21 - m12) / s,
            .x = 0.25 * s,
            .y = (m01 + m10) / s,
            .z = (m02 + m20) / s,
        };
    } else if (m11 > m22) {
        const s = @sqrt(1.0 + m11 - m00 - m22) * 2.0;
        return .{
            .w = (m02 - m20) / s,
            .x = (m01 + m10) / s,
            .y = 0.25 * s,
            .z = (m12 + m21) / s,
        };
    } else {
        const s = @sqrt(1.0 + m22 - m00 - m11) * 2.0;
        return .{
            .w = (m10 - m01) / s,
            .x = (m02 + m20) / s,
            .y = (m12 + m21) / s,
            .z = 0.25 * s,
        };
    }
}
