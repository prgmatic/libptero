const std = @import("std");
const rsp = @import("../rsp/rsp.zig");
const cache = @import("../cpu/cache.zig");
const Sample = @import("sample.zig").Sample;
const Stream = @import("stream.zig").Stream;

pub const max_channels = 32;
pub const position_fraction_bits = 12;
pub const sample_overread = 64;

/// libdragon's PCM command ABI. Positions, lengths, and steps are byte offsets
/// with twelve fractional bits. Sample data must include 64 readable bytes
/// after its logical end, filled with silence or the corresponding loop data.
pub const Channel = extern struct {
    position: u32 = 0,
    step: u32 = 0,
    length: u32 = 0,
    loop_length: u32 = 0,
    address: u32 = 0,
    flags: u32 = 0,

    pub const pcm16 = 1 << 2;
    pub const stereo = 1 << 3;
};

pub const Settings = extern struct {
    volume_left: [max_channels]u16 = @splat(0),
    volume_right: [max_channels]u16 = @splat(0),
    channels: [max_channels]Channel = @splat(.{}),
};

/// RSP PCM mixer with libdragon's instruction-identical 8/32-channel cores.
/// Borrows an initialized resident Runtime. Keep this object at a stable
/// address and complete submissions before changing settings or sample data.
/// Only one high-priority queue may be outstanding across the runtime.
pub const Mixer = struct {
    decoder: @import("vadpcm.zig").Decoder = .{},
    overlay: rsp.Overlay,
    queue: rsp.Queue,
    settings: Settings align(16),
    configured_channels: u16,
    global_volume: u16,
    pending_output: ?[]align(4) i16,
    runtime: *rsp.Runtime,
    stereo_secondary: [max_channels]bool,
    streams: [max_channels]?*Stream,
    /// Bounded PI polling budget for stream refill. Retry a timeout by calling
    /// submit again; complete stream.reader.wait before releasing its storage.
    stream_read_attempts: u32 = 1_000_000,

    pub fn init(self: *Mixer, runtime: *rsp.Runtime, channel_count: u16) !void {
        if (channel_count == 0 or channel_count > max_channels) return error.InvalidChannelCount;
        if (runtime.mixer_attached) return error.MixerAlreadyInitialized;
        self.decoder = .{};
        self.overlay.init(rsp.programs.audio_mixer);
        _ = rsp.registerOverlay(&self.overlay);
        self.queue.init(.high);
        self.settings = .{};
        self.configured_channels = channel_count;
        self.global_volume = 65535;
        self.pending_output = null;
        self.runtime = runtime;
        self.stereo_secondary = @splat(false);
        self.streams = @splat(null);
        self.stream_read_attempts = 1_000_000;
        runtime.mixer_attached = true;
    }

    fn editable(self: *Mixer, channel: usize) !void {
        if (self.pending_output != null or self.decoder.pending) return error.MixerBusy;
        if (channel >= self.configured_channels) return error.InvalidChannel;
        if (self.stereo_secondary[channel]) return error.StereoSecondaryChannel;
    }

    /// Start a resident asset from frame zero. Stereo consumes two slots.
    /// The generated asset determines looping so its DMA overread is correct.
    pub fn play(self: *Mixer, channel: usize, sample: Sample, output_frequency: u32) !void {
        try self.editable(channel);
        try sample.validate();
        if (sample.channels == 2 and (channel + 1 >= self.configured_channels or self.settings.channels[channel + 1].address != 0)) return error.StereoChannelUnavailable;
        const step = try frequencyStep(sample.frequency, output_frequency, sample.bytesPerFrame());
        try self.stop(channel);
        cache.writebackData(sample.data);
        self.settings.channels[channel] = .{
            .step = step,
            .length = sample.frames * sample.bytesPerFrame() << position_fraction_bits,
            .loop_length = sample.loop_frames * sample.bytesPerFrame() << position_fraction_bits,
            .address = rsp.physicalAddress(@intFromPtr(sample.data.ptr)),
            .flags = (if (sample.format == .pcm16) @as(u32, Channel.pcm16) else 0) | (if (sample.channels == 2) @as(u32, Channel.stereo) else 0),
        };
        if (sample.channels == 2) self.stereo_secondary[channel + 1] = true;
        try self.setVolume(channel, 1, 1);
    }

    pub fn stop(self: *Mixer, channel: usize) !void {
        try self.editable(channel);
        if (self.streams[channel]) |stream| {
            if (stream.reader.destination != null) return error.StreamBusy;
            stream.attached = false;
            self.streams[channel] = null;
        }
        if (self.settings.channels[channel].flags & Channel.stereo != 0) {
            self.stereo_secondary[channel + 1] = false;
            self.settings.volume_right[channel + 1] = 0;
        }
        self.settings.channels[channel] = .{};
        self.settings.volume_left[channel] = 0;
        self.settings.volume_right[channel] = 0;
    }

    /// Attach caller-owned fixed storage. Multiple streams may use the same
    /// ROM sample with independent positions, windows and playback controls.
    pub fn playStream(self: *Mixer, channel: usize, stream: *Stream, output_frequency: u32) !void {
        try self.editable(channel);
        if (stream.attached and self.streams[channel] != stream) return error.StreamAttached;
        if (stream.reader.destination != null) return error.StreamBusy;
        const sample = stream.sample;
        try sample.validate();
        if (sample.channels == 2 and (channel + 1 >= self.configured_channels or self.settings.channels[channel + 1].address != 0)) return error.StereoChannelUnavailable;
        const step = try frequencyStep(sample.frequency, output_frequency, sample.bytesPerFrame());
        try self.stop(channel);
        if (sample.vadpcm != null and !self.decoder.initialized) self.decoder.init();
        stream.cursor = 0;
        stream.window_valid = false;
        stream.attached = true;
        self.streams[channel] = stream;
        self.settings.channels[channel] = .{
            .step = step,
            .address = rsp.physicalAddress(@intFromPtr(stream.storage.ptr)),
            .flags = (if (sample.format == .pcm16) @as(u32, Channel.pcm16) else 0) | (if (sample.channels == 2) @as(u32, Channel.stereo) else 0),
        };
        if (sample.channels == 2) self.stereo_secondary[channel + 1] = true;
        try self.setVolume(channel, 1, 1);
    }

    pub fn seek(self: *Mixer, channel: usize, frame: u32) !void {
        try self.editable(channel);
        const stream = self.streams[channel] orelse return error.NotStreamedChannel;
        stream.attached = false;
        defer stream.attached = true;
        try stream.seek(frame);
    }

    /// Signed volumes preserve libdragon's .15 fixed-point truncation.
    pub fn setVolume(self: *Mixer, channel: usize, left: f32, right: f32) !void {
        try self.editable(channel);
        const l = try volume(left);
        const r = try volume(right);
        self.settings.volume_left[channel] = l;
        if (self.settings.channels[channel].flags & Channel.stereo != 0) {
            self.settings.volume_right[channel] = 0;
            self.settings.volume_left[channel + 1] = 0;
            self.settings.volume_right[channel + 1] = r;
        } else self.settings.volume_right[channel] = r;
    }

    pub fn setFrequency(self: *Mixer, channel: usize, frequency: u32, output_frequency: u32) !void {
        try self.editable(channel);
        const flags = self.settings.channels[channel].flags;
        const bytes: u32 = (if (flags & Channel.pcm16 != 0) @as(u32, 2) else 1) * (if (flags & Channel.stereo != 0) @as(u32, 2) else 1);
        self.settings.channels[channel].step = try frequencyStep(frequency, output_frequency, bytes);
    }

    /// Poll one writable AI buffer, mix at high priority, then enqueue it.
    pub fn tryPlay(self: *Mixer, output: *@import("output.zig").Output, max_attempts: u32) !bool {
        const buffer = (try output.acquire()) orelse return false;
        // A timeout keeps the acquired AI buffer and RSP resources borrowed;
        // callers may retry wait, then commit after it succeeds.
        self.submit(buffer) catch |err| {
            output.cancel();
            return err;
        };
        try self.wait(max_attempts);
        try output.commit();
        return true;
    }

    /// Output is interleaved signed stereo PCM. Its byte address may be 4 mod 8;
    /// the microcode preserves the preceding stereo frame in that case. The
    /// complete DMA/cache lines containing output must belong to the caller,
    /// including up to four trailing bytes written by the final rounded DMA.
    pub fn submit(self: *Mixer, output: []align(4) i16) !void {
        if (self.pending_output != null) return error.MixerBusy;
        if (output.len == 0 or output.len % 2 != 0 or output.len / 2 > 32767) return error.InvalidOutputLength;
        try self.decoder.wait(self.stream_read_attempts);
        for (0..self.configured_channels) |channel| {
            if (self.streams[channel]) |stream| {
                const window = try stream.prepareWithDecoder(@intCast(output.len / 2), self.settings.channels[channel].step, self.stream_read_attempts, &self.decoder);
                self.settings.channels[channel].position = window.position;
                self.settings.channels[channel].length = window.length;
                cache.writebackData(stream.storage);
            }
        }
        cache.writebackData(&self.settings);
        // Preserve neighboring bytes during cache invalidation and the RSP's
        // unaligned-output merge. No cached stores are allowed until wait.
        cache.writebackData(output);
        cache.invalidateData(output);
        self.queue.writeOverlayCommand(&self.overlay, 0, self.global_volume, &.{
            (@as(u32, @intCast(output.len / 2)) << 16) | self.configured_channels,
            rsp.physicalAddress(@intFromPtr(output.ptr)),
            rsp.physicalAddress(@intFromPtr(&self.settings)),
        });
        self.pending_output = output;
        rsp.submitHighPriority(&self.queue);
    }

    /// A timeout retains borrowed buffers for retry. Settings and output become
    /// CPU-visible only after the entire high-priority batch has completed.
    pub fn wait(self: *Mixer, max_attempts: u32) !void {
        const output = self.pending_output orelse return;
        if (!rsp.waitHighPriorityTimeout(&self.queue, max_attempts)) return error.RspTimeout;
        cache.invalidateData(&self.settings);
        cache.invalidateData(output);
        self.pending_output = null;
        for (0..self.configured_channels) |channel| {
            const voice = self.settings.channels[channel];
            if (self.streams[channel]) |stream| {
                if (stream.finish(voice.position)) try self.stop(channel);
                continue;
            }
            if (voice.address != 0 and voice.loop_length == 0 and voice.position >= voice.length) try self.stop(channel);
        }
    }

    pub fn deinit(self: *Mixer) !void {
        if (self.pending_output != null or self.decoder.pending) return error.MixerBusy;
        for (self.streams) |stream| if (stream) |active| {
            if (active.reader.destination != null) return error.StreamBusy;
        };
        for (self.streams) |stream| if (stream) |active| {
            active.attached = false;
        };
        try self.decoder.deinit();
        rsp.unregisterOverlay(&self.overlay);
        self.runtime.mixer_attached = false;
        self.* = undefined;
    }
};

fn frequencyStep(frequency: u32, output_frequency: u32, bytes_per_frame: u32) !u32 {
    if (output_frequency == 0 or frequency > 128000) return error.InvalidFrequency;
    // Truncate the sample ratio to .12 before shifting to byte units, exactly
    // as MIXER_FX64(frequency / sample_rate) << bytes_per_sample_shift does.
    const ratio = @as(f32, @floatFromInt(frequency)) / @as(f32, @floatFromInt(output_frequency));
    const fixed: u32 = @intFromFloat(ratio * 4096);
    return fixed * bytes_per_frame;
}
fn volume(value: f32) !u16 {
    if (!std.math.isFinite(value) or value < -1 or value > 1) return error.InvalidVolume;
    return @bitCast(@as(i16, @intFromFloat(value * 32767)));
}

test "frequency and volume conversions match libdragon truncation" {
    try std.testing.expectEqual(@as(u32, 8192), try frequencyStep(48000, 48000, 2));
    try std.testing.expectEqual(@as(u32, 4096), try frequencyStep(24000, 48000, 2));
    try std.testing.expectEqual(@as(u16, 8191), try volume(0.25));
    try std.testing.expectEqual(@as(u16, 0x8001), try volume(-1));
    try std.testing.expectError(error.InvalidVolume, volume(std.math.nan(f32)));
}

comptime {
    std.debug.assert(@sizeOf(Channel) == 24);
    std.debug.assert(@sizeOf(Settings) == 896);
    std.debug.assert(@offsetOf(Settings, "volume_right") == 64);
    std.debug.assert(@offsetOf(Settings, "channels") == 128);
}

test "native settings preserve the mixer DMA ABI" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Channel));
    try std.testing.expectEqual(@as(usize, 896), @sizeOf(Settings));
    const settings: Settings = .{};
    for (settings.channels) |channel| try std.testing.expectEqual(@as(u32, 0), channel.address);
}
