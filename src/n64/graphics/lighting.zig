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

pub const Light = union(enum) {
    directional: struct { color: @import("pixel.zig").Rgba32 = .white, direction: math.Vec3 },
    point: struct { color: @import("pixel.zig").Rgba32 = .white, position: math.Vec3, strength: f32, ignore_normals: bool = false },
};
pub const Lighting = struct {
    ambient: @import("pixel.zig").Rgba32 = .white,
    /// Consumed at beginGeometry, after the camera is attached. World space.
    lights: []const Light = &.{},

    pub fn apply(self: Lighting, context: anytype) void {
        context.setAmbientLight(self.ambient);
        for (self.lights, 0..) |light, index| switch (light) {
            .directional => |value| context.setDirectionalLightAt(@intCast(index), value.color, value.direction),
            .point => |value| context.setPointLightAt(@intCast(index), value.color, value.position, value.strength, value.ignore_normals),
        };
        context.setLightCount(@intCast(self.lights.len));
    }

    /// Copy the point lights that light `position` most into `dest`,
    /// strongest first, and return the filled prefix. Each light adds RSP
    /// work to every lit vertex, so scenes with many light sources should
    /// pass only a few. Influence is strength over squared distance;
    /// directional lights in `candidates` are skipped.
    pub fn strongestAt(dest: []Light, candidates: []const Light, position: math.Vec3) []Light {
        var scores: [max_selection]f32 = undefined;
        const capacity = @min(dest.len, max_selection);
        var count: usize = 0;
        for (candidates) |candidate| {
            const light = switch (candidate) {
                .point => |value| value,
                .directional => continue,
            };
            const offset = light.position.sub(position);
            const score = light.strength / (offset.dot(offset) + 1);
            if (count == capacity and (count == 0 or score <= scores[count - 1])) continue;
            var index = if (count < capacity) count else count - 1;
            while (index > 0 and scores[index - 1] < score) : (index -= 1) {
                scores[index] = scores[index - 1];
                dest[index] = dest[index - 1];
            }
            scores[index] = score;
            dest[index] = candidate;
            if (count < capacity) count += 1;
        }
        return dest[0..count];
    }

    const max_selection = 16;
};

test "strongestAt keeps the most influential point lights in order" {
    const candidates = [_]Light{
        .{ .point = .{ .position = .init(100, 0, 0), .strength = 50 } },
        .{ .directional = .{ .direction = .init(0, 1, 0) } },
        .{ .point = .{ .position = .init(10, 0, 0), .strength = 50 } },
        .{ .point = .{ .position = .init(30, 0, 0), .strength = 50 } },
        .{ .point = .{ .position = .init(20, 0, 0), .strength = 400 } },
    };
    var dest: [2]Light = undefined;
    const chosen = Lighting.strongestAt(&dest, &candidates, .zero);
    try std.testing.expectEqual(@as(usize, 2), chosen.len);
    try std.testing.expectEqual(@as(f32, 20), chosen[0].point.position.x);
    try std.testing.expectEqual(@as(f32, 10), chosen[1].point.position.x);
    var wide: [8]Light = undefined;
    try std.testing.expectEqual(@as(usize, 4), Lighting.strongestAt(&wide, &candidates, .zero).len);
    try std.testing.expectEqual(@as(usize, 0), Lighting.strongestAt(dest[0..0], &candidates, .zero).len);
}
pub const Fog = struct { color: @import("pixel.zig").Rgba32, near: f32, far: f32 };
