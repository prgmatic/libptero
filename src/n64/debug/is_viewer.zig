const pi = @import("../interfaces/parallel.zig");

pub var buffer: *volatile [0x80]u32 = @ptrFromInt(0xB3FF0020);
var write_len: *volatile u32 = @ptrFromInt(0xB3FF0014);

pub fn detect() bool {
    pi.waitIo();
    buffer[0] = 0x12345678;
    pi.waitIo();
    return buffer[0] == 0x12345678;
}

pub fn print(str: []const u8) void {
    var offset: usize = 0;
    while (offset < str.len) {
        const chunk = str[offset..@min(str.len, offset + 512)];
        printChunk(chunk);
        offset += chunk.len;
    }
}

fn printChunk(str: []const u8) void {
    var i: usize = 0;
    while (i * 4 < str.len) : (i += 1) {
        pi.waitIo();
        buffer[i] = packWord(str[i * 4 ..]);
    }
    flushBuffer(@intCast(str.len));
}

fn packWord(bytes: []const u8) u32 {
    var value: u32 = 0;
    for (bytes[0..@min(bytes.len, 4)], 0..) |byte, i| {
        value |= @as(u32, byte) << @as(u5, @intCast(24 - i * 8));
    }
    return value;
}

test "ISViewer pads partial words without reading past text" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0x61000000), packWord("a"));
    try std.testing.expectEqual(@as(u32, 0x61626300), packWord("abc"));
    try std.testing.expectEqual(@as(u32, 0x61626364), packWord("abcdef"));
}

pub fn flushBuffer(len: u32) void {
    pi.waitIo();
    write_len.* = len;
}
