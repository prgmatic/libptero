const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Format = types.Format;

pub const Level = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    owned: bool,
};

pub const Palette = struct {
    colors: [256][4]u8 = undefined,
    len: usize = 0,

    pub fn find(self: *const Palette, color: [4]u8) ?u8 {
        for (self.colors[0..self.len], 0..) |candidate, i|
            if (std.mem.eql(u8, &candidate, &color)) return @intCast(i);
        return null;
    }
};

pub const Prepared = struct {
    levels: std.ArrayList(Level) = .empty,
    palette: Palette,
    format: Format,

    pub fn deinit(self: *Prepared, allocator: Allocator) void {
        for (self.levels.items) |level| allocator.free(level.pixels);
        self.levels.deinit(allocator);
    }
};

pub fn prepare(
    allocator: Allocator,
    width: u32,
    height: u32,
    rgba: []const u8,
    options: types.Options,
) !Prepared {
    try validateInput(width, height, rgba);
    const format = options.format orelse chooseFormat(rgba);
    if (format == .yuv16 and width % 2 != 0) return error.YuvRequiresEvenWidth;

    var prepared = Prepared{ .palette = .{}, .format = format };
    errdefer prepared.deinit(allocator);
    const pixels = try allocator.dupe(u8, rgba);
    if (options.gamma_correct) applyGamma(pixels);
    try prepared.levels.append(allocator, .{ .width = width, .height = height, .pixels = pixels, .owned = true });
    if (options.mipmap == .box) try makeMipmaps(allocator, &prepared.levels);
    prepared.palette = try makePalette(prepared.levels.items, format);
    return prepared;
}

pub fn chooseFormat(rgba: []const u8) Format {
    const grayscale = isGrayscale(rgba);
    if (grayscale and isOpaque(rgba)) return .i8;
    if (grayscale) return .ia16;
    return .rgba16;
}

fn validateInput(width: u32, height: u32, rgba: []const u8) !void {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (width > 65535 or height > 65535) return error.InvalidDimensions;
    if (rgba.len != @as(usize, width) * height * 4) return error.InvalidPixelData;
}

fn isGrayscale(rgba: []const u8) bool {
    for (0..rgba.len / 4) |i| {
        const pixel = rgba[i * 4 ..][0..4];
        if (pixel[0] != pixel[1] or pixel[1] != pixel[2]) return false;
    }
    return true;
}

fn isOpaque(rgba: []const u8) bool {
    for (0..rgba.len / 4) |i| if (rgba[i * 4 + 3] != 255) return false;
    return true;
}

fn applyGamma(pixels: []u8) void {
    for (0..pixels.len / 4) |i| {
        for (0..3) |channel| {
            const value: f32 = @floatFromInt(pixels[i * 4 + channel]);
            pixels[i * 4 + channel] = @intFromFloat(@round(255.0 * std.math.pow(f32, value / 255.0, 2.2)));
        }
    }
}

fn makeMipmaps(allocator: Allocator, levels: *std.ArrayList(Level)) !void {
    while (levels.items.len < 8) {
        const previous = levels.items[levels.items.len - 1];
        if (previous.width == 1 and previous.height == 1) return;
        const width = @max(previous.width / 2, 1);
        const height = @max(previous.height / 2, 1);
        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        downsample(previous, width, height, pixels);
        try levels.append(allocator, .{ .width = width, .height = height, .pixels = pixels, .owned = true });
    }
}

fn downsample(source: Level, width: u32, height: u32, output: []u8) void {
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..4) |channel| {
                output[(y * width + x) * 4 + channel] = averageChannel(source, x, y, channel);
            }
        }
    }
}

fn averageChannel(source: Level, x: usize, y: usize, channel: usize) u8 {
    var sum: u16 = 0;
    var count: u16 = 0;
    for (0..2) |dy| {
        for (0..2) |dx| {
            const sx = x * 2 + dx;
            const sy = y * 2 + dy;
            if (sx < source.width and sy < source.height) {
                sum += source.pixels[(sy * source.width + sx) * 4 + channel];
                count += 1;
            }
        }
    }
    return @intCast((sum + count / 2) / count);
}

fn makePalette(levels: []const Level, format: Format) !Palette {
    var palette = Palette{};
    if (format == .ci4) try buildPalette(levels, &palette, 16);
    if (format == .ci8) try buildPalette(levels, &palette, 256);
    return palette;
}

fn buildPalette(levels: []const Level, palette: *Palette, limit: usize) !void {
    for (levels) |level| {
        for (0..level.pixels.len / 4) |i| {
            const color = level.pixels[i * 4 ..][0..4].*;
            if (palette.find(color) != null) continue;
            if (palette.len == limit) return error.TooManyColors;
            palette.colors[palette.len] = color;
            palette.len += 1;
        }
    }
}
