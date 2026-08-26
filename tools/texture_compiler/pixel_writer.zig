const std = @import("std");
const image = @import("image.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Dither = types.Dither;
const Format = types.Format;
const Level = image.Level;
const Palette = image.Palette;

pub fn write(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    level: Level,
    format: Format,
    palette: Palette,
    dither: Dither,
) !void {
    const effective_dither: Dither = if (format == .ci4 or format == .ci8) .none else dither;
    if (isFourBit(format)) return writeFourBit(allocator, output, level, format, palette, effective_dither);
    return writeWhole(allocator, output, level, format, palette, effective_dither);
}

pub fn rgba5551(pixel: [4]u8) u16 {
    return @as(u16, pixel[0] >> 3) << 11 |
        @as(u16, pixel[1] >> 3) << 6 |
        @as(u16, pixel[2] >> 3) << 1 |
        @intFromBool(pixel[3] >= 128);
}

pub fn byteCount(format: Format, pixels: u32) usize {
    const bits: u32 = @as(u32, 4) << @intCast(@intFromEnum(format) & 3);
    return @intCast((pixels * bits + 7) / 8);
}

fn writeFourBit(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    level: Level,
    format: Format,
    palette: Palette,
    dither: Dither,
) !void {
    for (0..level.height) |y| {
        const pixel_y: u32 = @intCast(y);
        var x: u32 = 0;
        while (x < level.width) : (x += 2) {
            const first = adjustedPixel(level, x, pixel_y, dither);
            const second = if (x + 1 < level.width) adjustedPixel(level, x + 1, pixel_y, dither) else [4]u8{ 0, 0, 0, 0 };
            try output.append(allocator, encodeNibble(format, first, palette) << 4 | encodeNibble(format, second, palette));
        }
    }
}

fn writeWhole(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    level: Level,
    format: Format,
    palette: Palette,
    dither: Dither,
) !void {
    for (0..level.height) |y| {
        const pixel_y: u32 = @intCast(y);
        var x: u32 = 0;
        while (x < level.width) : (x += 1) {
            const pixel = adjustedPixel(level, x, pixel_y, dither);
            try writePixel(allocator, output, format, pixel, level, x, pixel_y, palette);
            if (format == .yuv16) x += 1;
        }
    }
}

fn adjustedPixel(level: Level, x: u32, y: u32, dither: Dither) [4]u8 {
    var pixel = level.pixels[(y * level.width + x) * 4 ..][0..4].*;
    if (dither == .none) return pixel;
    const matrix = [4][4]i16{ .{ 0, 6, 1, 7 }, .{ 4, 2, 5, 3 }, .{ 3, 5, 2, 4 }, .{ 7, 1, 6, 0 } };
    const delta = matrix[x & 3][y & 3] - 4;
    for (0..3) |i| pixel[i] = @intCast(std.math.clamp(@as(i16, pixel[i]) + delta, 0, 255));
    return pixel;
}

fn writePixel(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    format: Format,
    pixel: [4]u8,
    level: Level,
    x: u32,
    y: u32,
    palette: Palette,
) !void {
    switch (format) {
        .rgba16, .rgba32, .ci8 => try writeColor(allocator, output, format, pixel, palette),
        .i8, .ia8, .ia16 => try writeIntensity(allocator, output, format, pixel),
        .yuv16 => try writeYuvPair(allocator, output, pixel, adjustedPixel(level, x + 1, y, .none)),
        else => unreachable,
    }
}

fn writeColor(allocator: Allocator, output: *std.ArrayList(u8), format: Format, pixel: [4]u8, palette: Palette) !void {
    switch (format) {
        .rgba16 => try appendInt(output, allocator, u16, rgba5551(pixel)),
        .rgba32 => try output.appendSlice(allocator, &pixel),
        .ci8 => try output.append(allocator, palette.find(pixel).?),
        else => unreachable,
    }
}

fn writeIntensity(allocator: Allocator, output: *std.ArrayList(u8), format: Format, pixel: [4]u8) !void {
    switch (format) {
        .i8 => try output.append(allocator, intensity(pixel)),
        .ia8 => try output.append(allocator, intensity(pixel) & 0xf0 | pixel[3] >> 4),
        .ia16 => try output.appendSlice(allocator, &.{ intensity(pixel), pixel[3] }),
        else => unreachable,
    }
}

fn encodeNibble(format: Format, pixel: [4]u8, palette: Palette) u8 {
    return switch (format) {
        .i4 => intensity(pixel) >> 4,
        .ia4 => (intensity(pixel) >> 5) << 1 | @intFromBool(pixel[3] >= 128),
        .ci4 => palette.find(pixel).?,
        else => unreachable,
    };
}

fn writeYuvPair(allocator: Allocator, output: *std.ArrayList(u8), a: [4]u8, b: [4]u8) !void {
    const ya = rgbToYuv(a);
    const yb = rgbToYuv(b);
    try output.appendSlice(allocator, &.{ @intCast((@as(u16, ya[1]) + yb[1] + 1) / 2), ya[0], @intCast((@as(u16, ya[2]) + yb[2] + 1) / 2), yb[0] });
}

fn rgbToYuv(pixel: [4]u8) [3]u8 {
    const r: i32 = pixel[0];
    const g: i32 = pixel[1];
    const b: i32 = pixel[2];
    return .{
        clampByte((77 * r + 150 * g + 29 * b + 128) >> 8),
        clampByte(((-43 * r - 85 * g + 128 * b + 128) >> 8) + 128),
        clampByte(((128 * r - 107 * g - 21 * b + 128) >> 8) + 128),
    };
}

fn intensity(pixel: [4]u8) u8 {
    return @intCast((@as(u16, pixel[0]) * 77 + @as(u16, pixel[1]) * 150 + @as(u16, pixel[2]) * 29 + 128) >> 8);
}

fn clampByte(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}

fn isFourBit(format: Format) bool {
    return format == .i4 or format == .ia4 or format == .ci4;
}

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try list.appendSlice(allocator, &bytes);
}
