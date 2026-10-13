const std = @import("std");
const rom = @import("../rom.zig");
const codec = @import("vadpcm.zig");
const Format = @import("Sample.zig").Format;

const StreamSample = @This();

asset: rom.Region,
frequency: u32,
frames: u32,
channels: u2 = 1,
format: Format = .pcm16,
loop_frames: u32 = 0,
vadpcm: ?codec.Metadata = null,
pub fn bytesPerFrame(self: StreamSample) u32 {
    return @as(u32, self.channels) * (if (self.format == .pcm16) @as(u32, 2) else 1);
}
pub fn validate(self: StreamSample) !void {
    if (self.channels < 1 or self.channels > 2 or self.frequency == 0 or self.frames == 0 or self.loop_frames > self.frames) return error.InvalidSample;
    if (self.vadpcm) |metadata| {
        if (self.format != .pcm16) return error.InvalidSample;
        const blocks = (@as(u64, self.frames) + 15) / 16;
        const data_bytes = blocks * 9 * self.channels;
        const checkpoints = (blocks + codec.checkpoint_blocks - 1) / codec.checkpoint_blocks;
        if (metadata.checkpoint_offset < data_bytes or metadata.checkpoint_offset % 16 != 0 or
            @as(u64, metadata.checkpoint_offset) + checkpoints * 32 > self.asset.size) return error.IncompleteVadpcm;
    } else if (@as(u64, self.frames) * self.bytesPerFrame() > self.asset.size) return error.IncompletePcm;
}
