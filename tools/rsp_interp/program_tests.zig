//! End-to-end instruction tests that execute encoded programs through
//! `Machine.run`, covering decoding, delay slots, and dispatch tables.
const std = @import("std");
const Machine = @import("Machine.zig");
const encode = @import("encode.zig");
const vector = @import("vector.zig");

const testing = std.testing;
const Vec = vector.Vec;

fn loadWords(m: *Machine, words: []const u32) void {
    for (words, 0..) |word, index| std.mem.writeInt(u32, m.imem[index * 4 ..][0..4], word, .big);
}

fn runWords(m: *Machine, words: []const u32) !Machine.RunResult {
    loadWords(m, words);
    m.start(0);
    return m.run(1000);
}

const ScalarCase = struct { op: u32, rs: u32 = 0, rt: u32 = 0, expected: u32 };

/// Executes `op` with $t0 = rs and $t1 = rt and checks the result in $t2.
fn expectScalar(case: ScalarCase) !void {
    var m = Machine.init(&.{});
    m.gpr[8] = case.rs;
    m.gpr[9] = case.rt;
    const result = try runWords(&m, &.{ case.op, encode.brk });
    try testing.expectEqual(Machine.Stop.broke, result.stop);
    try testing.expectEqual(case.expected, m.gpr[10]);
}

fn r(funct: u6) u32 {
    return encode.special(funct, 8, 9, 10, 0);
}

fn shift(funct: u6, amount: u5) u32 {
    return encode.special(funct, 0, 9, 10, amount);
}

fn i(op: u6, imm: u16) u32 {
    return encode.immediate(op, 8, 10, imm);
}

test "scalar ALU instructions" {
    const cases = [_]ScalarCase{
        .{ .op = r(0x20), .rs = 0xffff_ffff, .rt = 2, .expected = 1 },
        .{ .op = r(0x21), .rs = 5, .rt = 2, .expected = 7 },
        .{ .op = r(0x22), .rs = 5, .rt = 7, .expected = 0xffff_fffe },
        .{ .op = r(0x23), .rs = 5, .rt = 2, .expected = 3 },
        .{ .op = r(0x24), .rs = 0xf0f0, .rt = 0xff00, .expected = 0xf000 },
        .{ .op = r(0x25), .rs = 0xf0f0, .rt = 0xff00, .expected = 0xfff0 },
        .{ .op = r(0x26), .rs = 0xf0f0, .rt = 0xff00, .expected = 0x0ff0 },
        .{ .op = r(0x27), .rs = 0xf0f0, .rt = 0xff00, .expected = 0xffff_000f },
        .{ .op = r(0x2a), .rs = 0xffff_ffff, .rt = 0, .expected = 1 },
        .{ .op = r(0x2b), .rs = 0xffff_ffff, .rt = 0, .expected = 0 },
        .{ .op = shift(0x00, 4), .rt = 0x0f, .expected = 0xf0 },
        .{ .op = shift(0x02, 4), .rt = 0x8000_0000, .expected = 0x0800_0000 },
        .{ .op = shift(0x03, 4), .rt = 0x8000_0000, .expected = 0xf800_0000 },
        .{ .op = r(0x04), .rs = 36, .rt = 1, .expected = 16 },
        .{ .op = r(0x06), .rs = 4, .rt = 0x80, .expected = 0x08 },
        .{ .op = r(0x07), .rs = 4, .rt = 0x8000_0000, .expected = 0xf800_0000 },
        .{ .op = i(0x08, 0xffff), .rs = 0, .expected = 0xffff_ffff },
        .{ .op = i(0x09, 4), .rs = 4, .expected = 8 },
        .{ .op = i(0x0a, 0xffff), .rs = 0xffff_fffe, .expected = 1 },
        .{ .op = i(0x0b, 0xffff), .rs = 5, .expected = 1 },
        .{ .op = i(0x0c, 0x00ff), .rs = 0x1234, .expected = 0x34 },
        .{ .op = i(0x0d, 0x00ff), .rs = 0x1200, .expected = 0x12ff },
        .{ .op = i(0x0e, 0x00ff), .rs = 0x12f0, .expected = 0x120f },
        .{ .op = i(0x0f, 0x1234), .expected = 0x1234_0000 },
    };
    for (cases) |case| try expectScalar(case);
}

test "scalar loads and stores sign- and zero-extend DMEM" {
    var m = Machine.init(&.{});
    m.writeDmem(u32, 0x20, 0x80ff_7f01);
    m.gpr[8] = 0x20;
    m.gpr[9] = 0xaabb_ccdd;
    const program = [_]u32{
        encode.immediate(0x20, 8, 10, 0), encode.immediate(0x24, 8, 11, 0),
        encode.immediate(0x21, 8, 12, 0), encode.immediate(0x25, 8, 13, 0),
        encode.immediate(0x23, 8, 14, 0), encode.immediate(0x27, 8, 15, 0),
        encode.immediate(0x28, 8, 9, 4),  encode.immediate(0x29, 8, 9, 6),
        encode.immediate(0x2b, 8, 9, 8),  encode.brk,
    };
    _ = try runWords(&m, &program);
    try testing.expectEqual(@as(u32, 0xffff_ff80), m.gpr[10]);
    try testing.expectEqual(@as(u32, 0x80), m.gpr[11]);
    try testing.expectEqual(@as(u32, 0xffff_80ff), m.gpr[12]);
    try testing.expectEqual(@as(u32, 0x80ff), m.gpr[13]);
    try testing.expectEqual(@as(u32, 0x80ff_7f01), m.gpr[14]);
    try testing.expectEqual(@as(u32, 0x80ff_7f01), m.gpr[15]);
    try testing.expectEqual(@as(u32, 0xdd00_ccdd), m.readDmem(u32, 0x24));
    try testing.expectEqual(@as(u32, 0xaabb_ccdd), m.readDmem(u32, 0x28));
}

test "branches execute their delay slot and link past it" {
    var m = Machine.init(&.{});
    m.gpr[8] = 3;
    const program = [_]u32{
        // loop: t0 -= 1; t1 += 1 (delay slot) while t0 != 0
        encode.addiu(8, 8, -1),
        encode.bne(8, 0, -2),
        encode.addiu(9, 9, 1),
        encode.jump(0x03, 0x20),
        encode.addiu(10, 0, 7),
        encode.brk,
        encode.brk,
        encode.brk,
        // 0x20: return to 0x14 via $ra
        encode.jr(31),
        encode.addiu(11, 0, 1),
    };
    const result = try runWords(&m, &program);
    try testing.expectEqual(@as(u32, 3), m.gpr[9]);
    try testing.expectEqual(@as(u32, 7), m.gpr[10]);
    try testing.expectEqual(@as(u32, 1), m.gpr[11]);
    try testing.expectEqual(@as(u32, 0x14), m.gpr[31]);
    try testing.expectEqual(@as(u32, 0x18), m.pc);
    try testing.expectEqual(@as(u64, 14), result.instructions);
    try testing.expect(result.cycles >= result.instructions);
}

const BranchCase = struct { op: u32, value: u32, taken: bool };

fn expectBranch(case: BranchCase) !void {
    var m = Machine.init(&.{});
    m.gpr[8] = case.value;
    _ = try runWords(&m, &.{ case.op, encode.nop, encode.addiu(10, 0, 1), encode.brk, encode.brk });
    try testing.expectEqual(@intFromBool(!case.taken), m.gpr[10]);
}

test "conditional branch forms" {
    const forward = 2;
    const cases = [_]BranchCase{
        .{ .op = encode.signedImmediate(0x04, 8, 0, forward), .value = 0, .taken = true },
        .{ .op = encode.signedImmediate(0x04, 8, 0, forward), .value = 1, .taken = false },
        .{ .op = encode.signedImmediate(0x06, 8, 0, forward), .value = 0, .taken = true },
        .{ .op = encode.signedImmediate(0x07, 8, 0, forward), .value = 0, .taken = false },
        .{ .op = encode.signedImmediate(0x07, 8, 0, forward), .value = 1, .taken = true },
        .{ .op = encode.regimm(0x00, 8, forward), .value = 0xffff_ffff, .taken = true },
        .{ .op = encode.regimm(0x01, 8, forward), .value = 0, .taken = true },
        .{ .op = encode.regimm(0x10, 8, forward), .value = 1, .taken = false },
        .{ .op = encode.regimm(0x11, 8, forward), .value = 1, .taken = true },
    };
    for (cases) |case| try expectBranch(case);
}

test "jalr links into rd and jumps to rs" {
    var m = Machine.init(&.{});
    m.gpr[8] = 0x10;
    _ = try runWords(&m, &.{ encode.special(0x09, 8, 0, 12, 0), encode.nop, encode.brk, encode.brk, encode.brk });
    try testing.expectEqual(@as(u32, 8), m.gpr[12]);
    try testing.expectEqual(@as(u32, 0x14), m.pc);
}

test "invalid encodings, halts, and instruction budgets" {
    var m = Machine.init(&.{});
    try testing.expectError(error.InvalidInstruction, runWords(&m, &.{0x7000_0000}));
    try testing.expectError(error.InvalidInstruction, runWords(&m, &.{encode.special(0x18, 0, 0, 0, 0)}));
    try testing.expectError(error.InvalidInstruction, runWords(&m, &.{encode.regimm(0x02, 0, 0)}));
    try testing.expectError(error.InvalidInstruction, runWords(&m, &.{encode.cop2Move(.mfc2, 0, 0, 0) | 1 << 21}));
    m.gpr[8] = 2;
    const halted = try runWords(&m, &.{ encode.cop0Move(true, 8, 4), encode.brk });
    try testing.expectEqual(Machine.Stop.halted, halted.stop);
    var spin = Machine.init(&.{});
    const limited = try runWords(&spin, &.{ encode.jump(0x02, 0), encode.nop });
    try testing.expectEqual(Machine.Stop.instruction_limit, limited.stop);
    var interrupting = Machine.init(&.{});
    interrupting.sp.interrupt_on_break = true;
    _ = try runWords(&interrupting, &.{encode.brk});
    try testing.expectEqual(@as(u32, 1), interrupting.sp.interrupts);
}

test "COP2 register and control moves" {
    var m = Machine.init(&.{});
    m.vu.regs[2] = .{ 0x1234, 0x8001, 0, 0, 0, 0, 0, 0xabcd };
    m.gpr[8] = 0xffff_5678;
    m.gpr[9] = 0x0102;
    _ = try runWords(&m, &.{
        encode.cop2Move(.mfc2, 10, 2, 2),
        encode.cop2Move(.mfc2, 11, 2, 1),
        encode.cop2Move(.mtc2, 8, 3, 4),
        encode.cop2Move(.mtc2, 8, 3, 15),
        encode.cop2Move(.ctc2, 9, 1, 0),
        encode.cop2Move(.cfc2, 12, 1, 0),
        encode.cop2Move(.mfc2, 13, 2, 15),
        encode.brk,
    });
    try testing.expectEqual(@as(u32, 0xffff_8001), m.gpr[10]);
    try testing.expectEqual(@as(u32, 0x3480), m.gpr[11]);
    try testing.expectEqual(@as(u16, 0x5678), m.vu.regs[3][2]);
    try testing.expectEqual(@as(u16, 0x0056), m.vu.regs[3][7]);
    try testing.expectEqual(@as(u8, 2), m.vu.vcc_lo);
    try testing.expectEqual(@as(u32, 0x0102), m.gpr[12]);
    try testing.expectEqual(@as(u32, 0xffff_cd12), m.gpr[13]);
}

fn runVector(m: *Machine, funct: u6, element: u4) !void {
    _ = try runWords(m, &.{ encode.vectorOp(funct, 3, 1, 2, element), encode.brk });
}

test "computational dispatch covers every implemented opcode" {
    const a: Vec = .{ 1, 2, 3, 0xffff, 0x7fff, 0x8000, 0, 5 };
    const b: Vec = .{ 2, 2, 1, 1, 1, 0xffff, 0, 5 };
    for (0..64) |funct| {
        var m = Machine.init(&.{});
        m.vu.regs[1] = a;
        m.vu.regs[2] = b;
        try runVector(&m, @intCast(funct), 0);
    }
    var m = Machine.init(&.{});
    m.vu.regs[1] = a;
    m.vu.regs[2] = b;
    try runVector(&m, 0x10, 0);
    try testing.expectEqual(Vec{ 3, 4, 4, 0, 0x7fff, 0x8000, 0, 10 }, m.vu.regs[3]);
    try runVector(&m, 0x12, 0);
    try testing.expectEqual(vector.zero, m.vu.regs[3]);
    try runVector(&m, 0x14, 8);
    try testing.expectEqual(@as(u16, 3), m.vu.regs[3][0]);
    try testing.expectEqual(@as(u8, 0), m.vu.vco_hi);
    try runVector(&m, 0x20, 0);
    try testing.expectEqual(@as(u8, 0b0010_1001), m.vu.vcc_lo);
    try testing.expectEqual(@as(u8, 0), m.vu.vcc_hi | m.vu.vco_lo | m.vu.vco_hi);
    try runVector(&m, 0x26, 0);
    try testing.expectEqual(@as(u8, 0), m.vu.vce);
}

test "accumulator reads, rounding, moves, and divides through dispatch" {
    var m = Machine.init(&.{});
    m.vu.regs[1] = @splat(0x0100);
    m.vu.regs[2] = @splat(0x0100);
    try runVector(&m, 0x07, 0);
    for ([_]u4{ 8, 9, 10, 3 }, [_]u16{ 1, 0, 0, 0 }) |element, expected| {
        try runVector(&m, 0x1d, element);
        try testing.expectEqual(expected, m.vu.regs[3][0]);
    }
    m.vu.setAcc(0, 0x0000_0000_8000);
    m.vu.regs[2] = @splat(0x7fff);
    _ = try runWords(&m, &.{ encode.vectorOp(0x02, 3, 1, 2, 0), encode.brk });
    try testing.expectEqual(@as(u16, 0x7fff), m.vu.regs[3][0]);
    try testing.expectEqual(@as(u64, 0x7fff_8000), m.vu.acc[0]);
    m.vu.setAcc(0, -0x8000);
    _ = try runWords(&m, &.{ encode.vectorOp(0x0a, 3, 0, 2, 0), encode.brk });
    try testing.expectEqual(@as(i64, -1), m.vu.accSigned(0));
    m.vu.regs[2] = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    m.vu.regs[3] = vector.zero;
    _ = try runWords(&m, &.{ encode.vectorOp(0x33, 3, 4, 2, 14), encode.brk });
    try testing.expectEqual(@as(u16, 7), m.vu.regs[3][4]);
    try testing.expectEqual(@as(u16, 7), m.vu.accLow(0));
    m.vu.regs[2] = .{ 2, 0, 0, 0, 0, 0, 0, 0 };
    _ = try runWords(&m, &.{ encode.vectorOp(0x30, 3, 0, 2, 0), encode.brk });
    try testing.expectEqual(@as(u16, 0xe000), m.vu.regs[3][0]);
    _ = try runWords(&m, &.{ encode.vectorOp(0x32, 3, 1, 2, 0), encode.brk });
    try testing.expectEqual(@as(u16, 0x3fff), m.vu.regs[3][1]);
    _ = try runWords(&m, &.{ encode.vectorOp(0x31, 3, 0, 2, 9), encode.brk });
    _ = try runWords(&m, &.{ encode.vectorOp(0x34, 3, 0, 2, 0), encode.brk });
    _ = try runWords(&m, &.{ encode.vectorOp(0x35, 3, 0, 2, 0), encode.brk });
    _ = try runWords(&m, &.{ encode.vectorOp(0x36, 3, 0, 2, 0), encode.brk });
    try testing.expect(m.vu.div_pending);
}
