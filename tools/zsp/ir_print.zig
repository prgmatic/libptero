//! Renders IR items as GNU-style assembly. Scalar instructions print as
//! mnemonics; vector and COP2 instructions print as `.word` encodings with a
//! readable comment, since the host assembler has no RSP vector mnemonics.
const std = @import("std");
const ir = @import("ir.zig");
const regName = @import("registers.zig").regName;
const vectorRegName = @import("registers.zig").vectorRegName;

const Writer = std.Io.Writer;
const Inst = ir.Inst;

pub fn writeItems(writer: *Writer, items: []const ir.Item) !void {
    for (items) |item| try writeItem(writer, item);
}

pub fn writeItem(writer: *Writer, item: ir.Item) !void {
    switch (item) {
        .instruction => |inst| try writeInstruction(writer, inst),
        .label => |name| try writer.print("{s}:\n", .{name}),
        .text => |text| try writer.print("{s}\n", .{text}),
        .raw => |text| try writer.print("  {s}\n", .{text}),
        .exact_begin, .exact_end => try writeExactMarker(writer, item == .exact_begin),
    }
}

fn writeExactMarker(writer: *Writer, begin: bool) !void {
    try writer.print("# zsp exact block {s}\n", .{if (begin) "begin" else "end"});
}

pub fn writeInstruction(writer: *Writer, inst: Inst) !void {
    if (inst.text) |text| return writer.print("  {s}\n", .{text});
    try printers.get(inst.op.format())(writer, inst);
    try writer.writeByte('\n');
}

const Printer = *const fn (*Writer, Inst) Writer.Error!void;

const printers = std.EnumArray(ir.Format, Printer).init(.{
    .none = &printBare,
    .breakpoint = &printBreak,
    .register = &printRegister,
    .shift_variable = &printShiftVariable,
    .shift = &printShift,
    .immediate = &printImmediate,
    .upper = &printUpper,
    .memory = &printMemory,
    .jump = &printTarget,
    .jump_register = &printJumpRegister,
    .branch_compare = &printBranchCompare,
    .branch_zero = &printBranchZero,
    .branch_always = &printTarget,
    .cop0 = &printCop0,
    .cop2_lane = &printCop2Lane,
    .cop2_control = &printCop2Control,
    .vector = &printVector,
    .vector_lane = &printVectorLane,
    .vector_memory = &printVectorMemory,
});

fn mnemonic(inst: Inst) []const u8 {
    // `jalr` keeps the assembler's `jal $reg` spelling.
    return if (inst.op == .jalr) "jal" else inst.op.mnemonic();
}

fn printBare(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s}", .{mnemonic(inst)});
}

fn printBreak(writer: *Writer, inst: Inst) !void {
    if (inst.imm == 0) return writer.writeAll("  break");
    try writer.print("  break 0x{x}", .{@as(u32, @bitCast(inst.imm))});
}

fn printRegister(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, {s}, {s}", .{ mnemonic(inst), regName(inst.rd), regName(inst.rs), regName(inst.rt) });
}

fn printShiftVariable(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, {s}, {s}", .{ mnemonic(inst), regName(inst.rd), regName(inst.rt), regName(inst.rs) });
}

fn printShift(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, {s}, {d}", .{ mnemonic(inst), regName(inst.rd), regName(inst.rt), inst.imm });
}

/// `imm` or `%lo(symbol)`/`%lo(symbol + imm)` for relocated operands.
fn printOperandValue(writer: *Writer, inst: Inst) !void {
    const symbol = inst.symbol orelse return writer.print("{d}", .{inst.imm});
    if (inst.imm == 0) return writer.print("%lo({s})", .{symbol});
    try writer.print("%lo({s} + {d})", .{ symbol, inst.imm });
}

fn printImmediate(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, {s}, ", .{ mnemonic(inst), regName(inst.rt), regName(inst.rs) });
    try printOperandValue(writer, inst);
}

fn printUpper(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, ", .{ mnemonic(inst), regName(inst.rt) });
    try printOperandValue(writer, inst);
}

fn printMemory(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, ", .{ mnemonic(inst), regName(inst.rt) });
    try printOperandValue(writer, inst);
    try writer.print("({s})", .{regName(inst.rs)});
}

fn printTarget(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}", .{ mnemonic(inst), inst.symbol orelse "" });
}

fn printJumpRegister(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}", .{ mnemonic(inst), regName(inst.rs) });
}

fn printBranchCompare(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, {s}, {s}", .{ mnemonic(inst), regName(inst.rs), regName(inst.rt), inst.symbol orelse "" });
}

fn printBranchZero(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, {s}", .{ mnemonic(inst), regName(inst.rs), inst.symbol orelse "" });
}

fn printCop0(writer: *Writer, inst: Inst) !void {
    try writer.print("  {s} {s}, ${d}", .{ mnemonic(inst), regName(inst.rt), inst.imm });
}

fn printWord(writer: *Writer, inst: Inst) !void {
    try writer.print("  .word 0x{x:0>8} # {s} ", .{ inst.encode(), mnemonic(inst) });
}

fn printCop2Lane(writer: *Writer, inst: Inst) !void {
    try printWord(writer, inst);
    try writer.print("{s}, ${s}[{d}]", .{ regName(inst.rt), vectorRegName(inst.vt), inst.element });
}

fn printCop2Control(writer: *Writer, inst: Inst) !void {
    try printWord(writer, inst);
    try writer.print("{s}, ${d}", .{ regName(inst.rt), inst.imm });
}

fn printVector(writer: *Writer, inst: Inst) !void {
    try printWord(writer, inst);
    try writer.print("${s}, ${s}, ${s}", .{ vectorRegName(inst.vd), vectorRegName(inst.vs), vectorRegName(inst.vt) });
}

fn printVectorLane(writer: *Writer, inst: Inst) !void {
    try printWord(writer, inst);
    const destination = if (inst.dest_element >= 8) inst.dest_element - 8 else inst.dest_element;
    try writer.print("${s}[{d}], ${s}[{d}]", .{
        vectorRegName(inst.vd), destination, vectorRegName(inst.vt), inst.element -| 8,
    });
}

fn printVectorMemory(writer: *Writer, inst: Inst) !void {
    try printWord(writer, inst);
    try writer.print("${s}", .{vectorRegName(inst.vt)});
    if (inst.show_lane) try writer.print("[{d}]", .{inst.element});
    try writer.print(", {d}({s})", .{ inst.imm, regName(inst.rs) });
}

const testing = std.testing;

fn expectPrinted(expected: []const u8, item: ir.Item) !void {
    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeItem(&writer, item);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "scalar instructions print in the backend's assembly spelling" {
    try expectPrinted("  addiu $t0, $zero, 1\n", .{ .instruction = .{ .op = .addiu, .rt = .t0, .imm = 1 } });
    try expectPrinted("  addiu $t0, $zero, %lo(table)\n", .{ .instruction = .{ .op = .addiu, .rt = .t0, .symbol = "table" } });
    try expectPrinted("  lw $t0, %lo(table + 4)($t1)\n", .{ .instruction = .{ .op = .lw, .rt = .t0, .rs = .t1, .symbol = "table", .imm = 4 } });
    try expectPrinted("  sw $t0, -4($sp)\n", .{ .instruction = .{ .op = .sw, .rt = .t0, .rs = .sp, .imm = -4 } });
    try expectPrinted("  sllv $t0, $t1, $t2\n", .{ .instruction = .{ .op = .sllv, .rd = .t0, .rt = .t1, .rs = .t2 } });
    try expectPrinted("  sra $t0, $t1, 3\n", .{ .instruction = .{ .op = .sra, .rd = .t0, .rt = .t1, .imm = 3 } });
    try expectPrinted("  lui $t0, 4660\n", .{ .instruction = .{ .op = .lui, .rt = .t0, .imm = 4660 } });
    try expectPrinted("  bne $t0, $zero, done\n", .{ .instruction = .{ .op = .bne, .rs = .t0, .symbol = "done" } });
    try expectPrinted("  bgez $t0, done\n", .{ .instruction = .{ .op = .bgez, .rs = .t0, .symbol = "done" } });
    try expectPrinted("  b done\n", .{ .instruction = .{ .op = .b, .symbol = "done" } });
    try expectPrinted("  jal $t0\n", .{ .instruction = .{ .op = .jalr, .rs = .t0 } });
    try expectPrinted("  jr $ra\n", .{ .instruction = .{ .op = .jr, .rs = .ra } });
    try expectPrinted("  mtc0 $t0, $9\n", .{ .instruction = .{ .op = .mtc0, .rt = .t0, .imm = 9 } });
    try expectPrinted("  break 0x1f\n", .{ .instruction = .{ .op = .@"break", .imm = 0x1f } });
    try expectPrinted("  nop\n", .{ .instruction = .{ .op = .nop } });
    try expectPrinted("  custom $t0\n", .{ .raw = "custom $t0" });
    try expectPrinted("  li $t0, 1\n", .{ .instruction = .{ .op = .addiu, .text = "li $t0, 1" } });
    try expectPrinted("done:\n", .{ .label = "done" });
    try expectPrinted(".data\n", .{ .text = ".data" });
    try expectPrinted("# zsp exact block end\n", .exact_end);
}

test "vector instructions print as words with readable comments" {
    try expectPrinted("  .word 0x4a0208d0 # vadd $v03, $v01, $v02\n", .{ .instruction = .{ .op = .vadd, .vd = .v03, .vs = .v01, .vt = .v02 } });
    try expectPrinted("  .word 0x48881000 # mtc2 $t0, $v02[0]\n", .{ .instruction = .{ .op = .mtc2, .rt = .t0, .vt = .v02 } });
    try expectPrinted("  .word 0x48480800 # cfc2 $t0, $1\n", .{ .instruction = .{ .op = .cfc2, .rt = .t0, .imm = 1 } });
    try expectPrinted("  .word 0x4b1f1873 # vmov $v01[3], $v31[0]\n", .{ .instruction = .{ .op = .vmov, .vd = .v01, .dest_element = 3, .vt = .v31, .element = 8 } });
    try expectPrinted("  .word 0xc8012002 # lqv $v01, 32($zero)\n", .{ .instruction = .{ .op = .lqv, .vt = .v01, .imm = 32, .show_lane = false } });
    try expectPrinted("  .word 0xc9010a02 # lsv $v01[2], 4($t0)\n", .{ .instruction = .{ .op = .lsv, .vt = .v01, .rs = .t0, .element = 2, .imm = 4 } });
}
