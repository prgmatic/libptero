const std = @import("std");
const texture_compiler = @import("texture_compiler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 6) fatal("usage: texture-compiler <input.png> <texels.bin> <texture.zig> <name> <format>", .{});

    const format = texture_compiler.Format.parse(args[5]) orelse fatal("unknown texture format '{s}'", .{args[5]});

    const source = try readFile(init.io, allocator, args[1]);
    defer allocator.free(source);
    const result = texture_compiler.convertPng(allocator, source, .{ .format = format }) catch |err|
        fatal("{s}: {s}", .{ args[1], @errorName(err) });
    defer result.deinit(allocator);

    const data = try textureData(allocator, result);
    defer allocator.free(data);
    try writeFile(init.io, args[2], data);
    const source_code = try generateSource(allocator, args[4], result);
    defer allocator.free(source_code);
    try writeFile(init.io, args[3], source_code);
}

fn generateSource(allocator: std.mem.Allocator, name: []const u8, result: texture_compiler.Result) ![]u8 {
    const image_type = switch (result.format) {
        .rgba16 => "ImgRgba16",
        .rgba32 => "ImgRgba32",
        .ia4 => "ImgIa4",
        .ia8 => "ImgIa8",
        .ia16 => "ImgIa16",
        .i4 => "ImgI4",
        .i8 => "ImgI8",
        .yuv16 => "ImgYuv16",
        .ci4 => "ImgCi4",
        .ci8 => "ImgCi8",
    };
    if (result.palette.len != 0) return generatePalettedSource(allocator, name, image_type, result);
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\const bytes align(8) = @embedFile("texture_data").*;
        \\pub const {s}: n64.graphics.image.ConstImage(n64.graphics.image.{s}.Pixel) = .{{
        \\    .width = {d},
        \\    .height = {d},
        \\    .texel_data = std.mem.bytesAsSlice(n64.graphics.image.{s}.Pixel, &bytes),
        \\}};
        \\
    , .{ name, image_type, result.width, result.height, image_type });
}

fn textureData(allocator: std.mem.Allocator, result: texture_compiler.Result) ![]u8 {
    const palette_offset = std.mem.alignForward(usize, result.base_texel_bytes, 8);
    const length = if (result.palette.len == 0) result.base_texel_bytes else palette_offset + result.palette.len;
    const data = try allocator.alloc(u8, length);
    @memset(data, 0);
    @memcpy(data[0..result.base_texel_bytes], result.texels[0..result.base_texel_bytes]);
    if (result.palette.len != 0) @memcpy(data[palette_offset..], result.palette);
    return data;
}

fn generatePalettedSource(allocator: std.mem.Allocator, name: []const u8, image_type: []const u8, result: texture_compiler.Result) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\const bytes align(8) = @embedFile("texture_data").*;
        \\pub const {s}: n64.graphics.image.PalettedImage(n64.graphics.image.{s}.Pixel) = .{{
        \\    .width = {d}, .height = {d},
        \\    .texel_data = std.mem.bytesAsSlice(n64.graphics.image.{s}.Pixel, bytes[0..{d}]),
        \\    .palette = std.mem.bytesAsSlice(n64.graphics.color.Rgba16, bytes[{d}..]),
        \\}};
        \\
    , .{ name, image_type, result.width, result.height, image_type, result.base_texel_bytes, std.mem.alignForward(usize, result.base_texel_bytes, 8) });
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("texture-compiler: " ++ format ++ "\n", args);
    std.process.exit(1);
}

test "generated indexed assets share an aligned texel and RGBA16 palette blob" {
    const allocator = std.testing.allocator;
    const result = try texture_compiler.convertRgba(allocator, 2, 1, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, .{ .format = .ci4 });
    defer result.deinit(allocator);
    const data = try textureData(allocator, result);
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, 12), data.len);
    try std.testing.expectEqual(@as(u8, 1), data[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0xf8, 0x01, 0x07, 0xc1 }, data[8..]);
    const source = try generateSource(allocator, "indexed", result);
    defer allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "PalettedImage(n64.graphics.image.ImgCi4.Pixel)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "bytes[8..]") != null);
}
