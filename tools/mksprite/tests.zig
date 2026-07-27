const std = @import("std");
const mksprite = @import("root.zig");

test "RGBA16 sprite is compatible with the libdragon header" {
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0 };
    const result = try mksprite.convertRgba(std.testing.allocator, 2, 1, &pixels, .{ .format = .rgba16 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 0, 1, 0, 0x82, 0, 0, 0xf8, 0x01, 0x07, 0xc0, 0, 0, 0, 0 }, result.bytes[0..16]);
    try std.testing.expectEqual(@as(usize, 144), result.bytes.len);
}

test "automatic format preserves grayscale and alpha" {
    const gray = [_]u8{ 42, 42, 42, 255 };
    const alpha = [_]u8{ 42, 42, 42, 100 };
    const a = try mksprite.convertRgba(std.testing.allocator, 1, 1, &gray, .{});
    defer a.deinit(std.testing.allocator);
    const b = try mksprite.convertRgba(std.testing.allocator, 1, 1, &alpha, .{});
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(mksprite.Format.i8, a.format);
    try std.testing.expectEqual(mksprite.Format.ia16, b.format);
}

test "box mipmaps reach one pixel" {
    const pixels = [_]u8{255} ** (4 * 4 * 4);
    const result = try mksprite.convertRgba(std.testing.allocator, 4, 4, &pixels, .{ .mipmap = .box });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), result.levels);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, result.bytes[32..34], .big));
}

test "CI4 rejects images requiring quantization" {
    var pixels: [17 * 4]u8 = undefined;
    for (0..17) |i| pixels[i * 4 ..][0..4].* = .{ @intCast(i), 0, 0, 255 };
    try std.testing.expectError(error.TooManyColors, mksprite.convertRgba(std.testing.allocator, 17, 1, &pixels, .{ .format = .ci4 }));
}

test "format names match libdragon spelling" {
    inline for (std.meta.tags(mksprite.Format)) |format|
        try std.testing.expect(std.ascii.eqlIgnoreCase(format.name(), @tagName(format)));
}

test "all lossless pixel encodings produce sprites" {
    const pixels = [_]u8{ 40, 40, 40, 255, 200, 100, 50, 96 };
    inline for (std.meta.tags(mksprite.Format)) |format| {
        const result = try mksprite.convertRgba(std.testing.allocator, 2, 1, &pixels, .{
            .format = format,
            .dither = .ordered,
            .gamma_correct = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.bytes.len >= 136);
    }
}
