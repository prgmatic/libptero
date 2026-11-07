//! Delay slots of branches to cold blocks that rejoin right after the slot.
//! An out-of-line `@branchHint(.cold)` body ends with a jump back to the
//! label after its branch, so that label starts a new block and the
//! fall-through filler cannot look past it. When only the cold block jumps
//! to the label, the instruction after it may move into the slot: it then
//! runs before the cold block instead of after, which is the same as long
//! as the block neither touches what it writes nor changes what it reads.
//!
//!        bne $t9, $zero, cold          bne $t9, $zero, cold
//!        nop                     =>    luv $v24, 16($s4)
//!    join:                          join:
//!        luv $v24, 16($s4)              ...
//!        ...                        cold:
//!    cold:                              (does not use $v24 or $s4)
//!        ...                            j join
//!        j join
const std = @import("std");
const ir = @import("ir.zig");
const effects = @import("ir_effects.zig");
const schedule = @import("schedule.zig");
const branch_slots = @import("branch_slots.zig");

const Item = ir.Item;
const Items = std.ArrayList(Item);

/// Fall-through instructions considered for each slot.
const scan_limit = 4;
/// Instructions a cold block may have for its effects to be summarized.
const region_limit = 256;

pub fn fillFromRejoiningColdBlocks(items: *Items) void {
    var branch: usize = 0;
    while (branch + 2 < items.items.len) : (branch += 1) {
        const next = candidate(items.items, branch) orelse continue;
        items.items[branch + 1] = items.items[next];
        _ = items.orderedRemove(next);
    }
}

fn candidate(items: []const Item, branch: usize) ?usize {
    const cold = coldBlock(items, branch) orelse return null;
    const end = @min(items.len, cold.join.end + scan_limit);
    for (cold.join.end..end) |index| {
        if (!schedule.isMovable(items[index])) return null;
        if (movable(items, cold.join.end, index, cold.region.effects)) return index;
    }
    return null;
}

const ColdBlock = struct { join: Join, region: Region };

/// The cold block a branch with an empty slot goes to, when it rejoins at
/// labels right after the slot that nothing else reaches.
fn coldBlock(items: []const Item, branch: usize) ?ColdBlock {
    const target = emptyBranchTarget(items, branch) orelse return null;
    const join = joinLabels(items, branch + 2) orelse return null;
    const region = summarize(items, target, join) orelse return null;
    if (!onlyRegionReaches(items, join, region)) return null;
    return .{ .join = join, .region = region };
}

/// A conditional branch with an empty slot, and where it goes.
fn emptyBranchTarget(items: []const Item, branch: usize) ?usize {
    const inst = instructionAt(items, branch) orelse return null;
    if (!hasEmptySlot(items, branch) or effects.of(inst).control != .branch) return null;
    return branch_slots.labelIndex(items, inst.symbol orelse return null);
}

fn hasEmptySlot(items: []const Item, branch: usize) bool {
    const slot = instructionAt(items, branch + 1) orelse return false;
    return !items[branch].instruction.frozen and !slot.frozen and slot.isNop();
}

fn instructionAt(items: []const Item, index: usize) ?ir.Inst {
    if (index >= items.len or items[index] != .instruction) return null;
    return items[index].instruction;
}

/// The labels directly after the slot, at `[start, end)`.
const Join = struct { start: usize, end: usize };

fn joinLabels(items: []const Item, start: usize) ?Join {
    var end = start;
    while (end < items.len and items[end] == .label) end += 1;
    if (end == start or end == items.len) return null;
    return .{ .start = start, .end = end };
}

fn isJoin(items: []const Item, join: Join, name: []const u8) bool {
    for (items[join.start..join.end]) |item| {
        if (std.mem.eql(u8, item.label, name)) return true;
    }
    return false;
}

/// The combined effects of a cold block, and the instructions it spans.
const Region = struct {
    effects: effects.Effects = .{},
    start: usize,
    end: usize = 0,

    fn add(self: *Region, effect: effects.Effects) void {
        self.effects.scalar_reads |= effect.scalar_reads;
        self.effects.scalar_writes |= effect.scalar_writes;
        self.effects.vector_reads |= effect.vector_reads;
        self.effects.vector_writes |= effect.vector_writes;
        self.effects.state_reads = @bitCast(self.effects.state_reads.bits() | effect.state_reads.bits());
        self.effects.state_writes = @bitCast(self.effects.state_writes.bits() | effect.state_writes.bits());
        if (writesMemory(effect)) self.effects.memory = effect.memory;
    }

    /// Adds the instruction at `index`, which must exist.
    fn addAt(self: *Region, items: []const Item, index: usize) bool {
        const inst = instructionAt(items, index) orelse return false;
        self.add(effects.of(inst));
        return true;
    }

    fn contains(self: Region, index: usize) bool {
        return index >= self.start and index < self.end;
    }
};

fn writesMemory(effect: effects.Effects) bool {
    const access = effect.memory orelse return false;
    return access.store or access.unknown;
}

const Step = enum { more, done, fail };

/// Summarizes the block from `target` to its jump back to the join. Inner
/// branches must stay inside it; calls are followed into straight-line
/// callees that return.
fn summarize(items: []const Item, target: usize, join: Join) ?Region {
    var region: Region = .{ .start = target };
    const limit = @min(items.len, target + region_limit);
    for (target..limit) |index| {
        switch (visit(items, join, index, &region)) {
            .more => {},
            .done => return if (innerBranchesStay(items, region)) region else null,
            .fail => return null,
        }
    }
    return null;
}

fn visit(items: []const Item, join: Join, index: usize, region: *Region) Step {
    const inst = instructionAt(items, index) orelse return .more;
    const effect = effects.of(inst);
    region.add(effect);
    return switch (effect.control) {
        .none, .branch => .more,
        .call => followCall(items, inst, region),
        .jump => rejoins(items, join, index, inst, region),
        else => .fail,
    };
}

fn followCall(items: []const Item, inst: ir.Inst, region: *Region) Step {
    return if (addCallee(items, inst, region)) .more else .fail;
}

/// The block's final jump back to the join, with its slot.
fn rejoins(items: []const Item, join: Join, index: usize, inst: ir.Inst, region: *Region) Step {
    if (!isJoin(items, join, inst.symbol orelse return .fail)) return .fail;
    if (!region.addAt(items, index + 1)) return .fail;
    region.end = index + 2;
    return .done;
}

/// A called function's straight-line body, up to and with its return.
fn addCallee(items: []const Item, call: ir.Inst, region: *Region) bool {
    const start = branch_slots.labelIndex(items, call.symbol orelse return false) orelse return false;
    const ret = calleeReturn(items, start) orelse return false;
    addBody(items[start..ret], region);
    return region.addAt(items, ret) and region.addAt(items, ret + 1);
}

fn addBody(body: []const Item, region: *Region) void {
    for (body) |item| {
        if (item == .instruction) region.add(effects.of(item.instruction));
    }
}

/// The `jr $ra` ending a straight-line callee starting at `start`.
fn calleeReturn(items: []const Item, start: usize) ?usize {
    const limit = @min(items.len, start + region_limit);
    for (start..limit) |index| {
        const inst = instructionAt(items, index) orelse continue;
        const control = effects.of(inst).control;
        if (control == .none) continue;
        return if (control == .indirect_jump and inst.rs == .ra) index else null;
    }
    return null;
}

fn innerBranchesStay(items: []const Item, region: Region) bool {
    for (items[region.start..region.end]) |item| {
        if (!branchStaysIn(items, item, region)) return false;
    }
    return true;
}

fn branchStaysIn(items: []const Item, item: Item, region: Region) bool {
    if (item != .instruction or effects.of(item.instruction).control != .branch) return true;
    const target = branch_slots.labelIndex(items, item.instruction.symbol orelse return false) orelse return false;
    return region.contains(target);
}

/// Every transfer to a join label comes from inside the cold block.
fn onlyRegionReaches(items: []const Item, join: Join, region: Region) bool {
    for (items, 0..) |item, index| {
        if (item != .instruction) continue;
        const symbol = item.instruction.symbol orelse continue;
        if (isJoin(items, join, symbol) and !region.contains(index)) return false;
    }
    return true;
}

/// The instruction at `index` passes those from `first`, and running it
/// before the cold block instead of after leaves both paths the same.
fn movable(items: []const Item, first: usize, index: usize, region: effects.Effects) bool {
    const moving = effects.of(items[index].instruction);
    if (!sideEffectFree(moving)) return false;
    for (items[first..index]) |passed| {
        if (!@import("peephole.zig").independent(moving, effects.of(passed.instruction))) return false;
    }
    return untouchedBy(moving, region);
}

fn sideEffectFree(moving: effects.Effects) bool {
    if (writesMemory(moving)) return false;
    return moving.state_writes.bits() == 0 and moving.control == .none and (moving.scalar_writes | moving.vector_writes) != 0;
}

/// The block neither reads nor writes what `moving` writes, does not write
/// what it reads, and stores nothing a load could see.
fn untouchedBy(moving: effects.Effects, region: effects.Effects) bool {
    const scalar_clear = (region.scalar_reads | region.scalar_writes) & moving.scalar_writes == 0 and region.scalar_writes & moving.scalar_reads == 0;
    const vector_clear = (region.vector_reads | region.vector_writes) & moving.vector_writes == 0 and region.vector_writes & moving.vector_reads == 0;
    return scalar_clear and vector_clear and stateAndMemoryClear(moving, region);
}

fn stateAndMemoryClear(moving: effects.Effects, region: effects.Effects) bool {
    if (region.state_writes.overlaps(moving.state_reads)) return false;
    return moving.memory == null or region.memory == null;
}

const testing = std.testing;

fn run(source: []const Item) !Items {
    var list: Items = .empty;
    try list.appendSlice(testing.allocator, source);
    fillFromRejoiningColdBlocks(&list);
    return list;
}

fn coldProgram(cold_body: []const Item, after_join: []const Item) ![]Item {
    var list: Items = .empty;
    try list.appendSlice(testing.allocator, &.{
        .{ .instruction = .{ .op = .bne, .rs = .t9, .rt = .zero, .symbol = "cold" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .label = "join" },
    });
    try list.appendSlice(testing.allocator, after_join);
    try list.appendSlice(testing.allocator, &.{ .{ .instruction = .{ .op = .@"break" } }, .{ .label = "cold" } });
    try list.appendSlice(testing.allocator, cold_body);
    try list.appendSlice(testing.allocator, &.{
        .{ .instruction = .{ .op = .j, .symbol = "join" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .label = "callee" },
        .{ .instruction = .{ .op = .addiu, .rt = .t3, .rs = .zero, .imm = 1 } },
        .{ .instruction = .{ .op = .jr, .rs = .ra } },
        .{ .instruction = .{ .op = .nop } },
    });
    return list.toOwnedSlice(testing.allocator);
}

test "work after the join fills the slot of a branch to a rejoining cold block" {
    const source = try coldProgram(&.{
        .{ .instruction = .{ .op = .addiu, .rt = .t4, .rs = .zero, .imm = 2 } },
        .{ .instruction = .{ .op = .jal, .symbol = "callee" } },
        .{ .instruction = .{ .op = .nop } },
    }, &.{.{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 4 } }});
    defer testing.allocator.free(source);
    var list = try run(source);
    defer list.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.srl, list.items[1].instruction.op);
}

test "cold blocks that use the moved value, other jumps to the join, and stores keep the nop" {
    const cases = [_]struct { cold: []const Item, after: []const Item }{
        // The block reads the moved destination.
        .{ .cold = &.{.{ .instruction = .{ .op = .addu, .rd = .t2, .rs = .t1, .rt = .zero } }}, .after = &.{.{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 4 } }} },
        // The callee writes what the moved instruction reads.
        .{ .cold = &.{ .{ .instruction = .{ .op = .jal, .symbol = "callee" } }, .{ .instruction = .{ .op = .nop } } }, .after = &.{.{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .t3, .imm = 4 } }} },
        // A store in the block may change what the moved load reads.
        .{ .cold = &.{.{ .instruction = .{ .op = .sw, .rt = .t2, .rs = .a1 } }}, .after = &.{.{ .instruction = .{ .op = .lw, .rt = .t1, .rs = .a0 } }} },
        // The block leaves without rejoining.
        .{ .cold = &.{ .{ .instruction = .{ .op = .jr, .rs = .ra } }, .{ .instruction = .{ .op = .nop } } }, .after = &.{.{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 4 } }} },
    };
    for (cases) |case| {
        const source = try coldProgram(case.cold, case.after);
        defer testing.allocator.free(source);
        var list = try run(source);
        defer list.deinit(testing.allocator);
        try testing.expect(list.items[1].instruction.isNop());
    }

    // Another branch reaches the join, so it must still run the instruction.
    const shared = try coldProgram(&.{}, &.{.{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 4 } }});
    defer testing.allocator.free(shared);
    var with_other: Items = .empty;
    defer with_other.deinit(testing.allocator);
    try with_other.appendSlice(testing.allocator, shared);
    try with_other.appendSlice(testing.allocator, &.{ .{ .instruction = .{ .op = .beq, .rs = .t0, .rt = .zero, .symbol = "join" } }, .{ .instruction = .{ .op = .nop } } });
    fillFromRejoiningColdBlocks(&with_other);
    try testing.expect(with_other.items[1].instruction.isNop());
}
