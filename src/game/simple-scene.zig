const std = @import("std");
const Vector3 = @import("vector3.zig");
const Camera = @import("camera.zig").Camera;
const CameraOptions = @import("camera.zig").CameraOptions;
const objects = @import("objects.zig");
const renderer = @import("renderer.zig");
const MaterialType = @import("material.zig").MaterialType;
const s = @import("objects.zig").Sphere.init;
const Rgba32 = @import("n64").color.Rgba32;


var cameraOptions = CameraOptions{
    .sampleCount = 100,
    .maxDepth = 30,
    // .sampleCount = 2,
    // .maxDepth = 5,
    .fieldOfView = 20,
    .lookAt = Vector3.init(0, 0, 0),
};

const r: f32 = @cos(std.math.pi/4.0);
var spheres = [_]objects.Sphere{
    s(.Lambertian, .{ 0, 0,    -0.2}, 0.5, .{0.1, 0.5, 0.1}, 0),
    s(.Dielectric, .{-1, 0,       0}, 0.5, .{0.8, 0.8, 0.8}, 1.5),
    s(.Dielectric, .{-1, 0,       0}, 0.4, .{0.8, 0.8, 0.8}, 1.0 / 1.5),
    s(.Metal,      .{ 1, 0,       0}, 0.5, .{0.2, 0.1, 0.5}, 0.1),
    s(.Lambertian, .{ 0, -100.51, 0}, 100, .{0.5, 0.5, 0.1}, 0),
};

pub fn render(frameBuffer: []Rgba32, width: u32, height: u32) void {
    const aspect: f32 = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    cameraOptions.imageWidth = @intCast(width);
    cameraOptions.aspectRatio = aspect;
    const cam = Camera.init(Vector3.init(-2, 2, 2), cameraOptions);
    renderer.renderImage(&cam, &spheres, frameBuffer);
    
}

