const std = @import("std");
pub const Wave = struct { data: []const u8, frequency: u32, channels: u16, bits: u16, frames: u32 };

pub fn parse(bytes: []const u8) !Wave {
    const end = try riffEnd(bytes);
    const chunks = try findChunks(bytes[0..end]);
    return validate(chunks.format, chunks.data);
}
fn riffEnd(bytes: []const u8) !usize {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWave;
    const end = @as(u64, read(u32, bytes, 4)) + 8;
    if (end > bytes.len or end < 12) return error.TruncatedWave;
    return @intCast(end);
}
const Chunk = struct { name: []const u8, data: []const u8 };
const Chunks = struct {
    bytes: []const u8,
    offset: usize = 12,
    fn next(self: *Chunks) !?Chunk {
        if (self.offset == self.bytes.len) return null;
        if (self.bytes.len - self.offset < 8) return error.TruncatedChunk;
        const size: usize = read(u32, self.bytes, self.offset + 4);
        const start = self.offset + 8;
        if (size > self.bytes.len - start) return error.TruncatedChunk;
        const result: Chunk = .{ .name = self.bytes[self.offset..][0..4], .data = self.bytes[start..][0..size] };
        self.offset = start + size + (size & 1);
        if (self.offset > self.bytes.len) return error.TruncatedChunk;
        return result;
    }
};
fn findChunks(bytes: []const u8) !struct { format: []const u8, data: []const u8 } {
    var format: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var chunks: Chunks = .{ .bytes = bytes };
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, chunk.name, "fmt ")) format = chunk.data;
        if (std.mem.eql(u8, chunk.name, "data")) data = chunk.data;
    }
    return .{ .format = format orelse return error.MissingFormat, .data = data orelse return error.MissingData };
}
fn validate(format: []const u8, data: []const u8) !Wave {
    if (format.len < 16) return error.InvalidFormat;
    if (read(u16, format, 0) != 1) return error.UnsupportedCodec;
    const channels = read(u16, format, 2);
    const bits = read(u16, format, 14);
    try validateEncoding(channels, bits);
    const frequency = read(u32, format, 4);
    try validateRate(format, frequency, channels * (bits / 8));
    const frames = try frameCount(data.len, channels * (bits / 8));
    return .{ .data = data, .frequency = frequency, .channels = channels, .bits = bits, .frames = frames };
}
fn validateEncoding(channels: u16, bits: u16) !void {
    if (channels != 1 and channels != 2) return error.UnsupportedChannels;
    if (bits != 8 and bits != 16) return error.UnsupportedBits;
}
fn validateRate(format: []const u8, frequency: u32, stride: u16) !void {
    if (frequency == 0 or frequency > 128000) return error.InvalidFrequency;
    if (read(u16, format, 12) != stride or read(u32, format, 8) != frequency * stride) return error.InvalidFormat;
}
fn frameCount(length: usize, stride: u16) !u32 {
    if (length == 0 or length % stride != 0) return error.InvalidDataLength;
    return @intCast(length / stride);
}
fn read(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

/// Small real RIFF fixture including an odd-sized unknown chunk.
pub fn fixture(bits: u16, channels: u16, data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, 54 + data.len + (data.len & 1));
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], @intCast(bytes.len - 8), .little);
    @memcpy(bytes[8..16], "WAVEJUNK");
    std.mem.writeInt(u32, bytes[16..20], 1, .little);
    @memcpy(bytes[22..26], "fmt ");
    std.mem.writeInt(u32, bytes[26..30], 16, .little);
    std.mem.writeInt(u16, bytes[30..32], 1, .little);
    std.mem.writeInt(u16, bytes[32..34], channels, .little);
    std.mem.writeInt(u32, bytes[34..38], 22050, .little);
    std.mem.writeInt(u32, bytes[38..42], @as(u32, 22050) * channels * (bits / 8), .little);
    std.mem.writeInt(u16, bytes[42..44], channels * (bits / 8), .little);
    std.mem.writeInt(u16, bytes[44..46], bits, .little);
    @memcpy(bytes[46..50], "data");
    std.mem.writeInt(u32, bytes[50..54], @intCast(data.len), .little);
    @memcpy(bytes[54..][0..data.len], data);
    return bytes;
}

test "RIFF validation rejects truncation and unsupported formats" {
    const a = std.testing.allocator;
    const bytes = try fixture(16, 1, &.{ 0, 0 }, a);
    defer a.free(bytes);
    for (0..bytes.len) |length| try std.testing.expectError(if (length < 12) error.InvalidWave else error.TruncatedWave, parse(bytes[0..length]));
    bytes[30] = 3;
    try std.testing.expectError(error.UnsupportedCodec, parse(bytes));
    bytes[30] = 1;
    bytes[32] = 3;
    try std.testing.expectError(error.UnsupportedChannels, parse(bytes));
    bytes[32] = 1;
    bytes[44] = 24;
    try std.testing.expectError(error.UnsupportedBits, parse(bytes));
}
