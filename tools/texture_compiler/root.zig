const std = @import("std");
const png = @import("png");
const image = @import("image.zig");
const pixels = @import("pixel_writer.zig");
const types = @import("types.zig");

pub const Dither = types.Dither;
pub const Format = types.Format;
pub const Mipmap = types.Mipmap;
pub const Options = types.Options;
pub const Result = types.Result;

pub fn convertPng(allocator: std.mem.Allocator, source: []const u8, options: Options) !Result {
    const decoded = try png.readRgba(allocator, source);
    defer decoded.deinit(allocator);
    return convertRgba(allocator, decoded.width, decoded.height, decoded.pixels, options);
}

pub fn convertRgba(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    rgba: []const u8,
    options: Options,
) !Result {
    var prepared = try image.prepare(allocator, width, height, rgba, options);
    defer prepared.deinit(allocator);

    var texels: std.ArrayList(u8) = .empty;
    errdefer texels.deinit(allocator);
    const base_texel_bytes = pixels.byteCount(prepared.format, width * height);
    for (prepared.levels.items) |level|
        try pixels.write(allocator, &texels, level, prepared.format, prepared.palette, options.dither);

    var palette: std.ArrayList(u8) = .empty;
    errdefer palette.deinit(allocator);
    for (prepared.palette.colors[0..prepared.palette.len]) |color| {
        var encoded: [2]u8 = undefined;
        std.mem.writeInt(u16, &encoded, pixels.rgba5551(color), .big);
        try palette.appendSlice(allocator, &encoded);
    }
    return .{
        .texels = try texels.toOwnedSlice(allocator),
        .palette = try palette.toOwnedSlice(allocator),
        .format = prepared.format,
        .width = width,
        .height = height,
        .levels = @intCast(prepared.levels.items.len),
        .base_texel_bytes = base_texel_bytes,
    };
}

test {
    _ = @import("tests.zig");
}
