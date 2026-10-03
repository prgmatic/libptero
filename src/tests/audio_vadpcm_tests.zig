const std = @import("std");
const n64 = @import("n64");
const check = @import("assert.zig");
const runner = @import("runner.zig");
const codec = n64.audio.vadpcm;
const assets = @import("audio_test_assets");
const timeout = 1_000_000;
var runtime: n64.rsp.Runtime = undefined;
var decoder: codec.Decoder = .{};
var workspace: [codec.workspace_bytes + 16]u8 align(16) = undefined;
var state: codec.State align(16) = undefined;
var book: codec.Codebook align(16) = undefined;
var expected: [1504]i16 = undefined;
var original: [846]u8 = undefined;
var software_state: codec.State align(16) = undefined;
var mixer: n64.audio.mixer.Mixer = undefined;
var stream: n64.audio.Stream = undefined;
var storage: [512]u8 align(16) = undefined;
var second_storage: [512]u8 align(16) = undefined;
var second_stream: n64.audio.Stream = undefined;
var mixed: [64]i16 align(16) = undefined;
var reference_mix: [4][64]i16 align(16) = undefined;
var reference_pcm: [1280 * 2 + 32]i16 align(16) = undefined;
var reader: n64.rom.Reader = .{};

pub const tests = [_]runner.Test{
    .{ .name = "VADPCM: mono decoder, all predictors, scales and maximum batch", .run = mono },
    .{ .name = "VADPCM: stereo decoder, histories and maximum batch", .run = stereo },
    .{ .name = "VADPCM: state copy and clear commands", .run = stateCommands },
    .{ .name = "VADPCM: generated PCM8/16 assets, looping and EOF", .run = generated },
    .{ .name = "VADPCM: checkpoint seeks, fractional rates and tail loops", .run = seekAndLoop },
    .{ .name = "VADPCM: independent histories and retained PI timeout", .run = independent },
};

fn mono() !void {
    try rawDecode(1);
}
fn stereo() !void {
    try rawDecode(2);
}
fn rawDecode(channels: u2) !void {
    runtime.init();
    defer runtime.deinit();
    decoder = .{};
    decoder.init();
    defer decoder.deinit() catch {};
    for (&book, 0..) |*value, i| value.* = @intCast(@as(i32, @intCast(i % 17)) * 53 - 400);
    for ([_]u32{ 1, 2, 7, 16, codec.max_channel_blocks / @as(u32, channels) }) |blocks| for ([_]usize{ 0, 2, 4, 6 }) |offset| {
        @memset(&workspace, 0x55);
        const target: []align(2) u8 = @alignCast(workspace[offset..]);
        for (&state, 0..) |*value, i| value.* = @intCast(i * 70 + 13);
        software_state = state;
        const input = try codec.inputSlice(target, blocks, channels);
        for (0..input.len / 9) |block| {
            input[block * 9] = @intCast((block % 13) * 16 + block % 4);
            for (input[block * 9 + 1 ..][0..8], 0..) |*byte, i| byte.* = @truncate(block * 37 + i * 23);
        }
        @memcpy(original[0..input.len], input);
        decodeReference(original[0..input.len], &book, &software_state, channels, expected[0 .. blocks * 16 * channels]);
        try decoder.submit(target, &state, &book, blocks, channels);
        try decoder.wait(timeout);
        const output = std.mem.bytesAsSlice(i16, target[0..try codec.outputBytes(blocks, channels)]);
        for (output, expected[0..output.len]) |actual, value| try check.expectEqual(value, actual);
        for (state, software_state) |actual, value| try check.expectEqual(value, actual);
        for (workspace[0..offset]) |byte| try check.expectEqual(@as(u8, 0x55), byte);
        const end = std.mem.alignForward(usize, offset + try codec.outputBytes(blocks, channels), 8);
        for (workspace[end..][0..8]) |byte| try check.expectEqual(@as(u8, 0x55), byte);
    };
}
fn stateCommands() !void {
    runtime.init();
    defer runtime.deinit();
    decoder = .{};
    decoder.init();
    defer decoder.deinit() catch {};
    for (&software_state, 0..) |*value, i| value.* = @intCast(i * 51);
    try decoder.submitState(&state, &software_state);
    try decoder.wait(timeout);
    for (state, software_state) |actual, value| try check.expectEqual(value, actual);
    try decoder.submitState(&state, null);
    try decoder.wait(timeout);
    for (state) |value| try check.expectEqual(@as(i16, 0), value);
}

// Independent scalar reconstruction of the order-two decoder documented by
// libdragon's vendored codec/decode.c. Use wide sums to avoid host C overflow.
fn decodeReference(input: []const u8, codebook: *const codec.Codebook, history: *codec.State, channels: u2, output: []i16) void {
    for (0..input.len / (9 * @as(usize, channels))) |block| for (0..channels) |channel| {
        const frame = input[(block * channels + channel) * 9 ..][0..9];
        const predictor: usize = channel * 64 + (frame[0] & 15) * 16;
        const scale: u4 = @intCast(frame[0] >> 4);
        for (0..2) |half| {
            var residuals: [8]i32 = undefined;
            for (&residuals, 0..) |*residual, i| {
                const nibble = if (i % 2 == 0) frame[1 + half * 4 + i / 2] >> 4 else frame[1 + half * 4 + i / 2] & 15;
                const signed: i32 = @as(i32, nibble) - (if (nibble > 7) @as(i32, 16) else 0);
                residual.* = signed * (@as(i32, 1) << scale);
            }
            var result: [8]i16 = undefined;
            for (&result, 0..) |*value, i| {
                var sum: i64 = @as(i64, history[channel * 8 + 6]) * codebook[predictor + i] + @as(i64, history[channel * 8 + 7]) * codebook[predictor + 8 + i];
                sum += @as(i64, residuals[i]) * 2048;
                for (0..i) |j| sum += @as(i64, residuals[j]) * codebook[predictor + 8 + i - 1 - j];
                value.* = @intCast(std.math.clamp(sum >> 11, -32768, 32767));
                output[(block * 16 + half * 8 + i) * channels + channel] = value.*;
            }
            @memcpy(history[channel * 8 ..][0..8], &result);
        }
    };
}

fn loadReference(sample: n64.audio.StreamSample) !void {
    const blocks = (sample.frames + 15) / 16;
    software_state = @splat(0);
    var block: u32 = 0;
    while (block < blocks) {
        const count = @min(blocks - block, 846 / (9 * @as(u32, sample.channels)));
        const input = original[0 .. count * 9 * sample.channels];
        try reader.read(sample.asset, block * 9 * sample.channels, input, timeout);
        decodeReference(input, sample.vadpcm.?.codebook, &software_state, sample.channels, reference_pcm[block * 16 * sample.channels ..][0 .. count * 16 * sample.channels]);
        block += count;
    }
    const logical = sample.frames * @as(u32, sample.channels);
    const loop = sample.loop_frames * @as(u32, sample.channels);
    for (reference_pcm[logical..][0..32], 0..) |*value, i| value.* = if (loop == 0) 0 else reference_pcm[logical - loop + i % loop];
}
fn steady() void {
    const volumes = n64.rsp.overlayState(&mixer.overlay);
    @memset(volumes, 0);
    std.mem.writeInt(u16, volumes[0..2], 32766, .big);
    if (stream.sample.channels == 1) std.mem.writeInt(u16, volumes[64..66], 32766, .big) else std.mem.writeInt(u16, volumes[66..68], 32766, .big);
    n64.rsp.writebackOverlayState(&mixer.overlay);
}
fn generated() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 32);
    defer mixer.deinit() catch {};
    for ([_]n64.audio.StreamSample{ assets.mono8_vadpcm, assets.mono16_vadpcm, assets.stereo8_vadpcm, assets.stereo16_vadpcm, assets.finite_vadpcm }) |sample| {
        try loadReference(sample);
        stream = try .init(sample, &storage);
        try mixer.playStream(0, &stream, sample.frequency);
        steady();
        for (0..4) |batch| {
            try mixer.submit(&mixed);
            try mixer.wait(timeout);
            for (0..32) |frame| {
                const absolute = batch * 32 + frame;
                const position = absolute % sample.frames;
                for (0..2) |channel| {
                    const value = if (sample.loop_frames == 0 and absolute >= sample.frames) @as(i16, 0) else reference_pcm[position * sample.channels + (if (sample.channels == 1) 0 else channel)];
                    try check.expectEqual(value, mixed[frame * 2 + channel]);
                }
            }
        }
        if (sample.loop_frames == 0) try check.expect(!stream.attached) else try mixer.stop(0);
    }
}
fn seekAndLoop() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 32);
    defer mixer.deinit() catch {};
    var sample = assets.long_vadpcm;
    sample.loop_frames = 37;
    try loadReference(sample);
    stream = try .init(sample, &storage);
    for ([_]u32{ 0, 1009, 1024, 1031, 1183, 1200 }) |position| try comparePlayback(sample, position, sample.frequency);
    try comparePlayback(sample, 1017, sample.frequency / 2 + 137);
    try mixer.stop(0);
}
fn comparePlayback(sample: n64.audio.StreamSample, position: u32, frequency: u32) !void {
    const resident: n64.audio.Sample = .{
        .data = @alignCast(std.mem.sliceAsBytes(reference_pcm[0 .. sample.frames * sample.channels + 32])),
        .frequency = sample.frequency,
        .frames = sample.frames,
        .channels = sample.channels,
        .format = .pcm16,
        .loop_frames = sample.loop_frames,
    };
    try mixer.stop(0);
    try mixer.play(0, resident, sample.frequency);
    steady();
    mixer.settings.channels[0].position = position * resident.bytesPerFrame() << 12;
    try mixer.setFrequency(0, frequency, sample.frequency);
    for (&reference_mix) |*buffer| {
        try mixer.submit(buffer);
        try mixer.wait(timeout);
    }
    try mixer.stop(0);
    try mixer.playStream(0, &stream, sample.frequency);
    steady();
    try mixer.seek(0, position);
    try mixer.setFrequency(0, frequency, sample.frequency);
    for (&reference_mix) |*buffer| {
        try mixer.submit(&mixed);
        try mixer.wait(timeout);
        for (mixed, buffer) |actual, expected_value| try check.expectEqual(expected_value, actual);
    }
}

fn independent() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 32);
    defer mixer.deinit() catch {};
    const sample = assets.stereo16_vadpcm;
    try loadReference(sample);
    stream = try .init(sample, &storage);
    second_stream = try .init(sample, &second_storage);
    const resident: n64.audio.Sample = .{
        .data = @alignCast(std.mem.sliceAsBytes(reference_pcm[0 .. sample.frames * sample.channels + 32])),
        .frequency = sample.frequency,
        .frames = sample.frames,
        .channels = 2,
        .format = .pcm16,
        .loop_frames = sample.frames,
    };
    try mixer.play(0, resident, sample.frequency);
    try mixer.play(2, resident, sample.frequency);
    mixer.settings.channels[2].position = 16 * 4 << 12;
    twoSteady();
    for (&reference_mix) |*buffer| {
        try mixer.submit(buffer);
        try mixer.wait(timeout);
    }
    try mixer.stop(0);
    try mixer.stop(2);
    try mixer.playStream(0, &stream, sample.frequency);
    try mixer.playStream(2, &second_stream, sample.frequency);
    try mixer.seek(2, 16);
    twoSteady();
    mixer.stream_read_attempts = 0;
    if (mixer.submit(&mixed)) |_| return error.ExpectedPiTimeout else |err| try check.expect(err == error.PiTimeout);
    try check.expect(stream.reader.destination != null and mixer.pending_output == null);
    if (mixer.stop(0)) |_| return error.ExpectedStreamBusy else |err| try check.expect(err == error.StreamBusy);
    try stream.reader.wait(timeout);
    mixer.stream_read_attempts = timeout;
    for (&reference_mix) |*buffer| {
        try mixer.submit(&mixed);
        try mixer.wait(timeout);
        for (mixed, buffer) |actual, value| try check.expectEqual(value, actual);
    }
    try check.expect(stream.cursor != second_stream.cursor);
    try mixer.stop(0);
    try mixer.stop(2);
}
fn twoSteady() void {
    steady();
    const volumes = n64.rsp.overlayState(&mixer.overlay);
    std.mem.writeInt(u16, volumes[4..6], 32766, .big);
    std.mem.writeInt(u16, volumes[70..72], 32766, .big);
    n64.rsp.writebackOverlayState(&mixer.overlay);
}
