//! Target-agnostic expectations for standalone ZSP test programs.
//!
//! The hardware test ROM and the host RSP interpreter both execute every case
//! here, so a single table defines what each program must leave in DMEM.
const std = @import("std");

pub const Check = struct {
    offset: u16,
    /// Big-endian bytes expected at `offset`.
    expected: []const u8,
};

pub const Seed = struct { offset: u16, value: u32 };

/// The big-endian word at `smaller` must not exceed the word at `larger`,
/// such as a compiled kernel's cycles against its hand-scheduled original.
pub const Ordering = struct {
    smaller: u16,
    larger: u16,
    /// Cycles `smaller` may exceed `larger` by.
    slack: u32 = 0,
};

pub const Case = struct {
    name: []const u8,
    /// Fixture name under `src/tests/ucode/` without the `.zsp` extension.
    program: []const u8,
    /// DMEM word written before the program is loaded and started.
    seed: ?Seed = null,
    checks: []const Check,
    orderings: []const Ordering = &.{},
};

fn bigEndian(comptime T: type, comptime value: T) []const u8 {
    comptime {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        const final = bytes;
        return &final;
    }
}

fn at(comptime T: type, comptime offset: u16, comptime value: T) Check {
    return .{ .offset = offset, .expected = bigEndian(T, value) };
}

fn words(comptime offset: u16, comptime values: []const u32) Check {
    comptime {
        var bytes: [values.len * 4]u8 = undefined;
        for (values, 0..) |value, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .big);
        const final = bytes;
        return .{ .offset = offset, .expected = &final };
    }
}

pub const all = [_]Case{
    .{ .name = "arithmetic", .program = "arithmetic", .checks = &.{at(u32, 0, 15)} },
    .{ .name = "signed arithmetic", .program = "signed_arithmetic", .checks = &.{
        at(i32, 0, -24), at(i32, 4, -9), at(i32, 8, -18),
    } },
    .{ .name = "bitwise", .program = "bitwise", .checks = &.{at(u32, 0, 0x4f)} },
    .{ .name = "branches", .program = "branches", .checks = &.{at(u32, 0, 2)} },
    .{ .name = "comparisons", .program = "comparisons", .checks = &.{at(u32, 0, 4095)} },
    .{ .name = "loops", .program = "loops", .checks = &.{at(u32, 0, 4)} },
    .{ .name = "shifts", .program = "shifts", .checks = &.{at(u32, 0, 4)} },
    .{ .name = "register operations", .program = "register_ops", .checks = &.{
        at(u32, 0, 0x08000000), at(i32, 4, -4), at(i32, 8, 0x3ffffffc), at(u32, 12, 0xf0f0ff00),
    } },
    .{ .name = "large immediates", .program = "immediates", .checks = &.{
        at(u32, 0, 0x89abcdef), at(i32, 4, -2147483648), at(u32, 8, 0x12340000), at(i32, 12, -32768),
    } },
    .{ .name = "memory offsets", .program = "memory_offsets", .checks = &.{
        at(u32, 0, 0x11aa3344), at(u32, 4, 0x5566beef), at(u32, 8, 0x99aabb80), at(u32, 16, 0xaa),
        at(i32, 20, -128),      at(u32, 24, 0xbeef),    at(u32, 28, 0xaa334455),
    } },
    .{ .name = "scalar stores", .program = "scalar_stores", .checks = &.{
        at(u8, 0, 0xab),         at(i8, 1, -85),  at(u16, 2, 0xabcd), at(i16, 4, -21555),
        at(u32, 8, 0x0abcdef0), at(i32, 12, 0x00abcdef),
    } },
    .{ .name = "scalar loads", .program = "scalar_loads", .seed = .{ .offset = 0, .value = 0x80ff8001 }, .checks = &.{
        at(u32, 4, 0x00000080), at(i32, 8, -128),         at(u32, 12, 0x000080ff),
        at(i32, 16, -32513),    at(u32, 20, 0x80ff8001), at(i32, 24, -2130739199),
    } },
    .{ .name = "vector operations", .program = "vector_ops", .checks = &.{
        words(0x100, &.{ 0x00040006, 0x00007fff, 0x80003456, 0xb9b94645 }),
        words(0x110, &.{ 0xfffefffe, 0xfffe8001, 0x7ffef012, 0x9b9b9b9b }),
        words(0x120, &.{ 0x00010000, 0x00018000, 0x00010220, 0x0a0a5050 }),
        words(0x130, &.{ 0x00030006, 0xffffffff, 0x7fff3236, 0xafaff5f5 }),
        words(0x140, &.{ 0x00020006, 0xfffe7fff, 0x7ffe3016, 0xa5a5a5a5 }),
        words(0x150, &.{ 0xfffefffd, 0x00007fff, 0x8000edcb, 0x55550f0f }),
        words(0x180, &.{ 0xfffcfff9, 0x00000000, 0x8000cdc9, 0x50500a0a }),
        words(0x1a0, &.{ 0, 0, 0, 0 }),
        words(0x1b0, &.{ 0x0002c000, 0x7fff0000, 0, 0 }),
        words(0x210, &.{ 0xc0000000, 0, 0, 0 }),
        words(0x1c0, &.{ 0x00000080, 0x00000100, 0x7f807f80, 0x40000000 }),
        words(0x1d0, &.{ 0x00010002, 0, 0x7fff1234, 0 }),
        words(0x1e0, &.{ 0x40008000, 0xc0000000, 0xc0000000, 0x80000000 }),
        words(0x1f0, &.{ 0x00000000, 0xffffe000, 0x1fff048d, 0xeaaafc3c }),
        words(0x200, &.{ 0x00000000, 0x01ff0100, 0x00ff0024, 0x015501e1 }),
        words(0x160, &.{ 0x00040004, 0x00040004, 0x00040004, 0x00040004, 0, 0, 0, 0 }),
    } },
    .{ .name = "data blocks", .program = "data_blocks", .checks = &.{
        at(u32, 0x100, 0x12345678), at(u32, 0x104, 0x11),   at(u32, 0x108, 0x44),
        at(u32, 0x10c, 0x89abcdef), at(u32, 0x110, 0x76543210), at(u32, 0x114, 0xdeadbeef),
        at(u32, 0x118, 0xbeef),     at(u32, 0x11c, 0xcafe), at(u32, 0x120, 0x00),
        at(u32, 0x124, 0x10),       at(u32, 0x128, 0x04),   at(u32, 0x12c, 0x14),
        at(u32, 0x130, 0x08),
    } },
    // The plain kernel must match the hand-scheduled product without
    // costing more cycles.
    .{
        .name = "plain matrix kernels match hand scheduling",
        .program = "matrix_kernels",
        .checks = &.{ at(u32, 0x100, 1), at(u32, 0x10c, 1) },
        // On hardware the plain multiply is one cycle slower: the timing
        // model misses a stall when two stores wait on just-issued vector
        // results (`model_gap` in tools/rsp_interp/calibration.zig).
        .orderings = &.{ .{ .smaller = 0x108, .larger = 0x104, .slack = 1 }, .{ .smaller = 0x114, .larger = 0x110 } },
    },
};

test "checks encode big-endian expectations" {
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xe8 }, comptime at(i32, 0, -24).expected);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0, 0, 0, 2 }, comptime words(0, &.{ 1, 2 }).expected);
}
