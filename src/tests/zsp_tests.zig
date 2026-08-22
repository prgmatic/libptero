const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");
const zsp_programs = @import("zsp_test_programs");

const rsp = n64.rsp;
const rdp = n64.graphics.rdp;
const rsp_timeout_attempts: u32 = 1_000_000;

var dma_in_batch align(8) = [_]u32{
    0x01000100,
    0x12345678,
    0x00000000,
    0x00000000,
};

var invalid_command_batch: [rsp.command_queue.batch_word_count]u32 align(8) = .{0xff000000} ++
    .{0x00000000} ** (rsp.command_queue.batch_word_count - 1);

var command_queue_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var boundary_queue_buffer: [rsp.command_queue.batch_word_count * 2]u32 align(8) = undefined;
var chained_queue_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var called_block_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var alternate_queue_buffer: [rsp.command_queue.batch_word_count]u32 align(8) = undefined;
var continuous_queue: rsp.Queue = undefined;
var queued_dma_queue: rsp.Queue = undefined;
var syncpoint_queue: rsp.Queue = undefined;
var high_priority_queue: rsp.Queue = undefined;
var rdp_queue: rsp.Queue = undefined;
var rdp_buffer: [2]u64 align(8) = .{ 0, 0 };
var rdp_rollover_buffer: [2]u64 align(8) = .{ 0, 0 };
var rsp_rdp_command_buffer: [4]u64 align(8) = undefined;
var rsp_rdp_dynamic_buffers: [2][rsp.rdp_dynamic_buffer_len]u8 align(16) = undefined;
var queue_dma_source: [4]u32 align(8) = .{ 0x12345678, 0x89abcdef, 0x0badcafe, 0xfeedface };
var queue_dma_destination: [4]u32 align(8) = undefined;
var overlay_1: rsp.Overlay = undefined;
var overlay_2: rsp.Overlay = undefined;
var rdp_overlay: rsp.Overlay = undefined;

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
    .{ .name = "ZSP: chained command buffers", .run = chainedCommandBuffers },
    .{ .name = "ZSP: called command block", .run = calledCommandBlock },
    .{ .name = "ZSP: indirect called command block", .run = indirectCalledCommandBlock },
    .{ .name = "ZSP: swapped command buffers", .run = swappedCommandBuffers },
    .{ .name = "ZSP: continuous double-buffered queue", .run = continuousDoubleBufferedQueue },
    .{ .name = "ZSP: command fetch boundary", .run = commandFetchBoundary },
    .{ .name = "ZSP: polling syncpoint", .run = pollingSyncpoint },
    .{ .name = "ZSP: high-priority queue", .run = highPriorityQueue },
    .{ .name = "ZSP: RDP buffer commands", .run = rdpBufferCommands },
    .{ .name = "ZSP: RDP debug handoff", .run = rdpDebugHandoff },
    .{ .name = "ZSP: queued DMA command", .run = queuedDmaCommand },
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
    try expectDmemWord(u32, 0x124, 0x10);
    try expectDmemWord(u32, 0x128, 0x04);
    try expectDmemWord(u32, 0x12c, 0x14);
    try expectDmemWord(u32, 0x130, 0x08);
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
    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x100, 0x12345678);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x100, 0x12345678);
}

fn chainedCommandBuffers() !void {
    loadCommandDispatcher();
    var second = rsp.CommandQueue.init(chained_queue_buffer[0..]);
    second.writeDmem(0x308, 0x89abcdef);
    second.stop();
    var first = rsp.CommandQueue.init(command_queue_buffer[0..]);
    first.writeDmem(0x304, 0x12345678);
    first.jump(&second);
    rsp.submitCommands(&first);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x304, 0x12345678);
    try expectDmemWord(u32, 0x308, 0x89abcdef);
}

fn calledCommandBlock() !void {
    loadCommandDispatcher();
    var block = rsp.CommandQueue.init(called_block_buffer[0..]);
    block.writeDmem(0x30c, 0x89abcdef);
    block.returnFromCall();

    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x308, 0x12345678);
    queue.call(&block);
    queue.writeDmem(0x310, 0xcafebabe);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x308, 0x12345678);
    try expectDmemWord(u32, 0x30c, 0x89abcdef);
    try expectDmemWord(u32, 0x310, 0xcafebabe);
}

fn indirectCalledCommandBlock() !void {
    loadCommandDispatcher();
    var block = rsp.CommandQueue.init(called_block_buffer[0..]);
    block.writeDmem(0x344, 0x89abcdef);
    block.returnFromCall();

    const target: u32 = @truncate(@intFromPtr(block.buffer.ptr) & 0x00ffffff);
    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x340, target);
    queue.callIndirect(&block, 0x340);
    queue.writeDmem(0x348, 0xcafebabe);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x344, 0x89abcdef);
    try expectDmemWord(u32, 0x348, 0xcafebabe);
}

fn swappedCommandBuffers() !void {
    loadCommandDispatcher();
    var alternate = rsp.CommandQueue.init(alternate_queue_buffer[0..]);
    alternate.writeDmem(0x318, 0x89abcdef);
    alternate.swapBuffersToCaller(0);
    alternate.stop();

    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.writeDmem(0x314, 0x12345678);
    queue.swapBuffers(&alternate, 0);
    queue.writeDmem(0x31c, 0xcafebabe);
    queue.stop();
    rsp.submitCommands(&queue);
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x314, 0x12345678);
    try expectDmemWord(u32, 0x318, 0x89abcdef);
    try expectDmemWord(u32, 0x31c, 0xcafebabe);
}

fn continuousDoubleBufferedQueue() !void {
    loadCommandDispatcher();
    continuous_queue.init(.low);
    for (0..520) |index| {
        continuous_queue.writeDmem(0x400, @intCast(index));
    }
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    try expectDmemWord(u32, 0x400, 519);

    continuous_queue.writeDmem(0x404, 0x89abcdef);
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);
    try expectDmemWord(u32, 0x404, 0x89abcdef);
}

fn commandFetchBoundary() !void {
    loadCommandDispatcher();
    @memset(&boundary_queue_buffer, 0);
    for (boundary_queue_buffer[0..63]) |*word| word.* = 0x06000000;
    boundary_queue_buffer[63] = 0x01000350;
    boundary_queue_buffer[64] = 0x12345678;
    boundary_queue_buffer[65] = 0x00000000;
    n64.cache.writebackData(&boundary_queue_buffer);

    rsp.halt();
    rsp.waitHalted();
    rsp.io.readDmem(u32, 0xb0).* = @truncate(@intFromPtr(&boundary_queue_buffer) & 0x1fffffff);
    rsp.io.status_register_write.* = rsp.io.status_set_signal7;
    try runLoadedCommandDispatcher();

    try expectDmemWord(u32, 0x350, 0x12345678);
}

fn pollingSyncpoint() !void {
    loadCommandDispatcher();
    syncpoint_queue.init(.low);
    syncpoint_queue.writeDmem(0x320, 0x12345678);
    syncpoint_queue.syncpoint();
    if (!syncpoint_queue.waitSyncpointTimeout(rsp_timeout_attempts)) {
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }

    try expectDmemWord(u32, 0x320, 0x12345678);
    try testing.expect(!rsp.io.status_register_read.signal2);
    try testing.expect(!syncpoint_queue.storage.syncpoint_pending);

    syncpoint_queue.writeDmem(0x324, 0x89abcdef);
    syncpoint_queue.syncpoint();
    if (!syncpoint_queue.waitSyncpointTimeout(rsp_timeout_attempts)) {
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }
    try expectDmemWord(u32, 0x324, 0x89abcdef);
}

fn highPriorityQueue() !void {
    loadCommandDispatcher();
    rsp.io.status_register_write.* = rsp.io.status_set_signal0 | rsp.io.status_set_signal1 |
        rsp.io.status_clear_signal3 | rsp.io.status_clear_signal4 | rsp.io.status_clear_signal5;

    continuous_queue.init(.low);
    continuous_queue.writeDmem(0x330, 1);
    continuous_queue.waitThenWriteStatus(rsp.io.status_signal0, 0);
    continuous_queue.waitThenWriteStatus(rsp.io.status_signal1, 0);
    continuous_queue.writeDmem(0x334, 3);
    rsp.flush(&continuous_queue);
    try waitDmemValueTimeout(0x330, 1);

    high_priority_queue.init(.high);
    high_priority_queue.writeDmem(0x334, 2);
    rsp.submitHighPriority(&high_priority_queue);
    rsp.io.status_register_write.* = rsp.io.status_clear_signal0;
    if (!rsp.waitHighPriorityTimeout(&high_priority_queue, rsp_timeout_attempts)) {
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }

    try expectDmemWord(u32, 0x334, 2);
    try testing.expect(!rsp.io.status_register_read.signal3);
    try testing.expect(!rsp.io.status_register_read.signal4);
    rsp.io.status_register_write.* = rsp.io.status_clear_signal1;
    try waitQueueTimeout(&continuous_queue);
    try expectDmemWord(u32, 0x334, 3);
}

fn rdpBufferCommands() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&rdp_overlay));
    rdp_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_buffer);
    const buffer_address: u32 = @truncate(@intFromPtr(&rdp_buffer) & 0x00ffffff);
    const sentinel_address = buffer_address + @sizeOf(@TypeOf(rdp_buffer));

    rdp_queue.init(.low);
    rdp_queue.setRdpBuffer(buffer_address, buffer_address, sentinel_address);
    rdp_queue.appendRdpBuffer(buffer_address);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 0, 0, &.{});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_buffer);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_buffer[0]);
    try testing.expectEqual(@as(u64, 0xffffffffffffffff), rdp_buffer[1]);
    try expectDmemWord(u32, 0xc0, buffer_address + 8);
    try expectDmemWord(u32, 0xc4, sentinel_address);
    try testing.expectEqual(buffer_address, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(buffer_address + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);

    rdp_rollover_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_rollover_buffer);
    const rollover_address: u32 = @truncate(@intFromPtr(&rdp_rollover_buffer) & 0x00ffffff);
    rdp_queue.writeDmem(0xc8, buffer_address);
    rdp_queue.writeDmem(0xcc, rollover_address);
    rdp_queue.setRdpBuffer(buffer_address + 8, buffer_address, buffer_address + 8);
    rdp_queue.writeOverlayCommand(&rdp_overlay, 0, 0, &.{});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);

    n64.cache.invalidateData(&rdp_rollover_buffer);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rdp_rollover_buffer[0]);
    try testing.expectEqual(@as(u64, 0xffffffffffffffff), rdp_rollover_buffer[1]);
    try expectDmemWord(u32, 0xc0, rollover_address + 8);
    try expectDmemWord(u32, 0xc4, rollover_address + 0x10000);
    try expectDmemWord(u32, 0xc8, rollover_address);
    try expectDmemWord(u32, 0xcc, buffer_address);
    try testing.expectEqual(rollover_address, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(rollover_address + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpDebugHandoff() !void {
    loadCommandDispatcher();
    rdp_buffer = .{ 0xffffffffffffffff, 0xffffffffffffffff };
    n64.cache.writebackData(&rdp_buffer);
    const buffer_address: u32 = @truncate(@intFromPtr(&rdp_buffer) & 0x00ffffff);

    var queue = rsp.CommandQueue.init(command_queue_buffer[0..]);
    queue.setRdpBuffer(buffer_address, buffer_address, buffer_address + @sizeOf(@TypeOf(rdp_buffer)));
    queue.stop();
    rsp.submitCommands(&queue);
    rsp.io.readDmem(i8, rsp.rdp_target_bitdepth_dmem).* = -1;
    rsp.io.status_register_write.* = rsp.io.status_clear_signal0 | rsp.io.status_clear_interrupt;
    rsp.runAsync(rsp.programs.command_dispatcher.pc_start);

    var remaining = rsp_timeout_attempts;
    while (!rsp.io.status_register_read.signal0) : (remaining -= 1) {
        if (remaining != 0) continue;
        rsp.halt();
        rsp.waitHalted();
        return error.RspSignalTimeout;
    }
    rsp.io.status_register_write.* = rsp.io.status_clear_signal0 | rsp.io.status_clear_interrupt;
    try waitBrokeTimeout();
    try testing.expectEqual(buffer_address, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
}

fn rspBackedRdpQueue() !void {
    loadCommandDispatcher();
    rdp_overlay.init(rsp.programs.rdp_overlay);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&rdp_overlay));
    @memset(rsp_rdp_dynamic_buffers[0][0..], 0xff);
    @memset(rsp_rdp_dynamic_buffers[1][0..], 0xff);
    n64.cache.writebackData(&rsp_rdp_dynamic_buffers);
    rdp_queue.init(.low);
    var render_queue = rdp.RspRenderQueue.init(rdp.RspQueue.init(
        &rdp_queue,
        rsp_rdp_command_buffer[0..],
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    render_queue.cmd_queue.pipeSync();
    render_queue.execute();
    try waitQueueTimeout(&rdp_queue);

    const start: u32 = @truncate(@intFromPtr(&rsp_rdp_command_buffer) & 0x00ffffff);
    const first_dynamic: u32 = @truncate(@intFromPtr(&rsp_rdp_dynamic_buffers[0]) & 0x00ffffff);
    const second_dynamic: u32 = @truncate(@intFromPtr(&rsp_rdp_dynamic_buffers[1]) & 0x00ffffff);
    try testing.expectEqual(@as(u64, 0xe700000000000000), rsp_rdp_command_buffer[0]);
    try testing.expectEqual(start, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(start + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    try expectDmemWord(u32, 0xc4, start + 8);
    try expectDmemWord(u32, 0xc8, first_dynamic);
    try expectDmemWord(u32, 0xcc, second_dynamic);

    rdp_queue.writeOverlayCommand(&rdp_overlay, 0, 0, &.{});
    rsp.flush(&rdp_queue);
    try waitQueueTimeout(&rdp_queue);
    n64.cache.invalidateData(&rsp_rdp_dynamic_buffers[1]);
    try testing.expectEqual(
        @as(u64, 0xe700000000000000),
        std.mem.readInt(u64, rsp_rdp_dynamic_buffers[1][0..8], .big),
    );
    try testing.expectEqual(second_dynamic, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(second_dynamic + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    try expectDmemWord(u32, 0xc0, second_dynamic + 8);
    try expectDmemWord(u32, 0xc4, second_dynamic + rsp.rdp_dynamic_buffer_len);
    rsp.unregisterOverlay(&rdp_overlay);
}

fn rdpCompletionFence() !void {
    loadCommandDispatcher();
    rdp_queue.init(.low);
    var render_queue = rdp.RspRenderQueue.init(rdp.RspQueue.init(
        &rdp_queue,
        rsp_rdp_command_buffer[0..],
        .{ rsp_rdp_dynamic_buffers[0][0..], rsp_rdp_dynamic_buffers[1][0..] },
    ));
    const fence = rdp.syncFull(&render_queue);
    if (!fence.waitTimeout(rsp_timeout_attempts)) return error.RdpFenceTimeout;

    const start: u32 = @truncate(@intFromPtr(&rsp_rdp_command_buffer) & 0x00ffffff);
    try testing.expectEqual(@as(u64, 0xe900000000000000), rsp_rdp_command_buffer[0]);
    try testing.expectEqual(start, n64.interfaces.rdp.dma_start_addr.* & 0x00ffffff);
    try testing.expectEqual(start + 8, n64.interfaces.rdp.dma_end_addr.* & 0x00ffffff);
    try testing.expect(fence.isComplete());
}

fn queuedDmaCommand() !void {
    loadCommandDispatcher();
    queued_dma_queue.init(.low);
    queued_dma_queue.dmaToDmem(0x600, std.mem.asBytes(&queue_dma_source), false);
    queued_dma_queue.dmaToRdram(std.mem.asBytes(&queue_dma_destination), 0x600, false);
    rsp.flush(&queued_dma_queue);
    try waitQueueTimeout(&queued_dma_queue);
    n64.cache.invalidateData(&queue_dma_destination);

    try expectDmemWords(0x600, &queue_dma_source);
    for (queue_dma_source, queue_dma_destination) |expected, actual| {
        try testing.expectEqual(expected, actual);
    }
}

fn waitQueueTimeout(queue: *const rsp.Queue) !void {
    if (rsp.waitTimeout(queue, rsp_timeout_attempts)) return;
    rsp.halt();
    rsp.waitHalted();
    return error.RspSignalTimeout;
}

fn waitDmemValueTimeout(offset: u32, expected: u32) !void {
    var remaining = rsp_timeout_attempts;
    while (readDmemInt(u32, offset) != expected) {
        if (remaining == 0) {
            rsp.halt();
            rsp.waitHalted();
            return error.RspSignalTimeout;
        }
        remaining -= 1;
    }
}

fn rspLoadedOverlayDispatch() !void {
    loadCommandDispatcher();
    overlay_1.init(rsp.programs.static_overlay);
    overlay_2.init(rsp.programs.static_overlay_2);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&overlay_1));
    try testing.expectEqual(@as(u8, 2), rsp.registerOverlay(&overlay_2));
    continuous_queue.init(.low);
    continuous_queue.writeOverlayCommand(&overlay_1, 0, 0x504, &.{});
    continuous_queue.writeOverlayCommand(&overlay_1, 1, 0x508, &.{0xdeadbeef});
    continuous_queue.writeOverlayCommand(&overlay_1, 0, 0x50c, &.{});
    continuous_queue.writeOverlayCommand(&overlay_2, 0, 0x510, &.{});
    continuous_queue.writeOverlayCommand(&overlay_2, 0, 0x514, &.{});
    continuous_queue.writeOverlayCommand(&overlay_1, 0, 0x518, &.{});

    try expectDmemWord(u32, 0x78, 0x00040800);
    rsp.flush(&continuous_queue);
    try waitQueueTimeout(&continuous_queue);

    try expectDmemWord(u32, 0x504, 1);
    try expectDmemWord(u32, 0x508, 0xdeadbeef);
    try expectDmemWord(u32, 0x50c, 2);
    try expectDmemWord(u32, 0x510, 1);
    try expectDmemWord(u32, 0x514, 2);
    try expectDmemWord(u32, 0x518, 3);
    try expectDmemWord(u16, 0x800, rsp.programs.static_overlay.state_offset);
    try expectDmemWord(u16, 0x802, rsp.programs.static_overlay.state_len - 1);
    try expectDmemWord(u16, 0x808, 1 << 5);
    try expectDmemWord(u16, 0x80a, 1 << 2);
    try expectDmemWord(u16, 0x810, @intCast(rsp.programs.static_overlay.text.len - 1));
    try expectDmemWord(u16, 0x812, rsp.io.dma_imem_addr + rsp.programs.static_overlay.text_offset);
    const first_command = rsp.programs.static_overlay.commandAt(0);
    const descriptor = @as(u16, first_command.size) << 8 | first_command.handler_offset >> 2;
    try expectDmemWord(u16, 0x81c, descriptor);
    const argument_command = rsp.programs.static_overlay.commandAt(1);
    const argument_descriptor = @as(u16, argument_command.size) << 8 |
        argument_command.handler_offset >> 2;
    try expectDmemWord(u16, 0x81e, argument_descriptor);

    const overlay_1_state = rsp.overlayState(&overlay_1);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, overlay_1_state[0..4], .big));
    std.mem.writeInt(u32, overlay_1_state[0..4], 9, .big);
    rsp.writebackOverlayState(&overlay_1);
    try expectDmemWord(u32, rsp.programs.static_overlay.state_offset, 9);
    rsp.unregisterOverlay(&overlay_1);
    rsp.unregisterOverlay(&overlay_2);
    try expectDmemWord(u32, 0x3c, 0);
    try expectDmemWord(u32, 0x40, 0);
    try expectDmemWord(u32, 0x78, 0);

    overlay_2.init(rsp.programs.static_overlay_2);
    try testing.expectEqual(@as(u8, 1), rsp.registerOverlay(&overlay_2));
}

fn commandDispatcherInvalid() !void {
    loadCommandDispatcher();
    submitDispatcherBatch(&invalid_command_batch);
    try runLoadedCommandDispatcher();
}

fn loadCommandDispatcher() void {
    rsp.halt();
    rsp.waitHalted();
    rsp.loadResident(rsp.programs.command_dispatcher);
}

fn runLoadedCommandDispatcher() !void {
    rsp.runAsync(rsp.programs.command_dispatcher.pc_start);
    try waitBrokeTimeout();
}

fn submitDispatcherBatch(batch: *[rsp.command_queue.batch_word_count]u32) void {
    n64.cache.writebackData(batch);

    rsp.halt();
    rsp.waitHalted();
    const physical_address: u32 = @truncate(@intFromPtr(batch) & 0x1fffffff);
    rsp.io.readDmem(u32, 0xb0).* = physical_address;
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
