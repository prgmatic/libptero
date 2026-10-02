const std = @import("std");
const types = @import("model.zig");
const geometry = @import("geometry.zig");
const Rgba32 = @import("color.zig").Rgba32;

/// Borrowed references to one logical vertex in the hardware's paired layout.
pub const VertexRef = struct {
    position: *[3]i16,
    normal: *u16,
    color: *Rgba32,
    uv: *[2]i16,
};

pub const VertexBuffer = struct {
    pairs: []geometry.VertexPair,
    count: usize,

    pub fn get(self: VertexBuffer, index: usize) VertexRef {
        std.debug.assert(index < self.count);
        const pair = &self.pairs[index / 2];
        return if (index % 2 == 0)
            .{ .position = &pair.pos_a, .normal = &pair.normal_a, .color = &pair.color_a, .uv = &pair.uv_a }
        else
            .{ .position = &pair.pos_b, .normal = &pair.normal_b, .color = &pair.color_b, .uv = &pair.uv_b };
    }
    pub fn iterator(self: VertexBuffer) Iterator {
        return .{ .buffer = self };
    }
    pub const Iterator = struct {
        buffer: VertexBuffer,
        index: usize = 0,

        pub fn next(self: *Iterator) ?VertexRef {
            if (self.index == self.buffer.count) return null;
            const result = self.buffer.get(self.index);
            self.index += 1;
            return result;
        }
    };
};

/// Owns writable vertex copies; source metadata and triangle topology stay
/// borrowed. Wait for GPU completion before mutation/reset/deinit. Drawing the
/// borrowed model view writes back its dynamic data automatically.
pub const MutableModel = struct {
    source: types.Model,
    parts: []types.Part,
    buffers: [][]geometry.VertexPair,

    pub fn init(allocator: std.mem.Allocator, source: types.Model) !MutableModel {
        const parts = try allocator.dupe(types.Part, source.parts);
        errdefer allocator.free(parts);
        const buffers = try allocator.alloc([]geometry.VertexPair, parts.len);
        errdefer allocator.free(buffers);
        var initialized: usize = 0;
        errdefer for (buffers[0..initialized]) |buffer| allocator.free(buffer);
        for (parts, buffers) |*part, *buffer| {
            if (part.vertex_count == 0 or part.vertex_count > part.vertices.len * 2) return error.InvalidVertexCount;
            buffer.* = try allocator.dupe(geometry.VertexPair, part.vertices);
            initialized += 1;
            part.vertices = buffer.*;
            part.data_usage = .dynamic;
        }
        return .{ .source = source, .parts = parts, .buffers = buffers };
    }
    pub fn deinit(self: *MutableModel, allocator: std.mem.Allocator) void {
        for (self.buffers) |buffer| allocator.free(buffer);
        allocator.free(self.buffers);
        allocator.free(self.parts);
        self.* = undefined;
    }
    pub fn model(self: *const MutableModel) types.Model {
        var result = self.source;
        result.parts = self.parts;
        return result;
    }
    pub fn vertices(self: *MutableModel, part_index: usize) VertexBuffer {
        return .{ .pairs = self.buffers[part_index], .count = self.parts[part_index].vertex_count };
    }
    pub fn reset(self: *MutableModel) void {
        for (self.source.parts, self.buffers) |part, buffer| @memcpy(buffer, part.vertices);
    }
};

const fixture_vertices = [_]geometry.VertexPair{
    .{ .pos_a = .{ 1, 2, 3 }, .pos_b = .{ 4, 5, 6 }, .normal_a = 7, .normal_b = 8, .color_a = .red, .color_b = .blue },
    .{ .pos_a = .{ 9, 10, 11 }, .pos_b = .{ 12, 13, 14 }, .normal_a = 15, .normal_b = 16, .color_a = .white, .color_b = .black },
};
const fixture_parts = [_]types.Part{.{ .vertices = &fixture_vertices, .vertex_count = 3, .material_index = 2 }};
const fixture: types.Model = .{ .parts = &fixture_parts };

test "mutable vertices preserve source, topology, and odd-pair padding" {
    var instance = try MutableModel.init(std.testing.allocator, fixture);
    defer instance.deinit(std.testing.allocator);
    var iterator = instance.vertices(0).iterator();
    var count: usize = 0;
    while (iterator.next()) |vertex| {
        vertex.position[1] = 42;
        vertex.color.* = .green;
        vertex.uv.* = .{ 16, 32 };
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    const view = instance.model();
    try std.testing.expectEqual(types.DataUsage.dynamic, view.parts[0].data_usage);
    try std.testing.expectEqual(@as(i16, 42), view.parts[0].vertices[0].pos_b[1]);
    try std.testing.expectEqual(@as(i16, 13), view.parts[0].vertices[1].pos_b[1]);
    try std.testing.expectEqual(@as(i16, 2), fixture.parts[0].vertices[0].pos_a[1]);
    try std.testing.expectEqual(fixture.parts[0].strip_indices.ptr, view.parts[0].strip_indices.ptr);
    instance.reset();
    try std.testing.expectEqualSlices(geometry.VertexPair, &fixture_vertices, instance.buffers[0]);
}

fn allocationFixture(allocator: std.mem.Allocator) !void {
    var instance = try MutableModel.init(allocator, fixture);
    defer instance.deinit(allocator);
}

test "mutable model cleans up failed allocations and rejects invalid counts" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
    const invalid: types.Model = .{ .parts = &.{.{ .vertices = &fixture_vertices, .vertex_count = 5, .material_index = 0 }} };
    try std.testing.expectError(error.InvalidVertexCount, MutableModel.init(std.testing.allocator, invalid));
    const empty_part: types.Model = .{ .parts = &.{.{ .vertices = &fixture_vertices, .vertex_count = 0, .material_index = 0 }} };
    try std.testing.expectError(error.InvalidVertexCount, MutableModel.init(std.testing.allocator, empty_part));
}
