const command_queue = @import("command_queue.zig");
const CommandQueue = command_queue.CommandQueue;
const Overlay = @import("overlay.zig").Overlay;
const UCode = @import("ucode.zig").UCode;
const testing = @import("std").testing;

test "writeDmem encodes a fixed command batch" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(&buffer);

    queue.writeDmem(0x100, 0x12345678);
    queue.stop();

    try testing.expect(queue.isStopped());
    const expected = [_]u32{
        0x01000100,
        0x12345678,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 2);
    try testing.expectEqualSlices(u32, &expected, queue.words());
}

test "clear reopens and empties a command queue" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(&buffer);
    queue.writeDmem(0x100, 0x12345678);
    queue.stop();

    queue.clear();

    try testing.expect(!queue.isStopped());
    const expected = [_]u32{0} ** command_queue.batch_word_count;
    try testing.expectEqualSlices(u32, &expected, queue.words());
}

test "writeCommand encodes a static overlay command" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(&buffer);

    queue.writeCommand(0x10, 0x104, &.{0xcafebabe});
    queue.stop();

    const expected = [_]u32{
        0x10000104,
        0xcafebabe,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 2);
    try testing.expectEqualSlices(u32, &expected, queue.words());
}

test "writeCommand encodes a four-byte command without arguments" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(&buffer);

    queue.writeCommand(0x10, 0x104, &.{});
    queue.writeCommand(0x20, 0x108, &.{});
    queue.stop();

    const expected = [_]u32{
        0x10000104,
        0x20000108,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 2);
    try testing.expectEqualSlices(u32, &expected, queue.words());
}

test "a fixed queue holds two overlay commands and stop" {
    var buffer: [command_queue.batch_word_count]u32 align(8) = undefined;
    var queue = CommandQueue.init(&buffer);

    queue.writeCommand(0x10, 0x104, &.{0xcafebabe});
    queue.writeCommand(0x10, 0x108, &.{0xdeadbeef});
    queue.stop();

    const expected = [_]u32{
        0x10000104,
        0xcafebabe,
        0x10000108,
        0xdeadbeef,
    } ++ [_]u32{0} ** (command_queue.batch_word_count - 4);
    try testing.expectEqualSlices(u32, &expected, queue.words());
}

test "writeOverlay derives the command ID and validates metadata" {
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
    var queue = CommandQueue.init(&buffer);

    queue.writeOverlay(&registered, 3, 0x1234, &.{0xcafebabe});
    queue.stop();

    try testing.expectEqual(@as(u32, 0x23001234), buffer[0]);
    try testing.expectEqual(@as(u32, 0xcafebabe), buffer[1]);

    queue.clear();
    queue.writeOverlay(&registered, 16, 0x5678, &.{});
    queue.stop();
    try testing.expectEqual(@as(u32, 0x30005678), buffer[0]);
}
