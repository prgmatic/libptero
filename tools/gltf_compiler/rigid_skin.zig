//! First-joint bind-local batches, matching the Tiny3D rigid-skin contract.
const std = @import("std");
const compiler = @import("compiler.zig");
const rig = @import("rig.zig");
const Matrix = [4][4]f32;

pub fn prepare(allocator: std.mem.Allocator, document: compiler.Document, binary: []const u8, batches: []compiler.Batch, scale: f32) !void {
    for (batches) |*batch| {
        const skin_index = batch.skin orelse continue;
        try prepareBatch(allocator, document, binary, batch, document.skins[skin_index], scale);
    }
}

fn prepareBatch(allocator: std.mem.Allocator, document: compiler.Document, binary: []const u8, batch: *compiler.Batch, skin: rig.Skin, scale: f32) !void {
    const inverse = try rig.inverseBindView(document, binary, skin);
    for (batch.vertices) |*vertex| {
        const joint = vertex.influence.joints[0];
        if (joint >= skin.joints.len) return error.InvalidSkinJoint;
        try transformVertex(vertex, try inverseBindMatrix(inverse, joint, scale));
    }
    try groupVertices(allocator, batch, skin.joints);
}

fn inverseBindMatrix(inverse: ?compiler.AccessorView, joint: usize, scale: f32) !Matrix {
    var matrix: Matrix = undefined;
    for (0..4) |column| for (0..4) |row| {
        matrix[column][row] = try rig.inverseBindCoefficient(inverse, joint, column, row, scale);
    };
    return matrix;
}

fn transformVertex(vertex: *compiler.Vertex, matrix: Matrix) !void {
    vertex.position = try transformPosition(vertex.source_position orelse unpackPosition(vertex.position), matrix);
    vertex.normal = transformNormal(vertex.source_normal orelse unpackNormal(vertex.normal), matrix);
}

fn unpackPosition(position: [3]i16) [3]f32 {
    return .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
}

fn transformPosition(source: [3]f32, matrix: Matrix) ![3]i16 {
    var position: [3]i16 = undefined;
    for (0..3) |row| {
        var value = matrix[3][row];
        for (0..3) |column| value += matrix[column][row] * source[column];
        value = @round(value);
        if (!std.math.isFinite(value) or value < -32768 or value > 32767) return error.PositionOutOfRange;
        position[row] = @intFromFloat(value);
    }
    return position;
}

fn unpackNormal(normal: u16) [3]f32 {
    const x: i5 = @bitCast(@as(u5, @truncate(normal >> 11)));
    const y: i6 = @bitCast(@as(u6, @truncate(normal >> 5)));
    const z: i5 = @bitCast(@as(u5, @truncate(normal)));
    return .{ @as(f32, @floatFromInt(x)) / 15.5, @as(f32, @floatFromInt(y)) / 31.5, @as(f32, @floatFromInt(z)) / 15.5 };
}

fn transformNormal(normal: [3]f32, matrix: Matrix) u16 {
    var transformed: [3]f32 = @splat(0);
    for (0..3) |row| for (0..3) |column| {
        transformed[row] += matrix[column][row] * normal[column];
    };
    return compiler.packNormal(transformed);
}

fn groupVertices(allocator: std.mem.Allocator, batch: *compiler.Batch, joints: []const u16) !void {
    const reordered = try allocator.alloc(compiler.Vertex, batch.vertices.len);
    errdefer allocator.free(reordered);
    var remap: [70]u8 = undefined;
    var groups: std.ArrayList(compiler.JointGroup) = .empty;
    defer groups.deinit(allocator);
    var cursor: usize = 0;
    for (joints, 0..) |node, joint| {
        const start = cursor;
        cursor = copyJoint(batch.vertices, reordered, &remap, joint, start);
        if (cursor != start) try groups.append(allocator, .{ .node = node, .offset = @intCast(start), .count = @intCast(cursor - start) });
    }
    std.debug.assert(cursor == batch.vertices.len);
    const owned_groups = try groups.toOwnedSlice(allocator);
    for (batch.triangles) |*triangle| for (triangle) |*index| {
        index.* = remap[index.*];
    };
    allocator.free(batch.vertices);
    batch.vertices = reordered;
    batch.groups = owned_groups;
}

fn copyJoint(vertices: []const compiler.Vertex, reordered: []compiler.Vertex, remap: *[70]u8, joint: usize, start: usize) usize {
    var cursor = start;
    for (vertices, 0..) |vertex, index| {
        if (vertex.influence.joints[0] != joint) continue;
        reordered[cursor] = vertex;
        remap[index] = @intCast(cursor);
        cursor += 1;
    }
    return cursor;
}
test "mixed-joint triangles keep all corners and ignore nonfirst weights" {
    const allocator = std.testing.allocator;
    const vertices = try allocator.dupe(compiler.Vertex, &.{
        .{ .position = .{ 1, 0, 0 }, .normal = 0, .color = @splat(255), .uv = .{ 0, 0 }, .influence = .{ .joints = .{ 1, 0, 0, 0 }, .weights = .{ 0.1, 0.9, 0, 0 } } },
        .{ .position = .{ 2, 0, 0 }, .normal = 0, .color = @splat(255), .uv = .{ 0, 0 }, .influence = .{ .joints = .{ 0, 1, 0, 0 }, .weights = .{ 0, 1, 0, 0 } } },
        .{ .position = .{ 3, 0, 0 }, .normal = 0, .color = @splat(255), .uv = .{ 0, 0 }, .influence = .{ .joints = .{ 1, 0, 0, 0 } } },
    });
    var batch: compiler.Batch = .{ .vertices = vertices, .triangles = try allocator.dupe(compiler.Triangle, &.{.{ 0, 1, 2 }}), .material_index = 0 };
    defer {
        allocator.free(batch.vertices);
        allocator.free(batch.triangles);
        allocator.free(batch.groups);
    }
    try groupVertices(allocator, &batch, &.{ 4, 8 });
    try std.testing.expectEqualSlices(compiler.JointGroup, &.{ .{ .node = 4, .offset = 0, .count = 1 }, .{ .node = 8, .offset = 1, .count = 2 } }, batch.groups);
    try std.testing.expectEqual(compiler.Triangle{ 1, 0, 2 }, batch.triangles[0]);
    var matrix: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ -2, 0, 0, 1 } };
    try transformVertex(&batch.vertices[0], matrix);
    try std.testing.expectEqual([3]i16{ 0, 0, 0 }, batch.vertices[0].position);
    matrix[3][0] = 32768;
    try std.testing.expectError(error.PositionOutOfRange, transformVertex(&batch.vertices[0], matrix));
}

test "prepare transforms source floats before quantization and remaps skin joints" {
    const allocator = std.testing.allocator;
    const matrices = [2]Matrix{
        .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0.1, 0, 0, 1 } },
        .{ .{ 0, 1, 0, 0 }, .{ -1, 0, 0, 0 }, .{ 0, 0, 1, 0 }, .{ -0.1, 0, 0, 1 } },
    };
    var binary: [128]u8 = undefined;
    var offset: usize = 0;
    for (matrices) |matrix| for (matrix) |column| for (column) |coefficient| {
        std.mem.writeInt(u32, binary[offset..][0..4], @bitCast(coefficient), .little);
        offset += 4;
    };
    const document: compiler.Document = .{
        .accessors = &.{.{ .bufferView = 0, .componentType = 5126, .count = 2, .type = "MAT4" }},
        .bufferViews = &.{.{ .buffer = 0, .byteLength = binary.len }},
        .meshes = &.{},
        .skins = &.{.{ .joints = &.{ 4, 8 }, .inverseBindMatrices = 0 }},
    };
    var batches = [_]compiler.Batch{
        .{
            .vertices = try allocator.dupe(compiler.Vertex, &.{
                .{ .position = .{ 1, 0, 0 }, .source_position = .{ 1.49, 0, 0 }, .source_normal = .{ 0.5, 0.5, 0 }, .normal = 0, .color = @splat(255), .uv = .{ 0, 0 }, .influence = .{ .joints = .{ 1, 0, 0, 0 }, .weights = .{ 0, 1, 0, 0 } } },
                .{ .position = .{ 0, 0, 0 }, .source_position = .{ 0.49, 0, 0 }, .source_normal = .{ 1, 0, 0 }, .normal = 0, .color = @splat(255), .uv = .{ 0, 0 }, .influence = .{ .joints = .{ 0, 1, 0, 0 }, .weights = .{ 0.1, 0.9, 0, 0 } } },
                .{ .position = .{ 0, 1, 0 }, .source_position = .{ 0, 1.49, 0 }, .source_normal = .{ 0, 1, 0 }, .normal = 0, .color = @splat(255), .uv = .{ 0, 0 }, .influence = .{ .joints = .{ 1, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } } },
            }),
            .triangles = try allocator.dupe(compiler.Triangle, &.{.{ 0, 1, 2 }}),
            .material_index = 0,
            .skin = 0,
        },
        .{ .vertices = &.{}, .triangles = &.{}, .material_index = 0 },
    };
    defer {
        allocator.free(batches[0].vertices);
        allocator.free(batches[0].triangles);
        allocator.free(batches[0].groups);
    }
    try prepare(allocator, document, &binary, &batches, 2);
    const batch = &batches[0];
    try std.testing.expectEqualSlices(compiler.JointGroup, &.{ .{ .node = 4, .offset = 0, .count = 1 }, .{ .node = 8, .offset = 1, .count = 2 } }, batch.groups);
    try std.testing.expectEqual(compiler.Triangle{ 1, 0, 2 }, batch.triangles[0]);
    try std.testing.expectEqual([3]i16{ 1, 0, 0 }, batch.vertices[0].position);
    try std.testing.expectEqual([3]i16{ 0, 1, 0 }, batch.vertices[1].position);
    try std.testing.expectEqual([3]i16{ -2, 0, 0 }, batch.vertices[2].position);
    try std.testing.expectEqual(@as(u16, 0x7800), batch.vertices[0].normal);
    try std.testing.expectEqual(@as(u16, 0xaac0), batch.vertices[1].normal);
    try std.testing.expectEqual(@as(u16, 0x8000), batch.vertices[2].normal);
    try std.testing.expectEqual(@as(usize, 0), batches[1].groups.len);

    batch.vertices[0].influence.joints[0] = 2;
    try std.testing.expectError(error.InvalidSkinJoint, prepare(allocator, document, &binary, &batches, 2));
}
