const std = @import("std");
const Vector3 = @import("vector3.zig");
const Ray = @import("ray.zig");
const Quaternion = @import("quaternion.zig");

var rand = std.Random.DefaultPrng.init(1234);

pub const Camera = struct {
    position: Vector3,
    imageWidth: u16,
    aspectRatio: f32,
    focalLength: f32,
    sampleCount: u8,
    maxDepth: u16,
    fieldOfView: f32,
    lookAt: Vector3,

    imageHeight: u16 = 1,
    viewportHeight: f32 = 1,
    viewportWidth: f32 = 1,
    pixel00Loc: Vector3 = undefined,
    pixelDeltaU: Vector3 = undefined,
    pixelDeltaV: Vector3 = undefined,
    rotation: Quaternion = undefined,

    pub fn init(position: Vector3, options: CameraOptions) Camera {
        var c = Camera{
            .position = position,
            .imageWidth = options.imageWidth,
            .aspectRatio = options.aspectRatio,
            .focalLength = options.focalLength,
            .sampleCount = options.sampleCount,
            .maxDepth = options.maxDepth,
            .fieldOfView = options.fieldOfView,
            .lookAt = options.lookAt
        };

        c.updateViewport();
        return c;
    }

    pub fn updateViewport(c: *Camera) void {
        const lookDir = c.position.sub(c.lookAt);
        c.rotation = Quaternion.lookRotation(lookDir, Vector3.init(0, 1, 0));

        const fWidth: f32 = @floatFromInt(c.imageWidth);
        const fHeight: f32 = fWidth / c.aspectRatio;
        c.imageHeight = @intFromFloat(fHeight);

        const theta = std.math.degreesToRadians(c.fieldOfView);
        const h = @tan(theta / 2);
        c.viewportHeight = 2 * h * c.focalLength;
        
        // update aspectRatio
        c.aspectRatio = fWidth / fHeight;
        c.aspectRatio /= 2;
        c.viewportWidth = c.viewportHeight * c.aspectRatio;

        const viewportU = Vector3.init(c.viewportWidth, 0, 0);
        const viewportV = Vector3.init(0, -c.viewportHeight, 0);

        c.pixelDeltaU = viewportU.scale(1.0 / fWidth);
        c.pixelDeltaV = viewportV.scale(1.0 / fHeight);

        const upperLeft = c.position
            .sub(Vector3.init(0, 0, c.focalLength))
            .sub(viewportU.scale(0.5))
            .sub(viewportV.scale(0.5));
        c.pixel00Loc = c.pixelDeltaU.add(c.pixelDeltaV)
            .scale(0.5)
            .add(upperLeft);
    }

    pub fn getRay(self: Camera, x: f32, y: f32) Ray {
        var offsetX: f32 = 0;
        var offsetY: f32 = 0;
        if(self.sampleCount > 1) {
            offsetX = rand.random().float(f32) - 0.5;
            offsetY = rand.random().float(f32) - 0.5;
        }

        const pixelCenter = self.pixel00Loc
            .add(self.pixelDeltaU.scale(x + offsetX))
            .add(self.pixelDeltaV.scale(y + offsetY));
        var rayDirection = pixelCenter.sub(self.position);
        rayDirection = self.rotation.vectorMul(rayDirection);
        return Ray{
            .origin = self.position,
            .direction = rayDirection
        };
    }
};

pub const CameraOptions = struct {
    imageWidth: u16 = 800,
    aspectRatio: f32 = 16.0 / 9.0,
    focalLength: f32 = 1.0,
    sampleCount: u8 = 100,
    maxDepth: u16 = 50,
    fieldOfView: f32 = 90,
    lookAt: Vector3 = Vector3.zero(),
};
