const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");
const zsp_programs = @import("zsp_test_programs");

const rsp = n64.rsp;
const rsp_timeout_attempts: u32 = 1_000_000;

var dma_in_batch align(8) = [_]u32{
    0x01000100,
    0x12345678,
    0x00000000,
    0x00000000,
};

var invalid_command_batch align(8) = [_]u32{
    0xff000000,
    0x00000000,
    0x00000000,
    0x00000000,
};

var command_queue_buffer: [8]u32 align(8) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "ZSP: arithmetic", .run = arithmetic },
    .{ .name = "ZSP: signed arithmetic", .run = signedArithmetic },
    .{ .name = "ZSP: bitwise", .run = bitwise },
    .{ .name = "ZSP: branches", .run = branches },
    .{ .name = "ZSP: comparisons", .run = comparisons },
    .{ .name = "ZSP: loops", .run = loops },
    .{ .name = "ZSP: shifts", .run = shifts },
    .{ .name = "ZSP: register operations", .run = registerOperations },
    .{ .name = "ZSP: large immediates", .run = largeImmediates },
    .{ .name = "ZSP: memory offsets", .run = memoryOffsets },
    .{ .name = "ZSP: store u8", .run = storeU8 },
    .{ .name = "ZSP: store i8", .run = storeI8 },
    .{ .name = "ZSP: store u16", .run = storeU16 },
    .{ .name = "ZSP: store i16", .run = storeI16 },
    .{ .name = "ZSP: store u32", .run = storeU32 },
    .{ .name = "ZSP: store i32", .run = storeI32 },
    .{ .name = "ZSP: load u8", .run = loadU8 },
    .{ .name = "ZSP: load i8", .run = loadI8 },
    .{ .name = "ZSP: load u16", .run = loadU16 },
    .{ .name = "ZSP: load i16", .run = loadI16 },
    .{ .name = "ZSP: load u32", .run = loadU32 },
    .{ .name = "ZSP: load i32", .run = loadI32 },
    .{ .name = "ZSP: vector operations", .run = vectorOperations },
    .{ .name = "ZSP: data blocks", .run = dataBlocks },
    .{ .name = "ZSP: DMA in", .run = dmaIn },
    .{ .name = "ZSP: command dispatcher", .run = commandDispatcher },
    .{ .name = "ZSP: RSP-loaded overlay dispatch", .run = rspLoadedOverlayDispatch },
    .{ .name = "ZSP: command dispatcher invalid command", .run = commandDispatcherInvalid },
};

fn arithmetic() !void {
    try run(zsp_programs.arithmetic);
    try expectDmemWord(u32, 0, 15);
}

fn signedArithmetic() !void {
    try run(zsp_programs.signed_arithmetic);
    try expectDmemWord(i32, 0, -24);
    try expectDmemWord(i32, 4, -9);
    try expectDmemWord(i32, 8, -18);
}

fn bitwise() !void {
    try run(zsp_programs.bitwise);
    try expectDmemWord(u32, 0, 0x4f);
}

fn branches() !void {
    try run(zsp_programs.branches);
    try expectDmemWord(u32, 0, 2);
}

fn comparisons() !void {
    try run(zsp_programs.comparisons);
    try expectDmemWord(u32, 0, 4095);
}

fn loops() !void {
    try run(zsp_programs.loops);
    try expectDmemWord(u32, 0, 4);
}

fn shifts() !void {
    try run(zsp_programs.shifts);
    try expectDmemWord(u32, 0, 4);
}

fn registerOperations() !void {
    try run(zsp_programs.register_ops);
    try expectDmemWord(u32, 0, 0x08000000);
    try expectDmemWord(i32, 4, -4);
    try expectDmemWord(i32, 8, 0x3ffffffc);
    try expectDmemWord(u32, 12, 0xf0f0ff00);
}

fn largeImmediates() !void {
    try run(zsp_programs.immediates);
    try expectDmemWord(u32, 0, 0x89abcdef);
    try expectDmemWord(i32, 4, -2147483648);
    try expectDmemWord(u32, 8, 0x12340000);
    try expectDmemWord(i32, 12, -32768);
}

fn memoryOffsets() !void {
    try run(zsp_programs.memory_offsets);
    try expectDmemWord(u32, 0, 0x11aa3344);
    try expectDmemWord(u32, 4, 0x5566beef);
    try expectDmemWord(u32, 8, 0x99aabb80);
    try expectDmemWord(u32, 16, 0xaa);
    try expectDmemWord(i32, 20, -128);
    try expectDmemWord(u32, 24, 0xbeef);
    try expectDmemWord(u32, 28, 0xaa334455);
}

fn storeU32() !void {
    try run(zsp_programs.store_u32);
    try expectDmemWord(u32, 0, 0xABCDEF0);
}

fn storeI32() !void {
    try run(zsp_programs.store_i32);
    try expectDmemWord(i32, 0, 0xABCDEF);
}

fn storeU16() !void {
    try run(zsp_programs.store_u16);
    try expectDmemWord(u16, 0, 0xABCD);
}

fn storeI16() !void {
    try run(zsp_programs.store_i16);
    try expectDmemWord(i16, 0, -21555);
}

fn storeU8() !void {
    try run(zsp_programs.store_u8);
    try expectDmemWord(u8, 0, 0xAB);
}

fn storeI8() !void {
    try run(zsp_programs.store_i8);
    try expectDmemWord(i8, 0, -85);
}

fn loadU8() !void {
    seedLoadSource(0x80ff8001);
    try run(zsp_programs.load_u8);
    try expectDmemWord(u32, 4, 0x00000080);
}

fn loadI8() !void {
    seedLoadSource(0x80ff8001);
    try run(zsp_programs.load_i8);
    try expectDmemWord(i32, 4, -128);
}

fn loadU16() !void {
    seedLoadSource(0x80ff8001);
    try run(zsp_programs.load_u16);
    try expectDmemWord(u32, 4, 0x000080ff);
}

fn loadI16() !void {
    seedLoadSource(0x80ff8001);
    try run(zsp_programs.load_i16);
    try expectDmemWord(i32, 4, -32513);
}

fn loadU32() !void {
    seedLoadSource(0x89abcdef);
    try run(zsp_programs.load_u32);
    try expectDmemWord(u32, 4, 0x89abcdef);
}

fn loadI32() !void {
    seedLoadSource(0x80000000);
    try run(zsp_programs.load_i32);
    try expectDmemWord(i32, 4, -2147483648);
}

fn vectorOperations() !void {
    try run(zsp_programs.vector_ops);

    const add_expected = [_]u32{ 0x00040006, 0x00007fff, 0x80003456, 0xb9b94645 };
    const sub_expected = [_]u32{ 0xfffefffe, 0xfffe8001, 0x7ffef012, 0x9b9b9b9b };
    const and_expected = [_]u32{ 0x00010000, 0x00018000, 0x00010220, 0x0a0a5050 };
    const or_expected = [_]u32{ 0x00030006, 0xffffffff, 0x7fff3236, 0xafaff5f5 };
    const xor_expected = [_]u32{ 0x00020006, 0xfffe7fff, 0x7ffe3016, 0xa5a5a5a5 };
    const not_expected = [_]u32{ 0xfffefffd, 0x00007fff, 0x8000edcb, 0x55550f0f };
    const nor_expected = [_]u32{ 0xfffcfff9, 0x00000000, 0x8000cdc9, 0x50500a0a };

    try expectDmemWords(0x100, &add_expected);
    try expectDmemWords(0x110, &sub_expected);
    try expectDmemWords(0x120, &and_expected);
    try expectDmemWords(0x130, &or_expected);
    try expectDmemWords(0x140, &xor_expected);
    try expectDmemWords(0x150, &not_expected);
    try expectDmemWords(0x180, &nor_expected);
    const multiply_expected = [_]u32{ 0, 0, 0, 0 };
    try expectDmemWords(0x1a0, &multiply_expected);

    const wide_expected = [_]u32{
        0x00040004, 0x00040004, 0x00040004, 0x00040004,
        0x00000000, 0x00000000, 0x00000000, 0x00000000,
    };
    try expectDmemWords(0x160, &wide_expected);
}

fn dataBlocks() !void {
    try run(zsp_programs.data_blocks);

    try expectDmemWord(u32, 0x100, 0x12345678);
    try expectDmemWord(u32, 0x104, 0x11);
    try expectDmemWord(u32, 0x108, 0x44);
    try expectDmemWord(u32, 0x10c, 0x89abcdef);
    try expectDmemWord(u32, 0x110, 0x76543210);

    try expectDmemWord(u32, 0x114, 0xdeadbeef);
    try expectDmemWord(u32, 0x118, 0xbeef);
    try expectDmemWord(u32, 0x11c, 0xcafe);

    try expectDmemWord(u32, 0x120, 0x00);
    try expectDmemWord(u32, 0x124, 0x04);
    try expectDmemWord(u32, 0x128, 0x08);
    try expectDmemWord(u32, 0x12c, 0x0c);
    try expectDmemWord(u32, 0x130, 0x14);
}

fn dmaIn() !void {
    submitCommandBatch(&dma_in_batch);
    try run(zsp_programs.dma_in);
    for (dma_in_batch, 0..) |expected, index| {
        try expectDmemWord(u32, 0x20 + @as(u32, @intCast(index * 4)), expected);
    }
}

fn commandDispatcher() !void {
    loadCommandDispatcher();
    var queue = rsp.CommandQueue.init(&command_queue_buffer);
    queue.writeDmem(0x100, 0x12345678);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, rsp.command_status_dmem, 0);
    try expectDmemWord(u32, 0x100, 0x12345678);
}

fn rspLoadedOverlayDispatch() !void {
    loadCommandDispatcher();
    var queue = rsp.CommandQueue.init(&command_queue_buffer);
    queue.writeCommand(0x10, 0x104, 0xcafebabe);
    queue.writeCommand(0x10, 0x108, 0xdeadbeef);
    queue.stop();

    rsp.submitOverlay(1, rsp.programs.static_overlay, 0x800, 0x800);
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, rsp.command_status_dmem, 0);
    try expectDmemWord(u32, 0x104, 0x4f564c31);
    try expectDmemWord(u32, 0x108, 0x4f564c31);
    try expectDmemWord(u32, rsp.overlay_load_count_dmem, 1);
}

fn commandDispatcherInvalid() !void {
    loadCommandDispatcher();
    submitDispatcherBatch(&invalid_command_batch);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, rsp.command_status_dmem, 0xff);
}

fn loadCommandDispatcher() void {
    rsp.halt();
    rsp.waitHalted();
    rsp.load(rsp.programs.command_dispatcher);
}

fn runLoadedCommandDispatcher() !void {
    rsp.runAsync(rsp.programs.command_dispatcher.pc_start);
    try waitBrokeTimeout();
}

fn submitDispatcherBatch(batch: *[4]u32) void {
    n64.cache.writebackData(batch);

    rsp.halt();
    rsp.waitHalted();
    const physical_address: u32 = @truncate(@intFromPtr(batch) & 0x1fffffff);
    rsp.io.readDmem(u32, 0x58).* = physical_address;
}

fn submitCommandBatch(batch: *[4]u32) void {
    n64.cache.writebackData(batch);

    rsp.halt();
    rsp.waitHalted();
    const physical_address: u32 = @truncate(@intFromPtr(batch) & 0x1fffffff);
    rsp.io.readDmem(u32, 0).* = physical_address;
}

fn run(program: rsp.UCode) !void {
    rsp.runUCode(program);
    try waitBrokeTimeout();
}

fn seedLoadSource(value: u32) void {
    rsp.halt();
    rsp.waitHalted();
    rsp.io.readDmem(u32, 0).* = value;
}

fn waitBrokeTimeout() !void {
    var remaining = rsp_timeout_attempts;
    while (!rsp.is_broke()) : (remaining -= 1) {
        if (remaining != 0) continue;
        rsp.halt();
        rsp.waitHalted();
        return error.RspTimeout;
    }
}

fn expectDmemWord(comptime T: type, offset: u32, expected: T) !void {
    try testing.expectEqual(expected, readDmemInt(T, offset));
}

fn expectDmemWords(offset: u32, expected: []const u32) !void {
    for (expected, 0..) |word, index| {
        try expectDmemWord(u32, offset + @as(u32, @intCast(index * 4)), word);
    }
}

fn readDmemInt(comptime T: type, offset: u32) T {
    const info = @typeInfo(T).int;
    if (info.bits == 0 or info.bits > 32 or info.bits % 8 != 0) {
        @compileError("DMEM test reads support 8, 16, and 32-bit integer types");
    }

    const word = rsp.io.readDmem(u32, offset & ~@as(u32, 3)).*;
    if (info.bits == 32) {
        return switch (info.signedness) {
            .signed => @bitCast(word),
            .unsigned => word,
        };
    }

    const byte_len = info.bits / 8;
    const byte_offset = offset & 3;
    if (byte_offset + byte_len > 4) {
        @panic("DMEM test read crosses a word boundary");
    }

    const shift: u5 = @intCast((4 - byte_offset - byte_len) * 8);
    const Unsigned = std.meta.Int(.unsigned, info.bits);
    const raw: Unsigned = @truncate(word >> shift);
    return switch (info.signedness) {
        .signed => @bitCast(raw),
        .unsigned => raw,
    };
}
