//! Merge identical native vertices before cache batching. Skin influences and
//! bind-local source attributes participate so seams and animation stay intact.
const std = @import("std");
const Vertex = @import("compiler.zig").Vertex;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    sources: []?u32,
    vertices: std.ArrayList(Vertex) = .empty,

    pub fn init(allocator: std.mem.Allocator, count: usize) !Pool {
        const sources = try allocator.alloc(?u32, count);
        @memset(sources, null);
        return .{ .allocator = allocator, .sources = sources };
    }
    pub fn deinit(self: *Pool) void {
        self.allocator.free(self.sources);
        self.vertices.deinit(self.allocator);
    }
    pub fn intern(self: *Pool, source: u32, vertex: Vertex) !void {
        for (self.vertices.items, 0..) |existing, index| {
            if (std.meta.eql(existing, vertex)) {
                self.sources[source] = @intCast(index);
                return;
            }
        }
        try self.vertices.append(self.allocator, vertex);
        self.sources[source] = @intCast(self.vertices.items.len - 1);
    }
};

test "native duplicates merge while shading, UV and skin seams remain distinct" {
    var pool = try Pool.init(std.testing.allocator, 9);
    defer pool.deinit();
    const vertex: Vertex = .{ .position = .{ 1, 2, 3 }, .normal = 0x1234, .color = .{ 1, 2, 3, 4 }, .uv = .{ 5, 6 } };
    try pool.intern(0, vertex);
    try pool.intern(1, vertex);
    try std.testing.expectEqual(pool.sources[0], pool.sources[1]);
    var variants = [_]Vertex{vertex} ** 7;
    variants[0].position[0] += 1;
    variants[1].normal += 1;
    variants[2].color[3] += 1;
    variants[3].uv[0] += 1;
    variants[4].influence.joints[0] = 1;
    variants[5].source_position = .{ 1, 2, 3 };
    variants[6].source_normal = .{ 0, 1, 0 };
    for (variants, 2..) |variant, index| {
        try pool.intern(@intCast(index), variant);
        try std.testing.expectEqual(@as(?u32, @intCast(index - 1)), pool.sources[index]);
    }
    try std.testing.expectEqual(@as(usize, 8), pool.vertices.items.len);
}
