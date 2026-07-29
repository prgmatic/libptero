const CommandQueue = @import("command_queue.zig").CommandQueue;
const testing = @import("std").testing;

test "writeDmem encodes a fixed command batch" {
    var buffer: [4]u32 align(8) = undefined;
    var queue = CommandQueue.init(&buffer);

    queue.writeDmem(0x100, 0x12345678);
    queue.stop();

    try testing.expect(queue.isStopped());
    try testing.expectEqualSlices(u32, &.{
        0x01000100,
        0x12345678,
        0x00000000,
        0x00000000,
    }, queue.words());
}

test "clear reopens and empties a command queue" {
    var buffer: [4]u32 align(8) = undefined;
    var queue = CommandQueue.init(&buffer);
    queue.writeDmem(0x100, 0x12345678);
    queue.stop();

    queue.clear();

    try testing.expect(!queue.isStopped());
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, queue.words());
}
