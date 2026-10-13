const std = @import("std");
const cache = @import("../cpu/cache.zig");
const math = @import("../math.zig");
const rsp = @import("../rsp.zig");
const rdp = @import("../rdp.zig");
const Rgba32 = @import("pixel.zig").Rgba32;

const vertex_output_size = 36;
pub const max_lights = 7;
pub const VertexEffect = union(enum) {
    none,
    /// Sphere-map dimensions in texels. Generated coordinates replace mesh UVs.
    spherical: struct { width: u10, height: u10 },
};

pub const DrawFlags = packed struct(u17) {
    depth: bool = false,
    textured: bool = false,
    shaded: bool = false,
    cull_front: bool = false,
    cull_back: bool = false,
    _padding: u11 = 0,
    no_light: bool = false,
};

pub const VertexPair = extern struct {
    pos_a: [3]i16,
    normal_a: u16,
    pos_b: [3]i16,
    normal_b: u16,
    color_a: Rgba32 align(8),
    color_b: Rgba32,
    uv_a: [2]i16 = .{ 0, 0 },
    uv_b: [2]i16 = .{ 0, 0 },
};

pub fn packNormal(value: math.Vec3) u16 {
    const normal = value.normalized();
    const x: i32 = std.math.clamp(@as(i32, @intFromFloat(@round(normal.x * 15.5))), -16, 15);
    const y: i32 = std.math.clamp(@as(i32, @intFromFloat(@round(normal.y * 31.5))), -32, 31);
    const z: i32 = std.math.clamp(@as(i32, @intFromFloat(@round(normal.z * 15.5))), -16, 15);
    return (@as(u16, @bitCast(@as(i16, @intCast(x)))) & 0x1f) << 11 |
        (@as(u16, @bitCast(@as(i16, @intCast(y)))) & 0x3f) << 5 |
        (@as(u16, @bitCast(@as(i16, @intCast(z)))) & 0x1f);
}

pub const Viewport = @import("Viewport.zig");

pub const GeometryEncoder = @import("GeometryEncoder.zig");

comptime {
    if (@sizeOf(VertexPair) != 32 or @alignOf(VertexPair) < 8) @compileError("geometry vertex ABI mismatch");
}

test {
    _ = @import("lighting.zig");
}
