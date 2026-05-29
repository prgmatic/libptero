const std = @import("std");
const ast = @import("ast.zig");
const asm_writer = @import("asm_writer.zig");
const parser_mod = @import("parser.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const io = init.io;

    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: zsp <input.zsp> [output.s]\n", .{});
        return error.InvalidArgs;
    }

    var read_buf: [4096]u8 = undefined;
    var in_file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer in_file.close(io);
    var reader = in_file.reader(io, &read_buf);
    const source = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(source);

    var parser = try parser_mod.Parser.init(allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(allocator, functions);

    var out_buf: [4096]u8 = undefined;
    if (args.len == 3) {
        var out_file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
        defer out_file.close(io);
        var writer = out_file.writer(io, &out_buf);
        try asm_writer.write(&writer.interface, functions);
        try writer.interface.flush();
    } else {
        var writer = std.Io.File.stdout().writer(io, &out_buf);
        try asm_writer.write(&writer.interface, functions);
        try writer.interface.flush();
    }
}
