//! Native WAV assets with PCM or libdragon VADPCM encoding.
const std = @import("std");
pub const wav = @import("wav.zig");
pub const vadpcm = @import("vadpcm.zig");
pub const Compression = enum { none, vadpcm };
pub const Options = struct { loop: bool = false, streamed: bool = false, compression: Compression = .none };
pub const Result = struct {
    data: []u8,
    codebook: ?[128]i16 = null,
    checkpoint_offset: u32 = 0,
    frequency: u32,
    frames: u32,
    channels: u16,
    bits: u16,
    loop: bool,
    streamed: bool,
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub fn convert(allocator: std.mem.Allocator, bytes: []const u8, options: Options) !Result {
    const wave = try wav.parse(bytes);
    if (options.compression == .vadpcm) return compress(allocator, wave, options);
    if (!options.streamed and wave.data.len >= 0x80000) return error.SampleTooLong;
    const data = try allocator.alloc(u8, wave.data.len + 64);
    @memset(data, 0);
    convertPcm(data[0..wave.data.len], wave.data, wave.bits);
    if (options.loop) for (data[wave.data.len..], 0..) |*dest, index| {
        dest.* = data[index % wave.data.len];
    };
    return .{ .data = data, .frequency = wave.frequency, .frames = wave.frames, .channels = wave.channels, .bits = wave.bits, .loop = options.loop, .streamed = options.streamed };
}

fn compress(allocator: std.mem.Allocator, wave: wav.Wave, options: Options) !Result {
    if (!options.streamed) return error.CompressionRequiresRom;
    const encoded = try vadpcm.encode(allocator, wave);
    return .{ .data = encoded.data, .codebook = encoded.codebook, .checkpoint_offset = encoded.checkpoint_offset, .frequency = wave.frequency, .frames = wave.frames, .channels = wave.channels, .bits = 16, .loop = options.loop, .streamed = true };
}

fn convertPcm(data: []u8, source: []const u8, bits: u16) void {
    if (bits == 8) {
        for (source, data) |byte, *dest| dest.* = byte ^ 0x80;
    } else {
        var index: usize = 0;
        while (index < source.len) : (index += 2) {
            data[index] = source[index + 1];
            data[index + 1] = source[index];
        }
    }
}

pub fn generateSource(allocator: std.mem.Allocator, name: []const u8, result: Result) ![]u8 {
    if (!std.zig.isValidId(name)) return error.InvalidAssetName;
    if (result.codebook) |book| return compressedSource(allocator, name, result, book);
    const format_name = if (result.bits == 8) "pcm8" else "pcm16";
    const loop_frames = if (result.loop) result.frames else 0;
    if (result.streamed) return std.fmt.allocPrint(allocator,
        \\const n64 = @import("n64");
        \\pub const {s}: n64.audio.StreamSample = .{{
        \\    .asset = @import("rom_data").{s}, .frequency = {d}, .frames = {d},
        \\    .channels = {d}, .format = .{s}, .loop_frames = {d},
        \\}};
        \\
    , .{ name, name, result.frequency, result.frames, result.channels, format_name, loop_frames });
    return std.fmt.allocPrint(allocator,
        \\const n64 = @import("n64");
        \\const bytes align(16) = @embedFile("audio_data").*;
        \\pub const {s}: n64.audio.Sample = .{{
        \\    .data = &bytes, .frequency = {d}, .frames = {d},
        \\    .channels = {d}, .format = .{s}, .loop_frames = {d},
        \\}};
        \\
    , .{ name, result.frequency, result.frames, result.channels, format_name, loop_frames });
}

test "unsigned mono8 is signed and loop padding repeats even tiny clips" {
    const a = std.testing.allocator;
    const wave = try wav.fixture(8, 1, &.{ 0, 128, 255 }, a);
    defer a.free(wave);
    const result = try convert(a, wave, .{ .loop = true });
    defer result.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 127 }, result.data[0..3]);
    for (result.data[3..], 0..) |byte, index| try std.testing.expectEqual(result.data[index % 3], byte);
    const source = try generateSource(a, "clip", result);
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, ".loop_frames = 3") != null);
}

test "stereo16 preserves interleaving and negative samples in hardware byte order" {
    const a = std.testing.allocator;
    const wave = try wav.fixture(16, 2, &.{ 0x34, 0x12, 0x00, 0x80, 0xff, 0x7f, 0xff, 0xff }, a);
    defer a.free(wave);
    const result = try convert(a, wave, .{});
    defer result.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x80, 0, 0x7f, 0xff, 0xff, 0xff }, result.data[0..8]);
    try std.testing.expectEqual(@as(u32, 2), result.frames);
    for (result.data[8..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "ROM PCM exceeds resident position limit and emits handles without embedded data" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, 0x80000);
    defer a.free(bytes);
    @memset(bytes, 128);
    const wave = try wav.fixture(8, 1, bytes, a);
    defer a.free(wave);
    try std.testing.expectError(error.SampleTooLong, convert(a, wave, .{}));
    const result = try convert(a, wave, .{ .streamed = true, .loop = true });
    defer result.deinit(a);
    try std.testing.expectEqual(@as(u32, 0x80000), result.frames);
    const source = try generateSource(a, "track", result);
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "StreamSample") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@embedFile") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"rom_data\").track") != null);
}

fn compressedSource(allocator: std.mem.Allocator, name: []const u8, result: Result, book: [128]i16) ![]u8 {
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeAll("const n64 = @import(\"n64\");\nconst codebook align(16) = [128]i16{ ");
    for (book) |coefficient| try source.writer.print("{d}, ", .{coefficient});
    try source.writer.print(
        \\}};
        \\pub const {s}: n64.audio.StreamSample = .{{
        \\    .asset = @import("rom_data").{s}, .frequency = {d}, .frames = {d},
        \\    .channels = {d}, .format = .pcm16, .loop_frames = {d},
        \\    .vadpcm = .{{ .codebook = &codebook, .checkpoint_offset = {d} }},
        \\}};
        \\
    , .{ name, name, result.frequency, result.frames, result.channels, if (result.loop) result.frames else 0, result.checkpoint_offset });
    return source.toOwnedSlice();
}

test "VADPCM produces native ROM metadata and preserves unaligned logical loops" {
    const a = std.testing.allocator;
    var pcm: [17 * 2]u8 = @splat(0);
    for (0..17) |i| std.mem.writeInt(i16, pcm[i * 2 ..][0..2], @intCast(i * 900), .little);
    const wave = try wav.fixture(16, 1, &pcm, a);
    defer a.free(wave);
    try std.testing.expectError(error.CompressionRequiresRom, convert(a, wave, .{ .compression = .vadpcm }));
    const result = try convert(a, wave, .{ .compression = .vadpcm, .streamed = true, .loop = true });
    defer result.deinit(a);
    try std.testing.expectEqual(@as(u32, 17), result.frames);
    try std.testing.expectEqual(@as(u32, 32), result.checkpoint_offset);
    const source = try generateSource(a, "compressed", result);
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, ".loop_frames = 17") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".vadpcm = .{") != null);
}
