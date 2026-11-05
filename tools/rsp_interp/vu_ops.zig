//! COP2 instruction dispatch: register moves and computational vector ops.
const std = @import("std");
const Machine = @import("Machine.zig");
const fields = @import("fields.zig");
const vector = @import("vector.zig");
const multiply = @import("vu_multiply.zig");
const arith = @import("vu_arith.zig");
const divide = @import("vu_divide.zig");
const State = @import("vu_state.zig").State;

const Error = Machine.Error;
const Vec = vector.Vec;

pub fn execute(m: *Machine, op: u32) Error!void {
    if (op >> 25 & 1 != 0) return computational[fields.funct(op)](&m.vu, op);
    return moves[fields.rs(op) & 7](m, op);
}

const Move = *const fn (*Machine, u32) Error!void;

const moves = [8]Move{ mfc2, invalidMove, cfc2, invalidMove, mtc2, invalidMove, ctc2, invalidMove };

fn invalidMove(_: *Machine, _: u32) Error!void {
    return error.InvalidInstruction;
}

fn mfc2(m: *Machine, op: u32) Error!void {
    const v = m.vu.regs[fields.vs(op)];
    const e = fields.byteElement(op);
    const value: u16 = @as(u16, vector.byte(v, e)) << 8 | vector.byte(v, @as(usize, e) + 1);
    m.setReg(fields.rt(op), @bitCast(vector.signed(value)));
}

fn mtc2(m: *Machine, op: u32) Error!void {
    const value = m.gpr[fields.rt(op)];
    const v = &m.vu.regs[fields.vs(op)];
    const e = fields.byteElement(op);
    vector.setByte(v, e, @truncate(value >> 8));
    if (e != 15) vector.setByte(v, @as(usize, e) + 1, @truncate(value));
}

fn cfc2(m: *Machine, op: u32) Error!void {
    m.setReg(fields.rt(op), m.vu.readControl(fields.rd(op)));
}

fn ctc2(m: *Machine, op: u32) Error!void {
    m.vu.writeControl(fields.rd(op), m.gpr[fields.rt(op)]);
}

const Compute = *const fn (*State, u32) void;
const Lane = fn (*State, usize, u16, u16) u16;

const Post = enum { none, clear_carry, clear_carry_high, compare, clip };

/// Builds a whole-vector handler from a per-lane function. Destination writes
/// happen after all lanes are computed so vd may alias vs or vt.
fn lanewise(comptime lane: Lane, comptime post: Post) Compute {
    return struct {
        fn run(s: *State, op: u32) void {
            const a = s.regs[fields.vs(op)];
            const b = vector.select(s.regs[fields.vt(op)], fields.element(op));
            var out: Vec = undefined;
            for (&out, 0..) |*value, n| value.* = lane(s, n, a[n], b[n]);
            s.regs[fields.vd(op)] = out;
            finish(s, post);
        }
    }.run;
}

fn finish(s: *State, post: Post) void {
    switch (post) {
        .none => {},
        .clear_carry => clearCarry(s),
        .clear_carry_high => s.vco_hi = 0,
        .compare => {
            clearCarry(s);
            s.vcc_hi = 0;
        },
        .clip => {
            clearCarry(s);
            s.vce = 0;
        },
    }
}

fn clearCarry(s: *State) void {
    s.vco_lo = 0;
    s.vco_hi = 0;
}

fn nop(_: *State, _: u32) void {}

fn vsar(s: *State, op: u32) void {
    var out: Vec = vector.zero;
    for (&out, 0..) |*value, n| value.* = accumulatorSlice(s, fields.element(op), n);
    s.regs[fields.vd(op)] = out;
}

fn accumulatorSlice(s: *const State, element: u4, lane: usize) u16 {
    return switch (element) {
        8 => s.accHigh(lane),
        9 => s.accMid(lane),
        10 => s.accLow(lane),
        else => 0,
    };
}

fn rounding(comptime when_negative: bool) Compute {
    return struct {
        fn run(s: *State, op: u32) void {
            const b = vector.select(s.regs[fields.vt(op)], fields.element(op));
            const shift: u5 = if (fields.vs(op) & 1 != 0) 16 else 0;
            var out: Vec = undefined;
            for (&out, 0..) |*value, n| value.* = roundLane(s, n, @as(i64, vector.signed(b[n])) << shift, when_negative);
            s.regs[fields.vd(op)] = out;
        }
    }.run;
}

fn roundLane(s: *State, lane: usize, addend: i64, when_negative: bool) u16 {
    const acc = s.accSigned(lane);
    if ((acc < 0) == when_negative) s.setAcc(lane, acc + addend);
    return vector.clamp16(s.accSigned(lane) >> 16);
}

fn vmov(s: *State, op: u32) void {
    const b = vector.select(s.regs[fields.vt(op)], fields.element(op));
    const lane = fields.destinationLane(op);
    s.regs[fields.vd(op)][lane] = b[lane];
    s.setAccLowVector(b);
}

/// Reads the scalar divide input from vt; element selection only picks the lane.
fn divideSource(s: *const State, op: u32) u16 {
    return s.regs[fields.vt(op)][fields.element(op) & 7];
}

fn divideLow(comptime kind: divide.Kind, comptime double: bool) Compute {
    return struct {
        fn run(s: *State, op: u32) void {
            const value = divide.low(s, kind, double, divideSource(s, op));
            finishDivide(s, op, value);
        }
    }.run;
}

fn divideHigh(s: *State, op: u32) void {
    const value = divide.high(s, divideSource(s, op));
    finishDivide(s, op, value);
}

fn finishDivide(s: *State, op: u32, value: u16) void {
    s.setAccLowVector(vector.select(s.regs[fields.vt(op)], fields.element(op)));
    s.regs[fields.vd(op)][fields.destinationLane(op)] = value;
}

const vzero = lanewise(arith.vzero, .none);

const computational = blk: {
    var table: [64]Compute = @splat(vzero);
    table[0x00] = lanewise(multiply.vmulf, .none);
    table[0x01] = lanewise(multiply.vmulu, .none);
    table[0x02] = rounding(false);
    table[0x03] = lanewise(multiply.vmulq, .none);
    table[0x04] = lanewise(multiply.vmudl, .none);
    table[0x05] = lanewise(multiply.vmudm, .none);
    table[0x06] = lanewise(multiply.vmudn, .none);
    table[0x07] = lanewise(multiply.vmudh, .none);
    table[0x08] = lanewise(multiply.vmacf, .none);
    table[0x09] = lanewise(multiply.vmacu, .none);
    table[0x0a] = rounding(true);
    table[0x0b] = lanewise(multiply.vmacq, .none);
    table[0x0c] = lanewise(multiply.vmadl, .none);
    table[0x0d] = lanewise(multiply.vmadm, .none);
    table[0x0e] = lanewise(multiply.vmadn, .none);
    table[0x0f] = lanewise(multiply.vmadh, .none);
    table[0x10] = lanewise(arith.vadd, .clear_carry);
    table[0x11] = lanewise(arith.vsub, .clear_carry);
    table[0x13] = lanewise(arith.vabs, .none);
    table[0x14] = lanewise(arith.vaddc, .clear_carry_high);
    table[0x15] = lanewise(arith.vsubc, .none);
    table[0x1d] = vsar;
    table[0x20] = lanewise(arith.vlt, .compare);
    table[0x21] = lanewise(arith.veq, .compare);
    table[0x22] = lanewise(arith.vne, .compare);
    table[0x23] = lanewise(arith.vge, .compare);
    table[0x24] = lanewise(arith.vcl, .clip);
    table[0x25] = lanewise(arith.vch, .none);
    table[0x26] = lanewise(arith.vcr, .clip);
    table[0x27] = lanewise(arith.vmrg, .clear_carry);
    table[0x28] = lanewise(arith.vand, .none);
    table[0x29] = lanewise(arith.vnand, .none);
    table[0x2a] = lanewise(arith.vor, .none);
    table[0x2b] = lanewise(arith.vnor, .none);
    table[0x2c] = lanewise(arith.vxor, .none);
    table[0x2d] = lanewise(arith.vnxor, .none);
    table[0x30] = divideLow(.reciprocal, false);
    table[0x31] = divideLow(.reciprocal, true);
    table[0x32] = divideHigh;
    table[0x33] = vmov;
    table[0x34] = divideLow(.inverse_sqrt, false);
    table[0x35] = divideLow(.inverse_sqrt, true);
    table[0x36] = divideHigh;
    table[0x37] = nop;
    table[0x3f] = nop;
    break :blk table;
};
