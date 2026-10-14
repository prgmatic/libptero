//! Fixed-storage PCM windows. RSP positions are local .12 byte offsets; the
//! logical source cursor remains wide enough for tracks larger than RAM.
const std = @import("std");
const rom = @import("../rom.zig");
const vadpcm = @import("vadpcm.zig");
const Format = @import("Sample.zig").Format;
pub const Sample = @import("RomSample.zig");
pub const Window = struct { position: u32, length: u32 };

/// Caller owns aligned storage and keeps Stream at a stable address. One
/// Stream may attach to one mixer channel. Give independent voices independent
/// storage even when they play the same Sample. No allocation happens here.
const Stream = @This();

sample: Sample,
storage: []align(16) u8,
reader: rom.Reader = .{},
cursor: u64 = 0,
window_start: u64 = 0,
window_valid: bool = false,
submitted_position: u32 = 0,
attached: bool = false,
refills: u64 = 0,
compressed: @import("vadpcm_stream.zig").Storage = .{},

pub fn init(sample: Sample, storage: []align(16) u8) !Stream {
    try sample.validate();
    if (storage.len < 80 or storage.len % 16 != 0 or storage.len >= 0x80000) return error.InvalidStreamStorage;
    return .{ .sample = sample, .storage = storage };
}
pub fn positionFrames(self: *const Stream) u32 {
    return @intCast(self.cursor / (@as(u64, self.sample.bytesPerFrame()) << 12));
}
pub fn seek(self: *Stream, frame: u32) !void {
    if (self.attached) return error.StreamAttached;
    if (self.reader.destination != null) return error.StreamBusy;
    if (frame > self.sample.frames) return error.InvalidSeek;
    self.cursor = @as(u64, frame) * self.sample.bytesPerFrame() << 12;
    self.window_valid = false;
}
pub fn prepare(self: *Stream, output_frames: u32, step: u32, max_attempts: u32) !Window {
    return self.prepareWithDecoder(output_frames, step, max_attempts, null);
}
pub fn prepareWithDecoder(self: *Stream, output_frames: u32, step: u32, max_attempts: u32, decoder: ?*vadpcm.Decoder) !Window {
    // A prior timeout can still own decoded history or the window.
    // Finish both before resetting checkpoints or refilling storage.
    if (decoder) |active| try active.wait(max_attempts);
    try self.reader.wait(max_attempts);
    self.cursor = normalize(self.sample, self.cursor);
    const frame_bytes = self.sample.bytesPerFrame();
    const begin = self.cursor >> 12 & ~@as(u64, frame_bytes - 1);
    const minimum = try requiredBytes(self.cursor - (begin << 12), output_frames, step);
    if (minimum > self.storage.len) return error.StreamBufferTooSmall;
    if (!self.window_valid or begin < self.window_start or minimum + (begin - self.window_start) > self.storage.len) {
        self.window_valid = false;
        const trace_scope = @import("../debug/profiler.zig").scope("Audio refill CPU");
        defer trace_scope.end();
        try self.fill(begin, max_attempts, decoder);
        self.window_start = begin;
        self.window_valid = true;
        self.refills += 1;
    }
    const position: u32 = @intCast(self.cursor - (self.window_start << 12));
    self.submitted_position = position;
    const remaining = @as(u64, self.sample.frames) * frame_bytes - self.window_start;
    // Loops are expanded into the window. The microcode never sees a loop.
    const length: u32 = if (self.sample.loop_frames == 0 and remaining < 0x80000) @intCast(remaining << 12) else 0x7fffffff;
    return .{ .position = position, .length = length };
}
pub fn finish(self: *Stream, position: u32) bool {
    self.cursor += position - self.submitted_position;
    const ended = self.sample.loop_frames == 0 and self.cursor >= (@as(u64, self.sample.frames) * self.sample.bytesPerFrame() << 12);
    const wrapped = normalize(self.sample, self.cursor);
    if (wrapped != self.cursor) self.window_valid = false;
    self.cursor = wrapped;
    return ended;
}
fn fill(self: *Stream, start: u64, max_attempts: u32, decoder: ?*vadpcm.Decoder) !void {
    const length = @as(u64, self.sample.frames) * self.sample.bytesPerFrame();
    const loop_bytes = @as(u64, self.sample.loop_frames) * self.sample.bytesPerFrame();
    var copied: usize = 0;
    var position = start;
    while (copied < self.storage.len) {
        if (position >= length) {
            if (loop_bytes == 0) {
                @memset(self.storage[copied..], 0);
                return;
            }
            // Once a complete loop is in this window, repeat it locally
            // instead of issuing thousands of DMAs for tiny waveforms.
            if (copied >= loop_bytes) {
                const count: usize = @intCast(@min(loop_bytes, self.storage.len - copied));
                const previous = copied - @as(usize, @intCast(loop_bytes));
                @memcpy(self.storage[copied..][0..count], self.storage[previous..][0..count]);
                copied += count;
                continue;
            }
            position = length - loop_bytes + (position - length) % loop_bytes;
        }
        const count: usize = @intCast(@min(length - position, self.storage.len - copied));
        if (self.sample.vadpcm) |metadata| {
            try self.compressed.read(&self.reader, decoder orelse return error.CompressedDecoderRequired, self.sample.asset, metadata, self.sample.channels, position, self.storage[copied..][0..count], max_attempts);
        } else try self.reader.read(self.sample.asset, @intCast(position), self.storage[copied..][0..count], max_attempts);
        position += count;
        copied += count;
    }
}

fn normalize(sample: Sample, cursor: u64) u64 {
    const end = @as(u64, sample.frames) * sample.bytesPerFrame() << 12;
    if (cursor < end) return cursor;
    if (sample.loop_frames == 0) return end;
    const loop = @as(u64, sample.loop_frames) * sample.bytesPerFrame() << 12;
    return end - loop + (cursor - end) % loop;
}
fn requiredBytes(position: u64, output_frames: u32, step: u32) !u64 {
    // Include the entire final step plus a full RSP DMA cache after it.
    const bytes = ((position + @as(u64, output_frames) * step + 4095) >> 12) + 64;
    if (bytes >= 0x80000) return error.StreamBufferTooSmall;
    return bytes;
}
test "wide source cursor preserves fractions across long and short loops" {
    const sample: Sample = .{ .asset = .{ .offset = 0, .size = 12000000 }, .frequency = 48000, .frames = 3000000, .channels = 2, .loop_frames = 3 };
    try sample.validate();
    const end = @as(u64, sample.frames) * 4 << 12;
    try std.testing.expectEqual(end - (12 << 12) + 17, normalize(sample, end + (12 << 12) + 17));
    var finite = sample;
    finite.loop_frames = 0;
    try std.testing.expectEqual(end, normalize(finite, end + 123));
    try std.testing.expectEqual(@as(u64, 64 + 17), try requiredBytes(1, 16, 4096));
    try std.testing.expectError(error.StreamBufferTooSmall, requiredBytes(0, 32767, 128000));
}
test "stream storage budgets, source length and seek validation" {
    var buffer: [128]u8 align(16) = undefined;
    const sample: Sample = .{ .asset = .{ .offset = 0, .size = 128 }, .frequency = 48000, .frames = 64 };
    var stream = try Stream.init(sample, &buffer);
    try stream.seek(40);
    try std.testing.expectEqual(@as(u32, 40), stream.positionFrames());
    try std.testing.expectError(error.InvalidSeek, stream.seek(65));
    try std.testing.expectError(error.InvalidStreamStorage, Stream.init(sample, buffer[0..64]));
    stream.attached = true;
    try std.testing.expectError(error.StreamAttached, stream.seek(0));
    var bad = sample;
    bad.frames = 65;
    try std.testing.expectError(error.IncompletePcm, bad.validate());
}
