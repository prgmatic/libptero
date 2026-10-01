//! Small lossless PNG encoder using uncompressed zlib blocks; no external codec.
const std = @import("std");

pub fn encode(allocator: std.mem.Allocator, width: u16, height: u16, rgba: []const u8) ![]u8 {
    if (width == 0 or height == 0 or rgba.len != @as(usize, width) * height * 4) return error.InvalidImage;
    const stride = @as(usize, width) * 4;
    const scanlines = try allocator.alloc(u8, (stride + 1) * height);
    defer allocator.free(scanlines);
    for (0..height) |y| {
        scanlines[y * (stride + 1)] = 0;
        @memcpy(scanlines[y * (stride + 1) + 1 ..][0..stride], rgba[y * stride ..][0..stride]);
    }
    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(allocator);
    try storedZlib(allocator, &zlib, scanlines);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8;
    header[9] = 6;
    try chunk(allocator, &result, "IHDR", &header);
    try chunk(allocator, &result, "IDAT", zlib.items);
    try chunk(allocator, &result, "IEND", "");
    return result.toOwnedSlice(allocator);
}

fn storedZlib(a: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try out.appendSlice(a, &.{ 0x78, 0x01 });
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count: u16 = @intCast(@min(65535, bytes.len - offset));
        try out.append(a, if (offset + count == bytes.len) 1 else 0);
        var lengths: [4]u8 = undefined;
        std.mem.writeInt(u16, lengths[0..2], count, .little);
        std.mem.writeInt(u16, lengths[2..4], ~count, .little);
        try out.appendSlice(a, &lengths);
        try out.appendSlice(a, bytes[offset..][0..count]);
        offset += count;
    }
    try appendInt(a, out, adler32(bytes));
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn appendInt(a: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try out.appendSlice(a, &bytes);
}

fn chunk(a: std.mem.Allocator, out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    try appendInt(a, out, @intCast(data.len));
    const begin = out.items.len;
    try out.appendSlice(a, tag);
    try out.appendSlice(a, data);
    try appendInt(a, out, std.hash.Crc32.hash(out.items[begin..]));
}

test "PNG roundtrip includes multiple stored deflate blocks" {
    const a = std.testing.allocator;
    const pixels = try a.alloc(u8, 128 * 128 * 4);
    defer a.free(pixels);
    for (pixels, 0..) |*byte, i| byte.* = @truncate(i * 13);
    const encoded = try encode(a, 128, 128, pixels);
    defer a.free(encoded);
    const decoded = try @import("png").readRgba(a, encoded);
    defer decoded.deinit(a);
    try std.testing.expectEqual(@as(u32, 128), decoded.width);
    try std.testing.expectEqualSlices(u8, pixels, decoded.pixels);
    try std.testing.expectError(error.InvalidImage, encode(a, 1, 2, ""));
}
