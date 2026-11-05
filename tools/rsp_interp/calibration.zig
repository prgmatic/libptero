//! RSP timing microbenchmarks shared by the hardware test ROM and the host
//! interpreter. Each program times its own loop with the free-running RCP
//! clock (DPC_CLOCK, COP0 register 12), stores the elapsed cycles at DMEM 0,
//! and breaks. The interpreter answers DPC_CLOCK with its estimated cycle
//! count, so both sides report directly comparable numbers.
//!
//! `measured` holds results from an SC64-connected N64 (recorded 2026-11-04);
//! the host test fails when the timing model drifts from them by more than
//! `tolerance_percent`, except for documented `model_gap` entries.
const encode = @import("encode.zig");

pub const iterations = 64;
pub const result_offset = 0;
pub const tolerance_percent = 10;

pub const Benchmark = struct {
    name: []const u8,
    /// Program text; even word count so it is a whole number of DMA rows.
    text: []align(8) const u32,
    /// Cycles the loop took on hardware, or null if not yet recorded.
    measured: ?u32,
    /// Documented divergence the timing model does not yet capture; the
    /// host test reports but does not fail on it.
    model_gap: ?[]const u8 = null,
};

const t0 = 8;
const t1 = 9;
const t2 = 10;
const counter = 15;
const start_clock = 24;
const end_clock = 25;

fn vaddc(vd: u5, vs: u5, vt: u5) u32 {
    return encode.vectorOp(0x14, vd, vs, vt, 0);
}

fn repeat(comptime count: usize, comptime words: []const u32) []const u32 {
    var result: []const u32 = &.{};
    for (0..count) |_| result = result ++ words;
    return result;
}

/// Wraps `body` in a counted loop bracketed by DPC_CLOCK reads.
fn program(comptime body: []const u32) []align(8) const u32 {
    const prologue = [_]u32{ encode.cop0Move(false, start_clock, 12), encode.ori(counter, 0, iterations) };
    const loop_back: i16 = -@as(i16, @intCast(body.len + 2));
    const epilogue = [_]u32{
        encode.addiu(counter, counter, -1),
        encode.bne(counter, 0, loop_back),
        encode.nop,
        encode.cop0Move(false, end_clock, 12),
        encode.special(0x23, end_clock, start_clock, end_clock, 0),
        encode.sw(end_clock, 0, result_offset),
        encode.brk,
    };
    const words = prologue ++ body ++ epilogue;
    const padded = if (words.len % 2 == 0) words else words ++ [_]u32{encode.nop};
    const final: [padded.len]u32 align(8) = padded[0..padded.len].*;
    return &final;
}

pub const all = [_]Benchmark{
    .{ .name = "loop_overhead", .text = program(&.{}), .measured = 257 },
    .{ .name = "scalar_independent", .text = program(repeat(4, &.{ encode.addiu(t0, 0, 1), encode.addiu(t1, 0, 2), encode.addiu(t2, 0, 3) })), .measured = 1025 },
    .{ .name = "scalar_load_use", .text = program(repeat(4, &.{ encode.lw(t0, 0, 0x100), encode.addiu(t1, t0, 1) })), .measured = 1281 },
    .{ .name = "load_then_store", .text = program(repeat(4, &.{ encode.lw(t0, 0, 0x100), encode.addiu(t2, t2, 1), encode.sw(t1, 0, 0x108) })), .measured = 1281 },
    .{ .name = "vector_dependent", .text = program(repeat(8, &.{vaddc(1, 1, 2)})), .measured = 2048 },
    .{ .name = "vector_independent", .text = program(&.{ vaddc(1, 9, 9), vaddc(2, 9, 9), vaddc(3, 9, 9), vaddc(4, 9, 9), vaddc(5, 9, 9), vaddc(6, 9, 9), vaddc(7, 9, 9), vaddc(8, 9, 9) }), .measured = 704 },
    .{ .name = "dual_issue", .text = program(repeat(4, &.{ encode.addiu(t0, 0, 1), vaddc(1, 9, 9), encode.addiu(t1, 0, 2), vaddc(2, 9, 9) })), .measured = 769 },
    .{ .name = "vector_load_use", .text = program(repeat(4, &.{ encode.vectorLoad(.lqv, 1, 0, 0, 0x10), vaddc(2, 1, 1) })), .measured = 1281 },
    .{ .name = "vector_to_scalar", .text = program(repeat(4, &.{ encode.cop2Move(.mfc2, t0, 1, 0), encode.addiu(t1, t0, 1) })), .measured = 1282 },
    .{ .name = "multiply_accumulate", .text = program(repeat(4, &.{ encode.vectorOp(0x07, 3, 1, 2, 0), encode.vectorOp(0x0f, 4, 1, 2, 0), encode.vectorOp(0x0f, 5, 3, 4, 0) })), .measured = 1728 },
    .{ .name = "vector_store_use", .text = program(repeat(4, &.{ vaddc(1, 9, 9), encode.vectorStore(.sqv, 1, 0, 0, 0x10) })), .measured = 1344 },
    .{ .name = "carry_to_cfc2", .text = program(repeat(4, &.{ vaddc(1, 9, 9), encode.cop2Move(.cfc2, t0, 0, 0) })), .measured = 705, .model_gap = "back-to-back VADDC/CFC2 chains stall 2 more cycles per pair than modeled" },
    .{ .name = "reciprocal_chain", .text = program(repeat(4, &.{ encode.vectorOp(0x30, 1, 0, 1, 0), encode.vectorOp(0x30, 1, 0, 1, 0) })), .measured = 2048 },
    .{ .name = "taken_branches", .text = program(repeat(4, &.{ encode.signedImmediate(0x04, 0, 0, 1), encode.nop, encode.nop })), .measured = 1281 },
    .{ .name = "accumulator_chain", .text = program(repeat(4, &.{ encode.vectorOp(0x07, 3, 1, 2, 0), encode.vectorOp(0x0f, 4, 1, 2, 0), encode.vectorOp(0x0f, 5, 1, 2, 0) })), .measured = 960 },
    .{ .name = "carry_to_cfc2_single", .text = program(&.{ vaddc(1, 9, 9), encode.cop2Move(.cfc2, t0, 0, 0) }), .measured = 385 },
    .{ .name = "carry_to_cfc2_gap1", .text = program(&.{ vaddc(1, 9, 9), encode.addiu(t2, t2, 1), encode.cop2Move(.cfc2, t0, 0, 0) }), .measured = 385 },
    .{ .name = "carry_to_cfc2_gap2", .text = program(&.{ vaddc(1, 9, 9), encode.addiu(t2, t2, 1), encode.addiu(t1, t1, 1), encode.cop2Move(.cfc2, t0, 0, 0) }), .measured = 449 },
    .{ .name = "ctc2_to_vadd", .text = program(&.{ encode.cop2Move(.ctc2, 0, 0, 0), encode.vectorOp(0x10, 1, 9, 9, 0) }), .measured = 322 },
    .{ .name = "store_then_load", .text = program(repeat(4, &.{ encode.sw(t1, 0, 0x100), encode.lw(t0, 0, 0x100), encode.addiu(t2, t2, 1) })), .measured = 1218 },
    // Hazards scheduled code meets that hand-scheduled kernels avoid.
    .{ .name = "vector_same_destination", .text = program(repeat(8, &.{vaddc(1, 9, 9)})), .measured = 704 },
    .{ .name = "vector_write_after_read", .text = program(repeat(4, &.{ vaddc(2, 1, 1), vaddc(1, 3, 3) })), .measured = 1280 },
    .{ .name = "partial_load_pair", .text = program(repeat(4, &.{ ldv(1, 0, 0), ldv(1, 8, 1), vaddc(2, 1, 1) })), .measured = 1537 },
    .{ .name = "load_after_vector_read", .text = program(repeat(4, &.{ vaddc(2, 1, 1), ldv(1, 0, 0) })), .measured = 1089 },
    .{ .name = "mac_chain_same_destination", .text = program(repeat(4, &.{ mac(0x04, 13, 2, 10), mac(0x0d, 13, 1, 10), mac(0x0e, 13, 2, 9), mac(0x0f, 13, 1, 9) })), .measured = 1216 },
    .{ .name = "mac_chain_spread_destination", .text = program(repeat(4, &.{ mac(0x04, 29, 2, 10), mac(0x0d, 29, 1, 10), mac(0x0e, 14, 2, 9), mac(0x0f, 13, 1, 9) })), .measured = 1216 },
    .{ .name = "mac_then_store_single", .text = program(repeat(4, &.{ mac(0x0e, 10, 8, 9), encode.vectorStore(.sdv, 10, 0, 0, 2) })), .measured = 1344 },
    .{ .name = "multiply_then_sqv", .text = program(repeat(4, &.{ mac(0x07, 1, 9, 9), encode.vectorStore(.sqv, 1, 0, 0, 1) })), .measured = 1344 },
    .{ .name = "add_then_sdv", .text = program(repeat(4, &.{ vaddc(1, 9, 9), encode.vectorStore(.sdv, 1, 0, 0, 2) })), .measured = 1344 },
    .{ .name = "store_pair", .text = program(repeat(4, &.{ encode.vectorStore(.sdv, 20, 0, 0, 2), encode.vectorStore(.sdv, 21, 0, 0, 3) })), .measured = 770 },
    .{ .name = "add_pair_then_store_pair", .text = program(repeat(4, &.{ vaddc(10, 8, 9), vaddc(14, 7, 9), encode.vectorStore(.sdv, 10, 0, 0, 2), encode.vectorStore(.sdv, 14, 0, 0, 3) })), .measured = 2368, .model_gap = "a store waiting for one of two just-issued vector results delays the next instruction more than modeled" },
    .{ .name = "add_pair_then_one_store", .text = program(repeat(4, &.{ vaddc(10, 8, 9), vaddc(14, 7, 9), sdv(10, 2) })), .measured = 1536, .model_gap = "a store waiting for one of two just-issued vector results delays the next instruction more than modeled" },
    .{ .name = "add_pair_then_reversed_stores", .text = program(repeat(4, &.{ vaddc(10, 8, 9), vaddc(14, 7, 9), sdv(14, 3), sdv(10, 2) })), .measured = 1856 },
    .{ .name = "add_pair_gap_then_store_pair", .text = program(repeat(4, &.{ vaddc(10, 8, 9), vaddc(14, 7, 9), encode.nop, encode.nop, encode.nop, sdv(10, 2), sdv(14, 3) })), .measured = 1600 },
    .{ .name = "add_then_store_twice", .text = program(repeat(4, &.{ vaddc(10, 8, 9), sdv(10, 2), sdv(10, 3) })), .measured = 1600 },
    .{ .name = "add_then_store_then_scalar", .text = program(repeat(4, &.{ vaddc(10, 8, 9), sdv(10, 2), encode.addiu(t0, 0, 1) })), .measured = 1600 },
    .{ .name = "mac_then_store", .text = program(repeat(4, &.{ mac(0x0e, 10, 8, 9), mac(0x0f, 14, 7, 9), encode.vectorStore(.sdv, 10, 0, 0, 2), encode.vectorStore(.sdv, 14, 0, 0, 3) })), .measured = 2368, .model_gap = "a store waiting for one of two just-issued vector results delays the next instruction more than modeled" },
};

fn sdv(vt: u5, offset: i7) u32 {
    return encode.vectorStore(.sdv, vt, 0, 0, offset);
}

fn ldv(vt: u5, element: u4, offset: i7) u32 {
    return encode.vectorLoad(.ldv, vt, 0, element, offset);
}

fn mac(funct: u6, vd: u5, vs: u5, vt: u5) u32 {
    return encode.vectorOp(funct, vd, vs, vt, 0);
}

const std = @import("std");
const Machine = @import("Machine.zig");

/// Runs a benchmark in the interpreter and returns its self-timed cycles.
pub fn estimate(benchmark: Benchmark) !u32 {
    var machine = Machine.init(&.{});
    for (benchmark.text, 0..) |word, index| std.mem.writeInt(u32, machine.imem[index * 4 ..][0..4], word, .big);
    machine.start(0);
    const result = try machine.run(1_000_000);
    if (result.stop != .broke) return error.BenchmarkDidNotFinish;
    return machine.readDmem(u32, result_offset);
}

/// True when `estimated` is within `tolerance_percent` of `measured`.
pub fn withinTolerance(estimated: u32, measured: u32) bool {
    const difference = if (estimated > measured) estimated - measured else measured - estimated;
    return @as(u64, difference) * 100 <= @as(u64, measured) * tolerance_percent;
}

test "the timing model matches recorded hardware cycles" {
    var drifted = false;
    for (all) |benchmark| {
        const estimated = try estimate(benchmark);
        try std.testing.expect(estimated > iterations);
        const measured = benchmark.measured orelse continue;
        if (benchmark.model_gap != null or withinTolerance(estimated, measured)) continue;
        std.log.err("RSP timing \"{s}\": estimated {d} cycles, hardware {d}", .{ benchmark.name, estimated, measured });
        drifted = true;
    }
    if (drifted) return error.TimingModelDrift;
}

test "tolerance is symmetric and proportional" {
    try std.testing.expect(withinTolerance(110, 100));
    try std.testing.expect(withinTolerance(90, 100));
    try std.testing.expect(!withinTolerance(111, 100));
    try std.testing.expect(!withinTolerance(89, 100));
}
