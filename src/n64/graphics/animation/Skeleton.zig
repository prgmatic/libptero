const std = @import("std");
const math = @import("../../math.zig");
const animation = @import("../animation.zig");
const Node = animation.Node;
const Transform = animation.Transform;

const Skeleton = @This();

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

/// Pack global floating-point matrices directly into caller-owned RSP pose storage. Do not overwrite
/// an in-flight destination; use one pose buffer per outstanding frame.
/// Size the destination with the model's node count (`asset.poseLen()`), not
/// its joint count: skinned glTF models keep their mesh node in `nodes` too.
pub fn writeMatrices(self: *const Skeleton, destination: []math.FixedMat4) void {
    // Checked in every build mode: a short pose silently corrupts memory.
    if (destination.len != self.matrices.len) @panic("pose buffer length must equal the skeleton node count (asset.poseLen())");
    for (destination, self.matrices) |*fixed, *matrix| matrix.writeFixed3x4(fixed);
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
        if (self.nodes[i].parent) |parent| {
            self.matrices[parent].writeAffineProduct(&local, &self.matrices[i]);
        } else self.matrices[i] = local;
    }
}

/// Destination may alias either source. Only local transforms are blended;
/// call update afterward to recalculate the hierarchy.
pub fn blend(self: *Skeleton, a: *const Skeleton, b: *const Skeleton, factor: f32) void {
    if (self.bones.len != a.bones.len or a.bones.len != b.bones.len) @panic("blended skeletons must have the same node count");
    const t = std.math.clamp(factor, 0, 1);
    for (self.bones, a.bones, b.bones) |*out, start, end| out.* = start.blend(end, t);
}

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
