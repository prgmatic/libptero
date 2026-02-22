const std = @import("std");
const Camera = @import("camera.zig").Camera;
const Vector3 = @import("vector3.zig");
const Ray = @import("ray.zig");
const objects = @import("objects.zig");
const Rgba32 = @import("n64").color.Rgba32;

var objs: []objects.Sphere = undefined;

pub fn renderImage(cam: *const Camera, spheres: []objects.Sphere, frameBuffer: []Rgba32) void {
    objs = spheres;
    const width = cam.imageWidth;
    const height = cam.imageHeight;

    for(0..height) |y| {
        for (0..width) |x| {
            var color = Vector3.zero();

            for (0..cam.sampleCount) |_| {
                const ray = cam.getRay( @floatFromInt(x), @floatFromInt(y),);
                color.addAssign(rayColor(ray, cam.maxDepth));
            }

            const fSampleCount: f32 = @floatFromInt(cam.sampleCount);
            color.scaleAssign(1.0 / fSampleCount);
            
            const index = y * width + x;
            frameBuffer[index] = vec3ToColor(color);
        }
    }
}

fn vec3ToColor(v: Vector3) Rgba32 {
    return .{
        .r = @intFromFloat(v.x * 255),
        .g = @intFromFloat(v.y * 255),
        .b = @intFromFloat(v.z * 255),
        .a = 255,
    };
}

fn rayColor(ray: Ray, depth: u16) Vector3 {
    if(depth <= 0){
        return Vector3.zero();
    }
        
    var minHit: ?objects.Hit = null;
    for(objs) |sphere| {
        const hit = sphere.hit(ray, 0.01, 10);
        if(hit != null) {
            if (minHit == null or minHit.?.distance > hit.?.distance)
                minHit = hit;
        }
    }

    if(minHit != null) { 
        var scatterResult = minHit.?.material.scatter(ray, minHit.?);
        if (scatterResult != null) {
            return scatterResult.?.attenuation
                .mul(rayColor(scatterResult.?.ray, depth - 1));
        }
        return Vector3.zero();
        // const dir = minHit.?.normal.add(Vector3.randomUnitVector());
        // return rayColor(Ray{
        //     .direction = dir,
        //     .origin = minHit.?.postion
        // }, depth - 1).scale(0.5);
    }
    
    const unitDirection = ray.direction.normalized();
    const a: f32 = (unitDirection.y + 1.0) * 0.5;
    const white = Vector3.init(1.0, 1.0, 1.0);
    const blue = Vector3.init(0.5, 0.7, 1.0);
    return Vector3.lerp(white, blue, a);
}
