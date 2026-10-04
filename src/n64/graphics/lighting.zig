//! Host packing for the geometry overlay's shared directional/point slots.
const std = @import("std");
const math = @import("../math.zig");

pub fn point(view: *const math.Mat4, position: math.Vec3, strength: f32, ignore_normals: bool) [2]u32 {
    const p = view.transformPoint(position);
    const size: u16 = @intFromFloat(std.math.clamp(strength / 8192.0, 0, 0.5) * 65535.0);
    // The low byte distinguishes point lights from directional lights.
    const tagged_size = size | @as(u16, if (size & 255 == 0) 1 else 0) |
        @as(u16, if (ignore_normals) 0x8000 else 0);
    return .{ @as(u32, coordinate(p.x)) << 16 | coordinate(p.y), @as(u32, coordinate(p.z)) << 16 | tagged_size };
}

fn coordinate(value: f32) u16 {
    return @bitCast(@as(i16, @intFromFloat(std.math.clamp(value * 4, -32768, 32767))));
}

test "point slots use view-space quarter units, saturate, and retain their tag" {
    var view = math.Mat4.identity;
    view.m[3] = .{ 2, -3, 4, 1 };
    const words = point(&view, .init(-1, 5, -6), 40, false);
    try std.testing.expectEqual(@as(u32, 0x00040008), words[0]);
    try std.testing.expectEqual(@as(u32, 0xfff8013f), words[1]);
    try std.testing.expectEqual(@as(u32, 0x80007fff), point(&math.Mat4.identity, .init(-1e6, 1e6, 0), 0, false)[0]);
    try std.testing.expectEqual(@as(u32, 1), point(&math.Mat4.identity, .zero, -1, false)[1]);
    try std.testing.expectEqual(@as(u32, 0xffff), point(&math.Mat4.identity, .zero, 1e6, true)[1]);
}
