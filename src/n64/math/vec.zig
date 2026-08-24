const std = @import("std");

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .splat(0);
    pub const one: Vec3 = .splat(1);

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn splat(value: f32) Vec3 {
        return .init(value, value, value);
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .init(a.x + b.x, a.y + b.y, a.z + b.z);
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .init(a.x - b.x, a.y - b.y, a.z - b.z);
    }
    pub fn mul(a: Vec3, b: Vec3) Vec3 {
        return .init(a.x * b.x, a.y * b.y, a.z * b.z);
    }
    pub fn scale(a: Vec3, scalar: f32) Vec3 {
        return .init(a.x * scalar, a.y * scalar, a.z * scalar);
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn lengthSquared(self: Vec3) f32 {
        return self.dot(self);
    }
    pub fn length(self: Vec3) f32 {
        return @sqrt(self.lengthSquared());
    }
    pub fn distanceSquared(a: Vec3, b: Vec3) f32 {
        return a.sub(b).lengthSquared();
    }
    pub fn distance(a: Vec3, b: Vec3) f32 {
        return @sqrt(a.distanceSquared(b));
    }
    /// Matches Tiny3D by clamping very short lengths.
    pub fn normalized(self: Vec3) Vec3 {
        return self.scale(1.0 / @max(self.length(), 0.0001));
    }
    pub fn normalize(self: *Vec3) void {
        self.* = self.normalized();
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .init(a.y * b.z - b.y * a.z, a.z * b.x - b.z * a.x, a.x * b.y - b.x * a.y);
    }
    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return .init(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t);
    }
};

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const zero: Vec4 = .splat(0);

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
    pub fn splat(value: f32) Vec4 {
        return .init(value, value, value, value);
    }
    pub fn xyz(self: Vec4) Vec3 {
        return .init(self.x, self.y, self.z);
    }
    pub fn component(self: *Vec4, index: usize) *f32 {
        return switch (index) {
            0 => &self.x,
            1 => &self.y,
            2 => &self.z,
            3 => &self.w,
            else => unreachable,
        };
    }
};

test "vector layouts match Tiny3D" {
    try std.testing.expectEqual(12, @sizeOf(Vec3));
    try std.testing.expectEqual(16, @sizeOf(Vec4));
}
