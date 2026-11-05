//! Audio overlay workloads: VADPCM decode (checked against the vendored
//! reference decoder) and the PCM mixer.
const std = @import("std");
const n64 = @import("n64");
const audio_compiler = @import("audio_compiler");
const workloads = @import("workloads.zig");

const programs = n64.rsp.programs;
const Harness = workloads.Harness;
const Mixer = n64.audio.Mixer;
const vadpcm = n64.audio.vadpcm;

pub const all = [_]workloads.Workload{
    .{
        .name = "vadpcm_mono",
        .overlay = .audio_vadpcm,
        .description = "decode 64 mono VADPCM frames, compared with the reference decoder",
        .run = vadpcmMono,
        .symbols = workloads.symbolTable(.{ programs.command_dispatcher_symbols, programs.audio_vadpcm_symbols }),
    },
    .{
        .name = "vadpcm_stereo_batches",
        .overlay = .audio_vadpcm,
        .description = "two 24-block stereo batches joined by setState, compared with the reference decoder",
        .run = vadpcmStereo,
        .symbols = workloads.symbolTable(.{ programs.command_dispatcher_symbols, programs.audio_vadpcm_symbols }),
    },
    .{
        .name = "mixer_4voice",
        .overlay = .audio_mixer,
        .description = "mix 8-bit, 16-bit, stereo, and resampled voices into 512 stereo frames",
        .run = mixer,
        .symbols = workloads.symbolTable(.{ programs.command_dispatcher_symbols, programs.audio_mixer_symbols }),
    },
};

const vadpcm_overlay_id = 3;
const mixer_overlay_id = 4;
const vadpcm_blocks = 64;

const Vector = extern struct { values: [8]i16 align(16) };
extern fn vadpcm_decode(c_int, c_int, [*]const Vector, *Vector, usize, [*]i16, [*]const u8) c_int;

/// Deterministic test tone: two summed sines with a slow amplitude ramp.
fn tone(samples: []i16) void {
    for (samples, 0..) |*sample, index| {
        const t: f32 = @floatFromInt(index);
        const value = @sin(t * 0.071) * 9000 + @sin(t * 0.33) * 3000 * (t / @as(f32, @floatFromInt(samples.len)));
        sample.* = @intFromFloat(value);
    }
}

pub const Encoded = struct {
    frames: []u8,
    codebook: [128]i16,
    pcm: []i16,
    channels: u2,

    pub fn deinit(self: Encoded, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        allocator.free(self.pcm);
    }
};

/// Encodes `blocks` VADPCM blocks of an interleaved test tone per channel.
pub fn encodeTone(allocator: std.mem.Allocator, blocks: usize, channels: u2) !Encoded {
    const frames = blocks * 16;
    const mono = try allocator.alloc(i16, frames * 2);
    defer allocator.free(mono);
    tone(mono);
    const pcm = try allocator.alloc(i16, frames * channels);
    errdefer allocator.free(pcm);
    for (pcm, 0..) |*sample, index| sample.* = mono[index / channels + (index % channels) * frames / 2];
    const little = try allocator.alloc(u8, pcm.len * 2);
    defer allocator.free(little);
    for (pcm, 0..) |sample, index| std.mem.writeInt(i16, little[index * 2 ..][0..2], sample, .little);
    const encoded = try audio_compiler.vadpcm.encode(allocator, .{ .data = little, .frequency = 22050, .channels = channels, .bits = 16, .frames = @intCast(frames) });
    return .{ .frames = encoded.data, .codebook = encoded.codebook, .pcm = pcm, .channels = channels };
}

/// Decodes all blocks with the reference decoder, interleaving channels.
pub fn referenceDecode(allocator: std.mem.Allocator, encoded: Encoded, blocks: usize) ![]i16 {
    const output = try allocator.alloc(i16, blocks * 16 * encoded.channels);
    errdefer allocator.free(output);
    const channel_frames = try allocator.alloc(u8, blocks * 9);
    defer allocator.free(channel_frames);
    var decoded: [16]i16 = undefined;
    for (0..encoded.channels) |channel| {
        var book: [8]Vector = undefined;
        for (&book, 0..) |*vector, index| vector.values = encoded.codebook[channel * 64 + index * 8 ..][0..8].*;
        var state: Vector = .{ .values = @splat(0) };
        for (0..blocks) |block| {
            @memcpy(channel_frames[0..9], encoded.frames[(block * encoded.channels + channel) * 9 ..][0..9]);
            if (vadpcm_decode(4, 2, &book, &state, 1, &decoded, channel_frames.ptr) != 0) return error.ReferenceDecodeFailed;
            for (decoded, 0..) |sample, index| output[(block * 16 + index) * encoded.channels + channel] = sample;
        }
    }
    return output;
}

fn writeBigEndian(destination: []u8, values: []const i16) void {
    for (values, 0..) |value, index| std.mem.writeInt(i16, destination[index * 2 ..][0..2], value, .big);
}

const Decoder = struct {
    overlay: @import("rsp_interp").Session.Overlay,
    workspace: u32,
    book: u32,
};

fn setUpDecoder(h: *Harness, encoded: Encoded) !Decoder {
    const s = &h.session;
    const overlay = try s.registerOverlay(programs.audio_vadpcm, vadpcm_overlay_id);
    // Codebook bank zero must have address bit 7 clear for stereo switching.
    const book = try s.allocate(@sizeOf(vadpcm.Codebook), 256);
    writeBigEndian(try s.bytes(book, @sizeOf(vadpcm.Codebook)), &encoded.codebook);
    return .{ .overlay = overlay, .workspace = try s.allocate(vadpcm.workspace_bytes, 16), .book = book };
}

/// Queues one decode of `blocks` blocks starting at `first_block`.
fn queueDecode(h: *Harness, writer: *@import("rsp_interp").Session.CommandWriter, d: Decoder, encoded: Encoded, first_block: usize, blocks: u32, state: u32) !void {
    var view: [vadpcm.workspace_bytes]u8 align(16) = undefined;
    const input = try vadpcm.inputSlice(&view, blocks, encoded.channels);
    const offset: u32 = @intCast(@intFromPtr(input.ptr) - @intFromPtr(&view));
    const source = encoded.frames[first_block * 9 * encoded.channels ..][0..input.len];
    @memcpy(try h.session.bytes(d.workspace + offset, input.len), source);
    const stereo: u32 = if (encoded.channels == 2) 0x8000_0000 else 0;
    try writer.overlayCommand(d.overlay, 0, @intCast(d.workspace + offset), &.{ (blocks - 1) << 24 | d.workspace, state | stereo, d.book });
}

fn readOutput(h: *Harness, d: Decoder, destination: []i16) !void {
    const bytes = try h.rdramBytes(d.workspace, destination.len * 2);
    for (destination, 0..) |*sample, index| sample.* = std.mem.readInt(i16, bytes[index * 2 ..][0..2], .big);
}

pub const VadpcmRun = struct { outcome: workloads.Outcome, output: [vadpcm_blocks * 16]i16 };

pub fn runVadpcm(h: *Harness) !VadpcmRun {
    const encoded = try encodeTone(h.allocator, vadpcm_blocks, 1);
    defer encoded.deinit(h.allocator);
    const d = try setUpDecoder(h, encoded);
    const state = try h.session.allocate(@sizeOf(vadpcm.State), 16);
    var writer = try h.session.commands(16);
    try queueDecode(h, &writer, d, encoded, 0, vadpcm_blocks, state);
    const measured = try h.measure(writer);
    var run: VadpcmRun = undefined;
    try readOutput(h, d, &run.output);
    run.outcome = workloads.outcome(measured, &.{ try h.rdramBytes(d.workspace, vadpcm_blocks * 32), try h.rdramBytes(state, @sizeOf(vadpcm.State)) });
    return run;
}

fn vadpcmMono(h: *Harness) !workloads.Outcome {
    return (try runVadpcm(h)).outcome;
}

const stereo_batch_blocks = 24;

pub const StereoRun = struct { outcome: workloads.Outcome, output: [2 * stereo_batch_blocks * 32]i16 };

/// Two consecutive stereo batches; the second continues from a history
/// copied by the setState command, as stream checkpoints do.
pub fn runVadpcmStereo(h: *Harness) !StereoRun {
    const s = &h.session;
    const encoded = try encodeTone(h.allocator, 2 * stereo_batch_blocks, 2);
    defer encoded.deinit(h.allocator);
    const d = try setUpDecoder(h, encoded);
    const first_state = try s.allocate(@sizeOf(vadpcm.State), 16);
    const second_state = try s.allocate(@sizeOf(vadpcm.State), 16);
    var first = try s.commands(16);
    try first.overlayCommand(d.overlay, 1, @intCast(first_state), &.{0});
    try queueDecode(h, &first, d, encoded, 0, stereo_batch_blocks, first_state);
    const measured_first = try h.measure(first);
    var run: StereoRun = undefined;
    try readOutput(h, d, run.output[0 .. stereo_batch_blocks * 32]);
    var second = try s.commands(16);
    try second.overlayCommand(d.overlay, 1, @intCast(second_state), &.{first_state});
    try queueDecode(h, &second, d, encoded, stereo_batch_blocks, stereo_batch_blocks, second_state);
    const measured_second = try h.measure(second);
    try readOutput(h, d, run.output[stereo_batch_blocks * 32 ..]);
    const measured: workloads.Measurement = .{ .instructions = measured_first.instructions + measured_second.instructions, .cycles = measured_first.cycles + measured_second.cycles };
    run.outcome = workloads.outcome(measured, &.{ std.mem.sliceAsBytes(&run.output), try h.rdramBytes(second_state, @sizeOf(vadpcm.State)) });
    return run;
}

fn vadpcmStereo(h: *Harness) !workloads.Outcome {
    return (try runVadpcmStereo(h)).outcome;
}

const Channel = struct { bits: u8, stereo: bool, frequency: u32, loop: bool, left: u16, right: u16 };

/// Voices by mixer slot. A stereo voice also occupies the following slot,
/// which must stay empty, exactly as `Mixer.play` arranges it.
const mixer_channels = [_]?Channel{
    .{ .bits = 8, .stereo = false, .frequency = 22050, .loop = true, .left = 0x6000, .right = 0x2000 },
    .{ .bits = 16, .stereo = false, .frequency = 44100, .loop = false, .left = 0x4000, .right = 0x4000 },
    .{ .bits = 16, .stereo = true, .frequency = 32000, .loop = true, .left = 0x7fff, .right = 0x7fff },
    null,
    .{ .bits = 8, .stereo = false, .frequency = 11025, .loop = false, .left = 0x3000, .right = 0x5000 },
};
const output_frequency = 44100;
pub const mixer_frames = 512;
const sample_frames = 1024;

fn bytesPerFrame(channel: Channel) u32 {
    return @as(u32, channel.bits / 8) * (if (channel.stereo) @as(u32, 2) else 1);
}

/// Writes one channel's sample data (plus the mixer's overread padding).
fn placeSamples(h: *Harness, channel: Channel, seed: usize) !u32 {
    const len = sample_frames * bytesPerFrame(channel);
    const address = try h.session.allocate(len + Mixer.sample_overread, 8);
    const data = try h.session.bytes(address, len + Mixer.sample_overread);
    var pcm: [sample_frames * 2]i16 = undefined;
    tone(&pcm);
    for (0..len / (channel.bits / 8)) |index| {
        const sample = pcm[(index + seed * 37) % pcm.len];
        if (channel.bits == 8) data[index] = @bitCast(@as(i8, @intCast(sample >> 8))) else std.mem.writeInt(i16, data[index * 2 ..][0..2], sample, .big);
    }
    if (channel.loop) for (data[len..], 0..) |*byte, index| {
        byte.* = data[index];
    };
    return address;
}

const settings_volumes = 0;

/// Volume layout from `Mixer.setVolume`: a stereo voice keeps its left gain
/// in its own slot and its right gain in the secondary slot.
fn writeVolumes(bytes: []u8, index: usize, channel: Channel) void {
    const right_slot = if (channel.stereo) index + 1 else index;
    std.mem.writeInt(u16, bytes[settings_volumes + index * 2 ..][0..2], channel.left, .big);
    std.mem.writeInt(u16, bytes[settings_volumes + Mixer.max_channels * 2 + right_slot * 2 ..][0..2], channel.right, .big);
}
const settings_channels = 2 * Mixer.max_channels * 2;
const channel_stride = 24;

/// Fills one voice's volumes and channel record like `Mixer.play`.
fn writeChannel(h: *Harness, bytes: []u8, index: usize, channel: Channel) !void {
    writeVolumes(bytes, index, channel);
    const length = sample_frames * bytesPerFrame(channel) << Mixer.position_fraction_bits;
    const flags = @as(u32, if (channel.bits == 16) Mixer.Channel.pcm16 else 0) | @as(u32, if (channel.stereo) Mixer.Channel.stereo else 0);
    const fields = [6]u32{
        0,
        try Mixer.frequencyStep(channel.frequency, output_frequency, bytesPerFrame(channel)),
        length,
        if (channel.loop) length else 0,
        try placeSamples(h, channel, index),
        flags,
    };
    for (fields, 0..) |field, word| std.mem.writeInt(u32, bytes[settings_channels + index * channel_stride + word * 4 ..][0..4], field, .big);
}

pub const MixerRun = struct { outcome: workloads.Outcome, settings: u32, output: u32 };

pub fn runMixer(h: *Harness) !MixerRun {
    const s = &h.session;
    const overlay = try s.registerOverlay(programs.audio_mixer, mixer_overlay_id);
    const settings = try s.allocate(@sizeOf(Mixer.Settings), 16);
    const bytes = try s.bytes(settings, @sizeOf(Mixer.Settings));
    for (mixer_channels, 0..) |slot, index| {
        const channel = slot orelse continue;
        try writeChannel(h, bytes, index, channel);
    }
    const output = try s.allocate(mixer_frames * 4 + 8, 16);
    var writer = try s.commands(16);
    try writer.overlayCommand(overlay, 0, 0xffff, &.{ mixer_frames << 16 | mixer_channels.len, output, settings });
    const measured = try h.measure(writer);
    const parts = [_][]const u8{ try h.rdramBytes(output, mixer_frames * 4), try h.rdramBytes(settings, @sizeOf(Mixer.Settings)) };
    return .{ .outcome = workloads.outcome(measured, &parts), .settings = settings, .output = output };
}

fn mixer(h: *Harness) !workloads.Outcome {
    return (try runMixer(h)).outcome;
}

test "RSP VADPCM decode matches the reference decoder sample for sample" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    const run = try runVadpcm(&h);
    const encoded = try encodeTone(std.testing.allocator, vadpcm_blocks, 1);
    defer encoded.deinit(std.testing.allocator);
    const expected = try referenceDecode(std.testing.allocator, encoded, vadpcm_blocks);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(i16, expected, &run.output);
    // The encoder is lossy but must track the tone closely.
    var error_sum: u64 = 0;
    for (encoded.pcm, expected) |original, decoded| error_sum += @abs(@as(i32, original) - decoded);
    try std.testing.expect(error_sum / encoded.pcm.len < 400);
}

test "stereo batches joined by setState match a continuous reference decode" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    const run = try runVadpcmStereo(&h);
    const encoded = try encodeTone(std.testing.allocator, 2 * stereo_batch_blocks, 2);
    defer encoded.deinit(std.testing.allocator);
    const expected = try referenceDecode(std.testing.allocator, encoded, 2 * stereo_batch_blocks);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(i16, expected, &run.output);
}

test "mixer advances every channel and produces audible stereo output" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    const run = try runMixer(&h);
    const bytes = try h.rdramBytes(run.settings, @sizeOf(Mixer.Settings));
    for (mixer_channels, 0..) |slot, index| {
        const channel = slot orelse continue;
        const position = std.mem.readInt(u32, bytes[settings_channels + index * channel_stride ..][0..4], .big);
        const step = try Mixer.frequencyStep(channel.frequency, output_frequency, bytesPerFrame(channel));
        try std.testing.expectEqual(step * mixer_frames, position);
    }
    const output = try h.rdramBytes(run.output, mixer_frames * 4);
    var peak: u32 = 0;
    for (0..mixer_frames * 2) |sample| peak = @max(peak, @abs(@as(i32, std.mem.readInt(i16, output[sample * 2 ..][0..2], .big))));
    try std.testing.expect(peak > 1000);
}
