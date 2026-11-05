//! Per-lane semantics of the RSP multiply and multiply-accumulate family.
//!
//! Every function receives the source lane `a` (vs), the element-selected lane
//! `b` (vt), updates the accumulator lane, and returns the destination lane.
const std = @import("std");
const vector = @import("vector.zig");
const State = @import("vu_state.zig").State;

const signed = vector.signed;

fn fractional(a: u16, b: u16) i64 {
    return @as(i64, signed(a)) * signed(b) * 2;
}

fn signedTimesUnsigned(a: u16, b: u16) i64 {
    return @as(i64, signed(a)) * b;
}

fn unsignedTimesSigned(a: u16, b: u16) i64 {
    return @as(i64, a) * signed(b);
}

fn lowProduct(a: u16, b: u16) i64 {
    return (@as(u32, a) * b) >> 16;
}

fn highProduct(a: u16, b: u16) i64 {
    return @as(i64, signed(a) * signed(b)) << 16;
}

pub fn vmulf(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, fractional(a, b) + 0x8000);
    return s.saturateMid(lane);
}

pub fn vmulu(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, fractional(a, b) + 0x8000);
    return s.saturateUnsigned(lane);
}

pub fn vmacf(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, s.accSigned(lane) + fractional(a, b));
    return s.saturateMid(lane);
}

pub fn vmacu(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, s.accSigned(lane) + fractional(a, b));
    return s.saturateUnsigned(lane);
}

pub fn vmudl(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, lowProduct(a, b));
    return s.accLow(lane);
}

pub fn vmudm(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, signedTimesUnsigned(a, b));
    return s.accMid(lane);
}

pub fn vmudn(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, unsignedTimesSigned(a, b));
    return s.accLow(lane);
}

pub fn vmudh(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, highProduct(a, b));
    return s.saturateMid(lane);
}

pub fn vmadl(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, s.accSigned(lane) + lowProduct(a, b));
    return s.saturateLow(lane);
}

pub fn vmadm(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, s.accSigned(lane) + signedTimesUnsigned(a, b));
    return s.saturateMid(lane);
}

pub fn vmadn(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, s.accSigned(lane) + unsignedTimesSigned(a, b));
    return s.saturateLow(lane);
}

pub fn vmadh(s: *State, lane: usize, a: u16, b: u16) u16 {
    s.setAcc(lane, s.accSigned(lane) + highProduct(a, b));
    return s.saturateMid(lane);
}

/// MPEG-style quantized multiply.
pub fn vmulq(s: *State, lane: usize, a: u16, b: u16) u16 {
    var product: i32 = signed(a) * signed(b);
    if (product < 0) product += 31;
    s.setAcc(lane, @as(i64, product) << 16);
    return quantized(product);
}

/// Quantized accumulate; VMACQ ignores its vector operands.
pub fn vmacq(s: *State, lane: usize, a: u16, b: u16) u16 {
    _ = a;
    _ = b;
    const product = quantizedRound(@truncate(s.accSigned(lane) >> 16));
    s.setAcc(lane, @as(i64, product) << 16 | s.accLow(lane));
    return quantized(product);
}

fn quantizedRound(product: i32) i32 {
    if (product & 32 != 0) return product;
    if (product < 0) return product + 32;
    if (product >= 32) return product - 32;
    return product;
}

fn quantized(product: i32) u16 {
    return vector.clamp16(product >> 1) & 0xfff0;
}

const testing = std.testing;

fn expectLane(comptime op: anytype, a: u16, b: u16, expected: u16, acc: u64) !void {
    var s: State = .{};
    try testing.expectEqual(expected, op(&s, 0, a, b));
    try testing.expectEqual(acc, s.acc[0]);
}

test "single multiplies set the accumulator and destination views" {
    try expectLane(vmulf, 0x4000, 0x4000, 0x2000, 0x0000_2000_8000);
    try expectLane(vmulf, 0x8000, 0x8000, 0x7fff, 0x0000_8000_8000);
    try expectLane(vmulu, 0xc000, 0x4000, 0x0000, 0xffff_e000_8000);
    try expectLane(vmulu, 0x8000, 0x8000, 0xffff, 0x0000_8000_8000);
    try expectLane(vmudl, 0xffff, 0xffff, 0xfffe, 0x0000_0000_fffe);
    try expectLane(vmudm, 0xffff, 0x0002, 0xffff, 0xffff_ffff_fffe);
    try expectLane(vmudn, 0x0002, 0xffff, 0xfffe, 0xffff_ffff_fffe);
    try expectLane(vmudh, 0x0100, 0x0100, 0x7fff, 0x0001_0000_0000);
    try expectLane(vmudh, 0x0003, 0xfffe, 0xfffa, 0xffff_fffa_0000);
}

test "accumulating multiplies add to the existing accumulator" {
    var s: State = .{};
    _ = vmudh(&s, 0, 1, 2);
    try testing.expectEqual(@as(u16, 5), vmadh(&s, 0, 1, 3));
    try testing.expectEqual(@as(u16, 0x4000), vmadl(&s, 0, 0x8000, 0x8000));
    try testing.expectEqual(@as(u64, 0x0000_0005_4000), s.acc[0]);
    try testing.expectEqual(@as(u16, 0x3fff), vmadn(&s, 0, 0x0001, 0xffff));
    try testing.expectEqual(@as(u16, 5), vmadm(&s, 0, 0xffff, 0x0002));
    try testing.expectEqual(@as(u64, 0x0000_0005_3ffd), s.acc[0]);
    try testing.expectEqual(@as(u16, 5), vmacf(&s, 0, 0x0000, 0x0000));
    try testing.expectEqual(@as(u16, 5), vmacu(&s, 0, 0x0000, 0x0000));
    s.setAcc(0, 0x7fff_0000_0000);
    try testing.expectEqual(@as(u16, 0xffff), vmadl(&s, 0, 0, 0));
    try testing.expectEqual(@as(u16, 0x7fff), vmadh(&s, 0, 0, 0));
}

test "quantized multiplies round toward zero and mask low bits" {
    try expectLane(vmulq, 0x0100, 0x0100, 0x7ff0, 0x0001_0000_0000);
    try expectLane(vmulq, 0xffff, 0x0001, 0x0000, 0x0000_001e_0000);
    var s: State = .{};
    s.setAcc(0, 0x0000_0040_0000);
    try testing.expectEqual(@as(u16, 0x0010), vmacq(&s, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0x0000_0020_0000), s.acc[0]);
    s.setAcc(0, -0x40_0000);
    _ = vmacq(&s, 0, 0, 0);
    try testing.expectEqual(@as(i64, -0x20_0000), s.accSigned(0));
    s.setAcc(0, 0x0000_0060_0000);
    _ = vmacq(&s, 0, 0, 0);
    try testing.expectEqual(@as(u64, 0x0000_0060_0000), s.acc[0]);
    s.setAcc(0, 0x0000_0010_0000);
    _ = vmacq(&s, 0, 0, 0);
    try testing.expectEqual(@as(u64, 0x0000_0010_0000), s.acc[0]);
}
