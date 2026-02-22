const std = @import("std");
const Vector3 = @import("vector3.zig");
const Ray = @import("ray.zig");
const Material = @import("material.zig").Material;
const MaterialType = @import("material.zig").MaterialType;

pub const Hit = struct {
    postion: Vector3,
    normal: Vector3,
    distance: f32,
    isFrontFace: bool,
    material: Material
};

pub const Sphere = struct {
    position: Vector3,
    radius: f32,
    material: Material,
    
    pub fn init(material: MaterialType,  pos: [3]f32, radius: f32, albedo: [3]f32, fuzz: f32) Sphere {
        return .{
            .position = Vector3.init(pos[0], pos[1], pos[2]),
            .radius = radius,
            .material = .{
                .type = material,
                .albedo = Vector3.init(albedo[0], albedo[1], albedo[2]),
                .fuzz = fuzz
            }
        };
    }

    pub fn hit(self: Sphere, ray: Ray, minDist: f32, maxDist: f32) ?Hit {
        const oc = self.position.sub(ray.origin);
        const a = ray.direction.sqrMagnitude();
        const h = Vector3.dot(ray.direction, oc);
        const c = oc.sqrMagnitude() - self.radius * self.radius;
        const descriminant = h * h - a * c;

        if(descriminant < 0) return null;

        const sqrtd = std.math.sqrt(descriminant);

        var dist = (h - sqrtd) / a;
        if(dist <= minDist or maxDist <= dist) {
            dist = (h + sqrtd) / a;
            if(dist <= minDist or maxDist <= dist)
                return null;
        }

        const hitPos = ray.pointAt(dist);

        var normal = hitPos.sub(self.position).scale(1.0 / self.radius);
        const isFrontFace = Vector3.dot(ray.direction, normal) > 0;
        if (isFrontFace){
            normal.negateAssign();
        }
        
        return Hit{
            .postion = hitPos,
            .normal = normal,
            .distance = dist,
            .isFrontFace = isFrontFace,
            .material = self.material,
        };
    }
};
