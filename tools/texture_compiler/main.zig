const std = @import("std");
const texture_compiler = @import("texture_compiler");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| fatal("{s}", .{@errorName(err)});
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len == 1 or (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))) {
        std.debug.print("usage: texture-compiler <input.png> <texels.bin> <texture.zig> <name> <format> [--rom]\n", .{});
        return;
    }
    if (args.len != 6 and args.len != 7) fatal("usage: texture-compiler <input.png> <texels.bin> <texture.zig> <name> <format> [--rom]", .{});

    const rom = args.len == 7;
    if (rom and !std.mem.eql(u8, args[6], "--rom")) fatal("unknown option '{s}'", .{args[6]});
    const format = texture_compiler.Format.parse(args[5]) orelse fatal("unknown texture format '{s}'", .{args[5]});

    const source = try readFile(init.io, allocator, args[1]);
    defer allocator.free(source);
    const result = texture_compiler.convertPng(allocator, source, .{ .format = format }) catch |err|
        fatal("{s}: {s}", .{ args[1], @errorName(err) });
    defer result.deinit(allocator);

    const data = try texture_compiler.textureData(allocator, result);
    defer allocator.free(data);
    try writeFile(init.io, args[2], data);
    const source_code = try texture_compiler.generateSourceWithStorage(allocator, args[4], result, if (rom) .rom else .resident);
    defer allocator.free(source_code);
    try writeFile(init.io, args[3], source_code);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| fatal("{s}: {s}", .{ path, @errorName(err) });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| fatal("{s}: {s}", .{ path, @errorName(err) });
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
    const data = try texture_compiler.textureData(allocator, result);
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, 12), data.len);
    try std.testing.expectEqual(@as(u8, 1), data[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0xf8, 0x01, 0x07, 0xc1 }, data[8..]);
    const source = try texture_compiler.generateSource(allocator, "indexed", result);
    defer allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "PalettedImage(n64.graphics.image.ImgCi4.Pixel)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "bytes[8..]") != null);
}
