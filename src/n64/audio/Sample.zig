//! Resident signed PCM, big-endian for 16-bit input. Generated assets include
//! 64 bytes of silence or repeated loop data after the logical end.
const std = @import("std");
pub const Format = enum { pcm8, pcm16 };
const Sample = @This();

data: []align(16) const u8,
frequency: u32,
frames: u32,
channels: u2 = 1,
format: Format = .pcm16,
loop_frames: u32 = 0,

pub fn bytesPerFrame(self: Sample) u32 {
    return @as(u32, self.channels) * (if (self.format == .pcm16) @as(u32, 2) else 1);
}
pub fn validate(self: Sample) !void {
    if (self.channels < 1 or self.channels > 2 or self.frequency == 0 or self.frames == 0 or self.loop_frames > self.frames) return error.InvalidSample;
    const length = @as(u64, self.frames) * self.bytesPerFrame();
    // Keep every byte position in the reference's signed 31-bit window.
    if (length >= 0x80000) return error.SampleTooLong;
    if (self.data.len < length + 64) return error.MissingOverreadPadding;
}

test "resident samples require complete hardware padding and bounded positions" {
    const bytes align(16) = [_]u8{0} ** 80;
    const sample: Sample = .{ .data = &bytes, .frequency = 48000, .frames = 8 };
    try sample.validate();
    var bad = sample;
    bad.frames = 9;
    try std.testing.expectError(error.MissingOverreadPadding, bad.validate());
    bad.frames = 262144;
    try std.testing.expectError(error.SampleTooLong, bad.validate());
}
