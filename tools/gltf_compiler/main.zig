const std = @import("std");
const gltf = @import("gltf_compiler");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| fatal("{s}", .{@errorName(err)});
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 8) return error.InvalidArguments;
    const source = try readFile(init.io, allocator, args[1]);
    defer allocator.free(source);
    const glb = try gltf.parseGlb(source);
    var document = try gltf.parseDocument(allocator, glb.json);
    defer document.deinit();
    const scale = try std.fmt.parseFloat(f32, args[5]);
    const max_vertices = try std.fmt.parseInt(usize, args[6], 10);
    const preserve_triangle_order = std.mem.eql(u8, args[7], "true");
    if (!preserve_triangle_order and !std.mem.eql(u8, args[7], "false")) return error.InvalidArguments;
    const model = try gltf.convert(allocator, document.value, glb.binary, .{
        .scale = scale,
        .max_vertices_per_batch = max_vertices,
        .preserve_triangle_order = preserve_triangle_order,
    });
    defer model.deinit(allocator);
    const generated = try gltf.generate(allocator, model, document.value, glb.binary, args[4]);
    defer generated.deinit(allocator);
    try writeFile(init.io, args[2], generated.data);
    try writeFile(init.io, args[3], generated.source);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("gltf-compiler: " ++ format ++ "\n", args);
    std.debug.print("usage: gltf-compiler <input.glb> <model.bin> <model.zig> <name> <scale> <max-vertices-per-batch> <preserve-triangle-order>\n", .{});
    std.process.exit(1);
}
