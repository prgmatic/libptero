//! Bounded compressed ROM reads, checkpoint restore and RSP decode/discard.
const std = @import("std");
const rom = @import("../rom.zig");
const codec = @import("vadpcm.zig");

pub const Storage = struct {
    workspace: [codec.workspace_bytes]u8 align(16) = undefined,
    state: codec.State align(16) = @splat(0),
    decoded_blocks: u64 = 0,

    /// Read an arbitrary PCM16 byte range, restoring history at the preceding
    /// 1024-source-frame checkpoint. A partial final block is copied precisely.
    /// Reader and decoder timeouts retain this fixed storage for explicit retry.
    pub fn read(self: *Storage, reader: *rom.Reader, decoder: *codec.Decoder, asset: rom.Asset, metadata: codec.Metadata, channels: u2, start: u64, destination: []u8, attempts: u32) !void {
        const frame_bytes = @as(u64, channels) * 2;
        const first_block = start / (frame_bytes * 16);
        var block = first_block / codec.checkpoint_blocks * codec.checkpoint_blocks;
        const checkpoint = block / codec.checkpoint_blocks;
        try reader.read(asset, @intCast(metadata.checkpoint_offset + checkpoint * 32), std.mem.asBytes(&self.state), attempts);
        var copied: usize = 0;
        while (copied < destination.len) {
            const end = start + destination.len;
            const remaining_blocks = (end + frame_bytes * 16 - 1) / (frame_bytes * 16) - block;
            const count: u32 = @intCast(@min(remaining_blocks, codec.max_channel_blocks / @as(u32, channels)));
            const input = try codec.inputSlice(&self.workspace, count, channels);
            try reader.read(asset, @intCast(block * 9 * channels), input, attempts);
            try decoder.submit(&self.workspace, &self.state, metadata.codebook, count, channels);
            try decoder.wait(attempts);
            self.decoded_blocks += count;
            const batch_begin = block * frame_bytes * 16;
            const batch_end = batch_begin + try codec.outputBytes(count, channels);
            if (batch_end > start) {
                const begin = @max(start, batch_begin);
                const length: usize = @intCast(@min(end, batch_end) - begin);
                const offset: usize = @intCast(begin - batch_begin);
                @memcpy(destination[copied..][0..length], self.workspace[offset..][0..length]);
                copied += length;
            }
            block += count;
        }
    }
};
