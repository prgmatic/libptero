const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

const rdp = n64.graphics.rdp;
const Img = n64.graphics.image.ImgRgba16;
const Color = n64.graphics.color.Rgba16;

pub const tests = [_]runner.Test{
    .{ .name = "RDP: sync commands", .run = syncCommands },
    .{ .name = "RDP: scissor encoding", .run = scissorEncoding },
    .{ .name = "RDP: fill color encoding", .run = fillColorEncoding },
    .{ .name = "RDP: clear screen order", .run = clearScreenOrder },
    .{ .name = "RDP: queue clear", .run = queueClear },
};

fn syncCommands() !void {
    var buffer: [4]u64 = undefined;
    var queue = rdp.FixedCommandQueue.init(.{ .buffer = &buffer });

    queue.loadSync();
    queue.pipeSync();
    queue.tileSync();
    queue.fullSync();

    try testing.expectEqual(@as(usize, 4), queue.queue.index);
    try testing.expectEqual(@as(u64, 0xe600000000000000), buffer[0]);
    try testing.expectEqual(@as(u64, 0xe700000000000000), buffer[1]);
    try testing.expectEqual(@as(u64, 0xe800000000000000), buffer[2]);
    try testing.expectEqual(@as(u64, 0xe900000000000000), buffer[3]);
}

fn scissorEncoding() !void {
    var buffer: [1]u64 = undefined;
    var queue = rdp.FixedCommandQueue.init(.{ .buffer = &buffer });

    queue.setScissor(4, 8, 12, 16);

    try testing.expectEqual(@as(u64, 0xed0040080000c010), buffer[0]);
}

fn fillColorEncoding() !void {
    var buffer: [1]u64 = undefined;
    var queue = rdp.FixedCommandQueue.init(.{ .buffer = &buffer });

    queue.setFillColor(Color.red);

    try testing.expectEqual(@as(u64, 0xf7000000f801f801), buffer[0]);
}

fn clearScreenOrder() !void {
    var pixels: [4]Color align(8) = undefined;
    const image: Img = .{
        .width = 2,
        .height = 2,
        .texel_data = &pixels,
    };
    var buffer: [6]u64 = undefined;
    var queue = rdp.FixedRenderQueue.init(.{ .buffer = &buffer });

    queue.setFrameBuffer(image);
    queue.clearScreen(Color.black);

    const expected_opcodes = [_]u8{ 0xff, 0xe7, 0xef, 0xf7, 0xed, 0xf6 };
    try testing.expectEqual(expected_opcodes.len, queue.cmd_queue.queue.index);
    for (expected_opcodes, buffer) |expected, command| {
        try testing.expectEqual(expected, @as(u8, @truncate(command >> 56)));
    }
}

fn queueClear() !void {
    var buffer: [2]u64 = undefined;
    var queue = rdp.FixedCommandQueue.init(.{ .buffer = &buffer });

    queue.pipeSync();
    queue.fullSync();
    try testing.expectEqual(@as(usize, 2), queue.queue.index);

    queue.clear();
    try testing.expectEqual(@as(usize, 0), queue.queue.index);
}
