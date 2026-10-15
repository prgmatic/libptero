//! libdragon VADPCM RSP command ABI. PCM mixing remains a separate overlay.
const std = @import("std");
const rsp = @import("../rsp.zig");
const cache = @import("../cpu/cache.zig");
pub const max_channel_blocks = 94;
pub const checkpoint_blocks = 64;
pub const State = [16]i16;
pub const Codebook = [128]i16;
pub const workspace_bytes = 3072;
pub const Metadata = struct {
    codebook: *align(16) const Codebook,
    checkpoint_offset: u32,
};

pub fn outputBytes(blocks: u32, channels: u2) !usize {
    if (channels < 1 or channels > 2 or blocks == 0 or blocks > max_channel_blocks / @as(u32, channels)) return error.InvalidVadpcmBatch;
    return blocks * 32 * @as(u32, channels);
}
/// Encoded frames occupy the tail of the same RDRAM workspace as decoded PCM.
/// The caller owns the complete cache/DMA lines, including preceding alignment
/// bytes and eight padding bytes after output. Even addresses may be misaligned.
pub fn inputSlice(workspace: []align(2) u8, blocks: u32, channels: u2) ![]u8 {
    const output = try outputBytes(blocks, channels);
    if (workspace.len < output + 8) return error.VadpcmBufferTooSmall;
    const input = blocks * 9 * @as(u32, channels);
    const offset = std.mem.alignBackward(usize, output - input, 8);
    return workspace[offset..][0..input];
}

/// Stable-address decoder borrowing the active Runtime. One high-priority
/// submission may be outstanding; timeout retains workspace and state ownership.
/// Complete and deinitialize this object before deinitializing the Runtime.
pub const Decoder = struct {
    overlay: rsp.Overlay = undefined,
    queue: rsp.Queue = undefined,
    initialized: bool = false,
    pending: bool = false,
    borrowed_workspace: []u8 = &.{},
    borrowed_state: ?*align(16) State = null,

    pub fn init(self: *Decoder) void {
        std.debug.assert(!self.initialized);
        self.overlay.init(rsp.programs.audio_vadpcm);
        _ = rsp.registerOverlay(&self.overlay);
        self.queue.init(.high);
        self.initialized = true;
    }
    pub fn submit(self: *Decoder, workspace: []align(2) u8, state: *align(16) State, book: *align(16) const Codebook, blocks: u32, channels: u2) !void {
        if (!self.initialized) return error.DecoderNotInitialized;
        if (self.pending) return error.DecoderBusy;
        const input = try inputSlice(workspace, blocks, channels);
        const length = try outputBytes(blocks, channels);
        for (0..input.len / 9) |block| if (input[block * 9] & 15 >= 4 or input[block * 9] >> 4 > 12) return error.InvalidVadpcmFrame;
        cache.writebackData(workspace);
        cache.invalidateData(workspace);
        cache.writebackData(state);
        cache.invalidateData(state);
        cache.writebackData(book);
        self.queue.writeOverlayCommand(&self.overlay, 0, @import("../cpu.zig").physicalAddress(@intFromPtr(input.ptr)), &.{
            ((blocks - 1) << 24) | @import("../cpu.zig").physicalAddress(@intFromPtr(workspace.ptr)),
            @import("../cpu.zig").physicalAddress(@intFromPtr(state)) | (if (channels == 2) @as(u32, 0x80000000) else 0),
            @import("../cpu.zig").physicalAddress(@intFromPtr(book)),
        });
        self.borrowed_workspace = workspace[0 .. length + 8];
        self.borrowed_state = state;
        self.pending = true;
        rsp.submitHighPriority(&self.queue);
    }
    /// Ported SetState command: copy a decoder history or clear it on the RSP.
    pub fn submitState(self: *Decoder, destination: *align(16) State, source: ?*align(16) const State) !void {
        if (!self.initialized) return error.DecoderNotInitialized;
        if (self.pending) return error.DecoderBusy;
        cache.writebackData(destination);
        cache.invalidateData(destination);
        if (source) |history| cache.writebackData(history);
        self.queue.writeOverlayCommand(&self.overlay, 1, @import("../cpu.zig").physicalAddress(@intFromPtr(destination)), &.{if (source) |history| @import("../cpu.zig").physicalAddress(@intFromPtr(history)) else 0});
        self.borrowed_workspace = &.{};
        self.borrowed_state = destination;
        self.pending = true;
        rsp.submitHighPriority(&self.queue);
    }
    pub fn wait(self: *Decoder, max_attempts: u32) !void {
        if (!self.pending) return;
        if (!rsp.waitHighPriorityTimeout(&self.queue, max_attempts)) return error.RspTimeout;
        cache.invalidateData(self.borrowed_workspace);
        cache.invalidateData(self.borrowed_state.?);
        self.borrowed_state = null;
        self.pending = false;
    }
    pub fn deinit(self: *Decoder) !void {
        if (self.pending) return error.DecoderBusy;
        if (self.initialized) {
            rsp.releaseHighPriority(&self.queue);
            rsp.unregisterOverlay(&self.overlay);
        }
        self.* = .{};
    }
};

test "mono and stereo batch bounds and in-place DMA padding" {
    var workspace: [workspace_bytes]u8 align(16) = undefined;
    try std.testing.expectEqual(@as(usize, 3008), try outputBytes(94, 1));
    try std.testing.expectEqual(@as(usize, 846), (try inputSlice(&workspace, 47, 2)).len);
    try std.testing.expectError(error.InvalidVadpcmBatch, outputBytes(48, 2));
    try std.testing.expectError(error.InvalidVadpcmBatch, outputBytes(0, 1));
    try std.testing.expectError(error.VadpcmBufferTooSmall, inputSlice(workspace[0..32], 1, 1));
}
