const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

const Img = n64.graphics.image.ImgRgba16;
const Color = n64.graphics.color.Rgba16;

pub const tests = [_]runner.Test{
    .{ .name = "image: init and fill", .run = initAndFill },
    .{ .name = "image: fill region", .run = fillRegion },
};

fn initAndFill() !void {
    var memory: [128]u8 align(8) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var image = try Img.init(fixed.allocator(), 4, 3);

    try testing.expectEqual(@as(u16, 4), image.width);
    try testing.expectEqual(@as(u16, 3), image.height);
    try testing.expectEqual(@as(usize, 12), image.texel_data.len);

    image.fill(Color.red);
    for (image.texel_data) |pixel| {
        try testing.expectEqual(Color.red, pixel);
    }
}

fn fillRegion() !void {
    var memory: [128]u8 align(8) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var image = try Img.init(fixed.allocator(), 4, 3);

    image.fill(Color.black);
    image.fillRegion(Color.green, 1, 1, 2, 2);

    for (0..image.height) |y| {
        for (0..image.width) |x| {
            const expected = if (x >= 1 and x < 3 and y >= 1) Color.green else Color.black;
            try testing.expectEqual(expected, image.texel_data[y * image.width + x]);
        }
    }
}
