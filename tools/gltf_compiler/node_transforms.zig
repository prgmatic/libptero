//! Bake static mesh node transforms without introducing runtime matrix storage.
const std = @import("std");
const compiler = @import("compiler.zig");
const rig = @import("rig.zig");
const Matrix = [4][4]f32;
const identity: Matrix = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };

pub fn bakeNode(document: compiler.Document, index: usize, batches: []compiler.Batch, scale: f32) !void {
    // Skinned vertices are in the source mesh's local coordinates. Global joint
    // matrices and inverse binds perform the complete skin transform at runtime.
    if (document.nodes[index].skin != null) return;
    const matrix = try globalMatrix(document.nodes, @intCast(index), scale);
    for (batches) |batch| try bakeVertices(matrix, batch.vertices);
}

fn bakeVertices(matrix: Matrix, vertices: []compiler.Vertex) !void {
    for (vertices) |*vertex| {
        vertex.position = try position(matrix, vertex.position);
        vertex.normal = normal(matrix, vertex.normal);
    }
}

fn globalMatrix(nodes: []const rig.Node, index: u16, scale: f32) !Matrix {
    const local = localMatrix(nodes[index], scale);
    return if (try rig.parent(nodes, index)) |parent| multiply(try globalMatrix(nodes, parent, scale), local) else local;
}

fn localMatrix(node: rig.Node, scale: f32) Matrix {
    const x = node.rotation[0];
    const y = node.rotation[1];
    const z = node.rotation[2];
    const w = node.rotation[3];
    return .{
        .{ node.scale[0] * (1 - 2 * (y * y + z * z)), node.scale[0] * 2 * (x * y + w * z), node.scale[0] * 2 * (x * z - w * y), 0 },
        .{ node.scale[1] * 2 * (x * y - w * z), node.scale[1] * (1 - 2 * (x * x + z * z)), node.scale[1] * 2 * (y * z + w * x), 0 },
        .{ node.scale[2] * 2 * (x * z + w * y), node.scale[2] * 2 * (y * z - w * x), node.scale[2] * (1 - 2 * (x * x + y * y)), 0 },
        .{ node.translation[0] * scale, node.translation[1] * scale, node.translation[2] * scale, 1 },
    };
}

fn multiply(a: Matrix, b: Matrix) Matrix {
    var result: Matrix = undefined;
    for (0..4) |column| for (0..4) |row| {
        result[column][row] = 0;
        for (0..4) |k| result[column][row] += a[k][row] * b[column][k];
    };
    return result;
}

fn position(matrix: Matrix, value: [3]i16) ![3]i16 {
    var result: [3]i16 = undefined;
    for (0..3) |row| {
        var transformed = matrix[3][row];
        for (0..3) |column| transformed += matrix[column][row] * @as(f32, @floatFromInt(value[column]));
        transformed = @round(transformed);
        if (!std.math.isFinite(transformed) or transformed < -32768 or transformed > 32767) return error.PositionOutOfRange;
        result[row] = @intFromFloat(transformed);
    }
    return result;
}

fn normal(matrix: Matrix, packed_normal: u16) u16 {
    const x: i5 = @bitCast(@as(u5, @truncate(packed_normal >> 11)));
    const y: i6 = @bitCast(@as(u6, @truncate(packed_normal >> 5)));
    const z: i5 = @bitCast(@as(u5, @truncate(packed_normal)));
    const value = [3]f32{ @as(f32, @floatFromInt(x)) / 15.5, @as(f32, @floatFromInt(y)) / 31.5, @as(f32, @floatFromInt(z)) / 15.5 };
    const cofactors = [3][3]f32{
        cross(matrix[1][0..3].*, matrix[2][0..3].*),
        cross(matrix[2][0..3].*, matrix[0][0..3].*),
        cross(matrix[0][0..3].*, matrix[1][0..3].*),
    };
    const determinant = matrix[0][0] * cofactors[0][0] + matrix[0][1] * cofactors[0][1] + matrix[0][2] * cofactors[0][2];
    if (@abs(determinant) < 0.000001) return 0;
    var result: [3]f32 = @splat(0);
    for (0..3) |row| for (0..3) |column| {
        result[row] += cofactors[column][row] * value[column] / determinant;
    };
    return compiler.packNormal(result);
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

test "child static mesh inherits parent SRT in scaled coordinates" {
    const nodes = [_]rig.Node{
        .{ .mesh = 0, .translation = .{ 0, 2, 0 } },
        .{ .children = &.{0}, .translation = .{ 1, 0, 0 }, .scale = .{ 2, 2, 2 } },
    };
    const matrix = try globalMatrix(&nodes, 0, 64);
    try std.testing.expectEqual([3]i16{ 66, 256, 0 }, try position(matrix, .{ 1, 0, 0 }));
    try std.testing.expectEqual(compiler.packNormal(.{ 0, 1, 0 }), normal(matrix, compiler.packNormal(.{ 0, 1, 0 })));
    try std.testing.expectEqualDeep(identity, localMatrix(.{}, 64));
}

test "inverse transpose handles nonuniform scaling and zero scale" {
    const matrix = localMatrix(.{ .scale = .{ 2, 1, 1 } }, 64);
    const result = normal(matrix, compiler.packNormal(.{ 1, 1, 0 }));
    try std.testing.expectEqual(compiler.packNormal(.{ 0.5 * 11.0 / 15.5, 22.0 / 31.5, 0 }), result);
    try std.testing.expectEqual(@as(u16, 0), normal(localMatrix(.{ .scale = .{ 0, 0, 0 } }, 64), 0xffff));
}
