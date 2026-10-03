//! libdragon's four-predictor order-two host encoder, with native ROM checkpoints.
const std = @import("std");
const wav = @import("wav.zig");
const Vector = extern struct { values: [8]i16 align(16) };
const Params = extern struct { predictors: c_int = 4, minimum: c_int = -8, maximum: c_int = 7 };
extern fn vadpcm_encode(*const Params, [*]Vector, usize, [*]u8, [*]const i16, ?*anyopaque) c_int;
extern fn vadpcm_decode(c_int, c_int, [*]const Vector, *Vector, usize, [*]i16, [*]const u8) c_int;

pub const checkpoint_blocks = 64;
pub const Encoded = struct { data: []u8, codebook: [128]i16, checkpoint_offset: u32 };

pub fn encode(allocator: std.mem.Allocator, wave: wav.Wave) !Encoded {
    // Pad only the encoded final block. Logical frames and loop points remain exact.
    const blocks = (@as(usize, wave.frames) + 15) / 16;
    const encoded_bytes = blocks * 9 * wave.channels;
    const checkpoint_offset = std.mem.alignForward(usize, encoded_bytes, 16);
    const checkpoint_count = (blocks + checkpoint_blocks - 1) / checkpoint_blocks;
    const data = try allocator.alloc(u8, checkpoint_offset + checkpoint_count * 32);
    errdefer allocator.free(data);
    @memset(data, 0);
    var book: [16]Vector = @splat(.{ .values = @splat(0) });
    const samples = try allocator.alloc(i16, blocks * 16);
    defer allocator.free(samples);
    const compressed = try allocator.alloc(u8, blocks * 9);
    defer allocator.free(compressed);
    for (0..wave.channels) |channel| {
        unpackChannel(samples, wave, channel);
        const channel_book = book[channel * 8 ..][0..8];
        if (vadpcm_encode(&.{}, channel_book.ptr, blocks, compressed.ptr, samples.ptr, null) != 0) return error.VadpcmEncodeFailed;
        for (0..blocks) |block| @memcpy(data[(block * wave.channels + channel) * 9 ..][0..9], compressed[block * 9 ..][0..9]);
        try checkpoints(data[checkpoint_offset..], compressed, channel_book, channel, samples);
    }
    var coefficients: [128]i16 = undefined;
    for (book, 0..) |vector, i| @memcpy(coefficients[i * 8 ..][0..8], &vector.values);
    return .{ .data = data, .codebook = coefficients, .checkpoint_offset = @intCast(checkpoint_offset) };
}

fn unpackChannel(dest: []i16, wave: wav.Wave, channel: usize) void {
    @memset(dest, 0);
    for (dest[0..wave.frames], 0..) |*sample, frame| {
        const index = frame * wave.channels + channel;
        sample.* = if (wave.bits == 8) (@as(i16, wave.data[index]) - 128) * 256 else std.mem.readInt(i16, wave.data[index * 2 ..][0..2], .little);
    }
}

fn checkpoints(dest: []u8, source: []const u8, book: []const Vector, channel: usize, samples: []i16) !void {
    var state: Vector = .{ .values = @splat(0) };
    const blocks = source.len / 9;
    var block: usize = 0;
    var checkpoint: usize = 0;
    while (block < blocks) : (checkpoint += 1) {
        for (state.values, 0..) |value, lane| std.mem.writeInt(i16, dest[checkpoint * 32 + channel * 16 + lane * 2 ..][0..2], value, .big);
        const count = @min(checkpoint_blocks, blocks - block);
        if (vadpcm_decode(4, 2, book.ptr, &state, count, samples.ptr, source[block * 9 ..].ptr) != 0) return error.VadpcmDecodeFailed;
        block += count;
    }
}

test "stereo encoding separates codebooks and preserves checkpoint states" {
    const a = std.testing.allocator;
    var pcm: [16 * 80 * 4]u8 = undefined;
    for (0..16 * 80) |i| {
        std.mem.writeInt(i16, pcm[i * 4 ..][0..2], @intCast(@as(i32, @intCast(i % 97)) * 600 - 28000), .little);
        std.mem.writeInt(i16, pcm[i * 4 + 2 ..][0..2], @intCast(@as(i32, @intCast(i % 131)) * 400 - 26000), .little);
    }
    const bytes = try wav.fixture(16, 2, &pcm, a);
    defer a.free(bytes);
    const wave = try wav.parse(bytes);
    const result = try encode(a, wave);
    defer a.free(result.data);
    try std.testing.expectEqual(@as(u32, 1440), result.checkpoint_offset);
    for (result.data[result.checkpoint_offset..][0..32]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(!std.mem.eql(i16, result.codebook[0..64], result.codebook[64..]));
    try std.testing.expect(!std.mem.allEqual(u8, result.data[result.checkpoint_offset + 32 ..], 0));
}
