//! Minimal RSP instruction encoders used to build interpreter test programs.
pub const Load = enum(u5) { lbv, lsv, llv, ldv, lqv, lrv, lpv, luv, lhv, lfv, lwv, ltv, _ };
pub const Store = enum(u5) { sbv, ssv, slv, sdv, sqv, srv, spv, suv, shv, sfv, swv, stv, _ };

fn offset7(offset: i7) u32 {
    return @as(u7, @bitCast(offset));
}

pub fn vectorLoad(kind: Load, vt: u5, base: u5, element: u4, offset: i7) u32 {
    return vectorMemory(0x32, @intFromEnum(kind), vt, base, element, offset);
}

pub fn vectorStore(kind: Store, vt: u5, base: u5, element: u4, offset: i7) u32 {
    return vectorMemory(0x3a, @intFromEnum(kind), vt, base, element, offset);
}

fn vectorMemory(op: u6, kind: u5, vt: u5, base: u5, element: u4, offset: i7) u32 {
    return @as(u32, op) << 26 | @as(u32, base) << 21 | @as(u32, vt) << 16 |
        @as(u32, kind) << 11 | @as(u32, element) << 7 | offset7(offset);
}

/// Computational COP2 instruction: `funct vd, vs, vt[element]`.
pub fn vectorOp(funct: u6, vd: u5, vs: u5, vt: u5, element: u4) u32 {
    return 0x12 << 26 | 1 << 25 | @as(u32, element) << 21 | @as(u32, vt) << 16 |
        @as(u32, vs) << 11 | @as(u32, vd) << 6 | funct;
}

pub const Cop2Move = enum(u5) { mfc2 = 0, cfc2 = 2, mtc2 = 4, ctc2 = 6, _ };

pub fn cop2Move(kind: Cop2Move, rt: u5, rd: u5, element: u4) u32 {
    return 0x12 << 26 | @as(u32, @intFromEnum(kind)) << 21 | @as(u32, rt) << 16 |
        @as(u32, rd) << 11 | @as(u32, element) << 7;
}

pub fn cop0Move(write: bool, rt: u5, rd: u5) u32 {
    const sub: u32 = if (write) 4 else 0;
    return 0x10 << 26 | sub << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11;
}

pub fn special(funct: u6, rs: u5, rt: u5, rd: u5, sa: u5) u32 {
    return @as(u32, rs) << 21 | @as(u32, rt) << 16 | @as(u32, rd) << 11 | @as(u32, sa) << 6 | funct;
}

pub fn immediate(op: u6, rs: u5, rt: u5, imm: u16) u32 {
    return @as(u32, op) << 26 | @as(u32, rs) << 21 | @as(u32, rt) << 16 | imm;
}

pub fn signedImmediate(op: u6, rs: u5, rt: u5, imm: i16) u32 {
    return immediate(op, rs, rt, @bitCast(imm));
}

pub fn regimm(code: u5, rs: u5, offset: i16) u32 {
    return immediate(0x01, rs, code, @bitCast(offset));
}

pub fn jump(op: u6, target: u32) u32 {
    return @as(u32, op) << 26 | ((target >> 2) & 0x03ff_ffff);
}

pub fn addiu(rt: u5, rs: u5, imm: i16) u32 {
    return signedImmediate(0x09, rs, rt, imm);
}

pub fn ori(rt: u5, rs: u5, imm: u16) u32 {
    return immediate(0x0d, rs, rt, imm);
}

pub fn lw(rt: u5, base: u5, offset: i16) u32 {
    return signedImmediate(0x23, base, rt, offset);
}

pub fn sw(rt: u5, base: u5, offset: i16) u32 {
    return signedImmediate(0x2b, base, rt, offset);
}

/// Branch offsets are in instructions relative to the delay slot.
pub fn bne(rs: u5, rt: u5, offset: i16) u32 {
    return signedImmediate(0x05, rs, rt, offset);
}

pub fn jr(rs: u5) u32 {
    return special(0x08, rs, 0, 0, 0);
}

pub const nop: u32 = 0;
pub const brk: u32 = 0x0d;

test "encoders produce assembler-compatible words" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0x2509fffc), addiu(9, 8, -4));
    try testing.expectEqual(@as(u32, 0x4be208c7), vectorOp(7, 3, 1, 2, 15));
    try testing.expectEqual(@as(u32, 0xc8222004), vectorLoad(.lqv, 2, 1, 0, 4));
    try testing.expectEqual(@as(u32, 0xe8222004), vectorStore(.sqv, 2, 1, 0, 4));
    try testing.expectEqual(@as(u32, 0x40882000), cop0Move(true, 8, 4));
    try testing.expectEqual(@as(u32, 0x48881000), cop2Move(.mtc2, 8, 2, 0));
    try testing.expectEqual(@as(u32, 0x0c000400), jump(0x03, 0x1000));
    try testing.expectEqual(@as(u32, 0x03e00008), jr(31));
    try testing.expectEqual(@as(u32, 0x3508ffff), ori(8, 8, 0xffff));
    try testing.expectEqual(@as(u32, 0x8d090004), lw(9, 8, 4));
    try testing.expectEqual(@as(u32, 0xad090004), sw(9, 8, 4));
    try testing.expectEqual(@as(u32, 0x1509fffe), bne(8, 9, -2));
    try testing.expectEqual(@as(u32, 0x0511fffe), regimm(0x11, 8, -2));
}
