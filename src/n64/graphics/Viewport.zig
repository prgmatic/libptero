const math = @import("../math.zig");

const Viewport = @This();

width: u16,
height: u16,
projection: math.FixedMat4 align(16) = .identity,
camera: math.FixedMat4 align(16) = .identity,
camera_float: math.Mat4 = .identity,
w_normalization: f32 = 1,

pub fn init(width: u16, height: u16) Viewport {
    return .{ .width = width, .height = height };
}
pub fn setPerspective(self: *Viewport, fov: f32, near: f32, far: f32) void {
    const aspect = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    self.projection = math.Mat4.perspective(fov, aspect, near, far).toFixed();
    self.w_normalization = 2.0 / (far + near);
}
pub fn lookAt(self: *Viewport, eye: math.Vec3, target: math.Vec3, up: math.Vec3) void {
    self.camera_float = math.Mat4.lookAt(eye, target, up);
    self.camera = self.camera_float.toFixed();
}
pub fn setOrthographic(self: *Viewport, left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) void {
    self.projection = math.Mat4.orthographic(left, right, bottom, top, near, far).toFixed();
    self.w_normalization = 2.0 / (far + near);
}
