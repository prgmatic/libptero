const std = @import("std");
const image = @import("image.zig");
const pixels = @import("pixel_writer.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Format = types.Format;

pub fn write(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    levels: []const image.Level,
    format: Format,
    palette: image.Palette,
    options: types.Options,
) !void {
    try writeHeader(allocator, output, levels[0], format, options);
    var lod_positions = [_]usize{0} ** 7;
    var palette_position: usize = 0;
    for (levels, 0..) |level, index| {
        if (index > 0) patchLod(output.items, lod_positions[index - 1], format);
        try pixels.write(allocator, output, level, format, palette, options.dither);
        try padTo(output, allocator, 8);
        if (index == 0) palette_position = try writeExtension(allocator, output, levels, &lod_positions, format, palette);
    }
    try writePalette(allocator, output, palette, palette_position);
}

fn writeHeader(allocator: Allocator, output: *std.ArrayList(u8), first: image.Level, format: Format, options: types.Options) !void {
    try appendInt(output, allocator, u16, @intCast(first.width));
    try appendInt(output, allocator, u16, @intCast(first.height));
    try output.appendSlice(allocator, &.{ 0, @intFromEnum(format) | 0x80, options.horizontal_slices, options.vertical_slices });
}

fn patchLod(bytes: []u8, position: usize, format: Format) void {
    const value = @as(u32, @intFromEnum(format)) << 24 | @as(u32, @intCast(bytes.len));
    patchInt(bytes, u32, position, value);
}

fn writeExtension(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    levels: []const image.Level,
    lod_positions: *[7]usize,
    format: Format,
    palette: image.Palette,
) !usize {
    const start = output.items.len;
    try appendInt(output, allocator, u16, 128);
    try appendInt(output, allocator, u16, 6);
    const palette_position = output.items.len;
    try appendInt(output, allocator, u32, 0);
    try writeLodTable(allocator, output, levels, lod_positions);
    try writeFlags(allocator, output, levels, format, palette);
    try output.appendNTimes(allocator, 0, 128 - (output.items.len - start));
    return palette_position;
}

fn writeLodTable(allocator: Allocator, output: *std.ArrayList(u8), levels: []const image.Level, positions: *[7]usize) !void {
    for (0..7) |index| {
        const level: ?image.Level = if (index + 1 < levels.len) levels[index + 1] else null;
        try appendInt(output, allocator, u16, if (level) |value| @intCast(value.width) else 0);
        try appendInt(output, allocator, u16, if (level) |value| @intCast(value.height) else 0);
        positions[index] = output.items.len;
        try appendInt(output, allocator, u32, 0);
    }
}

fn writeFlags(allocator: Allocator, output: *std.ArrayList(u8), levels: []const image.Level, format: Format, palette: image.Palette) !void {
    const image_bytes = pixels.byteCount(format, levels[0].width * levels[0].height);
    const fits_tmem: u16 = if (image_bytes + palette.len * 2 <= 4096) 0x20 else 0;
    try appendInt(output, allocator, u16, @as(u16, @intCast(levels.len - 1)) | fits_tmem);
    try output.appendSlice(allocator, &.{ @intCast(palette.len), 0 });
}

fn writePalette(allocator: Allocator, output: *std.ArrayList(u8), palette: image.Palette, position: usize) !void {
    if (palette.len == 0) return;
    patchInt(output.items, u32, position, @intCast(output.items.len));
    for (palette.colors[0..palette.len]) |color|
        try appendInt(output, allocator, u16, pixels.rgba5551(color));
    try padTo(output, allocator, 8);
}

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try list.appendSlice(allocator, &bytes);
}

fn patchInt(bytes: []u8, comptime T: type, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

fn padTo(list: *std.ArrayList(u8), allocator: Allocator, boundary: usize) !void {
    const padding = (boundary - list.items.len % boundary) % boundary;
    try list.appendNTimes(allocator, 0, padding);
}
