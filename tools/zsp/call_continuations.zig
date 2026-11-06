//! A call whose code continues with a jump returns straight to the jump's
//! target, saving the jump:
//!
//!        jal f                          addiu $ra, $zero, %lo(next)
//!        <slot>                  =>     j f
//!        j next                         <slot>
//!        nop
//!
//! as when a loop body ends with a call and repeats. Afterwards `$ra` holds
//! `next` instead of the address of the removed jump; anything that returns
//! through it still lands at `next`, so only the slot must leave `$ra`
//! alone. Labels between the slot and the jump may stay only if nothing
//! branches to them, so transfers to a lone `j target; nop` are first sent
//! to `target` directly.
const std = @import("std");
const ir = @import("ir.zig");
const effects = @import("ir_effects.zig");
const branch_slots = @import("branch_slots.zig");

const Item = ir.Item;
const Inst = ir.Inst;
const Items = std.ArrayList(Item);

pub fn continueAtJumps(items: *Items) void {
    threadJumps(items.items);
    var index: usize = 0;
    while (index + 3 < items.items.len) : (index += 1) {
        const found = continuation(items.items, index) orelse continue;
        rewrite(items, index, found);
    }
}

/// `jal f; slot; labels; j target; nop` becomes
/// `addiu $ra, $zero, %lo(target); j f; slot; labels`.
fn rewrite(items: *Items, index: usize, found: Continuation) void {
    var call = items.items[index].instruction;
    call.op = .j;
    const slot = items.items[index + 1];
    // Shift the labels over the jump, making room for the slot.
    var label = found.jump;
    while (label > index + 2) : (label -= 1) items.items[label] = items.items[label - 1];
    items.items[index] = .{ .instruction = .{ .op = .addiu, .rt = .ra, .rs = .zero, .symbol = found.target } };
    items.items[index + 1] = .{ .instruction = call };
    items.items[index + 2] = slot;
    _ = items.orderedRemove(found.jump + 1);
}

const Continuation = struct { target: []const u8, jump: usize };

/// Where a call at `index` can return to directly, if it qualifies.
fn continuation(items: []const Item, index: usize) ?Continuation {
    if (!isMovableCall(items, index)) return null;
    const jump = nextInstruction(items, index + 2) orelse return null;
    const target = localJumpTarget(items, jump) orelse return null;
    return .{ .target = target, .jump = jump };
}

/// An unfrozen direct call whose slot leaves `$ra` alone.
fn isMovableCall(items: []const Item, index: usize) bool {
    const call = unfrozen(items, index) orelse return false;
    if (call.op != .jal or call.symbol == null) return false;
    const slot = unfrozen(items, index + 1) orelse return false;
    return !touchesReturnAddress(effects.of(slot));
}

/// The label of a `j label; nop` at `index` in this program.
fn localJumpTarget(items: []const Item, index: usize) ?[]const u8 {
    const target = plainJumpAt(items, index) orelse return null;
    _ = branch_slots.labelIndex(items, target) orelse return null;
    return target;
}

/// The target of an unfrozen `j target` with a free `nop` slot.
fn plainJumpAt(items: []const Item, index: usize) ?[]const u8 {
    const jump = unfrozen(items, index) orelse return null;
    if (jump.op != .j or !isFreeNop(items, index + 1)) return null;
    return jump.symbol;
}

/// The next instruction from `start`, past labels nothing transfers to.
fn nextInstruction(items: []const Item, start: usize) ?usize {
    var index = start;
    while (index < items.len) : (index += 1) {
        switch (items[index]) {
            .instruction => return index,
            .label => |name| if (referenced(items, name)) return null,
            else => return null,
        }
    }
    return null;
}

fn referenced(items: []const Item, name: []const u8) bool {
    for (items) |item| {
        if (item != .instruction) continue;
        const symbol = item.instruction.symbol orelse continue;
        if (std.mem.eql(u8, symbol, name)) return true;
    }
    return false;
}

/// Sends each unfrozen direct transfer that lands on `j target; nop` to
/// `target` itself.
fn threadJumps(items: []Item) void {
    for (items) |*item| {
        if (item.* != .instruction or item.instruction.frozen) continue;
        const inst = &item.instruction;
        if (!isDirectTransfer(inst.*)) continue;
        if (lonelyJumpTarget(items, inst.symbol.?)) |target| inst.symbol = target;
    }
}

fn isDirectTransfer(inst: Inst) bool {
    const control = effects.of(inst).control;
    return inst.symbol != null and (control == .branch or control == .jump);
}

/// The target of the `j target; nop` at label `name`, if that is all the
/// code there does.
fn lonelyJumpTarget(items: []const Item, name: []const u8) ?[]const u8 {
    const label = branch_slots.labelIndex(items, name) orelse return null;
    const target = plainJumpAt(items, pastLabels(items, label + 1)) orelse return null;
    return if (std.mem.eql(u8, target, name)) null else target;
}

fn pastLabels(items: []const Item, start: usize) usize {
    var index = start;
    while (index < items.len and items[index] == .label) index += 1;
    return index;
}

fn touchesReturnAddress(effect: effects.Effects) bool {
    const bit = effects.scalarBit(.ra);
    return (effect.scalar_reads | effect.scalar_writes) & bit != 0;
}

fn isFreeNop(items: []const Item, index: usize) bool {
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
    continueAtJumps(&list);
    return list;
}

const loop = [_]Item{
    .{ .label = "top" },
    .{ .instruction = .{ .op = .lw, .rt = .a0, .rs = .s0 } },
    .{ .instruction = .{ .op = .jal, .symbol = "send" } },
    .{ .instruction = .{ .op = .addiu, .rt = .s0, .rs = .s0, .imm = 4 } },
    .{ .instruction = .{ .op = .j, .symbol = "top" } },
    .{ .instruction = .{ .op = .nop } },
};

test "a call before a jump returns straight to the jump's target" {
    var list = try run(&loop);
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), list.items.len);
    const ra = list.items[2].instruction;
    try testing.expectEqual(ir.Op.addiu, ra.op);
    try testing.expectEqual(ir.Reg.ra, ra.rt);
    try testing.expectEqualStrings("top", ra.symbol.?);
    try testing.expectEqual(ir.Op.j, list.items[3].instruction.op);
    try testing.expectEqualStrings("send", list.items[3].instruction.symbol.?);
    try testing.expectEqual(ir.Op.addiu, list.items[4].instruction.op);
}

test "the call stays when its slot uses the return address or the jump goes elsewhere" {
    var outside = try run(&.{
        .{ .instruction = .{ .op = .jal, .symbol = "send" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .j, .symbol = "commandLoop" } },
        .{ .instruction = .{ .op = .nop } },
    });
    defer outside.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.jal, outside.items[0].instruction.op);

    var slot = try run(&.{
        .{ .label = "top" },
        .{ .instruction = .{ .op = .jal, .symbol = "send" } },
        .{ .instruction = .{ .op = .addu, .rd = .t0, .rs = .ra, .rt = .zero } },
        .{ .instruction = .{ .op = .j, .symbol = "top" } },
        .{ .instruction = .{ .op = .nop } },
    });
    defer slot.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.jal, slot.items[1].instruction.op);
}

test "transfers to a lone jump go to its target, and the call skips the unused label" {
    var list = try run(&.{
        .{ .label = "top" },
        .{ .instruction = .{ .op = .bgez, .rs = .a1, .symbol = "send_it" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .instruction = .{ .op = .j, .symbol = "again" } },
        .{ .instruction = .{ .op = .nop } },
        .{ .label = "send_it" },
        .{ .instruction = .{ .op = .jal, .symbol = "send" } },
        .{ .instruction = .{ .op = .addiu, .rt = .a2, .rs = .a2, .imm = 8 } },
        .{ .label = "again" },
        .{ .instruction = .{ .op = .j, .symbol = "top" } },
        .{ .instruction = .{ .op = .nop } },
    });
    defer list.deinit(testing.allocator);
    // The skip now jumps to the loop head itself.
    try testing.expectEqualStrings("top", list.items[3].instruction.symbol.?);
    try testing.expectEqual(@as(usize, 10), list.items.len);
    try testing.expectEqualStrings("top", list.items[6].instruction.symbol.?);
    try testing.expectEqual(ir.Op.j, list.items[7].instruction.op);
    try testing.expectEqual(ir.Op.addiu, list.items[8].instruction.op);
    try testing.expectEqualStrings("again", list.items[9].label);
}
