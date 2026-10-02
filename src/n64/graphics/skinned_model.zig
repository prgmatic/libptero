const std = @import("std");
const math = @import("../math.zig");
const geometry = @import("geometry.zig");
const model_types = @import("model.zig");
const animation = @import("animation.zig");

/// Writable model instance. Allocate one per in-flight frame, or wait for GPU
/// completion before updating again. The borrowed source stays immutable.
pub const SkinnedModel = struct {
    source: model_types.Model,
    parts: []model_types.Part,
    palettes: [][]math.Mat4,

    pub fn init(allocator: std.mem.Allocator, source: model_types.Model) !SkinnedModel {
        try validateModel(source);
        const parts = try allocator.alloc(model_types.Part, source.parts.len);
        errdefer allocator.free(parts);
        var allocated: usize = 0;
        errdefer for (parts[0..allocated]) |part| {
            if (part.skin != null) allocator.free(part.vertices);
        };
        for (source.parts, parts) |part, *destination| {
            destination.* = part;
            if (part.skin != null) {
                destination.vertices = try allocator.dupe(geometry.VertexPair, part.vertices);
                destination.data_usage = .dynamic;
            }
            allocated += 1;
        }
        const palettes = try allocatePalettes(allocator, source.skins);
        errdefer freePalettes(allocator, palettes);
        return .{ .source = source, .parts = parts, .palettes = palettes };
    }

    pub fn deinit(self: *SkinnedModel, allocator: std.mem.Allocator) void {
        freePalettes(allocator, self.palettes);
        for (self.parts) |part| {
            if (part.skin != null) allocator.free(part.vertices);
        }
        allocator.free(self.parts);
        self.* = undefined;
    }

    pub fn model(self: *const SkinnedModel) model_types.Model {
        var result = self.source;
        result.parts = self.parts;
        return result;
    }

    /// Recalculate vertices from the source and updated global bone matrices.
    /// All weights participate; inverse-transpose normals handle nonuniform scale.
    pub fn update(self: *SkinnedModel, skeleton: *const animation.Skeleton) void {
        std.debug.assert(self.source.nodes.ptr == skeleton.nodes.ptr and self.source.nodes.len == skeleton.nodes.len);
        for (self.source.skins, self.palettes) |skin, palette| {
            for (skin.joints, skin.inverse_bind_matrices, palette) |joint, inverse_bind, *matrix| {
                matrix.* = skeleton.matrices[joint].mul(&inverse_bind);
            }
        }
        for (self.source.parts, self.parts) |source, destination| {
            if (source.skin) |skin| self.updatePart(source, @constCast(destination.vertices), skin);
        }
    }

    fn updatePart(self: *SkinnedModel, source: model_types.Part, vertices: []geometry.VertexPair, skin: u16) void {
        const palette = self.palettes[skin];
        for (source.influences, 0..) |influence, i| {
            const pair = &vertices[i / 2];
            const original = source.vertices[i / 2];
            if (i % 2 == 0) {
                skinVertex(&pair.pos_a, &pair.normal_a, original.pos_a, original.normal_a, influence, palette);
            } else {
                skinVertex(&pair.pos_b, &pair.normal_b, original.pos_b, original.normal_b, influence, palette);
            }
        }
    }
};

fn validateModel(source: model_types.Model) !void {
    for (source.skins) |skin| {
        if (skin.joints.len != skin.inverse_bind_matrices.len) return error.InvalidSkin;
        for (skin.joints) |joint| if (joint >= source.nodes.len) return error.InvalidJoint;
    }
    for (source.parts) |part| try validatePart(source, part);
}
fn validatePart(source: model_types.Model, part: model_types.Part) !void {
    if (part.vertices.len * 2 < part.vertex_count) return error.InvalidVertices;
    const skin = part.skin orelse return;
    if (skin >= source.skins.len) return error.InvalidSkin;
    try validateInfluenceCount(part);
    for (part.influences) |influence| try validateInfluence(influence, source.skins[skin].joints.len);
}
fn validateInfluenceCount(part: model_types.Part) !void {
    if (part.influences.len < part.vertex_count or part.influences.len > part.vertices.len * 2) return error.InvalidInfluences;
}
fn validateInfluence(influence: animation.Influence, joint_count: usize) !void {
    for (influence.weights, influence.joints) |weight, joint| {
        if (!std.math.isFinite(weight) or weight < 0) return error.InvalidWeight;
        if (weight > 0 and joint >= joint_count) return error.InvalidJoint;
    }
}

fn allocatePalettes(allocator: std.mem.Allocator, skins: []const animation.Skin) ![][]math.Mat4 {
    const result = try allocator.alloc([]math.Mat4, skins.len);
    errdefer allocator.free(result);
    var count: usize = 0;
    errdefer for (result[0..count]) |palette| allocator.free(palette);
    for (skins, result) |skin, *palette| {
        if (skin.joints.len != skin.inverse_bind_matrices.len) return error.InvalidSkin;
        palette.* = try allocator.alloc(math.Mat4, skin.joints.len);
        count += 1;
    }
    return result;
}
fn freePalettes(allocator: std.mem.Allocator, palettes: [][]math.Mat4) void {
    for (palettes) |palette| allocator.free(palette);
    allocator.free(palettes);
}
fn skinVertex(position_out: *[3]i16, normal_out: *u16, position: [3]i16, packed_normal: u16, influence: animation.Influence, palette: []const math.Mat4) void {
    const input = math.Vec3.init(@floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]));
    const normal = unpackNormal(packed_normal);
    var blended: math.Mat4 = .{ .m = @splat(@splat(0)) };
    var weight_sum: f32 = 0;
    for (influence.joints, influence.weights) |joint, weight| {
        if (weight == 0) continue;
        addWeightedMatrix(&blended, palette[joint], weight);
        weight_sum += weight;
    }
    if (weight_sum <= 0) {
        position_out.* = position;
        normal_out.* = packed_normal;
        return;
    }
    const result = blended.transformPoint(input).xyz().scale(1 / weight_sum);
    const normal_matrix = normalMatrix(blended);
    position_out.* = .{ quantize(result.x), quantize(result.y), quantize(result.z) };
    normal_out.* = geometry.packNormal(normal_matrix.transformDirection(normal));
}
fn addWeightedMatrix(destination: *math.Mat4, matrix: math.Mat4, weight: f32) void {
    for (0..4) |column| for (0..3) |row| {
        destination.m[column][row] += matrix.m[column][row] * weight;
    };
}
fn quantize(value: f32) i16 {
    return @intFromFloat(std.math.clamp(@round(value), -32768, 32767));
}
fn unpackNormal(value: u16) math.Vec3 {
    const x: i5 = @bitCast(@as(u5, @truncate(value >> 11)));
    const y: i6 = @bitCast(@as(u6, @truncate(value >> 5)));
    const z: i5 = @bitCast(@as(u5, @truncate(value)));
    return math.Vec3.init(@as(f32, @floatFromInt(x)) / 15.5, @as(f32, @floatFromInt(y)) / 31.5, @as(f32, @floatFromInt(z)) / 15.5).normalized();
}
fn normalMatrix(matrix: math.Mat4) math.Mat4 {
    const a = math.Vec3.init(matrix.m[0][0], matrix.m[0][1], matrix.m[0][2]);
    const b = math.Vec3.init(matrix.m[1][0], matrix.m[1][1], matrix.m[1][2]);
    const c = math.Vec3.init(matrix.m[2][0], matrix.m[2][1], matrix.m[2][2]);
    const determinant = a.dot(b.cross(c));
    // A collapsed axis has no unique inverse; avoid NaNs during interactive edits.
    if (@abs(determinant) < 0.00000001) return matrix;
    const x = b.cross(c).scale(1 / determinant);
    const y = c.cross(a).scale(1 / determinant);
    const z = a.cross(b).scale(1 / determinant);
    return .{ .m = .{ .{ x.x, x.y, x.z, 0 }, .{ y.x, y.y, y.z, 0 }, .{ z.x, z.y, z.z, 0 }, .{ 0, 0, 0, 1 } } };
}

test "weighted skinning keeps immutable source and preserves per-instance pose" {
    const allocator = std.testing.allocator;
    const vertices = [_]geometry.VertexPair{.{ .pos_a = .{ 2, 0, 0 }, .normal_a = geometry.packNormal(.init(1, 1, 0)), .pos_b = .{ 0, 1, 0 }, .normal_b = 0, .color_a = .fromBytes(255, 255, 255, 255), .color_b = .fromBytes(255, 255, 255, 255) }};
    const influences = [_]animation.Influence{ .{ .joints = .{ 0, 1, 0, 0 }, .weights = .{ 0.25, 0.75, 0, 0 } }, .{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ 0, 0, 0, 0 } } };
    const parts = [_]model_types.Part{.{ .vertices = &vertices, .material_index = 0, .vertex_count = 2, .skin = 0, .influences = &influences }};
    const skins = [_]animation.Skin{.{ .joints = &.{ 0, 1 }, .inverse_bind_matrices = &.{ math.Mat4.identity, math.Mat4.identity } }};
    const nodes = [_]animation.Node{ .{ .transform = .{ .translation = .init(4, 0, 0) } }, .{ .transform = .{ .translation = .init(8, 0, 0) } } };
    const source: model_types.Model = .{ .parts = &parts, .skins = &skins, .nodes = &nodes };
    var skeleton = try animation.Skeleton.init(allocator, &nodes);
    defer skeleton.deinit(std.testing.allocator);
    var first = try SkinnedModel.init(allocator, source);
    defer first.deinit(std.testing.allocator);
    var second = try SkinnedModel.init(allocator, source);
    defer second.deinit(std.testing.allocator);
    first.update(&skeleton);
    try std.testing.expectEqual(@as(i16, 9), first.parts[0].vertices[0].pos_a[0]);
    try std.testing.expectEqual(@as(i16, 2), source.parts[0].vertices[0].pos_a[0]);
    try std.testing.expectEqual(@as(i16, 2), second.parts[0].vertices[0].pos_a[0]);
    try std.testing.expectEqualDeep(vertices[0].pos_b, first.parts[0].vertices[0].pos_b);
    skeleton.bones[0].translation = .zero;
    skeleton.bones[1].translation = .zero;
    skeleton.bones[0].scale = .init(2, 1, 1);
    skeleton.bones[1].scale = .one;
    skeleton.update();
    first.update(&skeleton);
    const normal = unpackNormal(first.parts[0].vertices[0].normal_a);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 1.25), normal.x / normal.y, 0.05);
    try std.testing.expectEqual(@as(i16, 3), first.model().parts[0].vertices[0].pos_a[0]);
}

test "four joint weights and separate skin palettes preserve the bind pose" {
    const nodes = [_]animation.Node{
        .{ .transform = .{ .translation = .init(5, 0, 0), .rotation = .fromAxisAngle(.init(0, 0, 1), std.math.pi / 2.0) } },
        .{ .parent = 0, .transform = .{ .translation = .init(2, 0, 0) } },
        .{},
        .{},
    };
    var skeleton = try animation.Skeleton.init(std.testing.allocator, &nodes);
    defer skeleton.deinit(std.testing.allocator);
    // Child global T(5,0) Rz(90) T(2,0); inverse is T(-2,0) Rz(-90) T(-5,0).
    const inverse_r = math.Mat4.fromSrt(.one, .fromAxisAngle(.init(0, 0, 1), -std.math.pi / 2.0), .zero);
    const inverse_t = math.Mat4.fromSrt(.one, .identity, .init(-5, 0, 0));
    const inverse_child_t = math.Mat4.fromSrt(.one, .identity, .init(-2, 0, 0));
    const inverse_parent = inverse_r.mul(&inverse_t);
    const inverse_child = inverse_child_t.mul(&inverse_parent);
    const skins = [_]animation.Skin{
        .{ .joints = &.{ 0, 1, 2, 3 }, .inverse_bind_matrices = &.{ inverse_parent, inverse_child, math.Mat4.identity, math.Mat4.identity } },
        .{ .joints = &.{1}, .inverse_bind_matrices = &.{inverse_child} },
    };
    const vertices = [_]geometry.VertexPair{.{ .pos_a = .{ 4, 3, 0 }, .normal_a = geometry.packNormal(.init(1, 0, 0)), .pos_b = .{ 0, 0, 0 }, .normal_b = 0, .color_a = .fromBytes(255, 255, 255, 255), .color_b = .fromBytes(255, 255, 255, 255) }};
    const parts = [_]model_types.Part{
        .{ .vertices = &vertices, .material_index = 0, .vertex_count = 1, .skin = 0, .influences = &.{.{ .joints = .{ 0, 1, 2, 3 }, .weights = .{ 0.1, 0.2, 0.3, 0.4 } }} },
        .{ .vertices = &vertices, .material_index = 0, .vertex_count = 1, .skin = 1, .influences = &.{.{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } }} },
        .{ .vertices = &vertices, .material_index = 0, .vertex_count = 1 },
    };
    const source: model_types.Model = .{ .nodes = &nodes, .skins = &skins, .parts = &parts };
    var instance = try SkinnedModel.init(std.testing.allocator, source);
    defer instance.deinit(std.testing.allocator);
    instance.update(&skeleton);
    for (instance.parts) |part| try std.testing.expectEqualDeep(vertices[0].pos_a, part.vertices[0].pos_a);
    try std.testing.expect(instance.parts[2].vertices.ptr == vertices[0..].ptr);
    skeleton.bones[2].translation.x = 10;
    skeleton.bones[3].translation.x = 20;
    skeleton.update();
    instance.update(&skeleton);
    try std.testing.expectEqual(@as(i16, 15), instance.parts[0].vertices[0].pos_a[0]);
    try std.testing.expectEqualDeep(vertices[0].pos_a, instance.parts[1].vertices[0].pos_a);
}

fn allocationFixture(allocator: std.mem.Allocator) !void {
    const vertices = [_]geometry.VertexPair{.{ .pos_a = .{ 0, 0, 0 }, .normal_a = 0, .pos_b = .{ 0, 0, 0 }, .normal_b = 0, .color_a = .fromBytes(255, 255, 255, 255), .color_b = .fromBytes(255, 255, 255, 255) }};
    const source: model_types.Model = .{ .nodes = &.{.{}}, .skins = &.{.{ .joints = &.{0}, .inverse_bind_matrices = &.{math.Mat4.identity} }}, .parts = &.{.{ .vertices = &vertices, .vertex_count = 1, .material_index = 0, .skin = 0, .influences = &.{.{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } }} }} };
    var instance = try SkinnedModel.init(allocator, source);
    defer instance.deinit(allocator);
}

test "skinned model validates native metadata and cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
    try std.testing.expectError(error.InvalidSkin, SkinnedModel.init(std.testing.allocator, .{ .parts = &.{}, .skins = &.{.{ .joints = &.{0}, .inverse_bind_matrices = &.{} }} }));
    try std.testing.expectError(error.InvalidJoint, SkinnedModel.init(std.testing.allocator, .{ .parts = &.{}, .skins = &.{.{ .joints = &.{0}, .inverse_bind_matrices = &.{math.Mat4.identity} }} }));
    try std.testing.expectError(error.InvalidWeight, validateInfluence(.{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ -1, 0, 0, 0 } }, 1));
    try std.testing.expectError(error.InvalidJoint, validateInfluence(.{ .joints = .{ 1, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } }, 1));
}
