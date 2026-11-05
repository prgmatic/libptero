//! 128-bit RSP vector register values and element-selection helpers.
//!
//! Lane 0 is the element at the lowest DMEM address, so byte 0 is the most
//! significant byte of lane 0. This matches the RSP's big-endian register view.
const std = @import("std");

pub const Vec = [8]u16;
pub const zero: Vec = @splat(0);

/// Returns byte `index` (modulo 16) of a vector register.
pub fn byte(v: Vec, index: usize) u8 {
    const wrapped = index & 15;
    return @truncate(v[wrapped >> 1] >> byteShift(wrapped));
}

/// Replaces byte `index` (modulo 16) of a vector register.
pub fn setByte(v: *Vec, index: usize, value: u8) void {
    const wrapped = index & 15;
    const shift = byteShift(wrapped);
    const lane = &v[wrapped >> 1];
    lane.* = (lane.* & ~(@as(u16, 0xff) << shift)) | (@as(u16, value) << shift);
}

fn byteShift(index: usize) u4 {
    return @intCast(8 - (index & 1) * 8);
}

/// Lane selections for the 16 element modifiers accepted by computational
/// vector instructions: vector, quarter, half, and whole-element broadcasts.
const selections = [16][8]u3{
    .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    .{ 0, 0, 2, 2, 4, 4, 6, 6 },
    .{ 1, 1, 3, 3, 5, 5, 7, 7 },
    .{ 0, 0, 0, 0, 4, 4, 4, 4 },
    .{ 1, 1, 1, 1, 5, 5, 5, 5 },
    .{ 2, 2, 2, 2, 6, 6, 6, 6 },
    .{ 3, 3, 3, 3, 7, 7, 7, 7 },
    @splat(0),
    @splat(1),
    @splat(2),
    @splat(3),
    @splat(4),
    @splat(5),
    @splat(6),
    @splat(7),
};

/// Applies an element modifier to the `vt` operand of a vector instruction.
pub fn select(v: Vec, element: u4) Vec {
    var out: Vec = undefined;
    for (selections[element], 0..) |lane, n| out[n] = v[lane];
    return out;
}

/// Signed value of a lane.
pub fn signed(value: u16) i32 {
    return @as(i16, @bitCast(value));
}

/// Saturates a signed value to a 16-bit lane.
pub fn clamp16(value: i64) u16 {
    const clamped: i16 = @intCast(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16)));
    return @bitCast(clamped);
}

/// Tests one lane bit of a VCO/VCC/VCE flag byte.
pub fn flag(mask: u8, lane: usize) bool {
    return mask >> @intCast(lane) & 1 != 0;
}

/// Writes one lane bit of a VCO/VCC/VCE flag byte and returns the value.
pub fn setFlag(mask: *u8, lane: usize, value: bool) bool {
    const bit = @as(u8, 1) << @intCast(lane);
    mask.* = (mask.* & ~bit) | (@as(u8, @intFromBool(value)) << @intCast(lane));
    return value;
}

const testing = std.testing;

test "byte access uses the big-endian register view" {
    var v: Vec = .{ 0x0102, 0x0304, 0, 0, 0, 0, 0, 0xeeff };
    try testing.expectEqual(@as(u8, 0x01), byte(v, 0));
    try testing.expectEqual(@as(u8, 0x02), byte(v, 1));
    try testing.expectEqual(@as(u8, 0x04), byte(v, 3));
    try testing.expectEqual(@as(u8, 0xff), byte(v, 15));
    try testing.expectEqual(@as(u8, 0x01), byte(v, 16));
    setByte(&v, 1, 0xaa);
    setByte(&v, 14, 0x11);
    try testing.expectEqual(@as(u16, 0x01aa), v[0]);
    try testing.expectEqual(@as(u16, 0x11ff), v[7]);
}

test "element modifiers broadcast quarters, halves, and whole lanes" {
    const v: Vec = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    try testing.expectEqual(v, select(v, 0));
    try testing.expectEqual(v, select(v, 1));
    try testing.expectEqual(Vec{ 11, 11, 13, 13, 15, 15, 17, 17 }, select(v, 3));
    try testing.expectEqual(Vec{ 12, 12, 12, 12, 16, 16, 16, 16 }, select(v, 6));
    try testing.expectEqual(@as(Vec, @splat(15)), select(v, 13));
}

test "clamp and flag helpers" {
    try testing.expectEqual(@as(u16, 0x7fff), clamp16(40000));
    try testing.expectEqual(@as(u16, 0x8000), clamp16(-40000));
    try testing.expectEqual(@as(u16, 0xfffe), clamp16(-2));
    try testing.expectEqual(@as(i32, -1), signed(0xffff));
    var mask: u8 = 0;
    try testing.expect(setFlag(&mask, 3, true));
    try testing.expect(flag(mask, 3));
    try testing.expect(!setFlag(&mask, 3, false));
    try testing.expectEqual(@as(u8, 0), mask);
}
