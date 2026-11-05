//! Machine instruction IR produced by instruction selection.
//!
//! The backend emits `Item`s instead of assembly text. Instructions carry
//! typed operands, so optimization passes read exact register, memory, and
//! pipeline effects (`ir_effects.zig`) instead of parsing text, and every
//! instruction encodes to its real machine word for the timing model.
//! `ir_print.zig` renders the final assembly.
const std = @import("std");
const ast = @import("ast.zig");

pub const Reg = ast.Register;
pub const VReg = ast.VectorRegister;

/// Operand layout of an instruction, which decides printing and encoding.
pub const Format = enum {
    none,
    breakpoint,
    /// `op rd, rs, rt`
    register,
    /// `op rd, rt, rs` (variable shifts)
    shift_variable,
    /// `op rd, rt, imm`
    shift,
    /// `op rt, rs, imm|%lo(symbol + imm)`
    immediate,
    /// `lui rt, imm`
    upper,
    /// `op rt, imm|%lo(symbol + imm)(rs)`
    memory,
    /// `op symbol`
    jump,
    /// `op rs`
    jump_register,
    /// `op rs, rt, symbol`
    branch_compare,
    /// `op rs, symbol`
    branch_zero,
    /// `op symbol`
    branch_always,
    /// `op rt, $imm`
    cop0,
    /// `op rt, $vt[element]`
    cop2_lane,
    /// `op rt, $imm`
    cop2_control,
    /// `op $vd, $vs, $vt` with `element` selecting the vt broadcast
    vector,
    /// `op $vd[dest_element], $vt[element]`
    vector_lane,
    /// `op $vt[element], imm(rs)`
    vector_memory,
};

pub const Op = enum {
    nop,
    @"break",
    add,
    addu,
    sub,
    subu,
    @"and",
    @"or",
    xor,
    nor,
    slt,
    sltu,
    sllv,
    srlv,
    srav,
    sll,
    srl,
    sra,
    addi,
    addiu,
    slti,
    sltiu,
    andi,
    ori,
    xori,
    lui,
    lb,
    lh,
    lw,
    lbu,
    lhu,
    sb,
    sh,
    sw,
    j,
    jal,
    jr,
    /// `jal $reg`, the assembler spelling of `jalr $ra, $reg`.
    jalr,
    beq,
    bne,
    beqz,
    bnez,
    blez,
    bgtz,
    bltz,
    bgez,
    b,
    mfc0,
    mtc0,
    mfc2,
    mtc2,
    cfc2,
    ctc2,
    vmulf,
    vmulu,
    vmudl,
    vmudm,
    vmudn,
    vmudh,
    vmacf,
    vmacu,
    vmadl,
    vmadm,
    vmadn,
    vmadh,
    vadd,
    vsub,
    vabs,
    vaddc,
    vsubc,
    vsar,
    vlt,
    veq,
    vne,
    vge,
    vcl,
    vch,
    vcr,
    vmrg,
    vand,
    vnand,
    vor,
    vnor,
    vxor,
    vnxor,
    vnop,
    /// `vmudn $vd, $vs, $v31[e]`: a left shift by a power-of-two constant.
    vsll8,
    /// `vmudm $vd, $vs, $v31[e]`: an arithmetic right shift.
    vsra,
    /// `vmudl $vd, $vs, $v31[e]`: a logical right shift.
    vsrl,
    vrcp,
    vrcpl,
    vrcph,
    vmov,
    vrsq,
    vrsql,
    vrsqh,
    lbv,
    lsv,
    llv,
    ldv,
    lqv,
    lrv,
    lpv,
    luv,
    ltv,
    sbv,
    ssv,
    slv,
    sdv,
    sqv,
    srv,
    spv,
    suv,
    stv,

    pub fn info(op: Op) OpInfo {
        return op_infos.get(op);
    }

    pub fn mnemonic(op: Op) []const u8 {
        return @tagName(op);
    }

    pub fn format(op: Op) Format {
        return op.info().format;
    }

    pub fn fromMnemonic(text: []const u8) ?Op {
        return std.meta.stringToEnum(Op, text);
    }
};

/// Encoding parameters. `code` is the funct, opcode, or sub-opcode for the
/// op's format; vector memory adds an offset scale and lane bit position.
pub const OpInfo = struct {
    format: Format,
    code: u32 = 0,
    scale: u5 = 1,
    lane_shift: u5 = 7,
};

const op_infos = std.EnumArray(Op, OpInfo).init(.{
    .nop = .{ .format = .none },
    .@"break" = .{ .format = .breakpoint, .code = 0x0d },
    .add = .{ .format = .register, .code = 0x20 },
    .addu = .{ .format = .register, .code = 0x21 },
    .sub = .{ .format = .register, .code = 0x22 },
    .subu = .{ .format = .register, .code = 0x23 },
    .@"and" = .{ .format = .register, .code = 0x24 },
    .@"or" = .{ .format = .register, .code = 0x25 },
    .xor = .{ .format = .register, .code = 0x26 },
    .nor = .{ .format = .register, .code = 0x27 },
    .slt = .{ .format = .register, .code = 0x2a },
    .sltu = .{ .format = .register, .code = 0x2b },
    .sllv = .{ .format = .shift_variable, .code = 0x04 },
    .srlv = .{ .format = .shift_variable, .code = 0x06 },
    .srav = .{ .format = .shift_variable, .code = 0x07 },
    .sll = .{ .format = .shift, .code = 0x00 },
    .srl = .{ .format = .shift, .code = 0x02 },
    .sra = .{ .format = .shift, .code = 0x03 },
    .addi = .{ .format = .immediate, .code = 0x08 },
    .addiu = .{ .format = .immediate, .code = 0x09 },
    .slti = .{ .format = .immediate, .code = 0x0a },
    .sltiu = .{ .format = .immediate, .code = 0x0b },
    .andi = .{ .format = .immediate, .code = 0x0c },
    .ori = .{ .format = .immediate, .code = 0x0d },
    .xori = .{ .format = .immediate, .code = 0x0e },
    .lui = .{ .format = .upper, .code = 0x0f },
    .lb = .{ .format = .memory, .code = 0x20 },
    .lh = .{ .format = .memory, .code = 0x21 },
    .lw = .{ .format = .memory, .code = 0x23 },
    .lbu = .{ .format = .memory, .code = 0x24 },
    .lhu = .{ .format = .memory, .code = 0x25 },
    .sb = .{ .format = .memory, .code = 0x28 },
    .sh = .{ .format = .memory, .code = 0x29 },
    .sw = .{ .format = .memory, .code = 0x2b },
    .j = .{ .format = .jump, .code = 0x02 },
    .jal = .{ .format = .jump, .code = 0x03 },
    .jr = .{ .format = .jump_register, .code = 0x08 },
    .jalr = .{ .format = .jump_register, .code = 0x09 },
    .beq = .{ .format = .branch_compare, .code = 0x04 },
    .bne = .{ .format = .branch_compare, .code = 0x05 },
    // Zero branches: opcode << 5 | rt field.
    .beqz = .{ .format = .branch_zero, .code = 0x04 << 5 },
    .bnez = .{ .format = .branch_zero, .code = 0x05 << 5 },
    .blez = .{ .format = .branch_zero, .code = 0x06 << 5 },
    .bgtz = .{ .format = .branch_zero, .code = 0x07 << 5 },
    .bltz = .{ .format = .branch_zero, .code = 0x01 << 5 | 0 },
    .bgez = .{ .format = .branch_zero, .code = 0x01 << 5 | 1 },
    .b = .{ .format = .branch_always, .code = 0x04 },
    .mfc0 = .{ .format = .cop0, .code = 0 },
    .mtc0 = .{ .format = .cop0, .code = 4 },
    .mfc2 = .{ .format = .cop2_lane, .code = 0 },
    .mtc2 = .{ .format = .cop2_lane, .code = 4 },
    .cfc2 = .{ .format = .cop2_control, .code = 2 },
    .ctc2 = .{ .format = .cop2_control, .code = 6 },
    .vmulf = .{ .format = .vector, .code = 0x00 },
    .vmulu = .{ .format = .vector, .code = 0x01 },
    .vmudl = .{ .format = .vector, .code = 0x04 },
    .vmudm = .{ .format = .vector, .code = 0x05 },
    .vmudn = .{ .format = .vector, .code = 0x06 },
    .vmudh = .{ .format = .vector, .code = 0x07 },
    .vmacf = .{ .format = .vector, .code = 0x08 },
    .vmacu = .{ .format = .vector, .code = 0x09 },
    .vmadl = .{ .format = .vector, .code = 0x0c },
    .vmadm = .{ .format = .vector, .code = 0x0d },
    .vmadn = .{ .format = .vector, .code = 0x0e },
    .vmadh = .{ .format = .vector, .code = 0x0f },
    .vadd = .{ .format = .vector, .code = 0x10 },
    .vsub = .{ .format = .vector, .code = 0x11 },
    .vabs = .{ .format = .vector, .code = 0x13 },
    .vaddc = .{ .format = .vector, .code = 0x14 },
    .vsubc = .{ .format = .vector, .code = 0x15 },
    .vsar = .{ .format = .vector, .code = 0x1d },
    .vlt = .{ .format = .vector, .code = 0x20 },
    .veq = .{ .format = .vector, .code = 0x21 },
    .vne = .{ .format = .vector, .code = 0x22 },
    .vge = .{ .format = .vector, .code = 0x23 },
    .vcl = .{ .format = .vector, .code = 0x24 },
    .vch = .{ .format = .vector, .code = 0x25 },
    .vcr = .{ .format = .vector, .code = 0x26 },
    .vmrg = .{ .format = .vector, .code = 0x27 },
    .vand = .{ .format = .vector, .code = 0x28 },
    .vnand = .{ .format = .vector, .code = 0x29 },
    .vor = .{ .format = .vector, .code = 0x2a },
    .vnor = .{ .format = .vector, .code = 0x2b },
    .vxor = .{ .format = .vector, .code = 0x2c },
    .vnxor = .{ .format = .vector, .code = 0x2d },
    .vnop = .{ .format = .vector, .code = 0x37 },
    .vsll8 = .{ .format = .vector, .code = 0x06 },
    .vsra = .{ .format = .vector, .code = 0x05 },
    .vsrl = .{ .format = .vector, .code = 0x04 },
    .vrcp = .{ .format = .vector_lane, .code = 0x30 },
    .vrcpl = .{ .format = .vector_lane, .code = 0x31 },
    .vrcph = .{ .format = .vector_lane, .code = 0x32 },
    .vmov = .{ .format = .vector_lane, .code = 0x33 },
    .vrsq = .{ .format = .vector_lane, .code = 0x34 },
    .vrsql = .{ .format = .vector_lane, .code = 0x35 },
    .vrsqh = .{ .format = .vector_lane, .code = 0x36 },
    // Vector memory: opcode << 5 | sub-opcode.
    .lbv = .{ .format = .vector_memory, .code = 0x32 << 5 | 0, .scale = 1, .lane_shift = 7 },
    .lsv = .{ .format = .vector_memory, .code = 0x32 << 5 | 1, .scale = 2, .lane_shift = 8 },
    .llv = .{ .format = .vector_memory, .code = 0x32 << 5 | 2, .scale = 4, .lane_shift = 8 },
    .ldv = .{ .format = .vector_memory, .code = 0x32 << 5 | 3, .scale = 8, .lane_shift = 8 },
    .lqv = .{ .format = .vector_memory, .code = 0x32 << 5 | 4, .scale = 16, .lane_shift = 8 },
    .lrv = .{ .format = .vector_memory, .code = 0x32 << 5 | 5, .scale = 16, .lane_shift = 8 },
    .lpv = .{ .format = .vector_memory, .code = 0x32 << 5 | 6, .scale = 8, .lane_shift = 7 },
    .luv = .{ .format = .vector_memory, .code = 0x32 << 5 | 7, .scale = 8, .lane_shift = 7 },
    .ltv = .{ .format = .vector_memory, .code = 0x32 << 5 | 11, .scale = 16, .lane_shift = 8 },
    .sbv = .{ .format = .vector_memory, .code = 0x3a << 5 | 0, .scale = 1, .lane_shift = 7 },
    .ssv = .{ .format = .vector_memory, .code = 0x3a << 5 | 1, .scale = 2, .lane_shift = 8 },
    .slv = .{ .format = .vector_memory, .code = 0x3a << 5 | 2, .scale = 4, .lane_shift = 8 },
    .sdv = .{ .format = .vector_memory, .code = 0x3a << 5 | 3, .scale = 8, .lane_shift = 8 },
    .sqv = .{ .format = .vector_memory, .code = 0x3a << 5 | 4, .scale = 16, .lane_shift = 8 },
    .srv = .{ .format = .vector_memory, .code = 0x3a << 5 | 5, .scale = 16, .lane_shift = 8 },
    .spv = .{ .format = .vector_memory, .code = 0x3a << 5 | 6, .scale = 8, .lane_shift = 7 },
    .suv = .{ .format = .vector_memory, .code = 0x3a << 5 | 7, .scale = 8, .lane_shift = 7 },
    .stv = .{ .format = .vector_memory, .code = 0x3a << 5 | 11, .scale = 16, .lane_shift = 8 },
});

/// One machine instruction. Field names follow the MIPS encoding: `rd`,
/// `rs`, and `rt` are scalar fields; `vd`, `vs`, and `vt` are vector fields.
/// Vector memory and COP2 lane moves name their vector register `vt`.
pub const Inst = struct {
    op: Op,
    rd: Reg = .zero,
    rs: Reg = .zero,
    rt: Reg = .zero,
    /// Immediate, memory offset, shift amount, COP register, or break code.
    imm: i32 = 0,
    /// Relocated symbol: `%lo(symbol + imm)` for immediates and memory, or
    /// the target of a jump or branch.
    symbol: ?[]const u8 = null,
    vd: VReg = .v00,
    vs: VReg = .v00,
    vt: VReg = .v00,
    /// Vector broadcast element, vector memory lane, or COP2 lane.
    element: u4 = 0,
    /// Destination element of a single-lane vector operation.
    dest_element: u4 = 0,
    /// Whether vector memory comments print the lane.
    show_lane: bool = true,
    /// Verbatim source text for instructions written with `asm(...)`.
    text: ?[]const u8 = null,
    /// Inside an `exact` block: never moved, removed, or rewritten.
    frozen: bool = false,

    pub fn isNop(self: Inst) bool {
        return self.op == .nop;
    }

    /// The machine word, with relocated fields left zero.
    pub fn encode(self: Inst) u32 {
        return encoders.get(self.op.format())(self);
    }
};

pub const Item = union(enum) {
    instruction: Inst,
    label: []const u8,
    /// A verbatim line: section directives, data, and blank lines.
    text: []const u8,
    /// Raw assembly the IR does not model; an optimization barrier.
    raw: []const u8,
    exact_begin,
    exact_end,
};

fn reg(value: Reg) u32 {
    return @intFromEnum(value);
}

fn vreg(value: VReg) u32 {
    return @intFromEnum(value);
}

fn low16(value: i32) u32 {
    return @as(u16, @truncate(@as(u32, @bitCast(value))));
}

fn encodeNone(_: Inst) u32 {
    return 0;
}

fn encodeBreak(inst: Inst) u32 {
    return (@as(u32, @bitCast(inst.imm)) & 0xfffff) << 6 | inst.op.info().code;
}

fn encodeRegister(inst: Inst) u32 {
    return reg(inst.rs) << 21 | reg(inst.rt) << 16 | reg(inst.rd) << 11 | inst.op.info().code;
}

fn encodeShift(inst: Inst) u32 {
    return reg(inst.rt) << 16 | reg(inst.rd) << 11 | (@as(u32, @bitCast(inst.imm)) & 31) << 6 | inst.op.info().code;
}

fn encodeImmediate(inst: Inst) u32 {
    const value = if (inst.symbol == null) low16(inst.imm) else 0;
    return inst.op.info().code << 26 | reg(inst.rs) << 21 | reg(inst.rt) << 16 | value;
}

fn encodeJump(inst: Inst) u32 {
    return inst.op.info().code << 26;
}

fn encodeJumpRegister(inst: Inst) u32 {
    const link: u32 = if (inst.op == .jalr) 31 << 11 else 0;
    return reg(inst.rs) << 21 | link | inst.op.info().code;
}

fn encodeBranchCompare(inst: Inst) u32 {
    return inst.op.info().code << 26 | reg(inst.rs) << 21 | reg(inst.rt) << 16;
}

fn encodeBranchZero(inst: Inst) u32 {
    const code = inst.op.info().code;
    return (code >> 5) << 26 | reg(inst.rs) << 21 | (code & 31) << 16;
}

fn encodeBranchAlways(_: Inst) u32 {
    return 0x04 << 26;
}

fn encodeCop0(inst: Inst) u32 {
    return 0x10 << 26 | inst.op.info().code << 21 | reg(inst.rt) << 16 | (@as(u32, @bitCast(inst.imm)) & 31) << 11;
}

fn encodeCop2Lane(inst: Inst) u32 {
    return 0x12 << 26 | inst.op.info().code << 21 | reg(inst.rt) << 16 | vreg(inst.vt) << 11 | @as(u32, inst.element) << 8;
}

fn encodeCop2Control(inst: Inst) u32 {
    return 0x12 << 26 | inst.op.info().code << 21 | reg(inst.rt) << 16 | (@as(u32, @bitCast(inst.imm)) & 31) << 11;
}

fn encodeVector(inst: Inst) u32 {
    return 0x4a000000 | @as(u32, inst.element) << 21 | vreg(inst.vt) << 16 | vreg(inst.vs) << 11 |
        vreg(inst.vd) << 6 | inst.op.info().code;
}

fn encodeVectorLane(inst: Inst) u32 {
    return 0x4a000000 | @as(u32, inst.element) << 21 | vreg(inst.vt) << 16 |
        @as(u32, inst.dest_element) << 11 | vreg(inst.vd) << 6 | inst.op.info().code;
}

fn encodeVectorMemory(inst: Inst) u32 {
    const op_info = inst.op.info();
    const scaled = @divTrunc(inst.imm, @as(i32, op_info.scale));
    const offset: u32 = @as(u7, @truncate(@as(u32, @bitCast(scaled))));
    return (op_info.code >> 5) << 26 | reg(inst.rs) << 21 | vreg(inst.vt) << 16 | (op_info.code & 31) << 11 |
        @as(u32, inst.element) << op_info.lane_shift | offset;
}

const Encoder = *const fn (Inst) u32;

const encoders = std.EnumArray(Format, Encoder).init(.{
    .none = &encodeNone,
    .breakpoint = &encodeBreak,
    .register = &encodeRegister,
    .shift_variable = &encodeRegister,
    .shift = &encodeShift,
    .immediate = &encodeImmediate,
    .upper = &encodeImmediate,
    .memory = &encodeImmediate,
    .jump = &encodeJump,
    .jump_register = &encodeJumpRegister,
    .branch_compare = &encodeBranchCompare,
    .branch_zero = &encodeBranchZero,
    .branch_always = &encodeBranchAlways,
    .cop0 = &encodeCop0,
    .cop2_lane = &encodeCop2Lane,
    .cop2_control = &encodeCop2Control,
    .vector = &encodeVector,
    .vector_lane = &encodeVectorLane,
    .vector_memory = &encodeVectorMemory,
});

const testing = std.testing;

test "scalar instructions encode to their MIPS words" {
    try testing.expectEqual(@as(u32, 0x2408_0001), (Inst{ .op = .addiu, .rt = .t0, .imm = 1 }).encode());
    try testing.expectEqual(@as(u32, 0x0109_5025), (Inst{ .op = .@"or", .rd = .t2, .rs = .t0, .rt = .t1 }).encode());
    try testing.expectEqual(@as(u32, 0x0009_4080), (Inst{ .op = .sll, .rd = .t0, .rt = .t1, .imm = 2 }).encode());
    try testing.expectEqual(@as(u32, 0x8c88_0004), (Inst{ .op = .lw, .rt = .t0, .rs = .a0, .imm = 4 }).encode());
    try testing.expectEqual(@as(u32, 0x0000_000d), (Inst{ .op = .@"break" }).encode());
    try testing.expectEqual(@as(u32, 0x0000_028d), (Inst{ .op = .@"break", .imm = 0xa }).encode());
    try testing.expectEqual(@as(u32, 0x0100_f809), (Inst{ .op = .jalr, .rs = .t0 }).encode());
    try testing.expectEqual(@as(u32, 0x0501_0000), (Inst{ .op = .bgez, .rs = .t0 }).encode());
    try testing.expectEqual(@as(u32, 0x1500_0000), (Inst{ .op = .bnez, .rs = .t0 }).encode());
    try testing.expectEqual(@as(u32, 0x4008_2000), (Inst{ .op = .mfc0, .rt = .t0, .imm = 4 }).encode());
    try testing.expectEqual(@as(u32, 0x0000_0000), (Inst{ .op = .nop }).encode());
}

test "vector instructions encode like the hardware assembler" {
    try testing.expectEqual(@as(u32, 0x4a0208d0), (Inst{ .op = .vadd, .vd = .v03, .vs = .v01, .vt = .v02 }).encode());
    try testing.expectEqual(@as(u32, 0xc8211000), (Inst{ .op = .llv, .rs = .at, .vt = .v01, .element = 0, .imm = 0 }).encode());
    try testing.expectEqual(@as(u32, 0xc8012002), (Inst{ .op = .lqv, .vt = .v01, .imm = 32 }).encode());
    try testing.expectEqual(@as(u32, 0x48881000), (Inst{ .op = .mtc2, .rt = .t0, .vt = .v02 }).encode());
    try testing.expectEqual(@as(u32, 0x48480800), (Inst{ .op = .cfc2, .rt = .t0, .imm = 1 }).encode());
    try testing.expectEqual(@as(u32, 0x4b1f1873), (Inst{ .op = .vmov, .vd = .v01, .dest_element = 3, .vt = .v31, .element = 8 }).encode());
    try testing.expectEqual(Format.vector, Op.vsll8.format());
    try testing.expectEqual(@as(?Op, .@"or"), Op.fromMnemonic("or"));
}
