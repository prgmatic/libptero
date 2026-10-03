const std = @import("std");
const n64 = @import("n64");
const testing = @import("assert.zig");
const runner = @import("runner.zig");
const rsp = n64.rsp;
const Mixer = n64.audio.mixer.Mixer;
const assets = @import("audio_test_assets");
const timeout = 1_000_000;

var runtime: rsp.Runtime = undefined;
var mixer: Mixer = undefined;
var samples: [128]i16 align(16) = undefined;
var output: [128]i16 align(16) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "Audio: high-priority mixer starts idle runtime", .run = idleSilence },
    .{ .name = "Audio: 8-channel PCM core", .run = pcm8 },
    .{ .name = "Audio: 32-channel PCM core and DMA alignment", .run = pcm32 },
    .{ .name = "Audio: generated mono/stereo PCM and loop/resampling", .run = generatedPcm },
    .{ .name = "Audio: end of waveform silence and stop", .run = finitePcm },
    .{ .name = "Audio: AI FIFO drains and releases all buffers", .run = aiOutput },
    .{ .name = "Audio: geometry preemption, clipping and queue refills", .run = geometryPreemption },
    .{ .name = "Stream PCM: geometry preemption, clipping and queue refills", .run = streamedGeometryPreemption },
};

fn idleSilence() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 8);
    defer mixer.deinit() catch {};
    @memset(&output, 12345);
    try mixer.submit(output[0..64]);
    try mixer.wait(timeout);
    for (output[0..64]) |sample| try testing.expectEqual(@as(i16, 0), sample);
    try testing.expect(!rsp.io.status_register_read.signal3);
    try testing.expect(!rsp.io.status_register_read.signal4);
    // The queue is reusable and completed tokens do not leave a stale request.
    for (0..16) |_| {
        try mixer.submit(output[0..64]);
        try mixer.wait(timeout);
    }
}

fn pcm8() !void {
    try verifyPcm(8, false);
}

fn pcm32() !void {
    try verifyPcm(32, true);
}

fn verifyPcm(channel_count: u16, misaligned: bool) !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, channel_count);
    defer mixer.deinit() catch {};
    for (&samples, 0..) |*sample, index| sample.* = if (index < 64) @as(i16, @intCast(index * 32 + 1024)) else 0;
    n64.cache.writebackData(&samples);
    @memset(&output, -12345);
    mixer.settings.channels[0] = .{
        .step = 2 << 12,
        .length = 64 * 2 << 12,
        .address = rsp.physicalAddress(@intFromPtr(&samples)),
        .flags = n64.audio.mixer.Channel.pcm16,
    };
    mixer.settings.volume_left[0] = 32767;
    mixer.settings.volume_right[0] = 32767;
    // Start at the steady-state filtered volume. libdragon's VMUDL global
    // scaling produces 32766 from 32767 * 65535.
    const state = rsp.overlayState(&mixer.overlay);
    std.mem.writeInt(u16, state[0..2], 32766, .big);
    std.mem.writeInt(u16, state[64..66], 32766, .big);
    rsp.writebackOverlayState(&mixer.overlay);
    const first: usize = if (misaligned) 2 else 0;
    const destination: []align(4) i16 = @alignCast(output[first..][0..64]);
    try mixer.submit(destination);
    try mixer.wait(timeout);
    for (0..32) |index| {
        try testing.expectEqual(samples[index], destination[index * 2]);
        try testing.expectEqual(samples[index], destination[index * 2 + 1]);
    }
    try testing.expectEqual(@as(u32, 32 * 2 << 12), mixer.settings.channels[0].position);
    if (misaligned) {
        try testing.expectEqual(@as(i16, -12345), output[0]);
        try testing.expectEqual(@as(i16, -12345), output[1]);
    }
    // RSP DMA rounds the final transfer up to eight bytes, just as libdragon
    // does. The caller owns that padding; the next DMA line must stay intact.
    const guard = std.mem.alignForward(usize, (first + 64) * @sizeOf(i16), 8) / @sizeOf(i16);
    try testing.expectEqual(@as(i16, -12345), output[guard]);
}

fn setSteadyVolume(channel: usize, left: u16, right: u16) void {
    const state = rsp.overlayState(&mixer.overlay);
    std.mem.writeInt(u16, state[channel * 2 ..][0..2], left, .big);
    std.mem.writeInt(u16, state[64 + channel * 2 ..][0..2], right, .big);
    rsp.writebackOverlayState(&mixer.overlay);
}

fn generatedPcm() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 32);
    defer mixer.deinit() catch {};
    for ([_]n64.audio.Sample{ assets.mono8, assets.mono16, assets.stereo8, assets.stereo16 }) |sample| {
        try sample.validate();
        try mixer.play(0, sample, sample.frequency);
        setSteadyVolume(0, 32766, if (sample.channels == 1) 32766 else 0);
        if (sample.channels == 2) setSteadyVolume(1, 0, 32766);
        mixer.settings.channels[0].position = 48 * sample.bytesPerFrame() << 12;
        try mixer.submit(output[0..64]);
        try mixer.wait(timeout);
        for (0..32) |frame| {
            const value = (@as(i16, @intCast((48 + frame) % 32)) - 16) * 256;
            try testing.expectEqual(value, output[frame * 2]);
            try testing.expectEqual(if (sample.channels == 1) value else -value, output[frame * 2 + 1]);
        }
        try mixer.setFrequency(0, sample.frequency / 2, sample.frequency);
        mixer.settings.channels[0].position = 0;
        try mixer.submit(output[0..64]);
        try mixer.wait(timeout);
        for (0..32) |frame| try testing.expectEqual((@as(i16, @intCast(frame / 2)) - 16) * 256, output[frame * 2]);
        try mixer.stop(0);
    }
}

var ai_memory: [64 * 1024]u8 align(16) = undefined;
var audio_output: n64.audio.Output = undefined;
fn aiOutput() !void {
    var fba = std.heap.FixedBufferAllocator.init(&ai_memory);
    const allocator = fba.allocator();
    try audio_output.init(allocator, .{});
    for (0..4) |_| {
        const buffer = (try audio_output.acquire()).?;
        @memset(buffer, 0);
        try audio_output.commit();
    }
    // Four reference-sized buffers drain in under 160 ms.
    try audio_output.deinit(allocator, 10_000_000);
    try testing.expect(n64.interfaces.audio.readStatus() & n64.interfaces.audio.busy == 0);
}

var renderer: n64.graphics.Renderer = undefined;
var geometry: n64.graphics.geometry.Context = undefined;
var viewport = n64.graphics.geometry.Viewport.init(8, 8);
var pixels: [64]n64.graphics.color.Rgba32 align(64) = undefined;
const vertices align(16) = [_]n64.graphics.geometry.VertexPair{
    .{ .pos_a = .{ -2, -1, 0 }, .pos_b = .{ 1, -1, 0 }, .normal_a = 0, .normal_b = 0, .color_a = .green, .color_b = .green },
    .{ .pos_a = .{ 0, 1, 0 }, .pos_b = .{ 0, 1, 0 }, .normal_a = 0, .normal_b = 0, .color_a = .green, .color_b = .green },
};
var stream: n64.audio.Stream = undefined;
var stream_storage: [384]u8 align(16) = undefined;
fn geometryPreemption() !void {
    try geometryPreemptionCase(false);
}
fn streamedGeometryPreemption() !void {
    try geometryPreemptionCase(true);
}
fn geometryPreemptionCase(streamed: bool) !void {
    runtime.init();
    defer runtime.deinit();
    renderer.init(&runtime);
    defer renderer.deinit();
    geometry.init(&renderer);
    defer geometry.deinit();
    try mixer.init(&runtime, 32);
    defer mixer.deinit() catch {};
    if (streamed) {
        stream = try .init(assets.mono16_stream, &stream_storage);
        try mixer.playStream(0, &stream, assets.mono16.frequency);
    } else try mixer.play(0, assets.mono16, assets.mono16.frequency);
    setSteadyVolume(0, 32766, 32766);
    const image: n64.graphics.image.ImgRgba32 = .{ .width = 8, .height = 8, .texel_data = &pixels };
    viewport = .init(8, 8);
    var expected: [64]u32 = undefined;
    for (0..17) |iteration| {
        renderer.beginFrame(image, .{ .clear_color = .black });
        renderer.render.setCombineMode(.shade);
        geometry.attachViewport(&viewport);
        geometry.setAmbientLight(.white);
        geometry.setDrawFlags(.{ .shaded = true, .cull_front = false, .cull_back = false });
        // More than one 2 KiB queue buffer, before the suspended vertex draw.
        for (0..300) |_| geometry.setAmbientLight(.white);
        geometry.loadVertices(&vertices, 0, 3);
        if (iteration != 0) {
            rsp.io.status_register_write.* = rsp.io.status_clear_signal0;
            renderer.queue.waitThenWriteStatus(0, rsp.io.status_set_signal0);
            renderer.queue.waitThenWriteStatus(rsp.io.status_signal0, rsp.io.status_set_signal0);
        }
        geometry.drawTriangle(0, 1, 2);
        geometry.syncTriangles();
        if (iteration != 0) renderer.queue.waitThenWriteStatus(rsp.io.status_signal0, 0);
        if (iteration != 0) {
            rsp.flush(&renderer.queue);
            var attempts: u32 = timeout;
            while (!rsp.io.status_register_read.signal0) {
                if (attempts == 0) return error.RspTimeout;
                attempts -= 1;
            }
            try mixer.submit(output[0..64]);
            rsp.io.status_register_write.* = rsp.io.status_clear_signal0;
            try mixer.wait(timeout);
            try testing.expect(rsp.io.status_register_read.signal0);
            for (0..32) |frame| try testing.expectEqual((@as(i16, @intCast(frame)) - 16) * 256, output[frame * 2]);
            rsp.io.status_register_write.* = rsp.io.status_clear_signal0;
        }
        const completion = renderer.submit();
        completion.wait(.{ .max_attempts = timeout }) catch |err| {
            n64.debug.diagnostics.reportRenderTimeout("audio-preemption", &renderer.queue);
            return err;
        };
        n64.cache.invalidateData(&pixels);
        var visible: usize = 0;
        for (pixels, 0..) |pixel, index| {
            const rgb = @as(u32, @bitCast(pixel)) >> 8;
            if (pixel.g != 0) visible += 1;
            if (iteration == 0) expected[index] = rgb else try testing.expectEqual(expected[index], rgb);
        }
        try testing.expect(visible > 0 and visible < pixels.len);
    }
    const state = rsp.overlayState(&geometry.geometry_overlay);
    const symbols = rsp.programs.geometry_overlay_symbols;
    const offset = symbols.clipping_code_size - geometry.geometry_overlay.program.state_offset;
    try testing.expect(std.mem.readInt(u16, state[offset..][0..2], .big) != 0);
}

fn finitePcm() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 8);
    defer mixer.deinit() catch {};
    try mixer.play(0, assets.finite, assets.finite.frequency);
    setSteadyVolume(0, 32766, 32766);
    mixer.settings.channels[0].position = 48 * 2 << 12;
    try mixer.submit(output[0..64]);
    try mixer.wait(timeout);
    for (0..32) |frame| {
        const expected: i16 = if (frame < 16) 1024 else 0;
        try testing.expectEqual(expected, output[frame * 2]);
        try testing.expectEqual(expected, output[frame * 2 + 1]);
    }
    try testing.expectEqual(@as(u32, 0), mixer.settings.channels[0].address);
    try mixer.submit(output[0..64]);
    try mixer.wait(timeout);
    for (output[0..64]) |value| try testing.expectEqual(@as(i16, 0), value);
}
