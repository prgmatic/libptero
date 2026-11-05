//! Per-lane semantics of RSP vector add, logic, compare, clip, and merge
//! instructions. Each function returns the destination lane and writes the
//! accumulator low lane plus any per-lane flags it defines.
const std = @import("std");
const vector = @import("vector.zig");
const State = @import("vu_state.zig").State;

const signed = vector.signed;
const flag = vector.flag;
const setFlag = vector.setFlag;

fn storeLow(s: *State, lane: usize, value: u16) u16 {
    s.setAccLow(lane, value);
    return value;
}

fn negate(value: u16) u16 {
    return 0 -% value;
}

pub fn vadd(s: *State, lane: usize, a: u16, b: u16) u16 {
    const sum = signed(a) + signed(b) + @intFromBool(flag(s.vco_lo, lane));
    s.setAccLow(lane, @truncate(@as(u32, @bitCast(sum))));
    return vector.clamp16(sum);
}

pub fn vsub(s: *State, lane: usize, a: u16, b: u16) u16 {
    const difference = signed(a) - signed(b) - @intFromBool(flag(s.vco_lo, lane));
    s.setAccLow(lane, @truncate(@as(u32, @bitCast(difference))));
    return vector.clamp16(difference);
}

pub fn vaddc(s: *State, lane: usize, a: u16, b: u16) u16 {
    const sum = @as(u32, a) + b;
    _ = setFlag(&s.vco_lo, lane, sum > 0xffff);
    return storeLow(s, lane, @truncate(sum));
}

pub fn vsubc(s: *State, lane: usize, a: u16, b: u16) u16 {
    _ = setFlag(&s.vco_lo, lane, a < b);
    _ = setFlag(&s.vco_hi, lane, a != b);
    return storeLow(s, lane, a -% b);
}

pub fn vabs(s: *State, lane: usize, a: u16, b: u16) u16 {
    if (signed(a) > 0) return storeLow(s, lane, b);
    if (signed(a) == 0) return storeLow(s, lane, 0);
    if (b == 0x8000) {
        s.setAccLow(lane, 0x8000);
        return 0x7fff;
    }
    return storeLow(s, lane, negate(b));
}

/// Reserved computational opcodes add into the accumulator and write zero.
pub fn vzero(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAccLow(lane, a +% b);
    return 0;
}

pub fn vand(s: *State, lane: usize, a: u16, b: u16) u16 {
    return storeLow(s, lane, a & b);
}

pub fn vnand(s: *State, lane: usize, a: u16, b: u16) u16 {
    return storeLow(s, lane, ~(a & b));
}

pub fn vor(s: *State, lane: usize, a: u16, b: u16) u16 {
    return storeLow(s, lane, a | b);
}

pub fn vnor(s: *State, lane: usize, a: u16, b: u16) u16 {
    return storeLow(s, lane, ~(a | b));
}

pub fn vxor(s: *State, lane: usize, a: u16, b: u16) u16 {
    return storeLow(s, lane, a ^ b);
}

pub fn vnxor(s: *State, lane: usize, a: u16, b: u16) u16 {
    return storeLow(s, lane, ~(a ^ b));
}

fn selectBy(s: *State, lane: usize, condition: bool, a: u16, b: u16) u16 {
    return storeLow(s, lane, if (setFlag(&s.vcc_lo, lane, condition)) a else b);
}

pub fn vlt(s: *State, lane: usize, a: u16, b: u16) u16 {
    const tie = signed(a) == signed(b) and flag(s.vco_lo, lane) and flag(s.vco_hi, lane);
    return selectBy(s, lane, signed(a) < signed(b) or tie, a, b);
}

pub fn veq(s: *State, lane: usize, a: u16, b: u16) u16 {
    return selectBy(s, lane, !flag(s.vco_hi, lane) and a == b, a, b);
}

pub fn vne(s: *State, lane: usize, a: u16, b: u16) u16 {
    return selectBy(s, lane, a != b or flag(s.vco_hi, lane), a, b);
}

pub fn vge(s: *State, lane: usize, a: u16, b: u16) u16 {
    const carry_pair = flag(s.vco_lo, lane) and flag(s.vco_hi, lane);
    return selectBy(s, lane, signed(a) > signed(b) or (a == b and !carry_pair), a, b);
}

pub fn vmrg(s: *State, lane: usize, a: u16, b: u16) u16 {
    return storeLow(s, lane, if (flag(s.vcc_lo, lane)) a else b);
}

/// VCH: begin a double-precision clip test against the high halves.
pub fn vch(s: *State, lane: usize, a: u16, b: u16) u16 {
    const opposite = (signed(a) ^ signed(b)) < 0;
    _ = setFlag(&s.vco_lo, lane, opposite);
    if (opposite) return clipHighOpposite(s, lane, a, b);
    return clipHighSame(s, lane, a, b);
}

fn clipHighOpposite(s: *State, lane: usize, a: u16, b: u16) u16 {
    const sum: i16 = @bitCast(a +% b);
    _ = setFlag(&s.vcc_hi, lane, signed(b) < 0);
    _ = setFlag(&s.vce, lane, sum == -1);
    _ = setFlag(&s.vco_hi, lane, sum != 0 and a != ~b);
    return storeLow(s, lane, if (setFlag(&s.vcc_lo, lane, sum <= 0)) negate(b) else a);
}

fn clipHighSame(s: *State, lane: usize, a: u16, b: u16) u16 {
    const difference: i16 = @bitCast(a -% b);
    _ = setFlag(&s.vcc_lo, lane, signed(b) < 0);
    _ = setFlag(&s.vce, lane, false);
    _ = setFlag(&s.vco_hi, lane, difference != 0 and a != ~b);
    return storeLow(s, lane, if (setFlag(&s.vcc_hi, lane, difference >= 0)) b else a);
}

/// VCL: complete a double-precision clip test using flags left by VCH.
pub fn vcl(s: *State, lane: usize, a: u16, b: u16) u16 {
    if (flag(s.vco_lo, lane)) return clipLowOpposite(s, lane, a, b);
    if (flag(s.vco_hi, lane)) return storeLow(s, lane, if (flag(s.vcc_hi, lane)) b else a);
    return storeLow(s, lane, if (setFlag(&s.vcc_hi, lane, a >= b)) b else a);
}

fn clipLowOpposite(s: *State, lane: usize, a: u16, b: u16) u16 {
    if (flag(s.vco_hi, lane)) return storeLow(s, lane, if (flag(s.vcc_lo, lane)) negate(b) else a);
    const condition = clipLowCondition(@as(u32, a) + b, flag(s.vce, lane));
    return storeLow(s, lane, if (setFlag(&s.vcc_lo, lane, condition)) negate(b) else a);
}

/// VCL's low-half test for opposite signs; VCE relaxes the equality case.
fn clipLowCondition(sum: u32, extension: bool) bool {
    const zero_sum = sum & 0xffff == 0;
    const carry = sum > 0xffff;
    if (extension) return zero_sum or !carry;
    return zero_sum and !carry;
}

/// VCR: single-precision one's-complement clip test.
pub fn vcr(s: *State, lane: usize, a: u16, b: u16) u16 {
    if ((signed(a) ^ signed(b)) < 0) {
        _ = setFlag(&s.vcc_hi, lane, signed(b) < 0);
        return storeLow(s, lane, if (setFlag(&s.vcc_lo, lane, signed(a) + signed(b) + 1 <= 0)) ~b else a);
    }
    _ = setFlag(&s.vcc_lo, lane, signed(b) < 0);
    return storeLow(s, lane, if (setFlag(&s.vcc_hi, lane, signed(a) - signed(b) >= 0)) b else a);
}

const testing = std.testing;

test "saturating add and subtract consume the carry flag" {
    var s: State = .{ .vco_lo = 1 };
    try testing.expectEqual(@as(u16, 0x7fff), vadd(&s, 0, 0x7fff, 0x0001));
    try testing.expectEqual(@as(u16, 0x8001), s.accLow(0));
    try testing.expectEqual(@as(u16, 0x8000), vsub(&s, 0, 0x8000, 0x0001));
    try testing.expectEqual(@as(u16, 0x7ffe), s.accLow(0));
    try testing.expectEqual(@as(u16, 3), vadd(&s, 1, 1, 2));
    try testing.expectEqual(@as(u16, 0xffff), vsub(&s, 1, 1, 2));
}

test "carry-producing add and subtract set VCO" {
    var s: State = .{};
    try testing.expectEqual(@as(u16, 0x0000), vaddc(&s, 2, 0xffff, 0x0001));
    try testing.expect(flag(s.vco_lo, 2));
    try testing.expectEqual(@as(u16, 0xffff), vsubc(&s, 3, 0x0000, 0x0001));
    try testing.expect(flag(s.vco_lo, 3));
    try testing.expect(flag(s.vco_hi, 3));
    _ = vsubc(&s, 3, 5, 5);
    try testing.expect(!flag(s.vco_lo, 3));
    try testing.expect(!flag(s.vco_hi, 3));
}

test "absolute value and reserved opcodes" {
    var s: State = .{};
    try testing.expectEqual(@as(u16, 9), vabs(&s, 0, 1, 9));
    try testing.expectEqual(@as(u16, 0), vabs(&s, 0, 0, 9));
    try testing.expectEqual(@as(u16, 0xfff7), vabs(&s, 0, 0xffff, 9));
    try testing.expectEqual(@as(u16, 0x7fff), vabs(&s, 0, 0xffff, 0x8000));
    try testing.expectEqual(@as(u16, 0x8000), s.accLow(0));
    try testing.expectEqual(@as(u16, 0), vzero(&s, 0, 3, 4));
    try testing.expectEqual(@as(u16, 7), s.accLow(0));
}

test "bitwise operations" {
    var s: State = .{};
    try testing.expectEqual(@as(u16, 0x0f00), vand(&s, 0, 0xff00, 0x0ff0));
    try testing.expectEqual(@as(u16, 0xf0ff), vnand(&s, 0, 0xff00, 0x0ff0));
    try testing.expectEqual(@as(u16, 0xfff0), vor(&s, 0, 0xff00, 0x0ff0));
    try testing.expectEqual(@as(u16, 0x000f), vnor(&s, 0, 0xff00, 0x0ff0));
    try testing.expectEqual(@as(u16, 0xf0f0), vxor(&s, 0, 0xff00, 0x0ff0));
    try testing.expectEqual(@as(u16, 0x0f0f), vnxor(&s, 0, 0xff00, 0x0ff0));
    try testing.expectEqual(@as(u16, 0x0f0f), s.accLow(0));
}

test "comparisons select operands and write VCC" {
    var s: State = .{};
    try testing.expectEqual(@as(u16, 0xffff), vlt(&s, 0, 0xffff, 1));
    try testing.expect(flag(s.vcc_lo, 0));
    try testing.expectEqual(@as(u16, 1), vlt(&s, 0, 2, 1));
    try testing.expect(!flag(s.vcc_lo, 0));
    s.vco_lo = 1;
    s.vco_hi = 1;
    _ = vlt(&s, 0, 4, 4);
    try testing.expect(flag(s.vcc_lo, 0));
    _ = vge(&s, 0, 4, 4);
    try testing.expect(!flag(s.vcc_lo, 0));
    _ = veq(&s, 0, 4, 4);
    try testing.expect(!flag(s.vcc_lo, 0));
    _ = vne(&s, 0, 4, 4);
    try testing.expect(flag(s.vcc_lo, 0));
    s.vco_hi = 0;
    _ = veq(&s, 0, 4, 4);
    try testing.expect(flag(s.vcc_lo, 0));
    _ = vne(&s, 0, 4, 4);
    try testing.expect(!flag(s.vcc_lo, 0));
    try testing.expectEqual(@as(u16, 5), vge(&s, 0, 5, 4));
    try testing.expectEqual(@as(u16, 9), vmrg(&s, 1, 8, 9));
    s.vcc_lo = 2;
    try testing.expectEqual(@as(u16, 8), vmrg(&s, 1, 8, 9));
}

test "VCH and VCL clip a value against positive and negative bounds" {
    var s: State = .{};
    try testing.expectEqual(@as(u16, 3), vch(&s, 0, 5, 3));
    try testing.expect(flag(s.vcc_hi, 0));
    try testing.expect(!flag(s.vco_lo, 0));
    try testing.expectEqual(@as(u16, 2), vch(&s, 1, 2, 3));
    try testing.expect(!flag(s.vcc_hi, 1));
    try testing.expectEqual(@as(u16, 0xfffd), vch(&s, 2, 0xfffb, 3));
    try testing.expect(flag(s.vcc_lo, 2));
    try testing.expect(flag(s.vco_lo, 2));
    try testing.expectEqual(@as(u16, 0xffff), vch(&s, 3, 0xfffe, 1));
    try testing.expect(flag(s.vce, 3));
    try testing.expect(!flag(s.vco_hi, 3));
    try testing.expectEqual(@as(u16, 0xfffe), vch(&s, 4, 0xfffe, 5));
    try testing.expect(!flag(s.vcc_lo, 4));

    s = .{ .vco_lo = 0b0011, .vco_hi = 0b0101, .vcc_lo = 0b0001, .vcc_hi = 0b0100, .vce = 0b0010 };
    try testing.expectEqual(@as(u16, 0xfffe), vcl(&s, 0, 9, 2));
    try testing.expectEqual(@as(u16, 0xfffe), vcl(&s, 1, 0, 2));
    try testing.expectEqual(@as(u16, 2), vcl(&s, 2, 9, 2));
    try testing.expectEqual(@as(u16, 2), vcl(&s, 3, 9, 2));
    try testing.expect(flag(s.vcc_hi, 3));
    try testing.expectEqual(@as(u16, 1), vcl(&s, 3, 1, 2));
    s.vco_lo = 1;
    s.vco_hi = 0;
    s.vce = 0;
    try testing.expectEqual(@as(u16, 0xfffe), vcl(&s, 0, 0xfffe, 2));
    try testing.expectEqual(@as(u16, 9), vcl(&s, 0, 9, 2));
}

test "VCR clips with one's-complement bounds" {
    var s: State = .{};
    try testing.expectEqual(@as(u16, 3), vcr(&s, 0, 5, 3));
    try testing.expect(flag(s.vcc_hi, 0));
    try testing.expectEqual(@as(u16, 2), vcr(&s, 0, 2, 3));
    try testing.expectEqual(@as(u16, 0xfffc), vcr(&s, 0, 0xfff0, 3));
    try testing.expect(flag(s.vcc_lo, 0));
    try testing.expectEqual(@as(u16, 0x000f), vcr(&s, 0, 1, 0xfff0));
    try testing.expect(flag(s.vcc_hi, 0));
    try testing.expectEqual(@as(u16, 0xfffe), vcr(&s, 0, 0xfffe, 3));
    try testing.expect(!flag(s.vcc_lo, 0));
}
