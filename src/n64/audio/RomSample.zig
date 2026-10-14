//! Cartridge audio metadata, shared by ROM streaming and typed PCM RAM loading.
const std = @import("std");
const rom = @import("../rom.zig");
const codec = @import("vadpcm.zig");
const PcmSample = @import("Sample.zig");
const Format = PcmSample.Format;

const RomSample = @This();

asset: rom.Region,
frequency: u32,
frames: u32,
channels: u2 = 1,
format: Format = .pcm16,
loop_frames: u32 = 0,
vadpcm: ?codec.Metadata = null,
pub fn bytesPerFrame(self: RomSample) u32 {
    return @as(u32, self.channels) * (if (self.format == .pcm16) @as(u32, 2) else 1);
}
pub fn validate(self: RomSample) !void {
    try self.validateMetadata();
    if (self.vadpcm) |metadata| {
        try self.validateVadpcm(metadata);
    } else if (@as(u64, self.frames) * self.bytesPerFrame() > self.asset.size) return error.IncompletePcm;
}

fn validateMetadata(self: RomSample) !void {
    if (self.channels < 1 or self.channels > 2 or self.frequency == 0 or self.frames == 0 or self.loop_frames > self.frames) return error.InvalidSample;
}

fn validateVadpcm(self: RomSample, metadata: codec.Metadata) !void {
    if (self.format != .pcm16) return error.InvalidSample;
    const blocks = (@as(u64, self.frames) + 15) / 16;
    const data_bytes = blocks * 9 * self.channels;
    const checkpoints = (blocks + codec.checkpoint_blocks - 1) / codec.checkpoint_blocks;
    if (metadata.checkpoint_offset < data_bytes or metadata.checkpoint_offset % 16 != 0 or
        @as(u64, metadata.checkpoint_offset) + checkpoints * 32 > self.asset.size) return error.IncompleteVadpcm;
}

/// The same cartridge PCM can be streamed or loaded through the shared ROM
/// owner. Keep the owner stable during DMA and storage alive during playback.
pub const Loaded = rom.LoadedAsset(PcmLayout);

pub fn storageSize(self: RomSample) usize {
    return std.mem.alignForward(usize, self.asset.size, 16);
}

/// Allocate only; call load/begin after placing the owner at its final address.
/// Compressed audio currently requires streaming and is not decoded by a load.
pub fn init(self: RomSample, allocator: std.mem.Allocator) !Loaded {
    try self.validateResident();
    return Loaded.init(allocator, self.asset, self);
}

/// Borrow complete aligned cache lines, including the generated PCM padding.
pub fn initBuffer(self: RomSample, bytes: []align(16) u8) !Loaded {
    try self.validateResident();
    return Loaded.initBuffer(self.asset, bytes, self);
}

fn validateResident(self: RomSample) !void {
    try self.validate();
    if (self.vadpcm != null) return error.CompressedSampleRequiresStreaming;
    const length = @as(u64, self.frames) * self.bytesPerFrame();
    if (length >= 0x80000) return error.SampleTooLong;
    if (self.asset.size < length + 64) return error.MissingOverreadPadding;
}

const PcmLayout = struct {
    pub const Storage = RomSample;
    pub const Value = PcmSample;

    pub fn bind(bytes: []align(16) const u8, source: *Storage, _: u64) Value {
        return .{
            .data = bytes,
            .frequency = source.frequency,
            .frames = source.frames,
            .channels = source.channels,
            .format = source.format,
            .loop_frames = source.loop_frames,
        };
    }
};

test "PCM loading validates size, padding and compression before allocation" {
    const sample: RomSample = .{ .asset = .{ .offset = 0, .size = 81 }, .frequency = 22050, .frames = 17, .format = .pcm8 };
    var bytes: [112]u8 align(16) = @splat(0xaa);
    var borrowed = try sample.initBuffer(&bytes);
    try std.testing.expectEqual(@as(usize, 96), sample.storageSize());
    try std.testing.expectEqual(@as(usize, 96), borrowed.bytes.len);
    try std.testing.expect(!borrowed.owned);
    try std.testing.expectError(error.NotLoaded, borrowed.view());
    try borrowed.deinit(std.testing.failing_allocator);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[96]);
    try std.testing.expectError(error.BufferTooSmall, sample.initBuffer(bytes[0..80]));
    try std.testing.expectError(error.OutOfMemory, sample.init(std.testing.failing_allocator));
    var owned = try sample.init(std.testing.allocator);
    try std.testing.expect(owned.owned);
    try owned.deinit(std.testing.allocator);

    var bad = sample;
    bad.asset.size = 80;
    try std.testing.expectError(error.MissingOverreadPadding, bad.init(std.testing.failing_allocator));
    bad.frames = 0x80000;
    bad.asset.size = 0x80000 + 64;
    try std.testing.expectError(error.SampleTooLong, bad.init(std.testing.failing_allocator));
    bad = sample;
    bad.format = .pcm16;
    bad.frames = 16;
    const book align(16) = [_]i16{0} ** 128;
    bad.vadpcm = .{ .codebook = &book, .checkpoint_offset = 16 };
    try std.testing.expectError(error.CompressedSampleRequiresStreaming, bad.init(std.testing.failing_allocator));
}

test "PCM binding preserves sample metadata and borrows the final DMA storage" {
    var bytes: [96]u8 align(16) = @splat(0x12);
    var source: RomSample = .{ .asset = .{ .offset = 0, .size = 96 }, .frequency = 32000, .frames = 8, .channels = 2, .loop_frames = 3 };
    const sample = PcmLayout.bind(&bytes, &source, 1);
    try sample.validate();
    try std.testing.expectEqual(@intFromPtr(&bytes), @intFromPtr(sample.data.ptr));
    try std.testing.expectEqual(source.frequency, sample.frequency);
    try std.testing.expectEqual(source.frames, sample.frames);
    try std.testing.expectEqual(source.channels, sample.channels);
    try std.testing.expectEqual(source.format, sample.format);
    try std.testing.expectEqual(source.loop_frames, sample.loop_frames);
}
