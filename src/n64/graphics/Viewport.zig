const math = @import("../math.zig");

const Viewport = @This();

width: u16,
height: u16,
projection: math.FixedMat4 align(16) = .identity,
camera: math.FixedMat4 align(16) = .identity,
camera_float: math.Mat4 = .identity,
projection_float: math.Mat4 = .identity,
/// projection_float * camera_float, kept current for `project`.
view_projection: math.Mat4 = .identity,
w_normalization: f32 = 1,

pub fn init(width: u16, height: u16) Viewport {
    return .{ .width = width, .height = height };
}
pub fn setPerspective(self: *Viewport, fov: f32, near: f32, far: f32) void {
    const aspect = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    self.setProjection(math.Mat4.perspective(fov, aspect, near, far));
    self.w_normalization = 2.0 / (far + near);
}
pub fn lookAt(self: *Viewport, eye: math.Vec3, target: math.Vec3, up: math.Vec3) void {
    self.camera_float = math.Mat4.lookAt(eye, target, up);
    self.camera = self.camera_float.toFixed();
    self.view_projection = self.projection_float.mul(&self.camera_float);
}
pub fn setOrthographic(self: *Viewport, left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) void {
    self.setProjection(math.Mat4.orthographic(left, right, bottom, top, near, far));
    self.w_normalization = 2.0 / (far + near);
}

fn setProjection(self: *Viewport, projection: math.Mat4) void {
    self.projection_float = projection;
    self.projection = projection.toFixed();
    self.view_projection = projection.mul(&self.camera_float);
}

pub const Projected = struct {
    /// Screen pixels, origin top-left.
    x: f32,
    y: f32,
    /// Normalized device depth, increasing with distance (about -1 at the near
    /// plane and 1 at the far plane).
    depth: f32,
    /// Screen pixels per world unit at this depth, for sizing sprites.
    scale: f32,
};

/// World position to screen, for anchoring sprites, text and sound panning
/// to 3D objects. Null when the point is behind the camera or within 1/1000
/// unit of its plane. Points off screen are still returned.
pub fn project(self: *const Viewport, world: math.Vec3) ?Projected {
    const clip = self.view_projection.transformPoint(world);
    if (clip.w < 0.001) return null;
    const inverse_w = 1 / clip.w;
    const half_w = @as(f32, @floatFromInt(self.width)) * 0.5;
    const half_h = @as(f32, @floatFromInt(self.height)) * 0.5;
    return .{
        .x = (clip.x * inverse_w + 1) * half_w,
        .y = (1 - clip.y * inverse_w) * half_h,
        .depth = clip.z * inverse_w,
        .scale = self.projection_float.m[1][1] * half_h * inverse_w,
    };
}

test "project maps the view axis to the screen centre and scales with distance" {
    const std = @import("std");
    var viewport: Viewport = .init(320, 240);
    viewport.setPerspective(std.math.pi / 2.0, 1, 100);
    viewport.lookAt(.init(0, 0, 10), .zero, .init(0, 1, 0));
    const centre = viewport.project(.zero).?;
    try std.testing.expectApproxEqAbs(@as(f32, 160), centre.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), centre.y, 0.01);
    // 90 degree vertical field: half the screen height spans 10 units at distance 10.
    try std.testing.expectApproxEqAbs(@as(f32, 12), centre.scale, 0.01);
    const up = viewport.project(.init(0, 5, 0)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 60), up.y, 0.01);
    const right = viewport.project(.init(5, 0, 0)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 220), right.x, 0.01);
    try std.testing.expect(viewport.project(.init(0, 0, 20)) == null);
    const near = viewport.project(.init(0, 0, 9)).?;
    const far = viewport.project(.init(0, 0, -80)).?;
    try std.testing.expect(near.depth < centre.depth and centre.depth < far.depth);
}
