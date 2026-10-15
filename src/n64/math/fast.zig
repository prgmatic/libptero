const std = @import("std");
const builtin = @import("builtin");

const pi_hi: f32 = 3.14159274;
const pi_lo: f32 = -8.74227766e-8;
const half_pi_hi: f32 = 1.57079637;

/// Fast modulo for the bounded magnitudes normally used by graphics code.
pub inline fn mod(x: f32, y: f32) f32 {
    return x - floor(x * (1.0 / y)) * y;
}

pub inline fn floor(value: f32) f32 {
    if (comptime builtin.cpu.arch == .mips) {
        var integer: f32 = undefined;
        asm volatile ("floor.w.s %[out], %[in]"
            : [out] "=f" (integer),
            : [in] "f" (value),
        );
        var result: f32 = undefined;
        asm volatile ("cvt.s.w %[out], %[in]"
            : [out] "=f" (result),
            : [in] "f" (integer),
        );
        return result;
    }
    return @floor(value);
}

/// Rounds to the nearest integer, halfway cases away from zero like `@round`.
/// `@round` lowers to a software `roundf` call on MIPS; this is an add and one
/// `trunc.w.s`. Values just below a half (within one ULP) may round up. The
/// value must fit in i32.
pub inline fn roundToInt(value: f32) i32 {
    return @intFromFloat(value + std.math.copysign(@as(f32, 0.5), value));
}

/// Sine approximation matching libdragon's `fm_sinf` accuracy and range
/// reduction. It stays within roughly five ULP on [-pi, pi].
pub fn sin(value: f32) f32 {
    const x = mod(value + pi_hi, 2 * pi_hi) - pi_hi;
    const squared = x * x;
    var polynomial: f32 = 1.3291330536e-10;
    polynomial = polynomial * squared - 2.3317808128e-8;
    polynomial = polynomial * squared + 2.5222900603e-6;
    polynomial = polynomial * squared - 1.7350520647e-4;
    polynomial = polynomial * squared + 6.6208802163e-3;
    polynomial = polynomial * squared - 1.0132116824e-1;
    return x * ((x - pi_hi) - pi_lo) * ((x + pi_hi) + pi_lo) * polynomial;
}

pub fn cos(value: f32) f32 {
    return sin(half_pi_hi - value);
}

test "fast trigonometry tracks standard functions over graphics angles" {
    const testing = std.testing;
    for ([_]f32{ -std.math.pi, -2.5, -1, 0, 0.5, 2, std.math.pi }) |angle| {
        try testing.expectApproxEqAbs(@sin(angle), sin(angle), 0.000002);
        try testing.expectApproxEqAbs(@cos(angle), cos(angle), 0.000002);
    }
}

test "fast rounding matches @round halfway cases" {
    try std.testing.expectEqual(@as(i32, 3), roundToInt(2.5));
    try std.testing.expectEqual(@as(i32, 0), roundToInt(0.25));
    try std.testing.expectEqual(@as(i32, -3), roundToInt(-2.5));
    try std.testing.expectEqual(@as(i32, -3), roundToInt(-2.6));
    try std.testing.expectEqual(@as(i32, 7), roundToInt(6.75));
}

test "fast modulo follows floor-based positive wrapping" {
    try std.testing.expectApproxEqAbs(@as(f32, 5.5), mod(-0.5, 6), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mod(6.5, 6), 0.000001);
}
