//! Fixed-capacity voice playback on one shared RSP runtime. No frame allocations.
const std = @import("std");
const rsp = @import("../rsp/rsp.zig");
const mixer_api = @import("mixer.zig");
const output_api = @import("output.zig");
const Sample = @import("sample.zig").Sample;
const Stream = @import("stream.zig").Stream;
const pool_api = @import("voice_pool.zig");
const playback = @import("playback.zig");
pub const Voice = pool_api.Voice;
pub const Options = struct { channels: u8 = 16, output: output_api.Options = .{} };
pub const PlayOptions = struct { volume: f32 = 1, pan: f32 = 0 };
pub const UpdateOptions = struct { max_buffers: u8 = 4, max_attempts: u32 = 1_000_000 };

/// Keep at a stable address. Voices and attached Streams borrow this player;
/// source samples and stream windows must outlive playback. Exhaustion returns
/// VoiceLimit; existing voices are never stolen. Owns Mixer and Output.
pub const Player = struct {
    mixer: mixer_api.Mixer = undefined,
    output: output_api.Output = undefined,
    pool: pool_api.Pool = .{ .count = 0 },
    pending_commit: bool = false,
    mixer_initialized: bool = false,

    pub fn init(self: *Player, allocator: std.mem.Allocator, runtime: *rsp.Runtime, options: Options) !void {
        if (options.channels == 0 or options.channels > 32) return error.InvalidChannelCount;
        if (runtime.mixer_attached) return error.MixerAlreadyInitialized;
        self.* = .{ .pool = .{ .count = options.channels } };
        try self.output.init(allocator, options.output);
        errdefer self.output.deinit(allocator, 1_000_000) catch unreachable; // No buffers have been queued.
        try self.mixer.init(runtime, options.channels);
        self.mixer_initialized = true;
    }

    pub fn play(self: *Player, sample: Sample, options: PlayOptions) !Voice {
        const gain = try gains(options);
        try self.editable();
        const voice = try self.pool.claim(sample.channels);
        errdefer self.pool.retire(voice.index);
        try self.mixer.play(voice.index, sample, self.output.timing.frequency);
        try self.mixer.setVolume(voice.index, gain[0], gain[1]);
        return voice;
    }

    pub fn playStream(self: *Player, stream: *Stream, options: PlayOptions) !Voice {
        const gain = try gains(options);
        try self.editable();
        const voice = try self.pool.claim(stream.sample.channels);
        errdefer self.pool.retire(voice.index);
        try self.mixer.playStream(voice.index, stream, self.output.timing.frequency);
        try self.mixer.setVolume(voice.index, gain[0], gain[1]);
        return voice;
    }

    pub fn stop(self: *Player, voice: Voice) !void {
        try self.editable();
        const index = try self.pool.resolve(voice);
        try self.mixer.stop(index);
        self.pool.retire(index);
    }
    pub fn setVolume(self: *Player, voice: Voice, options: PlayOptions) !void {
        const gain = try gains(options);
        try self.editable();
        try self.mixer.setVolume(try self.pool.resolve(voice), gain[0], gain[1]);
    }
    pub fn seek(self: *Player, voice: Voice, source_frame: u32) !void {
        try self.editable();
        try self.mixer.seek(try self.pool.resolve(voice), source_frame);
    }
    pub fn isPlaying(self: *Player, voice: Voice) bool {
        _ = self.pool.resolve(voice) catch return false;
        return true;
    }

    /// Fill at most max_buffers, always completing a previously timed-out mix
    /// first. PI/decoder timeouts are retried through this same entry point.
    /// Call regularly outside interrupts, normally after graphics submission.
    pub fn update(self: *Player, options: UpdateOptions) !u8 {
        return playback.update(self, options);
    }

    fn finishMix(self: *Player, attempts: u32) !void {
        try playback.finishMix(self, attempts);
    }
    fn editable(self: *Player) !void {
        if (!self.mixer_initialized) return error.PlayerStopped;
        if (self.pending_commit or self.mixer.decoder.pending) return error.MixerBusy;
    }

    /// Drain playback before destroying the shared runtime. Output timeouts
    /// retain allocation and permit retry. A pending decoder/refill must first
    /// be completed by update, which retains the stream's borrowed workspace.
    pub fn deinit(self: *Player, allocator: std.mem.Allocator, max_attempts: u32) !void {
        if (self.pending_commit) try self.finishMix(max_attempts);
        if (self.mixer_initialized) {
            try self.mixer.deinit();
            self.mixer_initialized = false;
            self.pool.widths = @splat(0);
        }
        try self.output.deinit(allocator, max_attempts);
        self.* = undefined;
    }
};

fn gains(options: PlayOptions) ![2]f32 {
    if (!std.math.isFinite(options.volume) or options.volume < 0 or options.volume > 1) return error.InvalidVolume;
    if (!std.math.isFinite(options.pan) or options.pan < -1 or options.pan > 1) return error.InvalidPan;
    return .{ options.volume * @min(1, 1 - options.pan), options.volume * @min(1, 1 + options.pan) };
}

test "pan preserves center volume and rejects invalid settings before playback" {
    try std.testing.expectEqual([2]f32{ 0.7, 0.7 }, try gains(.{ .volume = 0.7 }));
    try std.testing.expectEqual([2]f32{ 1, 0 }, try gains(.{ .pan = -1 }));
    try std.testing.expectEqual([2]f32{ 0, 1 }, try gains(.{ .pan = 1 }));
    try std.testing.expectError(error.InvalidPan, gains(.{ .pan = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidVolume, gains(.{ .volume = 2 }));
}
test {
    _ = pool_api;
    _ = playback;
}
