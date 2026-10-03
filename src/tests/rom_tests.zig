const n64 = @import("n64");
const testing = @import("assert.zig");
const runner = @import("runner.zig");
const assets = @import("audio_test_assets");
var reader: n64.rom.Reader = .{};
var bytes: [5016]u8 align(16) = undefined;
pub const tests = [_]runner.Test{
    .{ .name = "ROM: DMA reads odd ranges, chunk boundaries and tail padding", .run = readRanges },
    .{ .name = "ROM: bounded waits retain owned buffers for retry", .run = retryRead },
};
fn readRanges() !void {
    for ([_][2]usize{ .{ 0, 5003 }, .{ 1, 4097 }, .{ 4999, 4 }, .{ 17, 1 }, .{ 4095, 17 } }) |range| {
        @memset(&bytes, 0xaa);
        try reader.read(assets.raw_rom, @intCast(range[0]), bytes[1..][0..range[1]], 1_000_000);
        try testing.expectEqual(@as(u8, 0xaa), bytes[0]);
        try testing.expectEqual(@as(u8, 0xaa), bytes[range[1] + 1]);
        for (bytes[1..][0..range[1]], 0..) |byte, index| try testing.expectEqual(@as(u8, @truncate((index + range[0]) * 37 + 11)), byte);
    }
    try reader.read(assets.empty_rom, 0, bytes[0..0], 1000);
    try reader.read(assets.raw_rom, assets.raw_rom.size, bytes[0..0], 1000);
}
fn retryRead() !void {
    @memset(&bytes, 0);
    try reader.begin(assets.raw_rom, 0, bytes[0..5003]);
    reader.wait(0) catch |err| try testing.expect(err == error.PiTimeout);
    try testing.expect(reader.destination != null);
    try testing.expectEqual(@as(usize, 0), reader.copied);
    try reader.wait(1_000_000);
    for (bytes[0..5003], 0..) |byte, index| try testing.expectEqual(@as(u8, @truncate(index * 37 + 11)), byte);
}
