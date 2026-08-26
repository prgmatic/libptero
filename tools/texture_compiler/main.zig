const std = @import("std");
const texture_compiler = @import("texture_compiler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 6) fatal("usage: texture-compiler <input.png> <texels.bin> <texture.zig> <name> <format>", .{});

    const format = texture_compiler.Format.parse(args[5]) orelse fatal("unknown texture format '{s}'", .{args[5]});
    if (format == .ci4 or format == .ci8)
        fatal("indexed textures are not supported by libptero's renderer yet", .{});

    const source = try readFile(init.io, allocator, args[1]);
    defer allocator.free(source);
    const result = texture_compiler.convertPng(allocator, source, .{ .format = format }) catch |err|
        fatal("{s}: {s}", .{ args[1], @errorName(err) });
    defer result.deinit(allocator);

    try writeFile(init.io, args[2], result.texels[0..result.base_texel_bytes]);
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
        .ci4, .ci8 => unreachable,
    };
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\var bytes align(8) = @embedFile("texture_data").*;
        \\pub const {s}: n64.graphics.image.{s} = .{{
        \\    .width = {d},
        \\    .height = {d},
        \\    .texel_data = std.mem.bytesAsSlice(n64.graphics.image.{s}.Pixel, &bytes),
        \\}};
        \\
    , .{ name, image_type, result.width, result.height, image_type });
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
