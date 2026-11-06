//! Delay slots of conditional branches filled from the fall-through path.
//! The slot runs on both paths, so one of the next few instructions may
//! move into it when it is independent of those it passes and everything it
//! writes is dead where the branch goes:
//!
//!        beq $t0, $v1, rare             beq $t0, $v1, rare
//!        nop                     =>     srl $t0, $a0, 28
//!        srl $t0, $a0, 28
//!
//! Liveness at the target comes from a bounded walk over the program's IR,
//! following branches and jumps to labels it contains. Calls, returns,
//! indirect jumps, unknown targets, and raw assembly count as reads.
const std = @import("std");
const ir = @import("ir.zig");
const effects = @import("ir_effects.zig");
const schedule = @import("schedule.zig");

const Item = ir.Item;
const Inst = ir.Inst;
const Items = std.ArrayList(Item);

/// Instructions examined along every path before giving up.
const walk_budget = 64;
/// Fall-through instructions considered for each slot.
const scan_limit = 4;

pub fn fillFromFallthrough(items: *Items) void {
    var branch: usize = 0;
    while (branch + 2 < items.items.len) : (branch += 1) {
        const next = candidate(items.items, branch) orelse continue;
        items.items[branch + 1] = items.items[next];
        _ = items.orderedRemove(next);
    }
}

/// A fall-through instruction that may move into the empty slot of the
/// branch at `branch` and also run on the taken path. The branch reads its
/// operands first, so the moved instruction may overwrite them.
fn candidate(items: []const Item, branch: usize) ?usize {
    const target = emptyBranchTarget(items, branch) orelse return null;
    const end = @min(items.len, branch + 2 + scan_limit);
    for (branch + 2..end) |index| {
        if (!schedule.isMovable(items[index])) return null;
        if (movesToSlot(items, branch + 2, index, target)) return index;
    }
    return null;
}

/// Where an unfrozen conditional branch with an empty slot goes.
fn emptyBranchTarget(items: []const Item, branch: usize) ?usize {
    const inst = unfrozen(items, branch) orelse return null;
    if (effects.of(inst).control != .branch or !isFreeSlot(items, branch + 1)) return null;
    return labelIndex(items, inst.symbol orelse return null);
}

/// The instruction at `index` passes those from `first` and is dead at the
/// branch target.
fn movesToSlot(items: []const Item, first: usize, index: usize, target: usize) bool {
    const moving = sideEffectFree(items[index]) orelse return false;
    for (items[first..index]) |passed| {
        if (!@import("peephole.zig").independent(moving, effects.of(passed.instruction))) return false;
    }
    var budget: usize = walk_budget;
    const walk: Walk = .{ .items = items, .budget = &budget };
    return walk.deadFrom(target, Registers.written(moving));
}

/// Effects of work that may run on an extra path: only register writes, no
/// stores, accumulator or flag state, or control effects.
fn sideEffectFree(item: Item) ?effects.Effects {
    if (!schedule.isMovable(item)) return null;
    const moving = effects.of(item.instruction);
    return if (onlyWritesRegisters(moving)) moving else null;
}

fn onlyWritesRegisters(moving: effects.Effects) bool {
    if (moving.memory) |access| if (access.store or access.unknown) return false;
    return moving.state_writes.bits() == 0 and Registers.written(moving).any();
}

/// Scalar and vector registers whose values are still unaccounted for.
const Registers = struct {
    scalar: u32 = 0,
    vector: u32 = 0,

    fn written(effect: effects.Effects) Registers {
        return .{ .scalar = effect.scalar_writes, .vector = effect.vector_writes };
    }

    fn any(self: Registers) bool {
        return self.scalar != 0 or self.vector != 0;
    }

    fn readBy(self: Registers, effect: effects.Effects) bool {
        return self.scalar & effect.scalar_reads != 0 or self.vector & effect.vector_reads != 0;
    }

    /// What remains after `effect` overwrites some of the registers.
    fn without(self: Registers, effect: effects.Effects) Registers {
        return .{ .scalar = self.scalar & ~effect.scalar_writes, .vector = self.vector & ~effect.vector_writes };
    }
};

/// A liveness walk. A call is followed into its callee once, and the
/// callee's `jr $ra` resumes after the call.
const Walk = struct {
    items: []const Item,
    budget: *usize,
    return_to: ?usize = null,

    /// True when every register in `registers` is written before it is
    /// read along every path from `start`.
    fn deadFrom(self: Walk, start: usize, registers: Registers) bool {
        var pending = registers;
        var index = start;
        while (index < self.items.len) : (index += 1) {
            if (isLayoutOnly(self.items[index])) continue;
            const effect = self.take(index) orelse return false;
            const outcome = self.step(index, effect, &pending);
            if (outcome != .unknown) return outcome == .dead;
        }
        return false;
    }

    const Outcome = enum { dead, live, unknown };

    /// Applies one instruction; `unknown` continues to the next.
    fn step(self: Walk, index: usize, effect: effects.Effects, pending: *Registers) Outcome {
        if (pending.readBy(effect)) return .live;
        if (effect.isTransfer()) return if (self.afterTransfer(index, pending.*)) .dead else .live;
        pending.* = pending.without(effect);
        return if (pending.any()) .unknown else .dead;
    }

    /// The effects of the instruction at `index`, charged to the budget;
    /// null for anything the walk cannot see through.
    fn take(self: Walk, index: usize) ?effects.Effects {
        if (self.items[index] != .instruction or self.budget.* == 0) return null;
        self.budget.* -= 1;
        return effects.of(self.items[index].instruction);
    }

    /// Continues through a transfer's slot to where it goes.
    fn afterTransfer(self: Walk, index: usize, registers: Registers) bool {
        const inst = self.items[index].instruction;
        const control = effects.of(inst).control;
        if (control == .halt) return true;
        const pending = self.afterSlot(index, registers) orelse return false;
        return !pending.any() or self.follow(control, index, pending);
    }

    fn follow(self: Walk, control: effects.Control, index: usize, pending: Registers) bool {
        const inst = self.items[index].instruction;
        if (control == .branch) return self.toLabel(inst, pending) and self.deadFrom(index + 2, pending);
        if (control == .jump) return self.toLabel(inst, pending);
        return self.leave(control, index, pending);
    }

    /// Calls are followed once; only a followed call's `jr $ra` returns.
    fn leave(self: Walk, control: effects.Control, index: usize, pending: Registers) bool {
        const inst = self.items[index].instruction;
        if (control == .call) return self.intoCall(inst, index + 2, pending);
        return control == .indirect_jump and self.returns(inst, pending);
    }

    /// The registers still pending after the slot, or null if it reads one.
    fn afterSlot(self: Walk, index: usize, registers: Registers) ?Registers {
        if (index + 1 >= self.items.len or self.items[index + 1] != .instruction) return null;
        const slot = effects.of(self.items[index + 1].instruction);
        if (registers.readBy(slot)) return null;
        return registers.without(slot);
    }

    fn toLabel(self: Walk, inst: Inst, registers: Registers) bool {
        const target = labelIndex(self.items, inst.symbol orelse return false) orelse return false;
        return self.deadFrom(target, registers);
    }

    fn intoCall(self: Walk, inst: Inst, resume_at: usize, registers: Registers) bool {
        if (self.return_to != null) return false;
        var callee = self;
        callee.return_to = resume_at;
        return callee.toLabel(inst, registers);
    }

    fn returns(self: Walk, inst: Inst, registers: Registers) bool {
        const resume_at = self.return_to orelse return false;
        if (inst.rs != .ra) return false;
        var caller = self;
        caller.return_to = null;
        return caller.deadFrom(resume_at, registers);
    }
};

/// Labels, blank lines, and symbol visibility between functions.
fn isLayoutOnly(item: Item) bool {
    return switch (item) {
        .label => true,
        .text => |line| line.len == 0 or std.mem.startsWith(u8, line, ".globl"),
        else => false,
    };
}

pub fn labelIndex(items: []const Item, name: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (item == .label and std.mem.eql(u8, item.label, name)) return index;
    }
    return null;
}

fn isFreeSlot(items: []const Item, index: usize) bool {
    const inst = unfrozen(items, index) orelse return false;
    return inst.isNop();
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
    fillFromFallthrough(&list);
    return list;
}

test "fall-through work fills a slot when the target overwrites it" {
    var list = try run(&.{
        .{ .instruction = .{ .op = .beq, .rs = .t1, .rt = .v1, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 28 } },
        .{ .instruction = .{ .op = .@"break" } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .addiu, .rt = .t1, .imm = 36 } },
        .{ .instruction = .{ .op = .j, .symbol = "next" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .text = "" },
        .{ .text = ".globl next" },
        .{ .label = "next" },
        .{ .instruction = .{ .op = .@"break" } },
    });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.srl, list.items[1].instruction.op);
    try testing.expectEqual(@as(usize, 11), list.items.len);
}

test "fall-through work stays when the target may read it" {
    var reads = try run(&.{
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 28 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .addu, .rd = .t2, .rs = .t1, .rt = .t1 } },
    });
    defer reads.deinit(testing.allocator);
    try testing.expect(reads.items[1].instruction.isNop());

    var returns = try run(&.{
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 28 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .jr, .rs = .ra } },
        .{ .instruction = .{ .op = .nop } },
    });
    defer returns.deinit(testing.allocator);
    try testing.expect(returns.items[1].instruction.isNop());

    var call_slot = try run(&.{
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 28 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .jal, .symbol = "elsewhere" } },
        .{ .instruction = .{ .op = .addiu, .rt = .t1, .imm = 255 } },
    });
    defer call_slot.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.srl, call_slot.items[1].instruction.op);

    var through_call = try run(&.{
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .srl, .rd = .t2, .rt = .a0, .imm = 28 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .jal, .symbol = "callee" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .@"break" } },
        .{ .label = "callee" },
        .{ .instruction = .{ .op = .jr, .rs = .ra } },
        .{ .instruction = .{ .op = .addiu, .rt = .t2, .imm = 12 } },
    });
    defer through_call.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.srl, through_call.items[1].instruction.op);

    var returned_live = try run(&.{
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .srl, .rd = .t2, .rt = .a0, .imm = 28 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .jal, .symbol = "callee" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .addu, .rd = .t3, .rs = .t2, .rt = .zero } },
        .{ .label = "callee" },
        .{ .instruction = .{ .op = .jr, .rs = .ra } },
        .{ .instruction = .{ .op = .nop } },
    });
    defer returned_live.deinit(testing.allocator);
    try testing.expect(returned_live.items[1].instruction.isNop());

    var stores = try run(&.{
        .{ .instruction = .{ .op = .beq, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .sw, .rt = .t1, .rs = .a0 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .@"break" } },
    });
    defer stores.deinit(testing.allocator);
    try testing.expect(stores.items[1].instruction.isNop());
}

test "a later independent instruction may fill the slot" {
    var list = try run(&.{
        .{ .instruction = .{ .op = .beqz, .rs = .t1, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .add, .rd = .gp, .rs = .gp, .rt = .t7 } },
        .{ .instruction = .{ .op = .sll, .rd = .t2, .rt = .t2, .imm = 2 } },
        .{ .instruction = .{ .op = .@"break" } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .addu, .rd = .t3, .rs = .gp, .rt = .zero } },
        .{ .instruction = .{ .op = .@"break" } },
    });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.sll, list.items[1].instruction.op);
    try testing.expectEqual(ir.Op.add, list.items[2].instruction.op);
}

test "vector loads move when the target overwrites the register" {
    var list = try run(&.{
        .{ .instruction = .{ .op = .bne, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .lqv, .vt = .v02, .imm = 32 } },
        .{ .instruction = .{ .op = .@"break" } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .vadd, .vd = .v02, .vs = .v01, .vt = .v01 } },
        .{ .instruction = .{ .op = .@"break" } },
    });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.lqv, list.items[1].instruction.op);

    var read = try run(&.{
        .{ .instruction = .{ .op = .bne, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .lqv, .vt = .v02, .imm = 32 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .vadd, .vd = .v01, .vs = .v02, .vt = .v02 } },
        .{ .instruction = .{ .op = .@"break" } },
    });
    defer read.deinit(testing.allocator);
    try testing.expect(read.items[1].instruction.isNop());

    var accumulates = try run(&.{
        .{ .instruction = .{ .op = .bne, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .vxor, .vd = .v00, .vs = .v00, .vt = .v00 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .@"break" } },
    });
    defer accumulates.deinit(testing.allocator);
    try testing.expect(accumulates.items[1].instruction.isNop());
}

test "the walk follows both branch paths and the slot" {
    var list = try run(&.{
        .{ .instruction = .{ .op = .bne, .rs = .t0, .symbol = "rare" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .srl, .rd = .t1, .rt = .a0, .imm = 1 } },
        .{ .label = "rare" },
        .{ .instruction = .{ .op = .bgez, .rs = .a1, .symbol = "skip" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .addu, .rd = .t2, .rs = .t1, .rt = .zero } },
        .{ .label = "skip" },
        .{ .instruction = .{ .op = .@"break" } },
    });
    defer list.deinit(testing.allocator);
    try testing.expect(list.items[1].instruction.isNop());
}
