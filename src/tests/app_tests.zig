const std = @import("std");
const n64 = @import("n64");
const assets = @import("audio_test_assets");
const testing = @import("assert.zig");
const runner = @import("runner.zig");

var storage: [560 * 1024]u8 = undefined;
var app: n64.app.App(.{ .geometry = true, .transforms = 2, .cameras = 1 }) = undefined;
var player: n64.audio.Player = undefined;
var scheduler: n64.rom.Scheduler = undefined;
var asset_bytes: [1024]u8 align(16) = undefined;
const Slot = n64.rom.Slot(.{ .triangle = assets.model_rom, .joint = assets.joint_rom });
var slot: Slot = .{};

pub const tests = [_]runner.Test{
    .{ .name = "App: frame uploads, voice handles and scheduled typed assets", .run = gameLoop },
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
    try frame.setCamera(camera);
    try frame.drawModel(assets.model_resident, .identity);
    var transform = n64.math.Mat4.identity;
    transform.m[3][0] = 10;
    try frame.drawModel(assets.model_resident, transform);
    try testing.expectEqual(@as(f32, 0), app.uploads.matrices[0].get(3, 0));
    try testing.expectEqual(@as(f32, 10), app.uploads.matrices[1].get(3, 0));
    if (frame.drawModel(assets.model_resident, .identity)) |_| return error.ExpectedStorageFull else |err| try testing.expect(err == error.FrameStorageFull);
    try slot.draw(&app.geometry);
    _ = try frame.submit();
    if (frame.drawModel(assets.model_resident, .identity)) |_| return error.ExpectedFrameSubmitted else |err| try testing.expect(err == error.FrameSubmitted);
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
