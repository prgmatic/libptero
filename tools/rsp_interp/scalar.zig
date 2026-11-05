//! Scalar-unit instruction decoding and execution.
//!
//! Dispatch is table-driven by opcode field so each handler stays small. The
//! RSP never traps on overflow, so ADD/ADDI/SUB behave like their unsigned
//! forms, and 64-bit, multiply, divide, and likely-branch encodings are invalid.
const std = @import("std");
const Machine = @import("Machine.zig");
const cop0 = @import("cop0.zig");
const vu_ops = @import("vu_ops.zig");
const vector_memory = @import("vector_memory.zig");
const fields = @import("fields.zig");

const Error = Machine.Error;
const Handler = *const fn (*Machine, u32) Error!void;

pub fn execute(m: *Machine, op: u32) Error!void {
    return primary[fields.opcode(op)](m, op);
}

fn invalid(_: *Machine, _: u32) Error!void {
    return error.InvalidInstruction;
}

fn rs(m: *const Machine, op: u32) u32 {
    return m.gpr[fields.rs(op)];
}

fn rt(m: *const Machine, op: u32) u32 {
    return m.gpr[fields.rt(op)];
}

fn signedImmediate(op: u32) u32 {
    return @bitCast(@as(i32, fields.simm(op)));
}

fn effectiveAddress(m: *const Machine, op: u32) u32 {
    return rs(m, op) +% signedImmediate(op);
}

fn branchTarget(m: *const Machine, op: u32) u32 {
    return m.pc +% 4 +% (signedImmediate(op) << 2);
}

fn branchIf(m: *Machine, op: u32, condition: bool) void {
    if (condition) m.jump(branchTarget(m, op));
}

fn link(m: *Machine, register: u5) void {
    m.setReg(register, (m.pc + 8) & 0xffc);
}

fn special(m: *Machine, op: u32) Error!void {
    return special_table[fields.funct(op)](m, op);
}

fn regimm(m: *Machine, op: u32) Error!void {
    return regimm_table[fields.rt(op)](m, op);
}

fn j(m: *Machine, op: u32) Error!void {
    m.jump(fields.target(op) << 2);
}

fn jal(m: *Machine, op: u32) Error!void {
    link(m, 31);
    m.jump(fields.target(op) << 2);
}

fn beq(m: *Machine, op: u32) Error!void {
    branchIf(m, op, rs(m, op) == rt(m, op));
}

fn bne(m: *Machine, op: u32) Error!void {
    branchIf(m, op, rs(m, op) != rt(m, op));
}

fn blez(m: *Machine, op: u32) Error!void {
    branchIf(m, op, @as(i32, @bitCast(rs(m, op))) <= 0);
}

fn bgtz(m: *Machine, op: u32) Error!void {
    branchIf(m, op, @as(i32, @bitCast(rs(m, op))) > 0);
}

fn bltz(m: *Machine, op: u32) Error!void {
    branchIf(m, op, @as(i32, @bitCast(rs(m, op))) < 0);
}

fn bgez(m: *Machine, op: u32) Error!void {
    branchIf(m, op, @as(i32, @bitCast(rs(m, op))) >= 0);
}

fn bltzal(m: *Machine, op: u32) Error!void {
    const condition = @as(i32, @bitCast(rs(m, op))) < 0;
    link(m, 31);
    branchIf(m, op, condition);
}

fn bgezal(m: *Machine, op: u32) Error!void {
    const condition = @as(i32, @bitCast(rs(m, op))) >= 0;
    link(m, 31);
    branchIf(m, op, condition);
}

fn addiu(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), rs(m, op) +% signedImmediate(op));
}

fn slti(m: *Machine, op: u32) Error!void {
    const less = @as(i32, @bitCast(rs(m, op))) < fields.simm(op);
    m.setReg(fields.rt(op), @intFromBool(less));
}

fn sltiu(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), @intFromBool(rs(m, op) < signedImmediate(op)));
}

fn andi(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), rs(m, op) & fields.imm(op));
}

fn ori(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), rs(m, op) | fields.imm(op));
}

fn xori(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), rs(m, op) ^ fields.imm(op));
}

fn lui(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), @as(u32, fields.imm(op)) << 16);
}

fn lb(m: *Machine, op: u32) Error!void {
    const value: i8 = @bitCast(m.readDmem(u8, effectiveAddress(m, op)));
    m.setReg(fields.rt(op), @bitCast(@as(i32, value)));
}

fn lh(m: *Machine, op: u32) Error!void {
    const value: i16 = @bitCast(m.readDmem(u16, effectiveAddress(m, op)));
    m.setReg(fields.rt(op), @bitCast(@as(i32, value)));
}

fn lw(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), m.readDmem(u32, effectiveAddress(m, op)));
}

fn lbu(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), m.readDmem(u8, effectiveAddress(m, op)));
}

fn lhu(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), m.readDmem(u16, effectiveAddress(m, op)));
}

fn sb(m: *Machine, op: u32) Error!void {
    m.writeDmem(u8, effectiveAddress(m, op), @truncate(rt(m, op)));
}

fn sh(m: *Machine, op: u32) Error!void {
    m.writeDmem(u16, effectiveAddress(m, op), @truncate(rt(m, op)));
}

fn sw(m: *Machine, op: u32) Error!void {
    m.writeDmem(u32, effectiveAddress(m, op), rt(m, op));
}

fn shiftAmount(m: *const Machine, op: u32) u5 {
    return @truncate(rs(m, op));
}

fn sll(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rt(m, op) << fields.sa(op));
}

fn srl(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rt(m, op) >> fields.sa(op));
}

fn sra(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), @bitCast(@as(i32, @bitCast(rt(m, op))) >> fields.sa(op)));
}

fn sllv(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rt(m, op) << shiftAmount(m, op));
}

fn srlv(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rt(m, op) >> shiftAmount(m, op));
}

fn srav(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), @bitCast(@as(i32, @bitCast(rt(m, op))) >> shiftAmount(m, op)));
}

fn jr(m: *Machine, op: u32) Error!void {
    m.jump(rs(m, op));
}

fn jalr(m: *Machine, op: u32) Error!void {
    const target = rs(m, op);
    link(m, fields.rd(op));
    m.jump(target);
}

fn brk(m: *Machine, _: u32) Error!void {
    m.sp.halted = true;
    m.sp.broken = true;
    m.sp.interrupts += @intFromBool(m.sp.interrupt_on_break);
}

fn addu(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rs(m, op) +% rt(m, op));
}

fn subu(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rs(m, op) -% rt(m, op));
}

fn andr(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rs(m, op) & rt(m, op));
}

fn orr(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rs(m, op) | rt(m, op));
}

fn xorr(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), rs(m, op) ^ rt(m, op));
}

fn nor(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), ~(rs(m, op) | rt(m, op)));
}

fn slt(m: *Machine, op: u32) Error!void {
    const less = @as(i32, @bitCast(rs(m, op))) < @as(i32, @bitCast(rt(m, op)));
    m.setReg(fields.rd(op), @intFromBool(less));
}

fn sltu(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rd(op), @intFromBool(rs(m, op) < rt(m, op)));
}

fn cop0Instruction(m: *Machine, op: u32) Error!void {
    return cop0.execute(m, op);
}

fn cop2Instruction(m: *Machine, op: u32) Error!void {
    return vu_ops.execute(m, op);
}

fn lwc2(m: *Machine, op: u32) Error!void {
    return vector_memory.load(m, op);
}

fn swc2(m: *Machine, op: u32) Error!void {
    return vector_memory.store(m, op);
}

fn table(comptime size: usize, comptime entries: anytype) [size]Handler {
    var result: [size]Handler = @splat(&invalid);
    for (entries) |entry| result[entry[0]] = entry[1];
    return result;
}

const primary = table(64, .{
    .{ 0x00, &special },  .{ 0x01, &regimm },          .{ 0x02, &j },     .{ 0x03, &jal },
    .{ 0x04, &beq },      .{ 0x05, &bne },             .{ 0x06, &blez },  .{ 0x07, &bgtz },
    .{ 0x08, &addiu },    .{ 0x09, &addiu },           .{ 0x0a, &slti },  .{ 0x0b, &sltiu },
    .{ 0x0c, &andi },     .{ 0x0d, &ori },             .{ 0x0e, &xori },  .{ 0x0f, &lui },
    .{ 0x10, &cop0Instruction }, .{ 0x12, &cop2Instruction }, .{ 0x20, &lb }, .{ 0x21, &lh },
    .{ 0x23, &lw },       .{ 0x24, &lbu },             .{ 0x25, &lhu },   .{ 0x27, &lw },
    .{ 0x28, &sb },       .{ 0x29, &sh },              .{ 0x2b, &sw },    .{ 0x32, &lwc2 },
    .{ 0x3a, &swc2 },
});

const special_table = table(64, .{
    .{ 0x00, &sll },  .{ 0x02, &srl },  .{ 0x03, &sra },  .{ 0x04, &sllv },
    .{ 0x06, &srlv }, .{ 0x07, &srav }, .{ 0x08, &jr },   .{ 0x09, &jalr },
    .{ 0x0d, &brk },  .{ 0x20, &addu }, .{ 0x21, &addu }, .{ 0x22, &subu },
    .{ 0x23, &subu }, .{ 0x24, &andr }, .{ 0x25, &orr },  .{ 0x26, &xorr },
    .{ 0x27, &nor },  .{ 0x2a, &slt },  .{ 0x2b, &sltu },
});

const regimm_table = table(32, .{
    .{ 0x00, &bltz }, .{ 0x01, &bgez }, .{ 0x10, &bltzal }, .{ 0x11, &bgezal },
});
