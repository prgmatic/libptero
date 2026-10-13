const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");
const assets = @import("audio_test_assets");
const profiler = n64.debug.profiler;
var events: [256]profiler.Event = undefined;
var recorder = profiler.Recorder.init(&events);
var pixels: [8 * 8]n64.graphics.pixel.Rgba32 align(64) = undefined;
var runtime: n64.rsp.Runtime = undefined;
var renderer: n64.rdp.Renderer = undefined;
var rom_bytes: [16]u8 align(16) = undefined;
var transfer: n64.pi.Transfer = .{};

pub const tests = [_]runner.Test{
    .{ .name = "Profiler: bounded scopes, PI and render completion observations", .run = capture },
};
fn capture() !void {
    runtime.init();
    renderer.init(&runtime);
    try profiler.start(&recorder);
    errdefer profiler.stop(&recorder) catch {};
    const frame = profiler.scope("Profiler test frame");
    try transfer.begin(try assets.raw_rom.romOffset(), &rom_bytes);
    try transfer.wait(1_000_000);
    const image = try n64.graphics.Image(n64.graphics.pixel.Rgba32).initBuffer(&pixels, 8, 8);
    renderer.beginFrame(image, .{ .clear_color = .green });
    const completion = renderer.submit();
    try completion.wait(.{ .max_attempts = 1_000_000 });
    frame.end();
    try profiler.stop(&recorder);
    // Re-polling a completed fence/syncpoint must not append duplicate ends.
    const saved_count = recorder.count;
    try testing.expect(completion.isComplete());
    try testing.expectEqual(saved_count, recorder.count);
    try testing.expectEqual(@as(u32, 0), recorder.dropped);
    try testing.expect(recorder.elapsed > 0);
    var began: [6]u32 = @splat(0);
    var ended: [6]u32 = @splat(0);
    var previous: u64 = 0;
    for (recorder.events()) |event| {
        try testing.expect(event.ticks >= previous);
        previous = event.ticks;
        const lane = @intFromEnum(event.lane);
        if (event.kind == .begin) began[lane] += 1;
        if (event.kind == .end) ended[lane] += 1;
    }
    inline for (.{ .cpu, .rsp_low, .rdp, .pi }) |lane| {
        try testing.expect(began[@intFromEnum(@as(profiler.Lane, lane))] != 0);
        try testing.expectEqual(began[@intFromEnum(@as(profiler.Lane, lane))], ended[@intFromEnum(@as(profiler.Lane, lane))]);
    }
    n64.cpu.cache.invalidateData(&pixels);
    for (pixels) |pixel| try testing.expectEqual(n64.graphics.pixel.Rgba32.green, pixel);
    renderer.deinit();
    runtime.deinit();
}
