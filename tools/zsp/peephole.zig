//! Local rewrites over the instruction IR: relocation folding, dead-write
//! removal, CP0 polling loops, and transfer delay slots. Frozen (`exact`)
//! instructions and raw assembly are never moved, removed, or rewritten.
const std = @import("std");
const ir = @import("ir.zig");
const effects = @import("ir_effects.zig");
const schedule = @import("schedule.zig");

const Item = ir.Item;
const Inst = ir.Inst;
const Items = std.ArrayList(Item);

fn instructionAt(items: []const Item, index: usize) ?Inst {
    if (index >= items.len or items[index] != .instruction) return null;
    const inst = items[index].instruction;
    return if (inst.frozen) null else inst;
}

/// A non-frozen instruction that is not itself a transfer's delay slot.
fn rewritableAt(items: []const Item, index: usize) ?Inst {
    const inst = instructionAt(items, index) orelse return null;
    if (index > 0 and schedule.hasDelaySlot(items[index - 1])) return null;
    return inst;
}

fn isTransfer(inst: Inst) bool {
    return effects.of(inst).isTransfer();
}

// ------------------------------------------------------ lane-op encodings

/// VMOV and the divide operations ignore bit 3 of their destination
/// element, a field the RSP timing model reads as the `vs` register. Each
/// unfrozen lane operation takes the spelling whose register the nearby
/// instructions write least, so no false dependence slows the schedule.
pub fn chooseLaneEncodings(items: []Item) void {
    for (items, 0..) |*item, index| {
        if (item.* != .instruction) continue;
        const inst = &item.instruction;
        if (inst.frozen or inst.op.info().format != .vector_lane) continue;
        inst.dest_element = quieterElement(items, index, inst.dest_element);
    }
}

/// Instructions on either side that the scheduler may place nearby.
const lane_window = 8;

fn quieterElement(items: []const Item, index: usize, element: u4) u4 {
    const low = element & 7;
    const high = low | 8;
    return if (nearbyWrites(items, index, high) < nearbyWrites(items, index, low)) high else low;
}

fn nearbyWrites(items: []const Item, index: usize, register: u4) usize {
    const first = index -| lane_window;
    const end = @min(items.len, index + lane_window + 1);
    var count: usize = 0;
    for (items[first..end]) |item| {
        if (item != .instruction) continue;
        count += @intFromBool(effects.of(item.instruction).vector_writes & effects.vectorBit(@enumFromInt(register)) != 0);
    }
    return count;
}

// ------------------------------------------------------- relocation folding

/// `addiu $at, $zero, %lo(L + k); lw $t0, n($at)` becomes
/// `lw $t0, %lo(L + k + n)($zero)` when `$at` is not read again.
pub fn foldSymbolOffsets(items: *Items) void {
    var index: usize = 0;
    while (index + 1 < items.items.len) {
        if (foldableAddress(items.items, index)) |folded| {
            items.items[index + 1].instruction = folded;
            _ = items.orderedRemove(index);
            continue;
        }
        index += 1;
    }
}

fn foldableAddress(items: []const Item, index: usize) ?Inst {
    const address = rewritableAt(items, index) orelse return null;
    const memory = instructionAt(items, index + 1) orelse return null;
    if (!isScratchAddress(address) or !usesScratchBase(memory)) return null;
    if (scratchReadAfter(items, index + 2)) return null;
    var folded = memory;
    folded.text = null;
    folded.rs = .zero;
    folded.symbol = address.symbol;
    folded.imm = address.imm + memory.imm;
    return folded;
}

fn isScratchAddress(inst: Inst) bool {
    return inst.op == .addiu and inst.rt == .at and inst.rs == .zero and inst.symbol != null;
}

fn usesScratchBase(inst: Inst) bool {
    return inst.op.format() == .memory and inst.rs == .at and inst.symbol == null and inst.rt != .at;
}

/// Whether `$at` is read before it is next written within the run.
fn scratchReadAfter(items: []const Item, start: usize) bool {
    const bit = effects.scalarBit(.at);
    for (items[start..]) |item| {
        if (item != .instruction) return false;
        const item_effects = effects.of(item.instruction);
        if (item_effects.scalar_reads & bit != 0) return true;
        if (item_effects.scalar_writes & bit != 0 or item_effects.isTransfer()) return false;
    }
    return false;
}

// -------------------------------------------------------------- dead writes

/// Removes an instruction whose every result the next instruction
/// overwrites without reading.
pub fn removeDeadWrites(items: *Items) void {
    var index: usize = 0;
    while (index + 1 < items.items.len) {
        if (isDeadWrite(items.items, index)) {
            _ = items.orderedRemove(index);
            continue;
        }
        index += 1;
    }
}

fn isDeadWrite(items: []const Item, index: usize) bool {
    const first = rewritableAt(items, index) orelse return false;
    const second = instructionAt(items, index + 1) orelse return false;
    const a = effects.of(first);
    if (a.memory != null or a.isTransfer() or (a.scalar_writes | a.vector_writes) == 0) return false;
    return overwrittenBy(a, effects.of(second));
}

fn overwrittenBy(a: effects.Effects, b: effects.Effects) bool {
    const state_bits = a.state_writes.bits();
    if (state_bits & ~b.state_writes.bits() != 0 or state_bits & b.state_reads.bits() != 0) return false;
    if (a.scalar_writes & ~b.scalar_writes != 0 or a.vector_writes & ~b.vector_writes != 0) return false;
    return a.scalar_writes & b.scalar_reads == 0 and a.vector_writes & b.vector_reads == 0;
}

// ------------------------------------------------------------ polling loops

/// Instruction equality, comparing symbol and source text by content.
pub fn sameInst(a: Inst, b: Inst) bool {
    var left = a;
    var right = b;
    if (!optionalTextEqual(left.symbol, right.symbol) or !optionalTextEqual(left.text, right.text)) return false;
    left.symbol = null;
    right.symbol = null;
    left.text = null;
    right.text = null;
    return std.meta.eql(left, right);
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The structured loop `read; while (x != 0) { read }` lowers to
///
///     read; L: beq x, $zero, E; nop; read; j L; nop; E:
///
/// which folds to `L: read; bne x, $zero, L; nop; E:`. With a second
/// operation, `read; mask; L: beq ...; read; mask; j L; ...` rotates to
/// `read; L: mask; bne x, $zero, L; read; E:`.
pub fn foldPollingLoops(items: *Items) !void {
    var index: usize = 1;
    while (index + 6 < items.items.len) : (index += 1) {
        if (try foldTwoOperationLoop(items, index)) continue;
        foldSingleOperationLoop(items, index);
    }
}

const Loop = struct { label: []const u8, end: []const u8, reg: ir.Reg };

/// Matches `L: beq x, $zero, E; nop; <body...>; j L; nop; E:` at `label`.
fn matchLoop(items: []const Item, label: usize, body_len: usize) ?Loop {
    if (label + 5 + body_len >= items.len) return null;
    const head = loopHead(items, label) orelse return null;
    const end = label + 5 + body_len;
    if (!loopTail(items, label + 3 + body_len, head.label)) return null;
    if (items[end] != .label or !std.mem.eql(u8, head.end, items[end].label)) return null;
    return head;
}

/// `L: beq x, $zero, E; nop`
fn loopHead(items: []const Item, label: usize) ?Loop {
    if (items[label] != .label) return null;
    const branch = instructionAt(items, label + 1) orelse return null;
    if (branch.op != .beq or branch.rt != .zero) return null;
    if (!isNopAt(items, label + 2)) return null;
    return .{ .label = items[label].label, .end = branch.symbol.?, .reg = branch.rs };
}

/// `j L; nop`
fn loopTail(items: []const Item, jump: usize, label: []const u8) bool {
    const back = instructionAt(items, jump) orelse return false;
    if (back.op != .j or !isNopAt(items, jump + 1)) return false;
    return std.mem.eql(u8, back.symbol.?, label);
}

fn isNopAt(items: []const Item, index: usize) bool {
    const inst = instructionAt(items, index) orelse return false;
    return inst.isNop();
}

fn bodyRepeats(items: []const Item, before: usize, label: usize, count: usize) bool {
    for (0..count) |offset| {
        const original = instructionAt(items, before + offset) orelse return false;
        const repeated = instructionAt(items, label + 3 + offset) orelse return false;
        if (!sameInst(original, repeated)) return false;
    }
    return true;
}

fn backEdge(loop: Loop, reg: ir.Reg) Item {
    return .{ .instruction = .{ .op = .bne, .rs = reg, .symbol = loop.label } };
}

fn foldTwoOperationLoop(items: *Items, label: usize) !bool {
    if (label < 2 or label + 7 >= items.items.len) return false;
    const loop = matchLoop(items.items, label, 2) orelse return false;
    if (!bodyRepeats(items.items, label - 2, label, 2)) return false;
    const list = items.items;
    const mask = list[label - 1];
    const read = list[label - 2];
    const end = list[label + 7];
    list[label - 1] = list[label];
    list[label] = mask;
    list[label + 1] = backEdge(loop, loop.reg);
    list[label + 2] = read;
    list[label + 3] = end;
    items.replaceRangeAssumeCapacity(label + 4, 4, &.{});
    return true;
}

fn foldSingleOperationLoop(items: *Items, label: usize) void {
    const loop = matchLoop(items.items, label, 1) orelse return;
    const read = instructionAt(items.items, label - 1) orelse return;
    const read_writes = effects.of(read).scalar_writes;
    if (read_writes & effects.scalarBit(loop.reg) == 0 or !bodyRepeats(items.items, label - 1, label, 1)) return;
    const list = items.items;
    const end = list[label + 6];
    list[label - 1] = list[label];
    list[label] = .{ .instruction = read };
    list[label + 1] = backEdge(loop, loop.reg);
    list[label + 3] = end;
    items.replaceRangeAssumeCapacity(label + 4, 3, &.{});
    fillPollingSlot(items, label + 2, read_writes);
}

/// Work after the exit that only rewrites the polled registers can run in
/// the slot: busy iterations overwrite it with the next read, and the
/// exiting iteration keeps the original result.
fn fillPollingSlot(items: *Items, slot: usize, read_writes: u32) void {
    const candidate = rewritableAt(items.items, slot + 2) orelse return;
    if (!fitsPollingSlot(effects.of(candidate), read_writes)) return;
    items.items[slot] = items.items[slot + 2];
    _ = items.orderedRemove(slot + 2);
}

/// Pure scalar work that writes only registers the poll rewrites.
fn fitsPollingSlot(candidate: effects.Effects, read_writes: u32) bool {
    if (!isPureScalar(candidate)) return false;
    const writes = candidate.scalar_writes;
    return writes != 0 and writes & ~read_writes == 0 and candidate.scalar_reads & read_writes == 0;
}

/// Writes only scalar registers: no transfer, memory, vector, or state.
fn isPureScalar(candidate: effects.Effects) bool {
    if (candidate.isTransfer() or candidate.memory != null) return false;
    return candidate.vector_writes == 0 and candidate.state_writes.bits() == 0;
}

// -------------------------------------------------------------- delay slots

/// Moves an earlier independent instruction into each `nop` delay slot,
/// unless the timing model says the move makes the code around it slower.
pub fn fillDelaySlots(items: *Items) void {
    var transfer: usize = 0;
    while (transfer + 1 < items.items.len) : (transfer += 1) {
        if (!schedule.hasDelaySlot(items.items[transfer]) or !isNopAt(items.items, transfer + 1)) continue;
        const candidate = slotCandidate(items.items, transfer) orelse continue;
        if (!slotMoveHelps(items.items, candidate, transfer)) continue;
        const moved = items.orderedRemove(candidate);
        transfer -= 1;
        items.items[transfer + 1] = moved;
    }
}

/// Instructions after the slot whose stalls the move can change.
const slot_lookahead = 3;
const max_window = 32;

/// Compares the estimated cycles from `candidate` through a few
/// instructions past the slot, before and after moving it into the slot.
fn slotMoveHelps(items: []const Item, candidate: usize, transfer: usize) bool {
    const end = @min(items.len, transfer + 2 + slot_lookahead);
    if (end - candidate > max_window) return true;
    var moved: [max_window]Item = undefined;
    const window = items[candidate..end];
    const slot = transfer + 1 - candidate;
    @memcpy(moved[0 .. slot - 1], window[1..slot]);
    moved[slot - 1] = window[0];
    @memcpy(moved[slot .. window.len - 1], window[slot + 1 ..]);
    return schedule.estimateCycles(moved[0 .. window.len - 1]) <= schedule.estimateCycles(window);
}

/// The latest instruction before `transfer` that can move after it.
fn slotCandidate(items: []const Item, transfer: usize) ?usize {
    var index = transfer;
    while (index > 0) {
        index -= 1;
        if (!schedule.isMovable(items[index])) return null;
        if (items[index].instruction.isNop()) continue;
        if (canMoveAfter(items, index, transfer)) return index;
    }
    return null;
}

fn canMoveAfter(items: []const Item, from: usize, transfer: usize) bool {
    if (rewritableAt(items, from) == null) return false;
    const moving = effects.of(items[from].instruction);
    for (items[from + 1 .. transfer + 1]) |crossed| {
        if (!independent(moving, effects.of(crossed.instruction))) return false;
    }
    return true;
}

/// No register, state, or memory dependence in either direction.
pub fn independent(a: effects.Effects, b: effects.Effects) bool {
    if (masksConflict(a.scalar_writes, a.scalar_reads, b.scalar_writes, b.scalar_reads)) return false;
    if (masksConflict(a.vector_writes, a.vector_reads, b.vector_writes, b.vector_reads)) return false;
    if (masksConflict(a.state_writes.bits(), a.state_reads.bits(), b.state_writes.bits(), b.state_reads.bits())) return false;
    return !memoryDependent(a, b);
}

fn masksConflict(a_writes: u32, a_reads: u32, b_writes: u32, b_reads: u32) bool {
    return a_writes & (b_writes | b_reads) != 0 or b_writes & a_reads != 0;
}

fn memoryDependent(a: effects.Effects, b: effects.Effects) bool {
    const left = a.memory orelse return false;
    const right = b.memory orelse return false;
    return (left.store or right.store) and effects.mayAlias(left, right);
}

const testing = std.testing;

fn listOf(allocator: std.mem.Allocator, items: []const Item) !Items {
    var list: Items = .empty;
    try list.appendSlice(allocator, items);
    return list;
}

test "relocations fold into the following memory operand" {
    var list = try listOf(testing.allocator, &.{
        .{ .instruction = .{ .op = .addiu, .rt = .at, .symbol = "table", .imm = 4 } },
        .{ .instruction = .{ .op = .lw, .rt = .t0, .rs = .at, .imm = 8 } },
        .{ .instruction = .{ .op = .addiu, .rt = .at, .symbol = "table" } },
        .{ .instruction = .{ .op = .lw, .rt = .t0, .rs = .at } },
        .{ .instruction = .{ .op = .lw, .rt = .t1, .rs = .at, .imm = 4 } },
    });
    defer list.deinit(testing.allocator);
    foldSymbolOffsets(&list);
    try testing.expectEqual(@as(usize, 4), list.items.len);
    const folded = list.items[0].instruction;
    try testing.expectEqualStrings("table", folded.symbol.?);
    try testing.expectEqual(@as(i32, 12), folded.imm);
    try testing.expectEqual(ir.Reg.zero, folded.rs);
    // `$at` is read again, so the second address stays.
    try testing.expectEqual(ir.Op.addiu, list.items[1].instruction.op);
}

test "dead writes go unless state or memory makes them observable" {
    var list = try listOf(testing.allocator, &.{
        .{ .instruction = .{ .op = .addiu, .rt = .t0, .imm = 1 } },
        .{ .instruction = .{ .op = .addiu, .rt = .t0, .imm = 2 } },
        .{ .instruction = .{ .op = .vmudh, .vd = .v01, .vs = .v02, .vt = .v03 } },
        .{ .instruction = .{ .op = .vmadh, .vd = .v01, .vs = .v02, .vt = .v03 } },
        .{ .instruction = .{ .op = .lw, .rt = .t1, .rs = .a0 } },
        .{ .instruction = .{ .op = .addiu, .rt = .t1, .imm = 2 } },
    });
    defer list.deinit(testing.allocator);
    removeDeadWrites(&list);
    try testing.expectEqual(@as(usize, 5), list.items.len);
    try testing.expectEqual(@as(i32, 2), list.items[0].instruction.imm);
    try testing.expect(sameInst(list.items[1].instruction, .{ .op = .vmudh, .vd = .v01, .vs = .v02, .vt = .v03 }));
}

test "delay slots take the latest independent instruction" {
    var list = try listOf(testing.allocator, &.{
        .{ .instruction = .{ .op = .addiu, .rt = .t1, .imm = 2 } },
        .{ .instruction = .{ .op = .addiu, .rt = .t0, .imm = 1 } },
        .{ .instruction = .{ .op = .bne, .rs = .t0, .symbol = "x" } },
        .{ .instruction = .{ .op = .nop } },
    });
    defer list.deinit(testing.allocator);
    fillDelaySlots(&list);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(ir.Reg.t1, list.items[2].instruction.rt);
    try testing.expect(!independent(effects.of(.{ .op = .sw, .rt = .t0, .rs = .a0 }), effects.of(.{ .op = .lw, .rt = .t1, .rs = .a0 })));
    try testing.expect(!sameInst(.{ .op = .j, .symbol = "a" }, .{ .op = .j, .symbol = "b" }));
    try testing.expect(!sameInst(.{ .op = .j, .symbol = "a" }, .{ .op = .j }));
}

test "lane operations spell their destination to avoid nearby writes" {
    var list = try listOf(testing.allocator, &.{
        .{ .instruction = .{ .op = .vadd, .vd = .v01, .vs = .v02, .vt = .v03 } },
        .{ .instruction = .{ .op = .vrcp, .vd = .v04, .dest_element = 1, .vt = .v05, .element = 8 } },
        .{ .instruction = .{ .op = .vmov, .vd = .v06, .dest_element = 10, .vt = .v07, .element = 8 } },
        .{ .label = "next" },
        .{ .instruction = .{ .op = .vmov, .vd = .v06, .dest_element = 9, .vt = .v07, .element = 8, .frozen = true } },
    });
    defer list.deinit(testing.allocator);
    chooseLaneEncodings(list.items);
    try testing.expectEqual(@as(u4, 9), list.items[1].instruction.dest_element);
    try testing.expectEqual(@as(u4, 2), list.items[2].instruction.dest_element);
    try testing.expectEqual(@as(u4, 9), list.items[4].instruction.dest_element);
}
