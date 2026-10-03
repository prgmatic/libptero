const std = @import("std");
const n64 = @import("n64");
const testing = @import("assert.zig");
const runner = @import("runner.zig");
const assets = @import("audio_test_assets");
const timeout = 1_000_000;
var runtime: n64.rsp.Runtime = undefined;
var mixer: n64.audio.mixer.Mixer = undefined;
var stream: n64.audio.Stream = undefined;
var second: n64.audio.Stream = undefined;
var storage: [384]u8 align(16) = undefined;
var second_storage: [384]u8 align(16) = undefined;
var output: [64]i16 align(16) = undefined;
var expected: [12][64]i16 align(16) = undefined;
pub const tests = [_]runner.Test{
    .{ .name = "Stream PCM: mono8 matches resident output, ramps, rates and seeks", .run = mono8 },
    .{ .name = "Stream PCM: mono16 matches resident output, ramps, rates and seeks", .run = mono16 },
    .{ .name = "Stream PCM: stereo8 matches resident output, ramps, rates and seeks", .run = stereo8 },
    .{ .name = "Stream PCM: stereo16 matches resident output, ramps, rates and seeks", .run = stereo16 },
    .{ .name = "Stream PCM: EOF silence and voice release", .run = finite },
    .{ .name = "Stream PCM: partial tail loops match resident PCM", .run = tailLoop },
    .{ .name = "Stream PCM: independent voices and retry after PI timeout", .run = independent },
};
fn mono8() !void {
    try compare(assets.mono8, assets.mono8_stream);
}
fn mono16() !void {
    try compare(assets.mono16, assets.mono16_stream);
}
fn stereo8() !void {
    try compare(assets.stereo8, assets.stereo8_stream);
}
fn stereo16() !void {
    try compare(assets.stereo16, assets.stereo16_stream);
}
fn resetFilter() void {
    const state = n64.rsp.overlayState(&mixer.overlay);
    @memset(state, 0);
    n64.rsp.writebackOverlayState(&mixer.overlay);
}
fn controls(batch: usize, sample: n64.audio.Sample, streamed: bool, frequency: u32) !void {
    if (batch == 4) try mixer.setFrequency(0, frequency + 137, sample.frequency);
    if (batch == 6) try mixer.setVolume(0, 0.25, -0.5);
    if (batch == 8) {
        if (streamed) try mixer.seek(0, 48) else mixer.settings.channels[0].position = 48 * sample.bytesPerFrame() << 12;
    }
}
fn compare(sample: n64.audio.Sample, source: n64.audio.StreamSample) !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 32);
    defer mixer.deinit() catch {};
    for ([_]u32{ sample.frequency / 2, sample.frequency, sample.frequency * 2 }) |frequency| {
        resetFilter();
        try mixer.play(0, sample, sample.frequency);
        try mixer.setFrequency(0, frequency, sample.frequency);
        for (&expected, 0..) |*buffer, batch| {
            try controls(batch, sample, false, frequency);
            try mixer.submit(buffer);
            try mixer.wait(timeout);
        }
        try mixer.stop(0);
        resetFilter();
        stream = try .init(source, &storage);
        try mixer.playStream(0, &stream, sample.frequency);
        try mixer.setFrequency(0, frequency, sample.frequency);
        for (&expected, 0..) |*buffer, batch| {
            try controls(batch, sample, true, frequency);
            try mixer.submit(&output);
            try mixer.wait(timeout);
            for (output, buffer) |actual, value| try testing.expectEqual(value, actual);
        }
        try testing.expect(stream.refills > 1);
        try mixer.stop(0);
        try testing.expect(!stream.attached);
    }
}
fn finite() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 8);
    defer mixer.deinit() catch {};
    try mixer.play(0, assets.finite, assets.finite.frequency);
    mixer.settings.channels[0].position = 48 * 2 << 12;
    try mixer.submit(&expected[0]);
    try mixer.wait(timeout);
    resetFilter();
    stream = try .init(assets.finite_stream, &storage);
    try mixer.playStream(0, &stream, assets.finite.frequency);
    try mixer.seek(0, 48);
    try mixer.submit(&output);
    try mixer.wait(timeout);
    for (output, expected[0]) |actual, value| try testing.expectEqual(value, actual);
    try testing.expect(!stream.attached);
    try testing.expectEqual(@as(u32, 64), stream.positionFrames());
    try testing.expectEqual(@as(u32, 0), mixer.settings.channels[0].address);
}
fn independent() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 8);
    defer mixer.deinit() catch {};
    try mixer.play(0, assets.mono16, assets.mono16.frequency);
    try mixer.play(2, assets.mono16, assets.mono16.frequency);
    try mixer.setVolume(0, 0.25, 0.25);
    try mixer.setVolume(2, 0.125, 0.125);
    mixer.settings.channels[2].position = 11 * 2 << 12;
    try mixer.submit(&expected[0]);
    try mixer.wait(timeout);
    try mixer.stop(0);
    try mixer.stop(2);
    resetFilter();
    stream = try .init(assets.mono16_stream, &storage);
    second = try .init(assets.mono16_stream, &second_storage);
    try mixer.playStream(0, &stream, assets.mono16.frequency);
    try mixer.playStream(2, &second, assets.mono16.frequency);
    try mixer.seek(2, 11);
    try mixer.setVolume(0, 0.25, 0.25);
    try mixer.setVolume(2, 0.125, 0.125);
    mixer.stream_read_attempts = 0;
    mixer.submit(&output) catch |err| try testing.expect(err == error.PiTimeout);
    try testing.expect(mixer.pending_output == null);
    try testing.expect(stream.reader.destination != null);
    try stream.reader.wait(timeout);
    mixer.stream_read_attempts = timeout;
    try mixer.submit(&output);
    try mixer.wait(timeout);
    for (output, expected[0]) |actual, value| try testing.expectEqual(value, actual);
    try testing.expectEqual(@as(u32, 32), stream.positionFrames());
    try testing.expectEqual(@as(u32, 43), second.positionFrames());
    try mixer.stop(0);
    try testing.expect(second.attached);
    try mixer.stop(2);
}

var tail_pcm: [128 + 64]u8 align(16) = undefined;
fn tailLoop() !void {
    @memcpy(tail_pcm[0..128], assets.mono16.data[0..128]);
    for (tail_pcm[128..], 0..) |*byte, index| byte.* = tail_pcm[114 + index % 14];
    var resident = assets.mono16;
    resident.data = &tail_pcm;
    resident.loop_frames = 7;
    var source = assets.mono16_stream;
    source.loop_frames = 7;
    try compare(resident, source);
}
