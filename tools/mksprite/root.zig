const std = @import("std");
const png = @import("png");
const image = @import("image.zig");
const sprite_writer = @import("sprite_writer.zig");
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

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try sprite_writer.write(allocator, &output, prepared.levels.items, prepared.format, prepared.palette, options);
    return .{
        .bytes = try output.toOwnedSlice(allocator),
        .format = prepared.format,
        .width = width,
        .height = height,
        .levels = @intCast(prepared.levels.items.len),
    };
}

test {
    _ = @import("tests.zig");
}
