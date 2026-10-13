const std = @import("std");
const n64 = @import("n64");
const testing = @import("assert.zig");
const runner = @import("runner.zig");
const rsp = n64.rsp;
const Mixer = n64.audio.Mixer;
const assets = @import("audio_test_assets");
const timeout = 1_000_000;

var runtime: rsp.Runtime = undefined;
var mixer: Mixer = undefined;
var samples: [128]i16 align(16) = undefined;
var output: [128]i16 align(16) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "Audio: high-priority mixer starts idle runtime", .run = idleSilence },
    .{ .name = "Audio: resuming graphics cannot execute unpublished commands", .run = unpublishedCommands },
    .{ .name = "Audio: 8-channel PCM core", .run = pcm8 },
    .{ .name = "Audio: 32-channel PCM core and DMA alignment", .run = pcm32 },
    .{ .name = "Audio: generated mono/stereo PCM and loop/resampling", .run = generatedPcm },
    .{ .name = "Audio: end of waveform silence and stop", .run = finitePcm },
    .{ .name = "Audio: AI FIFO drains and releases all buffers", .run = aiOutput },
    .{ .name = "Audio: geometry preemption, clipping and queue refills", .run = geometryPreemption },
    .{ .name = "Stream PCM: geometry preemption, clipping and queue refills", .run = streamedGeometryPreemption },
    .{ .name = "VADPCM: decoder and mixer preempt clipped geometry", .run = decoderGeometryPreemption },
};

var publication_queue: rsp.Queue = undefined;
fn unpublishedCommands() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 8);
    defer mixer.deinit() catch {};
    publication_queue.init(.low);
    const marker = rsp.programs.command_dispatcher_symbols.resident_scratch + 16;
    publication_queue.writeDmem(marker, 1);
    _ = publication_queue.insertSyncpoint();
    try testing.expect(publication_queue.waitSyncpointTimeout(timeout));

    publication_queue.writeDmem(marker, 2);
    // Model eviction of cached command words before an explicit submission.
    n64.cpu.cache.writebackData(&publication_queue.storage.buffers[publication_queue.storage.write_index]);
    try mixer.submit(output[0..64]);
    try mixer.wait(timeout);
    n64.cpu.waitCycles(2000);
    try testing.expectEqual(@as(u32, 1), @import("n64").hw.sp.readDmem(u32, marker).*);

    _ = publication_queue.insertSyncpoint();
    try testing.expect(publication_queue.waitSyncpointTimeout(timeout));
    try testing.expectEqual(@as(u32, 2), @import("n64").hw.sp.readDmem(u32, marker).*);
}

fn idleSilence() !void {
    runtime.init();
    defer runtime.deinit();
    try mixer.init(&runtime, 8);
    defer mixer.deinit() catch {};
    @memset(&output, 12345);
    try mixer.submit(output[0..64]);
    try mixer.wait(timeout);
    for (output[0..64]) |sample| try testing.expectEqual(@as(i16, 0), sample);
    try testing.expect(!@import("n64").hw.sp.status_register_read.signal3);
    try testing.expect(!@import("n64").hw.sp.status_register_read.signal4);
    // The queue is reusable and completed tokens do not leave a stale request.
    for (0..128) |_| {
        try mixer.submit(output[0..64]);
        try mixer.wait(timeout);
        // Completion includes the outgoing pointer save, so an immediate
        // submission cannot be overwritten by the preceding queue epilogue.
        const slot = rsp.programs.command_dispatcher_symbols.pointer_stack + 9 * @sizeOf(u32);
        try testing.expectEqual(mixer.queue.high_return_address, @import("n64").hw.sp.readDmem(u32, slot).*);
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
    n64.cpu.cache.writebackData(&samples);
    @memset(&output, -12345);
    mixer.settings.channels[0] = .{
        .step = 2 << 12,
        .length = 64 * 2 << 12,
        .address = n64.cpu.physicalAddress(@intFromPtr(&samples)),
        .flags = n64.audio.Mixer.Channel.pcm16,
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
    try testing.expect(n64.hw.ai.readStatus() & n64.hw.ai.busy == 0);
}

var renderer: n64.rdp.Renderer = undefined;
var geometry: n64.graphics.GeometryEncoder = undefined;
var viewport = n64.graphics.Viewport.init(8, 8);
var pixels: [64]n64.graphics.pixel.Rgba32 align(64) = undefined;
const vertices align(16) = [_]n64.graphics.VertexPair{
    .{ .pos_a = .{ -2, -1, 0 }, .pos_b = .{ 1, -1, 0 }, .normal_a = 0, .normal_b = 0, .color_a = .green, .color_b = .green },
    .{ .pos_a = .{ 0, 1, 0 }, .pos_b = .{ 0, 1, 0 }, .normal_a = 0, .normal_b = 0, .color_a = .green, .color_b = .green },
};
var stream: n64.audio.Stream = undefined;
var stream_storage: [384]u8 align(16) = undefined;
fn geometryPreemption() !void {
    try geometryPreemptionCase(false, false);
}
fn streamedGeometryPreemption() !void {
    try geometryPreemptionCase(true, false);
}
var decode_workspace: [n64.audio.vadpcm.workspace_bytes]u8 align(16) = undefined;
var decode_history: n64.audio.vadpcm.State align(16) = @splat(0);
const decode_book align(16) = @as(n64.audio.vadpcm.Codebook, @splat(0));
fn decoderGeometryPreemption() !void {
    try geometryPreemptionCase(true, true);
}
fn geometryPreemptionCase(streamed: bool, compressed: bool) !void {
    runtime.init();
    defer runtime.deinit();
    renderer.init(&runtime);
    defer renderer.deinit();
    geometry.init(&renderer);
    defer geometry.deinit();
    try mixer.init(&runtime, 32);
    defer mixer.deinit() catch {};
    if (compressed) mixer.decoder.init();
    if (streamed) {
        stream = try .init(assets.mono16_stream, &stream_storage);
        try mixer.playStream(0, &stream, assets.mono16.frequency);
    } else try mixer.play(0, assets.mono16, assets.mono16.frequency);
    setSteadyVolume(0, 32766, 32766);
    const image: n64.graphics.Image(n64.graphics.pixel.Rgba32) = .{ .width = 8, .height = 8, .texel_data = &pixels };
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
            @import("n64").hw.sp.status_register_write.* = @import("n64").hw.sp.status_clear_signal0;
            renderer.queue.waitThenWriteStatus(0, @import("n64").hw.sp.status_set_signal0);
            renderer.queue.waitThenWriteStatus(@import("n64").hw.sp.status_signal0, @import("n64").hw.sp.status_set_signal0);
        }
        geometry.drawTriangle(0, 1, 2);
        geometry.syncTriangles();
        if (iteration != 0) renderer.queue.waitThenWriteStatus(@import("n64").hw.sp.status_signal0, 0);
        if (iteration != 0) {
            rsp.flush(&renderer.queue);
            var attempts: u32 = timeout;
            while (!@import("n64").hw.sp.status_register_read.signal0) {
                if (attempts == 0) return error.RspTimeout;
                attempts -= 1;
            }
            if (compressed) {
                const encoded = try n64.audio.vadpcm.inputSlice(&decode_workspace, 1, 1);
                encoded[0] = 0x80;
                @memset(encoded[1..], 0x12);
                @memset(&decode_history, 0);
                try mixer.decoder.submit(&decode_workspace, &decode_history, &decode_book, 1, 1);
                try expectFailure(error.RspTimeout, mixer.decoder.wait(0));
                try expectFailure(error.MixerBusy, mixer.stop(0));
                @import("n64").hw.sp.status_register_write.* = @import("n64").hw.sp.status_clear_signal0;
                try mixer.decoder.wait(timeout);
                try testing.expect(@import("n64").hw.sp.status_register_read.signal0);
                const decoded = std.mem.bytesAsSlice(i16, decode_workspace[0..32]);
                for (decoded, 0..) |value, sample| try testing.expectEqual(@as(i16, if (sample % 2 == 0) 256 else 512), value);
            }
            try mixer.submit(output[0..64]);
            @import("n64").hw.sp.status_register_write.* = @import("n64").hw.sp.status_clear_signal0;
            try mixer.wait(timeout);
            // Decoder consumed the first gate; the mix then releases the final
            // draw gate. PCM-only work resumes through the first gate here.
            try testing.expect(@import("n64").hw.sp.status_register_read.signal0 != compressed);
            for (0..32) |frame| try testing.expectEqual((@as(i16, @intCast(frame)) - 16) * 256, output[frame * 2]);
            @import("n64").hw.sp.status_register_write.* = @import("n64").hw.sp.status_clear_signal0;
        }
        const completion = renderer.submit();
        completion.wait(.{ .max_attempts = timeout }) catch |err| {
            n64.debug.diagnostics.reportRenderTimeout("audio-preemption", &renderer.queue);
            return err;
        };
        n64.cpu.cache.invalidateData(&pixels);
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

fn expectFailure(expected: anyerror, actual: anyerror!void) !void {
    if (actual) |_| return error.ExpectedFailure else |err| try testing.expect(err == expected);
}
