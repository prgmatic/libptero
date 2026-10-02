const std = @import("std");
const math = @import("../math.zig");

pub const Transform = struct {
    translation: math.Vec3 = .zero,
    rotation: math.Quat = .identity,
    scale: math.Vec3 = .one,

    pub fn matrix(self: Transform) math.Mat4 {
        return .fromSrt(self.scale, self.rotation, self.translation);
    }

    pub fn blend(a: Transform, b: Transform, factor: f32) Transform {
        return .{
            .translation = a.translation.lerp(b.translation, factor),
            .rotation = a.rotation.nlerp(b.rotation, factor),
            .scale = a.scale.lerp(b.scale, factor),
        };
    }
};

pub const Node = struct {
    name: []const u8 = "",
    parent: ?u16 = null,
    transform: Transform = .{},
};
pub const Skin = struct {
    joints: []const u16,
    inverse_bind_matrices: []const math.Mat4,
};
pub const Influence = struct {
    joints: [4]u16,
    weights: [4]f32,
};
pub const Path = enum { translation, rotation, scale };
pub const Interpolation = enum { linear, step, cubic_spline };
pub const Track = struct {
    node: u16,
    path: Path,
    interpolation: Interpolation = .linear,
    times: []const f32,
    /// Cubic tracks contain incoming tangent, value, outgoing tangent per key.
    values: []const [4]f32,

    pub fn sample(self: Track, time: f32) [4]f32 {
        std.debug.assert(self.times.len > 0);
        if (time <= self.times[0]) return self.key(0);
        const last = self.times.len - 1;
        if (time >= self.times[last]) return self.key(last);
        const low = self.segment(time);
        const high = low + 1;
        return self.interpolate(low, high, time);
    }

    fn segment(self: Track, time: f32) usize {
        var low: usize = 0;
        var high: usize = self.times.len - 1;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (self.times[middle] <= time) low = middle else high = middle;
        }
        return low;
    }

    fn interpolate(self: Track, low: usize, high: usize, time: f32) [4]f32 {
        if (self.interpolation == .step) return self.key(low);
        const duration = self.times[high] - self.times[low];
        const t = (time - self.times[low]) / duration;
        const a = self.key(low);
        const b = self.key(high);
        if (self.interpolation == .cubic_spline) return self.cubic(low, high, t, duration);
        if (self.path == .rotation) return quaternionArray(slerp(arrayQuaternion(a), arrayQuaternion(b), t));
        var result: [4]f32 = undefined;
        for (&result, a, b) |*value, start, end| value.* = math.lerp(start, end, t);
        return result;
    }

    fn key(self: Track, index: usize) [4]f32 {
        return self.values[if (self.interpolation == .cubic_spline) index * 3 + 1 else index];
    }

    fn cubic(self: Track, low: usize, high: usize, t: f32, duration: f32) [4]f32 {
        const t2 = t * t;
        const t3 = t2 * t;
        var result: [4]f32 = undefined;
        for (&result, 0..) |*value, i| {
            value.* = (2 * t3 - 3 * t2 + 1) * self.key(low)[i] +
                (t3 - 2 * t2 + t) * duration * self.values[low * 3 + 2][i] +
                (-2 * t3 + 3 * t2) * self.key(high)[i] +
                (t3 - t2) * duration * self.values[high * 3][i];
        }
        return if (self.path == .rotation) quaternionArray(arrayQuaternion(result).normalized()) else result;
    }
};
pub const Clip = struct {
    name: []const u8,
    duration: f32,
    tracks: []const Track,
};

/// Mutable node transforms and global matrices. Definitions stay borrowed.
/// Hierarchies are validated and ordered once; update performs no allocation.
pub const Skeleton = struct {
    nodes: []const Node,
    bones: []Transform,
    matrices: []math.Mat4,
    order: []u16,

    pub fn init(allocator: std.mem.Allocator, nodes: []const Node) !Skeleton {
        if (nodes.len > std.math.maxInt(u16)) return error.TooManyNodes;
        const bones = try allocator.alloc(Transform, nodes.len);
        errdefer allocator.free(bones);
        const matrices = try allocator.alloc(math.Mat4, nodes.len);
        errdefer allocator.free(matrices);
        const order = try allocator.alloc(u16, nodes.len);
        errdefer allocator.free(order);
        const states = try allocator.alloc(u2, nodes.len);
        defer allocator.free(states);
        @memset(states, 0);
        var count: usize = 0;
        for (nodes, 0..) |_, i| try visit(nodes, states, order, &count, i);
        var result: Skeleton = .{ .nodes = nodes, .bones = bones, .matrices = matrices, .order = order };
        result.reset();
        result.update();
        return result;
    }

    pub fn deinit(self: *Skeleton, allocator: std.mem.Allocator) void {
        allocator.free(self.order);
        allocator.free(self.matrices);
        allocator.free(self.bones);
        self.* = undefined;
    }

    pub fn reset(self: *Skeleton) void {
        for (self.bones, self.nodes) |*bone, node| bone.* = node.transform;
    }

    pub fn findBone(self: *const Skeleton, name: []const u8) ?u16 {
        for (self.nodes, 0..) |node, i| if (std.mem.eql(u8, node.name, name)) return @intCast(i);
        return null;
    }

    pub fn update(self: *Skeleton) void {
        for (self.order) |i| {
            const local = self.bones[i].matrix();
            self.matrices[i] = if (self.nodes[i].parent) |parent| self.matrices[parent].mul(&local) else local;
        }
    }

    /// Destination may alias either source. Only local transforms are blended;
    /// call update afterward to recalculate the hierarchy.
    pub fn blend(self: *Skeleton, a: *const Skeleton, b: *const Skeleton, factor: f32) void {
        std.debug.assert(self.bones.len == a.bones.len and a.bones.len == b.bones.len);
        const t = std.math.clamp(factor, 0, 1);
        for (self.bones, a.bones, b.bones) |*out, start, end| out.* = start.blend(end, t);
    }
};

fn visit(nodes: []const Node, states: []u2, order: []u16, count: *usize, index: usize) !void {
    switch (states[index]) {
        1 => return error.CyclicHierarchy,
        2 => return,
        else => {},
    }
    states[index] = 1;
    if (nodes[index].parent) |parent| {
        if (parent >= nodes.len) return error.InvalidParent;
        try visit(nodes, states, order, count, parent);
    }
    states[index] = 2;
    order[count.*] = @intCast(index);
    count.* += 1;
}

/// Independent playback state borrowing an immutable clip. Applying only writes
/// targeted properties, so a later player can override an earlier player's pose.
pub const Player = struct {
    clip: *const Clip,
    time: f32 = 0,
    speed: f32 = 1,
    playing: bool = true,
    looping: bool = true,

    pub fn seek(self: *Player, time: f32) void {
        self.time = std.math.clamp(time, 0, self.clip.duration);
    }

    pub fn update(self: *Player, skeleton: *Skeleton, delta: f32) void {
        if (self.playing) {
            self.time += delta * self.speed;
            self.wrap();
        }
        self.apply(skeleton);
    }

    fn wrap(self: *Player) void {
        if (self.clip.duration <= 0) {
            self.time = 0;
            self.playing = false;
        } else if (self.looping) {
            self.time = @mod(self.time, self.clip.duration);
        } else if (self.reachedEnd()) {
            self.time = std.math.clamp(self.time, 0, self.clip.duration);
            self.playing = false;
        }
    }

    fn reachedEnd(self: *const Player) bool {
        return if (self.speed < 0) self.time <= 0 else self.time >= self.clip.duration;
    }

    pub fn apply(self: *const Player, skeleton: *Skeleton) void {
        for (self.clip.tracks) |track| {
            const value = track.sample(self.time);
            const bone = &skeleton.bones[track.node];
            switch (track.path) {
                .translation => bone.translation = .init(value[0], value[1], value[2]),
                .scale => bone.scale = .init(value[0], value[1], value[2]),
                .rotation => bone.rotation = arrayQuaternion(value).normalized(),
            }
        }
    }
};

fn arrayQuaternion(value: [4]f32) math.Quat {
    return .{ .x = value[0], .y = value[1], .z = value[2], .w = value[3] };
}
fn quaternionArray(value: math.Quat) [4]f32 {
    return .{ value.x, value.y, value.z, value.w };
}
fn slerp(a: math.Quat, input_b: math.Quat, t: f32) math.Quat {
    var b = input_b;
    var dot = a.dot(b);
    if (dot < 0) {
        b = .{ .x = -b.x, .y = -b.y, .z = -b.z, .w = -b.w };
        dot = -dot;
    }
    if (dot > 0.9995) return a.nlerp(b, t);
    const angle = std.math.acos(std.math.clamp(dot, -1, 1));
    const denominator = @sin(angle);
    const x = @sin((1 - t) * angle) / denominator;
    const y = @sin(t * angle) / denominator;
    return .{ .x = a.x * x + b.x * y, .y = a.y * x + b.y * y, .z = a.z * x + b.z * y, .w = a.w * x + b.w * y };
}

test "hierarchy supports unordered nodes, attachment matrices, reset and aliased blending" {
    const nodes = [_]Node{
        .{ .name = "child", .parent = 1, .transform = .{ .translation = .init(0, 2, 0) } },
        .{ .name = "root", .transform = .{ .translation = .init(3, 0, 0) } },
    };
    var skeleton = try Skeleton.init(std.testing.allocator, &nodes);
    defer skeleton.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u16, 0), skeleton.findBone("child"));
    try std.testing.expectEqual(@as(?u16, null), skeleton.findBone("missing"));
    try std.testing.expectEqual(@as(f32, 3), skeleton.matrices[0].m[3][0]);
    try std.testing.expectEqual(@as(f32, 2), skeleton.matrices[0].m[3][1]);
    var other = try Skeleton.init(std.testing.allocator, &nodes);
    defer other.deinit(std.testing.allocator);
    other.bones[1].translation.x = 7;
    skeleton.blend(&skeleton, &other, 0.5);
    skeleton.update();
    try std.testing.expectEqual(@as(f32, 5), skeleton.matrices[0].m[3][0]);
    skeleton.reset();
    skeleton.update();
    try std.testing.expectEqual(@as(f32, 3), skeleton.matrices[0].m[3][0]);
    try std.testing.expectError(error.CyclicHierarchy, Skeleton.init(std.testing.allocator, &.{.{ .parent = 0 }}));
    try std.testing.expectError(error.InvalidParent, Skeleton.init(std.testing.allocator, &.{.{ .parent = 1 }}));
}

test "players loop, seek while paused, override properties and stop at final pose" {
    const times = [_]f32{ 0, 1 };
    const tracks = [_]Track{.{ .node = 0, .path = .translation, .times = &times, .values = &.{ .{ 0, 0, 0, 0 }, .{ 10, 0, 0, 0 } } }};
    const clip: Clip = .{ .name = "move", .duration = 1, .tracks = &tracks };
    var skeleton = try Skeleton.init(std.testing.allocator, &.{.{}});
    defer skeleton.deinit(std.testing.allocator);
    var player: Player = .{ .clip = &clip };
    player.update(&skeleton, 2.25);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), skeleton.bones[0].translation.x, 0.00001);
    player.playing = false;
    player.seek(0.75);
    player.update(&skeleton, 1);
    try std.testing.expectEqual(@as(f32, 7.5), skeleton.bones[0].translation.x);
    player.looping = false;
    player.playing = true;
    player.update(&skeleton, 1);
    try std.testing.expect(!player.playing);
    try std.testing.expectEqual(@as(f32, 10), skeleton.bones[0].translation.x);
    player.looping = true;
    player.playing = true;
    player.speed = -1;
    player.seek(0.25);
    player.update(&skeleton, 0.5);
    try std.testing.expectEqual(@as(f32, 0.75), player.time);
}

test "step, cubic Hermite and shortest quaternion interpolation" {
    const times = [_]f32{ 0, 2 };
    var track: Track = .{ .node = 0, .path = .translation, .interpolation = .step, .times = &times, .values = &.{ .{ 2, 0, 0, 0 }, .{ 6, 0, 0, 0 } } };
    try std.testing.expectEqual(@as(f32, 2), track.sample(1)[0]);
    try std.testing.expectEqual(@as(f32, 6), track.sample(2)[0]);
    track.interpolation = .cubic_spline;
    track.values = &.{ .{ 0, 0, 0, 0 }, .{ 2, 0, 0, 0 }, .{ 2, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 6, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    try std.testing.expectEqual(@as(f32, 4.5), track.sample(1)[0]);
    track.path = .rotation;
    track.interpolation = .linear;
    track.values = &.{ .{ 0, 0, 0, 1 }, .{ 0, 0, -1, 0 } };
    const q = track.sample(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710677), @abs(q[2]), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710677), q[3], 0.00001);
}

test "sparse channels and later players preserve unrelated authored properties" {
    const nodes = [_]Node{ .{ .transform = .{ .scale = .init(2, 3, 4), .rotation = .fromAxisAngle(.init(0, 1, 0), 0.7) } }, .{ .transform = .{ .translation = .init(5, 6, 7) } } };
    var skeleton = try Skeleton.init(std.testing.allocator, &nodes);
    defer skeleton.deinit(std.testing.allocator);
    const base: Clip = .{ .name = "base", .duration = 2, .tracks = &.{.{ .node = 0, .path = .translation, .times = &.{ 0, 2 }, .values = &.{ .{ 0, 0, 0, 0 }, .{ 4, 0, 0, 0 } } }} };
    const override: Clip = .{ .name = "override", .duration = 2, .tracks = &.{.{ .node = 0, .path = .translation, .times = &.{0}, .values = &.{.{ 9, 0, 0, 0 }} }} };
    var first: Player = .{ .clip = &base };
    var second: Player = .{ .clip = &override };
    first.update(&skeleton, 1);
    second.update(&skeleton, 1);
    try std.testing.expectEqual(@as(f32, 9), skeleton.bones[0].translation.x);
    try std.testing.expectEqualDeep(nodes[0].transform.rotation, skeleton.bones[0].rotation);
    try std.testing.expectEqualDeep(nodes[0].transform.scale, skeleton.bones[0].scale);
    try std.testing.expectEqualDeep(nodes[1].transform, skeleton.bones[1]);
    first.speed = -1;
    first.looping = false;
    first.update(&skeleton, 1);
    try std.testing.expect(!first.playing);
    try std.testing.expectEqual(@as(f32, 0), first.time);
    const still: Clip = .{ .name = "still", .duration = 0, .tracks = &.{} };
    second = .{ .clip = &still };
    second.update(&skeleton, 2);
    try std.testing.expect(!second.playing);
    try std.testing.expectEqual(@as(f32, 0), second.time);
}

test "quaternion blending accepts opposite signs and cubic sampling normalizes" {
    const a: Transform = .{};
    const b: Transform = .{ .rotation = .{ .x = 0, .y = 0, .z = 0, .w = -1 } };
    const mixed = a.blend(b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(mixed.rotation.w), 0.00001);
    const cubic: Track = .{ .node = 0, .path = .rotation, .interpolation = .cubic_spline, .times = &.{ 0, 1 }, .values = &.{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 1 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 0 } } };
    const q = arrayQuaternion(cubic.sample(0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 1), q.dot(q), 0.00001);
    try std.testing.expect(q.z > 0 and q.w > 0);
}

fn allocationFixture(allocator: std.mem.Allocator) !void {
    var skeleton = try Skeleton.init(allocator, &.{ .{}, .{ .parent = 0 } });
    defer skeleton.deinit(allocator);
}

test "skeleton frees partially allocated instances" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}
