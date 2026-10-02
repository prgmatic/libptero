//! Deterministic population-weighted median cut for native RGBA16 palettes.
const std = @import("std");
const image = @import("image.zig");
const Color = [4]u8;
const Bucket = struct { colors: []Color };

pub fn make(allocator: std.mem.Allocator, levels: []const image.Level, limit: usize) !image.Palette {
    const colors = try collectColors(allocator, levels);
    defer allocator.free(colors);
    var buckets: [256]Bucket = undefined;
    buckets[0] = .{ .colors = colors };
    var used: usize = 1;
    while (used < limit) {
        const choice = chooseBucket(buckets[0..used]) orelse break;
        const split = splitBucket(buckets[choice]);
        buckets[choice] = split[0];
        buckets[used] = split[1];
        used += 1;
    }
    var palette: image.Palette = .{ .len = used };
    for (buckets[0..used], 0..) |bucket, i| palette.colors[i] = average(bucket.colors);
    return palette;
}

fn collectColors(allocator: std.mem.Allocator, levels: []const image.Level) ![]Color {
    var count: usize = 0;
    for (levels) |level| count += level.pixels.len / 4;
    const colors = try allocator.alloc(Color, count);
    var cursor: usize = 0;
    for (levels) |level| for (0..level.pixels.len / 4) |i| {
        const pixel = level.pixels[i * 4 ..][0..4].*;
        colors[cursor] = if (pixel[3] < 128) .{ 0, 0, 0, 0 } else .{ pixel[0], pixel[1], pixel[2], 255 };
        cursor += 1;
    };
    return colors;
}
fn ranges(colors: []const Color) [4]u8 {
    var low: Color = @splat(255);
    var high: Color = @splat(0);
    for (colors) |color| for (0..4) |i| {
        low[i] = @min(low[i], color[i]);
        high[i] = @max(high[i], color[i]);
    };
    var result: Color = undefined;
    for (&result, high, low) |*value, max, min| value.* = max - min;
    return result;
}
fn axis(colors: []const Color) usize {
    const spread = ranges(colors);
    // Keep binary alpha classes separate before dividing RGB ranges.
    if (spread[3] != 0) return 3;
    var best: usize = 0;
    for (1..3) |i| if (spread[i] > spread[best]) {
        best = i;
    };
    return best;
}
fn chooseBucket(buckets: []const Bucket) ?usize {
    var best: ?usize = null;
    var priority: usize = 0;
    for (buckets, 0..) |bucket, i| {
        const spread = ranges(bucket.colors);
        const extent: usize = spread[axis(bucket.colors)];
        const score = extent * extent * bucket.colors.len;
        if (score > priority) {
            best = i;
            priority = score;
        }
    }
    return best;
}
fn splitBucket(bucket: Bucket) [2]Bucket {
    const channel = axis(bucket.colors);
    std.mem.sort(Color, bucket.colors, channel, less);
    var middle = bucket.colors.len / 2;
    // Alpha split should not mix transparent and opaque colors in either bucket.
    if (channel == 3) {
        middle = 0;
        while (bucket.colors[middle][3] == 0) middle += 1;
    }
    return .{ .{ .colors = bucket.colors[0..middle] }, .{ .colors = bucket.colors[middle..] } };
}
fn less(channel: usize, a: Color, b: Color) bool {
    if (a[channel] != b[channel]) return a[channel] < b[channel];
    return std.mem.order(u8, &a, &b) == .lt;
}
fn average(colors: []const Color) Color {
    var sums: [4]u64 = @splat(0);
    for (colors) |color| for (&sums, color) |*sum, value| {
        sum.* += value;
    };
    var result: Color = undefined;
    for (&result, sums) |*value, sum| value.* = @intCast((sum + colors.len / 2) / colors.len);
    return result;
}

test "median cut preserves alpha classes and representative gradients" {
    var pixels: [256 * 4]u8 = undefined;
    for (0..256) |i| {
        pixels[i * 4 ..][0..4].* = .{ @intCast(i), @intCast(i), @intCast(i), if (i < 16) @as(u8, 0) else 255 };
    }
    const level: image.Level = .{ .width = 256, .height = 1, .pixels = &pixels, .owned = false };
    const palette = try make(std.testing.allocator, &.{level}, 16);
    try std.testing.expectEqual(@as(usize, 16), palette.len);
    try std.testing.expect(palette.find(.{ 0, 0, 0, 0 }) != null);
    for (16..256) |i| {
        const color: Color = .{ @intCast(i), @intCast(i), @intCast(i), 255 };
        const selected = palette.colors[palette.nearest(color)];
        try std.testing.expectEqual(@as(u8, 255), selected[3]);
        try std.testing.expect(@abs(@as(i16, selected[0]) - @as(i16, @intCast(i))) <= 16);
    }
}
