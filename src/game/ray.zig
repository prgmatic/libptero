const Ray = @This();
const Vector3 = @import("vector3.zig");

origin: Vector3,
direction: Vector3,

pub fn pointAt(self: Ray, distance: f32) Vector3 {
    return self.origin.add(self.direction.scale(distance));
}
