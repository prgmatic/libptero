const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

const Rgba16 = n64.graphics.color.Rgba16;

pub const tests = [_]runner.Test{
    .{ .name = "color: RGBA16 bytes", .run = rgba16FromBytes },
    .{ .name = "color: RGBA16 constants", .run = rgba16Constants },
    .{ .name = "color: alpha threshold", .run = rgba16AlphaThreshold },
};

fn rgba16FromBytes() !void {
    const color = Rgba16.fromBytes(255, 128, 0, 255);
    try testing.expectEqual(@as(u5, 31), color.r);
    try testing.expectEqual(@as(u5, 16), color.g);
    try testing.expectEqual(@as(u5, 0), color.b);
    try testing.expectEqual(@as(u1, 1), color.a);
}

fn rgba16Constants() !void {
    try testing.expectEqual(@as(u16, 0xf801), @as(u16, @bitCast(Rgba16.red)));
    try testing.expectEqual(@as(u16, 0x07c1), @as(u16, @bitCast(Rgba16.green)));
    try testing.expectEqual(@as(u16, 0x003f), @as(u16, @bitCast(Rgba16.blue)));
    try testing.expectEqual(@as(u16, 0x0001), @as(u16, @bitCast(Rgba16.black)));
    try testing.expectEqual(@as(u16, 0xffff), @as(u16, @bitCast(Rgba16.white)));
}

fn rgba16AlphaThreshold() !void {
    try testing.expectEqual(@as(u1, 0), Rgba16.fromBytes(0, 0, 0, 127).a);
    try testing.expectEqual(@as(u1, 1), Rgba16.fromBytes(0, 0, 0, 128).a);
}
