pub const Vector3 = @This();
const std = @import("std");
var rand = std.Random.DefaultPrng.init(431);

x: f32,
y: f32,
z: f32,

pub fn zero() Vector3 {
    return .{ .x = 0, .y = 0, .z = 0 };
}

pub fn init(x: f32, y: f32, z: f32) Vector3 {
    return .{ .x = x, .y = y, .z = z };
}

pub fn negate(v: Vector3) Vector3 {
    return .{
        .x = -v.x,
        .y = -v.y,
        .z = -v.z,
    };
}

pub fn negateAssign(v: *Vector3) void {
    v.x = -v.x;
    v.y = -v.y;
    v.z = -v.z;
}

pub fn add(a: Vector3, b: Vector3) Vector3 {
     return .{
        .x = a.x + b.x,
        .y = a.y + b.y,
        .z = a.z + b.z,
    };
}

pub fn addAssign(a: *Vector3, b: Vector3) void {
    a.x += b.x;
    a.y += b.y;
    a.z += b.z;
}

pub fn sub(a: Vector3, b: Vector3) Vector3 {
     return .{
        .x = a.x - b.x,
        .y = a.y - b.y,
        .z = a.z - b.z,
    };
}

pub fn subAssign(a: *Vector3, b: Vector3) void {
    a.x -= b.x;
    a.y -= b.y;
    a.z -= b.z;
}

pub fn mul(a: Vector3, b: Vector3) Vector3 {
     return .{
        .x = a.x * b.x,
        .y = a.y * b.y,
        .z = a.z * b.z,
    };
}

pub fn mulAssign(a: *Vector3, b: Vector3) void {
    a.x *= b.x;
    a.y *= b.y;
    a.z *= b.z;
}

pub fn scale(v: Vector3, scalar: f32) Vector3 {
     return .{
        .x = v.x * scalar,
        .y = v.y * scalar,
        .z = v.z * scalar,
    };
}

pub fn scaleAssign(v: *Vector3, scalar: f32) void {
    v.x *= scalar;
    v.y *= scalar;
    v.z *= scalar;
}


pub fn magnitude(self: Vector3) f32 {
    return std.math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
}

pub fn sqrMagnitude(self: Vector3) f32 {
    return self.x * self.x + self.y * self.y + self.z * self.z;
}

pub fn normalized(self: Vector3) Vector3 {
    const length = self.magnitude();
    return .{
        .x = self.x / length,
        .y = self.y / length,
        .z = self.z / length
    };
}

pub fn normalize(self: *Vector3) void {
    const length = self.magnitude();
    self.x /= length;
    self.y /= length;
    self.z /= length;
}

pub fn dot(a: Vector3, b: Vector3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

pub fn cross(a: Vector3, b: Vector3) Vector3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x
    };
}

pub fn reflect(v: Vector3, normal: Vector3) Vector3 {
    return v.sub(normal.scale(Vector3.dot(v, normal) * 2.0));
}

pub fn lerp(a: Vector3, b: Vector3, t: f32) Vector3 {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .z = a.z + (b.z - a.z) * t,
    };
}

pub const fmtColor = std.fmt.Alt(Vector3, colorFormat);

fn colorFormat(v: Vector3, writer: *std.io.Writer) !void {
    try writer.print("{d} {d} {d}", .{
        @as(u8, @intFromFloat(v.x * 255)),
        @as(u8, @intFromFloat(v.y * 255)),
        @as(u8, @intFromFloat(v.z * 255)),
    });
}

fn random() Vector3 {
    const x = (rand.random().float(f32) - 0.5) * 2;
    const y = (rand.random().float(f32) - 0.5) * 2;
    const z = (rand.random().float(f32) - 0.5) * 2;

    return Vector3.init(x, y, z);
}

pub fn randomUnitVector() Vector3 {

    while (true) {
        const p = Vector3.random();
        const magSqr = p.sqrMagnitude();
        if (1e-160 < magSqr and magSqr <= 1)
            return p.scale(1.0 / std.math.sqrt(magSqr));
    }
}

pub fn randomOnHemisphere(normal: Vector3) Vector3 {
    const result = randomUnitVector();
    if(dot(result, normal) > 0.0){
        return result;
    }
    return result.negate();
}

fn linearToGammaComp(x: f32, gamma: f32) f32 {
    return std.math.pow(f32, x, 1.0 / gamma);
}


pub fn linearToGamma(self: Vector3, gamma: f32) Vector3 {
    const r = std.math.pow(f32, self.x, 1.0 / gamma);
    const g = std.math.pow(f32, self.y, 1.0 / gamma);
    const b = std.math.pow(f32, self.z, 1.0 / gamma);

    return Vector3.init(r, g, b);
}

 pub fn isNearZero(self: Vector3) bool {
    const s = 1e-8;
    return @abs(self.x) < s and @abs(self.y) < s and @abs(self.z) < s;
}

pub fn refract(v: Vector3, normal:Vector3, refractiveIndex: f32) Vector3 {
    const cosTheta = @min(dot(v.negate(), normal), 1.0);
    const outPerspective = normal.scale(cosTheta)
        .add(v)
        .scale(refractiveIndex);
    const outParallel = normal.scale(-std.math.sqrt(@abs(1.0 - outPerspective.sqrMagnitude())));
    return outPerspective.add(outParallel);
}
