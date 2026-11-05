//! RSP reciprocal and reciprocal-square-root unit (VRCP/VRSQ families).
const std = @import("std");
const vector = @import("vector.zig");
const State = @import("vu_state.zig").State;

pub const Kind = enum { reciprocal, inverse_sqrt };

pub const reciprocals: [512]u16 = blk: {
    @setEvalBranchQuota(10_000);
    break :blk buildReciprocals();
};
pub const inverse_square_roots: [512]u16 = blk: {
    @setEvalBranchQuota(100_000);
    break :blk buildInverseSquareRoots();
};

pub fn buildReciprocals() [512]u16 {
    var table: [512]u16 = undefined;
    table[0] = 0xffff;
    for (1..512) |index| table[index] = reciprocalEntry(index);
    return table;
}

fn reciprocalEntry(index: usize) u16 {
    const quotient = (@as(u64, 1) << 34) / (index + 512);
    return @truncate((quotient + 1) >> 8);
}

pub fn buildInverseSquareRoots() [512]u16 {
    var table: [512]u16 = undefined;
    for (&table, 0..) |*entry, index| entry.* = inverseSquareRootEntry(index);
    return table;
}

/// Largest b with a * b^2 < 2^44, halved; matches the hardware ROM.
fn inverseSquareRootEntry(index: usize) u16 {
    const a: u64 = (index + 512) >> @intCast(index & 1);
    const root = std.math.sqrt(((@as(u64, 1) << 44) - 1) / a);
    return @truncate(root >> 1);
}

/// Computes the 32-bit result for a sign-extended or double-precision input.
pub fn compute(kind: Kind, input: i32) i32 {
    if (input == 0) return 0x7fff_ffff;
    if (input == std.math.minInt(i16)) return @bitCast(@as(u32, 0xffff_0000));
    const mask = input >> 31;
    var data = input ^ mask;
    if (input > std.math.minInt(i16)) data -%= mask;
    return lookup(kind, @bitCast(data), mask);
}

fn lookup(kind: Kind, data: u32, mask: i32) i32 {
    const shift: u5 = @intCast(@clz(data));
    const index: usize = @intCast(((@as(u64, data) << shift) & 0x7fc0_0000) >> 22);
    const scaled: i32 = @bitCast((0x10000 | @as(u32, tableEntry(kind, index, shift))) << 14);
    return (scaled >> resultShift(kind, shift)) ^ mask;
}

fn tableEntry(kind: Kind, index: usize, shift: u5) u16 {
    return switch (kind) {
        .reciprocal => reciprocals[index],
        .inverse_sqrt => inverse_square_roots[(index & 0x1fe) | (shift & 1)],
    };
}

fn resultShift(kind: Kind, shift: u5) u5 {
    return switch (kind) {
        .reciprocal => 31 - shift,
        .inverse_sqrt => (31 - shift) >> 1,
    };
}

/// Low-precision operation (VRCP/VRSQ) or the low half of a double-precision
/// operation (VRCPL/VRSQL). Returns the lane written to `vd[de]`.
pub fn low(s: *State, kind: Kind, double: bool, source: u16) u16 {
    const input: i32 = if (double and s.div_pending)
        @bitCast(@as(u32, s.div_in) << 16 | source)
    else
        vector.signed(source);
    const result = compute(kind, input);
    s.div_pending = false;
    s.div_out = @truncate(@as(u32, @bitCast(result)) >> 16);
    return @truncate(@as(u32, @bitCast(result)));
}

/// VRCPH/VRSQH: latch the high input half and return the previous high result.
pub fn high(s: *State, source: u16) u16 {
    s.div_pending = true;
    s.div_in = source;
    return s.div_out;
}

const testing = std.testing;

test "tables match their generating formulas and known hardware values" {
    try testing.expectEqual(reciprocals, buildReciprocals());
    try testing.expectEqual(inverse_square_roots, buildInverseSquareRoots());
    try testing.expectEqualSlices(u16, &.{ 0xffff, 0xff00, 0xfe01, 0xfd04, 0xfc07, 0xfb0c, 0xfa11, 0xf918 }, reciprocals[0..8]);
    try testing.expectEqual(@as(u16, 0x5555), reciprocals[256]);
    try testing.expectEqualSlices(u16, &.{ 0x6a09, 0xffff, 0x6955, 0xff00, 0x68a1, 0xfe02, 0x67ef, 0xfd06 }, inverse_square_roots[0..8]);
}

test "reciprocal and inverse square root results" {
    try testing.expectEqual(@as(i32, 0x7fff_ffff), compute(.reciprocal, 0));
    try testing.expectEqual(@as(u32, 0xffff_0000), @as(u32, @bitCast(compute(.reciprocal, -32768))));
    try testing.expectEqual(@as(i32, 0x7fff_c000), compute(.reciprocal, 1));
    try testing.expectEqual(@as(i32, 0x3fff_e000), compute(.reciprocal, 2));
    try testing.expectEqual(@as(u32, 0xc000_1fff), @as(u32, @bitCast(compute(.reciprocal, -2))));
    try testing.expectEqual(@as(i32, 0x2aaa_a000), compute(.reciprocal, 3));
    try testing.expectEqual(@as(i32, 0x7fff_c000), compute(.inverse_sqrt, 1));
    try testing.expectEqual(@as(i32, 0x5a82_4000), compute(.inverse_sqrt, 2));
    try testing.expectEqual(@as(i32, 0x3fff_e000), compute(.inverse_sqrt, 4));
}

test "double-precision sequencing through VRCPH and VRCPL" {
    var s: State = .{};
    try testing.expectEqual(@as(u16, 0), high(&s, 0x0001));
    try testing.expect(s.div_pending);
    try testing.expectEqual(@as(u16, 0x7fff), low(&s, .reciprocal, true, 0x0000));
    try testing.expect(!s.div_pending);
    try testing.expectEqual(@as(u16, 0x0000), high(&s, 0));
    _ = low(&s, .reciprocal, false, 2);
    try testing.expectEqual(@as(u16, 0x3fff), s.div_out);
    try testing.expectEqual(@as(u16, 0x3fff), high(&s, 0));
}
