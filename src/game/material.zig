const std = @import("std");
const Vector3 = @import("vector3.zig");
const Ray = @import("ray.zig");
const Hit = @import("objects.zig").Hit;

var rand = std.Random.DefaultPrng.init(54321);

pub const Material = struct {
    type: MaterialType,
    albedo: Vector3 = Vector3.init(1, 1, 1),
    fuzz: f32 = 0,

    pub fn scatter(self: Material, ray: Ray, hit: Hit) ?ScatterResult {
        switch (self.type) {
            .Lambertian => return lambertianScatter(hit, self.albedo),
            .Metal => return metalScatter(ray, hit, self.albedo, self.fuzz),
            .Dielectric => return dielectricScatter(ray, hit, self.fuzz)
        }
    }
};

pub const MaterialType = enum {
    Lambertian,
    Metal,
    Dielectric
};

pub const ScatterResult = struct {
    ray: Ray,
    attenuation: Vector3,
};

fn lambertianScatter(hit: Hit, albedo: Vector3) ScatterResult {
    var scatterDir = hit.normal.add(Vector3.randomUnitVector());
    if(scatterDir.isNearZero())
        scatterDir = hit.normal;
    
    return .{
        .ray = Ray{
            .origin = hit.postion,
            .direction = hit.normal.add(Vector3.randomUnitVector()),
        },
        .attenuation = albedo
    };
}

fn metalScatter(ray: Ray, hit: Hit, albedo: Vector3, fuzz: f32) ScatterResult {
    var reflected = Vector3.reflect(ray.direction, hit.normal);
    reflected = reflected.normalized().add(Vector3.randomUnitVector().scale(fuzz));
    return .{
        .ray = Ray {
            .origin = hit.postion,
            .direction = reflected,
        },
        .attenuation = albedo
    };
}

fn dielectricScatter(ray: Ray, hit: Hit, refractiveIndex: f32) ScatterResult {
    const ri = if(!hit.isFrontFace) (1.0 / refractiveIndex) else refractiveIndex;
    var dir = ray.direction.normalized();

    const cosTheta = @min(Vector3.dot(dir.negate(), hit.normal), 1.0);
    const sinTheta = std.math.sqrt(1.0 - cosTheta * cosTheta);

    const cannotRefract = ri * sinTheta > 1.0;

    if(cannotRefract or reflectance(cosTheta, ri) > rand.random().float(f32)) {
        dir = dir.reflect(hit.normal);
    }
    else {
        dir = dir.refract(hit.normal, ri);
    }   

    return .{
        .ray = .{
            .origin = hit.postion,
            .direction = dir,
        },
        .attenuation = Vector3.init(1, 1, 1),
    };
}

fn reflectance(cos: f32, refractiveIndex: f32) f32 {
    var r0 = (1.0 - refractiveIndex) / (1 + refractiveIndex);
    r0 = r0 * r0;
    return r0 + (1 - r0) * std.math.pow(f32, 1 - cos, 5);
}
