//! Collects the IR produced by instruction selection. Formatted names live
//! in the emitter's arena, which owns them until `deinit`.
const std = @import("std");
const ir = @import("ir.zig");
const ir_parse = @import("ir_parse.zig");

const Emitter = @This();
const Reg = ir.Reg;
const VReg = ir.VReg;
const Op = ir.Op;

arena: std.heap.ArenaAllocator,
items: std.ArrayList(ir.Item) = .empty,
/// Nesting depth of `exact` blocks; their instructions are frozen.
exact_depth: usize = 0,

pub fn init(allocator: std.mem.Allocator) Emitter {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Emitter) void {
    self.arena.deinit();
    self.* = undefined;
}

fn arenaAllocator(self: *Emitter) std.mem.Allocator {
    return self.arena.allocator();
}

pub fn item(self: *Emitter, value: ir.Item) !void {
    var stored = value;
    switch (stored) {
        .exact_begin => self.exact_depth += 1,
        .exact_end => self.exact_depth -|= 1,
        .instruction => |*instruction| instruction.frozen = instruction.frozen or self.exact_depth != 0,
        else => {},
    }
    try self.items.append(self.arenaAllocator(), stored);
}

pub fn inst(self: *Emitter, value: ir.Inst) !void {
    try self.item(.{ .instruction = value });
}

/// Formats a name owned by the emitter.
pub fn name(self: *Emitter, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(self.arenaAllocator(), fmt, args);
}

pub fn label(self: *Emitter, value: []const u8) !void {
    try self.item(.{ .label = value });
}

pub fn labelFmt(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
    try self.label(try self.name(fmt, args));
}

/// A verbatim assembly line, such as a directive or data.
pub fn text(self: *Emitter, value: []const u8) !void {
    try self.item(.{ .text = value });
}

pub fn textFmt(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
    try self.text(try self.name(fmt, args));
}

pub fn blank(self: *Emitter) !void {
    try self.text("");
}

/// Raw `asm(...)` text: modeled when the IR recognizes it, a barrier otherwise.
pub fn assembly(self: *Emitter, value: []const u8) !void {
    try self.item(ir_parse.parseStatement(value));
}

pub fn exactBegin(self: *Emitter) !void {
    try self.item(.exact_begin);
}

pub fn exactEnd(self: *Emitter) !void {
    try self.item(.exact_end);
}

pub fn nop(self: *Emitter) !void {
    try self.inst(.{ .op = .nop });
}

/// `op rd, rs, rt`
pub fn register(self: *Emitter, op: Op, rd: Reg, rs: Reg, rt: Reg) !void {
    try self.inst(.{ .op = op, .rd = rd, .rs = rs, .rt = rt });
}

/// `op rd, value, amount` for variable shifts.
pub fn shiftVariable(self: *Emitter, op: Op, rd: Reg, value: Reg, amount: Reg) !void {
    try self.inst(.{ .op = op, .rd = rd, .rt = value, .rs = amount });
}

pub fn shift(self: *Emitter, op: Op, rd: Reg, value: Reg, amount: i64) !void {
    try self.inst(.{ .op = op, .rd = rd, .rt = value, .imm = @intCast(amount) });
}

/// `op rt, rs, imm`
pub fn immediate(self: *Emitter, op: Op, rt: Reg, rs: Reg, value: i64) !void {
    try self.inst(.{ .op = op, .rt = rt, .rs = rs, .imm = @truncate(value) });
}

/// `op rt, rs, %lo(symbol + offset)`
pub fn immediateSymbol(self: *Emitter, op: Op, rt: Reg, rs: Reg, symbol: []const u8, offset: i64) !void {
    try self.inst(.{ .op = op, .rt = rt, .rs = rs, .symbol = symbol, .imm = @intCast(offset) });
}

pub fn upper(self: *Emitter, rt: Reg, value: u16) !void {
    try self.inst(.{ .op = .lui, .rt = rt, .imm = value });
}

/// `op rt, offset(base)` or `op rt, %lo(symbol + offset)(base)`
pub fn memory(self: *Emitter, op: Op, rt: Reg, base: Reg, symbol: ?[]const u8, offset: i64) !void {
    try self.inst(.{ .op = op, .rt = rt, .rs = base, .symbol = symbol, .imm = @intCast(offset) });
}

/// `j`, `jal`, or `b` to a symbol.
pub fn jump(self: *Emitter, op: Op, target: []const u8) !void {
    try self.inst(.{ .op = op, .symbol = target });
}

pub fn jumpRegister(self: *Emitter, op: Op, target: Reg) !void {
    try self.inst(.{ .op = op, .rs = target });
}

pub fn branch(self: *Emitter, op: Op, rs: Reg, rt: Reg, target: []const u8) !void {
    try self.inst(.{ .op = op, .rs = rs, .rt = rt, .symbol = target });
}

pub fn branchZero(self: *Emitter, op: Op, rs: Reg, target: []const u8) !void {
    try self.inst(.{ .op = op, .rs = rs, .symbol = target });
}

pub fn cop0(self: *Emitter, op: Op, rt: Reg, index: u5) !void {
    try self.inst(.{ .op = op, .rt = rt, .imm = index });
}

pub fn breakpoint(self: *Emitter, code: u20) !void {
    try self.inst(.{ .op = .@"break", .imm = code });
}

pub fn vector(self: *Emitter, op: Op, vd: VReg, vs: VReg, vt: VReg, element: u4) !void {
    try self.inst(.{ .op = op, .vd = vd, .vs = vs, .vt = vt, .element = element });
}

pub fn vectorLane(self: *Emitter, op: Op, vd: VReg, dest_element: u4, vt: VReg, element: u4) !void {
    try self.inst(.{ .op = op, .vd = vd, .dest_element = dest_element, .vt = vt, .element = element });
}

/// `mfc2`/`mtc2 rt, $vt[lane]`
pub fn laneMove(self: *Emitter, op: Op, rt: Reg, vt: VReg, lane: u3) !void {
    try self.inst(.{ .op = op, .rt = rt, .vt = vt, .element = lane });
}

/// `cfc2`/`ctc2 rt, $index`
pub fn controlMove(self: *Emitter, op: Op, rt: Reg, index: u2) !void {
    try self.inst(.{ .op = op, .rt = rt, .imm = index });
}

pub fn vectorMemory(self: *Emitter, op: Op, vt: VReg, lane: u4, base: Reg, offset: i64, show_lane: bool) !void {
    try self.inst(.{ .op = op, .vt = vt, .element = lane, .rs = base, .imm = @intCast(offset), .show_lane = show_lane });
}

/// Index of the next item, for passes that patch emitted code.
pub fn len(self: *const Emitter) usize {
    return self.items.items.len;
}

const testing = std.testing;

test "the emitter records typed instructions and owned names" {
    var out = Emitter.init(testing.allocator);
    defer out.deinit();
    try out.labelFmt("LABEL_{s}_{d}", .{ "f", 3 });
    try out.immediate(.addiu, .t0, .zero, 1);
    try out.assembly("custom $t0");
    try out.assembly("addiu $t1, $zero, 2");
    try out.vectorMemory(.lqv, .v01, 0, .t0, 16, false);
    try testing.expectEqual(@as(usize, 5), out.len());
    try testing.expectEqualStrings("LABEL_f_3", out.items.items[0].label);
    try testing.expect(out.items.items[2] == .raw);
    try testing.expectEqualStrings("addiu $t1, $zero, 2", out.items.items[3].instruction.text.?);
    try testing.expectEqual(ir.Op.lqv, out.items.items[4].instruction.op);
    try out.exactBegin();
    try out.nop();
    try out.exactEnd();
    try out.nop();
    try testing.expect(out.items.items[6].instruction.frozen);
    try testing.expect(!out.items.items[8].instruction.frozen);
}
