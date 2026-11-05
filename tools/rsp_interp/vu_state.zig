//! Architectural state of the RSP vector unit (COP2).
const std = @import("std");
const vector = @import("vector.zig");

const Vec = vector.Vec;
const accumulator_mask: u64 = (1 << 48) - 1;

pub const State = struct {
    regs: [32]Vec = @splat(vector.zero),
    /// Eight 48-bit accumulator lanes stored in the low bits of each word.
    acc: [8]u64 = @splat(0),
    vco_lo: u8 = 0,
    vco_hi: u8 = 0,
    vcc_lo: u8 = 0,
    vcc_hi: u8 = 0,
    vce: u8 = 0,
    div_in: u16 = 0,
    div_out: u16 = 0,
    /// Set by VRCPH/VRSQH so the following low-half operation uses `div_in`.
    div_pending: bool = false,

    pub fn accSigned(self: *const State, lane: usize) i64 {
        const shifted: i64 = @bitCast(self.acc[lane] << 16);
        return shifted >> 16;
    }

    pub fn setAcc(self: *State, lane: usize, value: i64) void {
        self.acc[lane] = @as(u64, @bitCast(value)) & accumulator_mask;
    }

    pub fn accHigh(self: *const State, lane: usize) u16 {
        return @truncate(self.acc[lane] >> 32);
    }

    pub fn accMid(self: *const State, lane: usize) u16 {
        return @truncate(self.acc[lane] >> 16);
    }

    pub fn accLow(self: *const State, lane: usize) u16 {
        return @truncate(self.acc[lane]);
    }

    pub fn setAccLow(self: *State, lane: usize, value: u16) void {
        self.acc[lane] = (self.acc[lane] & ~@as(u64, 0xffff)) | value;
    }

    /// Writes all eight accumulator low lanes, as VMOV and the divide unit do.
    pub fn setAccLowVector(self: *State, value: Vec) void {
        for (value, 0..) |lane, n| self.setAccLow(n, lane);
    }

    /// Signed saturation of accumulator bits 31..16.
    pub fn saturateMid(self: *const State, lane: usize) u16 {
        return vector.clamp16(self.accSigned(lane) >> 16);
    }

    /// Low accumulator lane, clamped to 0x0000/0xffff when bits 47..16 are out of range.
    pub fn saturateLow(self: *const State, lane: usize) u16 {
        const upper = self.accSigned(lane) >> 16;
        if (upper < std.math.minInt(i16)) return 0;
        if (upper > std.math.maxInt(i16)) return 0xffff;
        return self.accLow(lane);
    }

    /// Unsigned saturation used by VMULU and VMACU.
    pub fn saturateUnsigned(self: *const State, lane: usize) u16 {
        const high = vector.signed(self.accHigh(lane));
        if (high < 0) return 0;
        if (high != 0 or vector.signed(self.accMid(lane)) < 0) return 0xffff;
        return self.accMid(lane);
    }

    /// Encodes VCO, VCC, or VCE for CFC2. Higher control registers alias VCE.
    pub fn readControl(self: *const State, index: u5) u32 {
        const pair = self.controlPair(index);
        const value: u16 = @as(u16, pair.hi) << 8 | pair.lo;
        return @bitCast(@as(i32, vector.signed(value)));
    }

    pub fn writeControl(self: *State, index: u5, value: u32) void {
        const lo: u8 = @truncate(value);
        const hi: u8 = @truncate(value >> 8);
        switch (index & 3) {
            0 => {
                self.vco_lo = lo;
                self.vco_hi = hi;
            },
            1 => {
                self.vcc_lo = lo;
                self.vcc_hi = hi;
            },
            else => self.vce = lo,
        }
    }

    const Pair = struct { lo: u8, hi: u8 };

    fn controlPair(self: *const State, index: u5) Pair {
        return switch (index & 3) {
            0 => .{ .lo = self.vco_lo, .hi = self.vco_hi },
            1 => .{ .lo = self.vcc_lo, .hi = self.vcc_hi },
            else => .{ .lo = self.vce, .hi = 0 },
        };
    }
};

const testing = std.testing;

test "accumulator lanes wrap to 48 bits and sign-extend" {
    var s: State = .{};
    s.setAcc(0, -1);
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff), s.acc[0]);
    try testing.expectEqual(@as(i64, -1), s.accSigned(0));
    s.setAcc(1, 0x1234_5678_9abc);
    try testing.expectEqual(@as(u16, 0x1234), s.accHigh(1));
    try testing.expectEqual(@as(u16, 0x5678), s.accMid(1));
    try testing.expectEqual(@as(u16, 0x9abc), s.accLow(1));
    s.setAccLow(1, 0x1111);
    try testing.expectEqual(@as(u64, 0x1234_5678_1111), s.acc[1]);
    s.setAccLowVector(@splat(7));
    try testing.expectEqual(@as(u16, 7), s.accLow(4));
}

test "accumulator saturation modes" {
    var s: State = .{};
    s.setAcc(0, 0x0000_7000_1234);
    try testing.expectEqual(@as(u16, 0x7000), s.saturateMid(0));
    try testing.expectEqual(@as(u16, 0x1234), s.saturateLow(0));
    try testing.expectEqual(@as(u16, 0x7000), s.saturateUnsigned(0));
    s.setAcc(0, 0x0001_0000_1234);
    try testing.expectEqual(@as(u16, 0x7fff), s.saturateMid(0));
    try testing.expectEqual(@as(u16, 0xffff), s.saturateLow(0));
    try testing.expectEqual(@as(u16, 0xffff), s.saturateUnsigned(0));
    s.setAcc(0, -0x1_0000_0000);
    try testing.expectEqual(@as(u16, 0x8000), s.saturateMid(0));
    try testing.expectEqual(@as(u16, 0x0000), s.saturateLow(0));
    try testing.expectEqual(@as(u16, 0x0000), s.saturateUnsigned(0));
    s.setAcc(0, 0x0000_8000_0000);
    try testing.expectEqual(@as(u16, 0xffff), s.saturateUnsigned(0));
}

test "control registers round-trip and sign-extend" {
    var s: State = .{};
    s.writeControl(0, 0x80ff);
    try testing.expectEqual(@as(u32, 0xffff_80ff), s.readControl(0));
    s.writeControl(1, 0x0102);
    try testing.expectEqual(@as(u32, 0x0102), s.readControl(1));
    s.writeControl(2, 0xffaa);
    try testing.expectEqual(@as(u32, 0xaa), s.readControl(2));
    try testing.expectEqual(@as(u32, 0xaa), s.readControl(3));
}
