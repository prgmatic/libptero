//! Delay slots of backward loop branches. When no instruction inside the
//! loop can fill the slot, the first instruction after the loop may: it runs
//! once per iteration instead of once after the exit, which is harmless when
//! the loop never reads a register it writes before writing it again.
//! Loads qualify too: the copy that runs after the last iteration reads the
//! same memory the original would have.
//!
//!     L: mfc0 $at, $5               L: mfc0 $at, $5
//!        bne $at, $zero, L     =>      bne $at, $zero, L
//!        nop                           andi $at, $t0, 4095
//!        andi $at, $t0, 4095
const std = @import("std");
const ir = @import("ir.zig");
const effects = @import("ir_effects.zig");
const schedule = @import("schedule.zig");

const Item = ir.Item;
const Inst = ir.Inst;
const Items = std.ArrayList(Item);

pub fn fillLoopExitSlots(items: *Items) void {
    var branch: usize = 0;
    while (branch + 2 < items.items.len) : (branch += 1) {
        const exit = exitCandidate(items.items, branch) orelse continue;
        items.items[branch + 1] = items.items[exit];
        _ = items.orderedRemove(exit);
    }
}

/// The instruction after the loop closed by the branch at `branch`, when it
/// may move into the branch's empty slot.
fn exitCandidate(items: []const Item, branch: usize) ?usize {
    const head = loopHead(items, branch) orelse return null;
    if (!isFreeSlot(items, branch + 1)) return null;
    const exit = firstAfter(items, branch + 2) orelse return null;
    const moving = movableScalar(items[exit]) orelse return null;
    return if (repeatable(items[head + 1 .. branch], items[branch].instruction, moving)) exit else null;
}

/// Running `moving` after every iteration leaves the loop's reads intact
/// and does not compound: registers the loop keeps, it may not read.
fn repeatable(body: []const Item, branch: Inst, moving: effects.Effects) bool {
    const kept = keptByLoop(body, branch, moving.scalar_writes) orelse return false;
    return kept & moving.scalar_reads == 0;
}

/// The label a backward conditional branch at `index` targets.
fn loopHead(items: []const Item, index: usize) ?usize {
    const inst = unfrozen(items, index) orelse return null;
    if (effects.of(inst).control != .branch) return null;
    return labelBefore(items, index, inst.symbol orelse return null);
}

fn labelBefore(items: []const Item, index: usize, name: []const u8) ?usize {
    var head = index;
    while (head > 0) {
        head -= 1;
        if (items[head] == .label and std.mem.eql(u8, items[head].label, name)) return head;
    }
    return null;
}

fn isFreeSlot(items: []const Item, index: usize) bool {
    const inst = unfrozen(items, index) orelse return false;
    return inst.isNop();
}

/// The first instruction at or after `start`, skipping labels no transfer
/// targets: a referenced label is another path into the moved instruction.
fn firstAfter(items: []const Item, start: usize) ?usize {
    for (items[start..], start..) |item, index| {
        switch (item) {
            .instruction => return index,
            .label => |name| if (isReferenced(items, name)) return null,
            else => return null,
        }
    }
    return null;
}

fn isReferenced(items: []const Item, name: []const u8) bool {
    for (items) |item| {
        if (item != .instruction) continue;
        const symbol = item.instruction.symbol orelse continue;
        if (std.mem.eql(u8, symbol, name)) return true;
    }
    return false;
}

/// Effects of scalar-only work that may run repeatedly: no stores, state,
/// vector, or control effects, and not frozen.
fn movableScalar(item: Item) ?effects.Effects {
    if (!schedule.isMovable(item)) return null;
    const moving = effects.of(item.instruction);
    return if (writesOnlyScalars(moving)) moving else null;
}

fn writesOnlyScalars(moving: effects.Effects) bool {
    if (moving.memory) |access| if (access.store) return false;
    if (moving.vector_writes != 0 or moving.state_writes.bits() != 0) return false;
    return moving.scalar_writes != 0;
}

/// The registers in `registers` that `body` may leave unwritten, or null
/// when the body or its closing `branch` may read one before the body
/// writes it again. Transfers must stay inside the body.
fn keptByLoop(body: []const Item, branch: Inst, registers: u32) ?u32 {
    var scan: Scan = .{ .body = body, .pending = registers };
    for (body) |item| {
        if (!scan.step(item)) return null;
    }
    if (effects.of(branch).scalar_reads & scan.pending != 0) return null;
    return scan.pending;
}

/// Walks a loop body. Writes count only on the straight prefix every
/// iteration runs; past a label or a branch, paths differ.
const Scan = struct {
    body: []const Item,
    pending: u32,
    straight: bool = true,

    fn step(self: *Scan, item: Item) bool {
        switch (item) {
            .label => self.straight = false,
            .instruction => |inst| return self.visit(inst),
            else => return false,
        }
        return true;
    }

    fn visit(self: *Scan, inst: Inst) bool {
        const inst_effects = effects.of(inst);
        if (inst_effects.scalar_reads & self.pending != 0) return false;
        if (inst_effects.isTransfer()) {
            if (!branchesWithin(self.body, inst)) return false;
            self.straight = false;
        }
        if (self.straight) self.pending &= ~inst_effects.scalar_writes;
        return true;
    }
};

/// Whether `inst` is a jump or branch to a label in `body`.
fn branchesWithin(body: []const Item, inst: Inst) bool {
    const control = effects.of(inst).control;
    if (control != .branch and control != .jump) return false;
    return hasLabel(body, inst.symbol orelse return false);
}

fn hasLabel(body: []const Item, name: []const u8) bool {
    for (body) |item| {
        if (item == .label and std.mem.eql(u8, item.label, name)) return true;
    }
    return false;
}

fn unfrozen(items: []const Item, index: usize) ?Inst {
    if (index >= items.len or items[index] != .instruction) return null;
    const inst = items[index].instruction;
    return if (inst.frozen) null else inst;
}

const testing = std.testing;

fn run(source: []const Item) !Items {
    var list: Items = .empty;
    try list.appendSlice(testing.allocator, source);
    fillLoopExitSlots(&list);
    return list;
}

test "work after a polling loop fills its back-edge slot" {
    var list = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .mfc0, .rt = .at, .imm = 5 } },
        .{ .instruction = .{ .op = .bne, .rs = .at, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .label = "unused" },
        .{ .instruction = .{ .op = .andi, .rt = .at, .rs = .t0, .imm = 4095 } },
    });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), list.items.len);
    try testing.expectEqual(ir.Op.andi, list.items[3].instruction.op);
    try testing.expectEqualStrings("unused", list.items[4].label);
}

test "exit work may write a register the loop never touches" {
    var list = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .mfc0, .rt = .t2, .imm = 11 } },
        .{ .instruction = .{ .op = .@"and", .rd = .t2, .rs = .t2, .rt = .t0 } },
        .{ .instruction = .{ .op = .bne, .rs = .t2, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .lw, .rt = .s0, .rs = .zero, .imm = 4 } },
    });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.lw, list.items[4].instruction.op);

    var branch_reads = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .mfc0, .rt = .t2, .imm = 11 } },
        .{ .instruction = .{ .op = .bne, .rs = .t2, .rt = .s0, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .lw, .rt = .s0, .rs = .zero, .imm = 4 } },
    });
    defer branch_reads.deinit(testing.allocator);
    try testing.expect(branch_reads.items[3].instruction.isNop());

    var compounding = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .mfc0, .rt = .t2, .imm = 11 } },
        .{ .instruction = .{ .op = .bne, .rs = .t2, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .addi, .rt = .s0, .rs = .s0, .imm = 1 } },
    });
    defer compounding.deinit(testing.allocator);
    try testing.expect(compounding.items[3].instruction.isNop());
}

test "exit work stays for stores, results the loop reads, or another entry" {
    var reads = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .addu, .rd = .at, .rs = .t0, .rt = .t1 } },
        .{ .instruction = .{ .op = .bne, .rs = .at, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .andi, .rt = .t0, .rs = .t2, .imm = 1 } },
    });
    defer reads.deinit(testing.allocator);
    try testing.expect(reads.items[3].instruction.isNop());

    var entered = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .mfc0, .rt = .at, .imm = 5 } },
        .{ .instruction = .{ .op = .bne, .rs = .at, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .label = "E" },
        .{ .instruction = .{ .op = .andi, .rt = .at, .rs = .t0, .imm = 1 } },
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "E" } },
        .{ .instruction = .{ .op = .nop } },
    });
    defer entered.deinit(testing.allocator);
    try testing.expect(entered.items[3].instruction.isNop());

    var memory = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .mfc0, .rt = .at, .imm = 5 } },
        .{ .instruction = .{ .op = .bne, .rs = .at, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .sw, .rt = .at, .rs = .t0 } },
    });
    defer memory.deinit(testing.allocator);
    try testing.expect(memory.items[3].instruction.isNop());

    var load = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .mfc0, .rt = .at, .imm = 5 } },
        .{ .instruction = .{ .op = .bne, .rs = .at, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .lw, .rt = .at, .rs = .t0 } },
    });
    defer load.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.lw, load.items[3].instruction.op);
}

test "forward branches and missing exits leave the slot alone" {
    var forward = try run(&.{
        .{ .instruction = .{ .op = .bne, .rs = .at, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .label = "L" },
        .{ .instruction = .{ .op = .andi, .rt = .at, .rs = .t0, .imm = 1 } },
    });
    defer forward.deinit(testing.allocator);
    try testing.expect(forward.items[1].instruction.isNop());

    var unlabeled = try run(&.{
        .{ .instruction = .{ .op = .mfc0, .rt = .at, .imm = 5 } },
        .{ .instruction = .{ .op = .bne, .rs = .at } },
        .{ .instruction = .{ .op = .nop } },
        .{ .label = "end" },
    });
    defer unlabeled.deinit(testing.allocator);
    try testing.expect(unlabeled.items[2].instruction.isNop());
}

test "a loop with internal branches still fills its back-edge slot" {
    var list = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "skip" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .addi, .rt = .t0, .rs = .t0, .imm = 36 } },
        .{ .label = "skip" },
        .{ .instruction = .{ .op = .addi, .rt = .t6, .rs = .t6, .imm = 36 } },
        .{ .instruction = .{ .op = .bne, .rs = .t6, .rt = .t8, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .sub, .rd = .t1, .rs = .t0, .rt = .t3 } },
    });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), list.items.len);
    try testing.expectEqual(ir.Op.sub, list.items[7].instruction.op);
}

test "exit work stays out of a loop whose branches leave it or read its result" {
    var leaving = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "out" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .bne, .rs = .t6, .rt = .t8, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .sub, .rd = .t1, .rs = .t0, .rt = .t3 } },
        .{ .label = "out" },
    });
    defer leaving.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.nop, leaving.items[4].instruction.op);
    var reading = try run(&.{
        .{ .label = "L" },
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "skip" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .addi, .rt = .t1, .rs = .t0, .imm = 4 } },
        .{ .label = "skip" },
        .{ .instruction = .{ .op = .sw, .rt = .t1, .rs = .zero } },
        .{ .instruction = .{ .op = .bne, .rs = .t6, .rt = .t8, .symbol = "L" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .sub, .rd = .t1, .rs = .t0, .rt = .t3 } },
    });
    defer reading.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.nop, reading.items[7].instruction.op);
}
