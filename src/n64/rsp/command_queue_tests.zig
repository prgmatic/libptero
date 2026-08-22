const command_queue = @import("command_queue.zig");
const CommandQueue = command_queue.CommandQueue;
const QueueStorage = command_queue.QueueStorage;
const Overlay = @import("overlay.zig").Overlay;
const UCode = @import("ucode.zig").UCode;
const testing = @import("std").testing;

test "writeDmem encodes a fixed command batch" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.writeDmem(0x100, 0x12345678);
    queue.stop();

    try testing.expect(queue.sealed);
    const expected = [_]u32{
        0x01000100,
        0x12345678,
        0x00000000,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 3);
    try testing.expectEqualSlices(u32, &expected, queue.buffer);
}

test "clear reopens and empties a command queue" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);
    queue.writeDmem(0x100, 0x12345678);
    queue.stop();

    queue.clear();

    try testing.expect(!queue.sealed);
    const expected = [_]u32{0} ** command_queue.batch_word_count;
    try testing.expectEqualSlices(u32, &expected, queue.buffer);
}

test "writeRawCommand encodes a command" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.writeRawCommand(0x10, 0x104, &.{0xcafebabe});
    queue.stop();

    const expected = [_]u32{
        0x10000104,
        0xcafebabe,
        0x00000000,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 3);
    try testing.expectEqualSlices(u32, &expected, queue.buffer);
}

test "writeRawCommand encodes a four-byte command without arguments" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.writeRawCommand(0x10, 0x104, &.{});
    queue.writeRawCommand(0x20, 0x108, &.{});
    queue.stop();

    const expected = [_]u32{
        0x10000104,
        0x20000108,
        0x00000000,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 3);
    try testing.expectEqualSlices(u32, &expected, queue.buffer);
}

test "a fixed queue holds two overlay commands and stop" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.writeRawCommand(0x10, 0x104, &.{0xcafebabe});
    queue.writeRawCommand(0x10, 0x108, &.{0xdeadbeef});
    queue.stop();

    const expected = [_]u32{
        0x10000104,
        0xcafebabe,
        0x10000108,
        0xdeadbeef,
        0x00000000,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 5);
    try testing.expectEqualSlices(u32, &expected, queue.buffer);
}

test "jump links two complete command buffers" {
    var second_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var second = CommandQueue.init(second_buffer[0..]);
    second.writeDmem(0x104, 0x89abcdef);
    second.stop();
    var first_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var first = CommandQueue.init(first_buffer[0..]);
    first.writeDmem(0x100, 0x12345678);

    first.jump(&second);

    const target: u32 = @truncate(@intFromPtr(&second_buffer) & 0x00ffffff);
    try testing.expectEqual(@as(u32, 0x02000000) | target, first_buffer[2]);
    try testing.expect(first.sealed);
    try testing.expectEqual(&second, first.next.?);
}

test "double-buffered queue initializes two writable buffers" {
    var queue: QueueStorage = undefined;
    queue.init();

    try testing.expectEqual(@as(u1, 0), queue.write_index);
    try testing.expect(!queue.submitted);
    try testing.expect(!queue.syncpoint_pending);
    try testing.expect(!queue.queues[0].sealed);
    try testing.expect(!queue.queues[1].sealed);
    try testing.expectEqual(@as(usize, 0x200), queue.queues[0].buffer.len);
    try testing.expectEqual(@as(usize, 0x100), command_queue.fetch_window_byte_len);
    try testing.expectEqual(&queue.buffers[0], queue.queues[0].buffer);
    try testing.expectEqual(&queue.buffers[1], queue.queues[1].buffer);
}

test "writeOverlayCommand derives the command ID and validates metadata" {
    const commands = [_]u8{
        0x00, 0x04, 0x02, 0x00,
        0x03, 0x08, 0x02, 0x40,
        0x10, 0x04, 0x02, 0x80,
    };
    var registered: Overlay = undefined;
    registered.init(UCode{ .text = &.{}, .commands = &commands });
    registered.id = 2;
    registered.slot_count = 2;
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.writeOverlayCommand(&registered, 3, 0x1234, &.{0xcafebabe});
    queue.stop();

    try testing.expectEqual(@as(u32, 0x23001234), buffer[0]);
    try testing.expectEqual(@as(u32, 0xcafebabe), buffer[1]);

    queue.clear();
    queue.writeOverlayCommand(&registered, 16, 0x5678, &.{});
    queue.stop();
    try testing.expectEqual(@as(u32, 0x30005678), buffer[0]);
}

test "writeDmaCommand matches the libdragon command layout" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.writeDmaCommand(0x00123458, 0x600, 15, 0x0c);

    try testing.expectEqual(@as(u32, 0x05123458), buffer[0]);
    try testing.expectEqual(@as(u32, 0x600), buffer[1]);
    try testing.expectEqual(@as(u32, 15), buffer[2]);
    try testing.expectEqual(@as(u32, 0x0c), buffer[3]);
}

test "waitThenWriteStatus matches the libdragon command layout" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.waitThenWriteStatus(0x00001000, 0x00100000);

    try testing.expectEqual(@as(u32, 0x08100000), buffer[0]);
    try testing.expectEqual(@as(u32, 0x00001000), buffer[1]);
}

test "RDP buffer commands match the libdragon command layout" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(buffer[0..]);

    queue.setRdpBuffer(0x00123450, 0x00123000, 0x00124000);
    queue.appendRdpBuffer(0x00123458);

    try testing.expectEqual(@as(u32, 0x09123450), buffer[0]);
    try testing.expectEqual(@as(u32, 0x00123000), buffer[1]);
    try testing.expectEqual(@as(u32, 0x00124000), buffer[2]);
    try testing.expectEqual(@as(u32, 0x0a123458), buffer[3]);
}

test "call and return encode a minimal command block" {
    var block_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var block = CommandQueue.init(block_buffer[0..]);
    block.writeDmem(0x104, 0x89abcdef);
    block.returnFromCall();

    var queue_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(queue_buffer[0..]);
    queue.call(&block);

    const target: u32 = @truncate(@intFromPtr(&block_buffer) & 0x00ffffff);
    try testing.expectEqual(@as(u32, 0x03000000) | target, queue_buffer[0]);
    try testing.expectEqual(@as(u32, 0), queue_buffer[1]);
    try testing.expectEqual(@as(u32, 0x04000000), block_buffer[2]);
    try testing.expectEqual(&block, queue.call_target.?);
    try testing.expect(block.sealed);
}

test "indirect call matches the libdragon placeholder layout" {
    var block_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var block = CommandQueue.init(block_buffer[0..]);
    block.returnFromCall();

    var queue_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(queue_buffer[0..]);
    queue.callIndirect(&block, 0x340);

    try testing.expectEqual(@as(u32, 0x03000340), queue_buffer[0]);
    try testing.expectEqual(@as(u32, 0x80000000), queue_buffer[1]);
    try testing.expectEqual(&block, queue.call_target.?);
}

test "swap buffers encodes libdragon pointer stack slots" {
    var alternate_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var alternate = CommandQueue.init(alternate_buffer[0..]);
    alternate.swapBuffersToCaller(0x00002000);
    alternate.stop();

    var queue_buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(queue_buffer[0..]);
    queue.swapBuffers(&alternate, 0x00400000);

    try testing.expectEqual(@as(u32, 0x07000024), queue_buffer[0]);
    try testing.expectEqual(@as(u32, 0x00000020), queue_buffer[1]);
    try testing.expectEqual(@as(u32, 0x00400000), queue_buffer[2]);
    try testing.expectEqual(@as(u32, 0x07000020), alternate_buffer[0]);
    try testing.expectEqual(@as(u32, 0x00000024), alternate_buffer[1]);
    try testing.expectEqual(@as(u32, 0x00002000), alternate_buffer[2]);
    try testing.expectEqual(&alternate, queue.swap_target.?);
}
