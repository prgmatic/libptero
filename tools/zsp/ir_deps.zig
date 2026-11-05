//! Dependence graph for a straight-line run of instructions.
//!
//! Registers and implicit vector state are tracked per resource. Most
//! accumulator and flag writes are dead (every computational vector op
//! writes the accumulator), so a writer is ordered only against the live
//! value before it and the next live writer after it, instead of against
//! every other writer. The last writer of each resource is live-out.
const std = @import("std");
const ir = @import("ir.zig");
const effects = @import("ir_effects.zig");

const Effects = effects.Effects;
const BitSet = std.DynamicBitSetUnmanaged;

pub const Graph = struct {
    /// `preds[j]` holds every instruction that must issue before `j`.
    preds: []BitSet,

    pub fn init(allocator: std.mem.Allocator, all: []const Effects) !Graph {
        const preds = try allocator.alloc(BitSet, all.len);
        for (preds) |*set| set.* = try BitSet.initEmpty(allocator, all.len);
        var graph: Graph = .{ .preds = preds };
        for (0..resource_count) |resource| try graph.addResourceEdges(allocator, all, @intCast(resource));
        graph.addMemoryEdges(all);
        return graph;
    }

    pub fn depends(self: Graph, later: usize, earlier: usize) bool {
        return self.preds[later].isSet(earlier);
    }

    fn edge(self: Graph, from: usize, to: usize) void {
        if (from != to) self.preds[to].set(from);
    }

    fn addResourceEdges(self: Graph, allocator: std.mem.Allocator, all: []const Effects, resource: u7) !void {
        const live = try liveWrites(allocator, all, resource);
        defer allocator.free(live);
        var scan: ResourceScan = .{ .graph = self, .allocator = allocator };
        defer scan.deinit();
        for (all, live, 0..) |item, is_live, index| try scan.visit(item, resource, index, is_live);
    }

    /// Stores order against every possibly aliasing access; loads may
    /// reorder freely with each other.
    fn addMemoryEdges(self: Graph, all: []const Effects) void {
        for (all, 0..) |later, j| {
            const b = later.memory orelse continue;
            for (all[0..j], 0..) |earlier, i| {
                const a = earlier.memory orelse continue;
                if (memoryConflict(all, i, j, a, b)) self.edge(i, j);
            }
        }
    }
};

fn memoryConflict(all: []const Effects, i: usize, j: usize, a: effects.Access, b: effects.Access) bool {
    if (!a.store and !b.store) return false;
    if (effects.mayAlias(a, b)) return true;
    // Disjoint offsets only prove independence while the base is unchanged.
    return baseWrittenBetween(all, i, j, a.base);
}

fn baseWrittenBetween(all: []const Effects, i: usize, j: usize, base: ir.Reg) bool {
    const bit = effects.scalarBit(base);
    for (all[i + 1 .. j]) |between| if (between.scalar_writes & bit != 0) return true;
    return false;
}

/// 32 scalar registers, 32 vector registers, then the implicit state bits.
pub const resource_count = 32 + 32 + 6;

pub fn reads(item: Effects, resource: u7) bool {
    return resourceBit(item.scalar_reads, item.vector_reads, item.state_reads, resource);
}

pub fn writes(item: Effects, resource: u7) bool {
    return resourceBit(item.scalar_writes, item.vector_writes, item.state_writes, resource);
}

fn resourceBit(scalar: u32, vector: u32, state: effects.State, resource: u7) bool {
    if (resource < 32) return scalar >> @intCast(resource) & 1 != 0;
    if (resource < 64) return vector >> @intCast(resource - 32) & 1 != 0;
    return state.bits() >> @intCast(resource - 64) & 1 != 0;
}

/// A write is live when a later instruction reads it before the next
/// write, or when no later write replaces it.
fn liveWrites(allocator: std.mem.Allocator, all: []const Effects, resource: u7) ![]bool {
    const live = try allocator.alloc(bool, all.len);
    var next_is_read = true;
    var index = all.len;
    while (index > 0) {
        index -= 1;
        const item = all[index];
        live[index] = writes(item, resource) and next_is_read;
        next_is_read = nextEventIsRead(item, resource, next_is_read);
    }
    return live;
}

fn nextEventIsRead(item: Effects, resource: u7, after: bool) bool {
    if (reads(item, resource)) return true;
    if (writes(item, resource)) return false;
    return after;
}

/// Forward scan for one resource, adding true, anti, and output edges.
const ResourceScan = struct {
    graph: Graph,
    allocator: std.mem.Allocator,
    writer: ?usize = null,
    readers: std.ArrayList(usize) = .empty,
    dead: std.ArrayList(usize) = .empty,

    fn deinit(self: *ResourceScan) void {
        self.readers.deinit(self.allocator);
        self.dead.deinit(self.allocator);
    }

    fn visit(self: *ResourceScan, item: Effects, resource: u7, index: usize, live: bool) !void {
        if (reads(item, resource)) try self.read(index);
        if (writes(item, resource)) try self.write(index, live);
    }

    fn read(self: *ResourceScan, index: usize) !void {
        if (self.writer) |writer| self.graph.edge(writer, index);
        try self.readers.append(self.allocator, index);
    }

    /// Every write follows the current value's readers. A live write also
    /// follows the dead writes since the previous live value.
    fn write(self: *ResourceScan, index: usize, live: bool) !void {
        for (self.readers.items) |reader| self.graph.edge(reader, index);
        if (!live) return self.dead.append(self.allocator, index);
        for (self.dead.items) |dead| self.graph.edge(dead, index);
        if (self.writer) |writer| self.graph.edge(writer, index);
        self.writer = index;
        self.readers.clearRetainingCapacity();
        self.dead.clearRetainingCapacity();
    }
};

const testing = std.testing;

fn graphOf(arena: std.mem.Allocator, instructions: []const ir.Inst) !Graph {
    const all = try arena.alloc(Effects, instructions.len);
    for (instructions, all) |inst, *item| item.* = effects.of(inst);
    return Graph.init(arena, all);
}

test "register dependences order producers, consumers, and overwrites" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const graph = try graphOf(arena.allocator(), &.{
        .{ .op = .addiu, .rt = .t0, .imm = 1 },
        .{ .op = .addu, .rd = .t1, .rs = .t0, .rt = .t0 },
        .{ .op = .addiu, .rt = .t0, .imm = 2 },
        .{ .op = .addiu, .rt = .t2, .imm = 3 },
    });
    try testing.expect(graph.depends(1, 0));
    try testing.expect(graph.depends(2, 1));
    try testing.expect(graph.depends(2, 0));
    try testing.expect(!graph.depends(3, 0) and !graph.depends(3, 2));
}

test "dead accumulator writes do not serialize independent vector ops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const graph = try graphOf(arena.allocator(), &.{
        .{ .op = .vmudh, .vd = .v01, .vs = .v02, .vt = .v03 },
        .{ .op = .vmadh, .vd = .v01, .vs = .v04, .vt = .v05 },
        .{ .op = .vxor, .vd = .v06, .vs = .v07, .vt = .v07 },
        .{ .op = .vxor, .vd = .v08, .vs = .v09, .vt = .v09 },
        .{ .op = .vmudh, .vd = .v10, .vs = .v02, .vt = .v03 },
    });
    // The multiply chain stays ordered.
    try testing.expect(graph.depends(1, 0));
    // The dead accumulator writes stay outside that chain...
    try testing.expect(graph.depends(2, 1));
    // ...but not ordered against each other.
    try testing.expect(!graph.depends(3, 2));
    // The final, live-out accumulator write follows both.
    try testing.expect(graph.depends(4, 2) and graph.depends(4, 3));
}

test "stores order against possibly aliasing accesses only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const graph = try graphOf(arena.allocator(), &.{
        .{ .op = .sw, .rt = .t0, .rs = .a0, .imm = 0 },
        .{ .op = .lw, .rt = .t1, .rs = .a0, .imm = 4 },
        .{ .op = .lw, .rt = .t2, .rs = .a0, .imm = 0 },
        .{ .op = .lw, .rt = .t3, .rs = .a1, .imm = 8 },
        .{ .op = .lw, .rt = .t4, .rs = .a0, .imm = 4 },
        .{ .op = .addiu, .rt = .a0, .rs = .a0, .imm = 4 },
        .{ .op = .lw, .rt = .t5, .rs = .a0, .imm = 4 },
        .{ .op = .mtc0, .rt = .t0, .imm = 1 },
    });
    try testing.expect(!graph.depends(1, 0));
    try testing.expect(graph.depends(2, 0));
    try testing.expect(graph.depends(3, 0));
    try testing.expect(!graph.depends(4, 1));
    // A load after the base changes may alias the earlier store.
    try testing.expect(graph.depends(6, 0));
    try testing.expect(graph.depends(7, 0) and graph.depends(7, 6));
}
