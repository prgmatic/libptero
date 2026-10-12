const std = @import("std");
const n64 = @import("n64");
const assets = @import("audio_test_assets");
const testing = @import("assert.zig");
const runner = @import("runner.zig");

var storage: [560 * 1024]u8 = undefined;
var app: n64.app.App(.{ .geometry = true, .transforms = 2, .cameras = 2, .pose_matrices = 2, .vertex_pairs = 16 }) = undefined;
var player: n64.audio.Player = undefined;
var scheduler: n64.rom.Scheduler = undefined;
var asset_bytes: [1024]u8 align(16) = undefined;
const Slot = n64.rom.Slot(.{ .triangle = assets.model_rom, .joint = assets.joint_rom });
var slot: Slot = .{};

pub const tests = [_]runner.Test{
    .{ .name = "App: frame uploads, voice handles and scheduled typed assets", .run = gameLoop },
    .{ .name = "App: recorded/dynamic geometry and isolated sprite passes", .run = passRendering },
};

fn gameLoop() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();
    try app.init(allocator, .{ .input = false });
    try player.init(allocator, &app.runtime, .{ .channels = 3, .output = .{ .frequency = 8000, .buffer_count = 2 } });
    const music = try player.play(assets.stereo16, .{ .volume = 0.1 });
    const effect = try player.play(assets.finite, .{});
    if (player.play(assets.mono16, .{})) |_| return error.ExpectedVoiceLimit else |err| try testing.expect(err == error.VoiceLimit);
    try testing.expectEqual(@as(u8, 2), effect.index);
    try player.stop(music);
    const replacement = try player.play(assets.stereo16, .{ .volume = 0.1 });
    if (player.stop(music)) |_| return error.ExpectedInvalidVoice else |err| try testing.expect(err == error.InvalidVoice);

    scheduler = try .init(.{ .chunk_bytes = 16 });
    try slot.request(.triangle, &asset_bytes, &scheduler);
    if (slot.retire()) |_| return error.ExpectedAssetBusy else |err| try testing.expect(err == error.AssetBusy);
    var polls: usize = 0;
    while (!try slot.poll()) : (polls += 1) {
        if (polls == 1_000_000) return error.PiTimeout;
        try scheduler.serviceAudio(&player, .{});
    }
    try testing.expect(scheduler.isIdle());
    try testing.expect(scheduler.transfers > 1);
    var camera = n64.graphics.geometry.Viewport.init(320, 240);
    camera.setPerspective(n64.math.degreesToRadians(70), 1, 500);
    camera.lookAt(.init(0, 0, 250), .zero, .init(0, 1, 0));
    const frame = try app.beginFrame(.{ .clear_color = .green });
    const world = try frame.beginGeometry(.{ .camera = camera });
    try world.drawModel(assets.model_resident, .identity);
    var transform = n64.math.Mat4.identity;
    transform.m[3][0] = 10;
    try world.drawModel(assets.model_resident, transform);
    try testing.expectEqual(@as(f32, 0), app.uploads.matrices[0].get(3, 0));
    try testing.expectEqual(@as(f32, 10), app.uploads.matrices[1].get(3, 0));
    if (world.drawModel(assets.model_resident, .identity)) |_| return error.ExpectedStorageFull else |err| try testing.expect(err == error.FrameStorageFull);
    try slot.draw(&app.geometry);
    _ = try frame.submit();
    if (world.drawModel(assets.model_resident, .identity)) |_| return error.ExpectedFrameSubmitted else |err| try testing.expect(err == error.FrameSubmitted);
    _ = try player.service(.{});
    try frame.present();
    try slot.retire();
    if (frame.present()) |_| return error.ExpectedInvalidFrame else |err| try testing.expect(err == error.InvalidFrame);
    try testing.expect(!player.isPlaying(effect));
    try player.stop(replacement);
    try player.deinit(allocator, 10_000_000);
    const abandoned = try app.beginFrame(.{});
    try abandoned.discard();
    try app.deinit(allocator);
}

var recorded: n64.graphics.geometry.RecordedModel = undefined;
const white_texels: [4]n64.graphics.color.Rgba16 align(8) = @splat(.white);

fn passRendering() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();
    try app.init(allocator, .{ .input = false });
    var camera = n64.graphics.geometry.Viewport.init(320, 240);
    camera.setPerspective(n64.math.degreesToRadians(70), 1, 500);
    camera.lookAt(.init(0, 0, 250), .zero, .init(0, 1, 0));
    const frame = try app.beginFrame(.{ .clear_color = .blue });
    const world = try frame.beginGeometry(.{ .camera = camera, .lighting = .{
        .ambient = .fromBytes(128, 128, 128, 255),
        .lights = &.{
            .{ .directional = .{ .direction = .init(1, -1, 1) } },
            .{ .point = .{ .position = .init(0, 0, 100), .strength = 100 } },
        },
    } });
    var pose = [_]n64.math.FixedMat4{ .identity, .identity };
    try world.setPose(&pose);
    try world.recordModel(&recorded, assets.joint_resident);
    try world.drawRecorded(&recorded, .identity);
    var part = assets.model_resident.model.parts[0];
    part.vertices = try frame.uploadVertices(part.vertices);
    part.data_usage = .dynamic;
    var model = assets.model_resident.model;
    model.parts = (&part)[0..1];
    try world.drawModel(assets.model_resident.withModel(model), .identity);
    const hud = try frame.beginOverlay(.{});
    if (world.drawRecorded(&recorded, .identity)) |_| return error.ExpectedInvalidPass else |err| try testing.expect(err == error.InvalidPass);
    n64.cache.writebackData(&white_texels);
    const image: n64.graphics.image.ConstImage(n64.graphics.color.Rgba16) = .{ .width = 2, .height = 2, .texel_data = &white_texels };
    try hud.drawSprite(image, .{ .position = .{ 8, 8 }, .scale = .{ 4, 4 }, .tint = .red });
    // Font rendering sets primitive color even when there are no glyphs.
    const font: n64.graphics.font.Font = .{ .point_size = 8, .ascent = 8, .descent = 0, .line_height = 8, .ranges = &.{}, .glyphs = &.{} };
    var scratch: [16]u8 = undefined;
    try hud.drawTextPrint(font, 0, 0, &scratch, .{ .color = .green }, "{d}", .{123});
    try hud.drawSprite(image, .{ .position = .{ 24, 8 }, .scale = .{ 4, 4 } });
    try hud.drawSprite(image, .{ .position = .{ 40, 8 }, .scale = .{ 4, 4 }, .tint = .fromInt(0xff000080) });
    const completion = try frame.submit();
    try completion.wait(.{});
    // The frame is still acquired. Read GPU-only storage through its uncached alias.
    const pixels: [*]const volatile n64.graphics.color.Rgba16 = @ptrFromInt(@intFromPtr(app.acquired.image.texel_data.ptr) | n64.io.kseg1_addr);
    const red = pixels[10 * 320 + 10];
    const white = pixels[10 * 320 + 26];
    const purple = pixels[10 * 320 + 42];
    try testing.expect(red.r >= 30 and red.g <= 1 and red.b <= 1);
    try testing.expect(white.r >= 30 and white.g >= 30 and white.b >= 30);
    try testing.expect(purple.r >= 13 and purple.r <= 18 and purple.g <= 1 and purple.b >= 13 and purple.b <= 18);
    try frame.present();
    try app.deinit(allocator);
}
