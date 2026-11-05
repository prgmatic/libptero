//! Reads one line of assembly into the IR. Used for `asm("...")` statements
//! and optimizer tests: recognized instructions take part in scheduling and
//! keep their original spelling; anything else stays a raw barrier.
const std = @import("std");
const ir = @import("ir.zig");
const registers = @import("registers.zig");

const Inst = ir.Inst;

/// Parses a full line, including labels, comments, and directives.
pub fn parseLine(text: []const u8) ir.Item {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (markers.get(trimmed)) |marker| return marker;
    if (isLabel(trimmed)) return .{ .label = trimmed[0 .. trimmed.len - 1] };
    if (isDirective(trimmed)) return .{ .text = text };
    return parseStatement(trimmed);
}

const markers = std.StaticStringMap(ir.Item).initComptime(.{
    .{ "# zsp exact block begin", .exact_begin },
    .{ "# zsp exact block end", .exact_end },
});

fn isLabel(line: []const u8) bool {
    return line.len > 1 and line[line.len - 1] == ':' and std.mem.indexOfAny(u8, line, " \t#") == null;
}

/// Blank lines, comments, and directives other than instruction words.
fn isDirective(line: []const u8) bool {
    if (line.len == 0 or line[0] == '#') return true;
    return line[0] == '.' and !std.mem.startsWith(u8, line, ".word ");
}

/// Parses the text of an `asm(...)` statement.
pub fn parseStatement(text: []const u8) ir.Item {
    var inst = parseInstruction(text) orelse return .{ .raw = text };
    inst.text = text;
    return .{ .instruction = inst };
}

pub fn parseInstruction(text: []const u8) ?Inst {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (std.mem.startsWith(u8, trimmed, ".word ")) return parseWord(trimmed[".word ".len..]);
    const split = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const named = ir.Op.fromMnemonic(trimmed[0..split]) orelse return null;
    var operands = Operands.init(trimmed[split..]) orelse return null;
    const op = registerJumpAlias(named, operands.peek());
    return parsers.get(op.format())(op, &operands);
}

/// `jal $reg` is the assembler spelling of `jalr`.
fn registerJumpAlias(op: ir.Op, first_operand: ?[]const u8) ir.Op {
    if (op != .jal or first_operand == null) return op;
    return if (std.mem.startsWith(u8, first_operand.?, "$")) .jalr else op;
}

const Operands = struct {
    items: [4][]const u8 = undefined,
    len: usize = 0,
    index: usize = 0,

    fn init(text: []const u8) ?Operands {
        var self: Operands = .{};
        const without_comment = text[0 .. std.mem.indexOfScalar(u8, text, '#') orelse text.len];
        var parts = std.mem.splitScalar(u8, without_comment, ',');
        while (parts.next()) |part| {
            const operand = std.mem.trim(u8, part, " \t");
            if (operand.len == 0) continue;
            if (self.len == self.items.len) return null;
            self.items[self.len] = operand;
            self.len += 1;
        }
        return self;
    }

    fn peek(self: *const Operands) ?[]const u8 {
        return if (self.index < self.len) self.items[self.index] else null;
    }

    fn next(self: *Operands) ?[]const u8 {
        const operand = self.peek() orelse return null;
        self.index += 1;
        return operand;
    }

    fn scalar(self: *Operands) ?ir.Reg {
        return registers.parseScalar(self.next() orelse return null);
    }

    fn integer(self: *Operands) ?i32 {
        return parseInteger(self.next() orelse return null);
    }

    fn finish(self: *const Operands, inst: Inst) ?Inst {
        return if (self.index == self.len) inst else null;
    }
};

fn parseInteger(text: []const u8) ?i32 {
    return std.fmt.parseInt(i32, text, 0) catch null;
}

const Value = struct { imm: i32 = 0, symbol: ?[]const u8 = null };

/// An integer, `%lo(symbol)`, or `%lo(symbol + offset)`.
fn parseValue(text: []const u8) ?Value {
    if (parseInteger(text)) |value| return .{ .imm = value };
    if (!std.mem.startsWith(u8, text, "%lo(") or text[text.len - 1] != ')') return null;
    const inner = text["%lo(".len .. text.len - 1];
    const plus = std.mem.indexOfScalar(u8, inner, '+') orelse return .{ .symbol = std.mem.trim(u8, inner, " ") };
    return .{
        .symbol = std.mem.trim(u8, inner[0..plus], " "),
        .imm = parseInteger(std.mem.trim(u8, inner[plus + 1 ..], " ")) orelse return null,
    };
}

const Parser = *const fn (ir.Op, *Operands) ?Inst;

const parsers = std.EnumArray(ir.Format, Parser).init(.{
    .none = &parseNone,
    .breakpoint = &parseBreak,
    .register = &parseRegister,
    .shift_variable = &parseShiftVariable,
    .shift = &parseShift,
    .immediate = &parseImmediate,
    .upper = &parseUpper,
    .memory = &parseMemory,
    .jump = &parseJump,
    .jump_register = &parseJumpRegister,
    .branch_compare = &parseBranchCompare,
    .branch_zero = &parseBranchZero,
    .branch_always = &parseJump,
    .cop0 = &parseCop0,
    .cop2_lane = &parseUnsupported,
    .cop2_control = &parseUnsupported,
    .vector = &parseUnsupported,
    .vector_lane = &parseUnsupported,
    .vector_memory = &parseUnsupported,
});

/// COP2 instructions have no assembler mnemonics; they appear as `.word`.
fn parseUnsupported(_: ir.Op, _: *Operands) ?Inst {
    return null;
}

fn parseNone(op: ir.Op, operands: *Operands) ?Inst {
    return operands.finish(.{ .op = op });
}

fn parseBreak(op: ir.Op, operands: *Operands) ?Inst {
    const code = if (operands.peek() != null) operands.integer() orelse return null else 0;
    return operands.finish(.{ .op = op, .imm = code });
}

fn parseRegister(op: ir.Op, operands: *Operands) ?Inst {
    const rd = operands.scalar() orelse return null;
    const rs = operands.scalar() orelse return null;
    const rt = operands.scalar() orelse return null;
    return operands.finish(.{ .op = op, .rd = rd, .rs = rs, .rt = rt });
}

fn parseShiftVariable(op: ir.Op, operands: *Operands) ?Inst {
    const rd = operands.scalar() orelse return null;
    const rt = operands.scalar() orelse return null;
    const rs = operands.scalar() orelse return null;
    return operands.finish(.{ .op = op, .rd = rd, .rs = rs, .rt = rt });
}

fn parseShift(op: ir.Op, operands: *Operands) ?Inst {
    const rd = operands.scalar() orelse return null;
    const rt = operands.scalar() orelse return null;
    const amount = operands.integer() orelse return null;
    return operands.finish(.{ .op = op, .rd = rd, .rt = rt, .imm = amount });
}

fn parseImmediate(op: ir.Op, operands: *Operands) ?Inst {
    const rt = operands.scalar() orelse return null;
    const rs = operands.scalar() orelse return null;
    const value = parseValue(operands.next() orelse return null) orelse return null;
    return operands.finish(.{ .op = op, .rt = rt, .rs = rs, .imm = value.imm, .symbol = value.symbol });
}

fn parseUpper(op: ir.Op, operands: *Operands) ?Inst {
    const rt = operands.scalar() orelse return null;
    const value = parseValue(operands.next() orelse return null) orelse return null;
    return operands.finish(.{ .op = op, .rt = rt, .imm = value.imm, .symbol = value.symbol });
}

fn parseMemory(op: ir.Op, operands: *Operands) ?Inst {
    const rt = operands.scalar() orelse return null;
    const address = parseAddress(operands.next() orelse return null) orelse return null;
    return operands.finish(.{ .op = op, .rt = rt, .rs = address.base, .imm = address.value.imm, .symbol = address.value.symbol });
}

const Address = struct { base: ir.Reg, value: Value };

/// `offset(base)`, `%lo(symbol + offset)(base)`, or `(base)`.
fn parseAddress(text: []const u8) ?Address {
    if (!std.mem.endsWith(u8, text, ")")) return null;
    const open = std.mem.lastIndexOfScalar(u8, text, '(') orelse return null;
    const base = registers.parseScalar(text[open + 1 .. text.len - 1]) orelse return null;
    if (open == 0) return .{ .base = base, .value = .{} };
    return .{ .base = base, .value = parseValue(text[0..open]) orelse return null };
}

fn parseJump(op: ir.Op, operands: *Operands) ?Inst {
    const target = operands.next() orelse return null;
    if (std.mem.startsWith(u8, target, "$")) return null;
    return operands.finish(.{ .op = op, .symbol = target });
}

fn parseJumpRegister(op: ir.Op, operands: *Operands) ?Inst {
    const rs = operands.scalar() orelse return null;
    return operands.finish(.{ .op = op, .rs = rs });
}

fn parseBranchCompare(op: ir.Op, operands: *Operands) ?Inst {
    const rs = operands.scalar() orelse return null;
    const rt = operands.scalar() orelse return null;
    const target = operands.next() orelse return null;
    return operands.finish(.{ .op = op, .rs = rs, .rt = rt, .symbol = target });
}

fn parseBranchZero(op: ir.Op, operands: *Operands) ?Inst {
    const rs = operands.scalar() orelse return null;
    const target = operands.next() orelse return null;
    return operands.finish(.{ .op = op, .rs = rs, .symbol = target });
}

fn parseCop0(op: ir.Op, operands: *Operands) ?Inst {
    const rt = operands.scalar() orelse return null;
    const register = operands.next() orelse return null;
    if (register.len < 2 or register[0] != '$') return null;
    const index = std.fmt.parseInt(u5, register[1..], 10) catch return null;
    return operands.finish(.{ .op = op, .rt = rt, .imm = index });
}

/// Decodes a `.word` holding a COP2 instruction; other words are data.
fn parseWord(text: []const u8) ?Inst {
    const value_text = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '#') orelse text.len], " \t");
    const word = std.fmt.parseInt(u32, value_text, 0) catch return null;
    const inst = decodeCop2(word) orelse return null;
    // Only accept words the IR re-encodes exactly.
    return if (inst.encode() == word) inst else null;
}

pub fn decodeCop2(word: u32) ?Inst {
    return switch (word >> 26) {
        0x12 => if (word & (1 << 25) != 0) decodeVector(word) else decodeCop2Move(word),
        0x32, 0x3a => decodeVectorMemory(word),
        else => null,
    };
}

fn field(word: u32, shift: u5) u5 {
    return @truncate(word >> shift);
}

fn findOp(format: ir.Format, code: u32) ?ir.Op {
    for (std.enums.values(ir.Op)) |op| {
        if (op.format() == format and op.info().code == code) return op;
    }
    return null;
}

fn decodeVector(word: u32) ?Inst {
    const code = word & 0x3f;
    const element: u4 = @truncate(word >> 21);
    if (findOp(.vector, code)) |op| return .{
        .op = op,
        .vd = @enumFromInt(field(word, 6)),
        .vs = @enumFromInt(field(word, 11)),
        .vt = @enumFromInt(field(word, 16)),
        .element = element,
    };
    const op = findOp(.vector_lane, code) orelse return null;
    return .{
        .op = op,
        .vd = @enumFromInt(field(word, 6)),
        .dest_element = @truncate(word >> 11),
        .vt = @enumFromInt(field(word, 16)),
        .element = element,
    };
}

fn decodeCop2Move(word: u32) ?Inst {
    const op = findOp(.cop2_lane, field(word, 21)) orelse findOp(.cop2_control, field(word, 21)) orelse return null;
    const rt: ir.Reg = @enumFromInt(field(word, 16));
    if (op.format() == .cop2_control) return .{ .op = op, .rt = rt, .imm = field(word, 11) };
    return .{ .op = op, .rt = rt, .vt = @enumFromInt(field(word, 11)), .element = @truncate((word >> 8) & 7) };
}

fn decodeVectorMemory(word: u32) ?Inst {
    const op = findOp(.vector_memory, (word >> 26) << 5 | field(word, 11)) orelse return null;
    const info = op.info();
    const offset: i7 = @bitCast(@as(u7, @truncate(word)));
    return .{
        .op = op,
        .rs = @enumFromInt(field(word, 21)),
        .vt = @enumFromInt(field(word, 16)),
        .element = @truncate((word >> info.lane_shift) & (@as(u32, 0xf) >> @intCast(info.lane_shift - 7))),
        .imm = @as(i32, offset) * info.scale,
    };
}

const testing = std.testing;

fn expectRoundTrip(line: []const u8) !void {
    const inst = parseInstruction(line) orelse return error.NotParsed;
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var printed = inst;
    printed.text = null;
    try @import("ir_print.zig").writeInstruction(&writer, printed);
    try testing.expectEqualStrings(line, std.mem.trim(u8, writer.buffered(), " \n"));
}

test "assembly lines parse back to the instructions they print" {
    for ([_][]const u8{
        "addiu $t0, $zero, 1",           "addiu $at, $zero, %lo(table + 8)", "or $t2, $t0, $t1",
        "lw $t0, 0($a0)",
        "sllv $t0, $t1, $t2",            "sra $t0, $t1, 3",                  "lui $t0, 4660",
        "lw $t0, 4($a0)",                "sh $t0, %lo(table)($t1)",          "lbu $t0, %lo(x + -2)($zero)",
        "j done",                        "jal helper",                       "jal $t0",
        "jr $ra",                        "beq $t0, $t1, done",               "bnez $t0, done",
        "bgez $t0, done",                "b done",                           "mfc0 $t0, $4",
        "mtc0 $t1, $9",                  "break",                            "break 0x5",
        "nop",                           ".word 0x4a0208d0 # vadd $v03, $v01, $v02",
        ".word 0x48881000 # mtc2 $t0, $v02[0]",
        ".word 0x48480800 # cfc2 $t0, $1",
        ".word 0xc9010a02 # lsv $v01[2], 4($t0)",
        ".word 0x4b1f1873 # vmov $v01[3], $v31[0]",
    }) |line| try expectRoundTrip(line);
}

test "unrecognized assembly stays a raw barrier" {
    try testing.expectEqual(@as(?Inst, null), parseInstruction("custom $t2, $t3"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("addiu $t0, $t1"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("addiu $t0, $t1, 1, 2"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction(".word 0x12345678"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("lw $t0, 4"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("mfc0 $t0, 4"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("j $t0"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction(".word 0x4a000000 | 1"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("lw $t0, 4($q9)"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("lw $t0, 4)$t1("));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("lw $t0, %hi(x)($t1)"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction("jal"));
    try testing.expectEqual(@as(?Inst, null), parseInstruction(".word 0x48200000"));
    try testing.expect(parseStatement("custom") == .raw);
    const parsed = parseStatement("addiu $t0,$zero,1");
    try testing.expectEqualStrings("addiu $t0,$zero,1", parsed.instruction.text.?);
}

test "lines classify labels, directives, and exact markers" {
    try testing.expectEqualStrings("done", parseLine("done:").label);
    try testing.expect(parseLine("  .data") == .text);
    try testing.expect(parseLine("# comment") == .text);
    try testing.expect(parseLine("# zsp exact block begin") == .exact_begin);
    try testing.expect(parseLine("# zsp exact block end") == .exact_end);
    try testing.expect(parseLine("  addiu $t0, $zero, 1") == .instruction);
    try testing.expect(parseLine("") == .text);
}
