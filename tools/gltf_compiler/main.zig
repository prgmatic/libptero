const std = @import("std");
const gltf = @import("gltf_compiler");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| fatal("{s}", .{@errorName(err)});
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len == 1 or (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))) {
        std.debug.print("usage: gltf-compiler <input.glb> <model.bin> <model.zig> <name> <scale> <max-vertices-per-batch> <preserve-triangle-order> [weighted|first_joint [material:width:height ...]] [--rom]\n", .{});
        return;
    }
    const rom = args.len > 1 and std.mem.eql(u8, args[args.len - 1], "--rom");
    const count = args.len - @intFromBool(rom);
    if (count < 8) return error.InvalidArguments;
    const source = try readFile(init.io, allocator, args[1]);
    defer allocator.free(source);
    const glb = gltf.parseGlb(source) catch |err| fatal("{s}: decoding GLB: {s}", .{ args[1], @errorName(err) });
    var document = gltf.parseDocument(allocator, glb.json) catch |err| fatal("{s}: parsing glTF: {s}", .{ args[1], @errorName(err) });
    defer document.deinit();
    const scale = try std.fmt.parseFloat(f32, args[5]);
    const max_vertices = try std.fmt.parseInt(usize, args[6], 10);
    const preserve_triangle_order = std.mem.eql(u8, args[7], "true");
    if (!preserve_triangle_order and !std.mem.eql(u8, args[7], "false")) return error.InvalidArguments;
    const sizes = try allocator.alloc(gltf.TextureSize, count - @min(count, 9));
    defer allocator.free(sizes);
    for (sizes, args[@min(count, 9)..count]) |*size, arg| size.* = try gltf.parseTextureSize(arg);
    var diagnostic: gltf.Diagnostic = .{};
    const model = gltf.convert(allocator, document.value, glb.binary, .{
        .scale = scale,
        .texture_sizes = sizes,
        .max_vertices_per_batch = max_vertices,
        .preserve_triangle_order = preserve_triangle_order,
        .skinning = if (count >= 9) std.meta.stringToEnum(@FieldType(gltf.ConvertOptions, "skinning"), args[8]) orelse return error.InvalidArguments else .weighted,
        .diagnostic = &diagnostic,
    }) catch |err| fatalConversion(args[1], err, document.value, diagnostic);
    defer model.deinit(allocator);
    const generated = try gltf.generateWithStorage(allocator, model, document.value, glb.binary, args[4], if (rom) .rom else .resident);
    defer generated.deinit(allocator);
    try writeFile(init.io, args[2], generated.data);
    try writeFile(init.io, args[3], generated.source);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| fatal("{s}: {s}", .{ path, @errorName(err) });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| fatal("{s}: {s}", .{ path, @errorName(err) });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

/// Report a conversion error with the mesh, primitive, material and vertex
/// recorded in the diagnostic.
fn fatalConversion(path: []const u8, err: anyerror, document: gltf.Document, diagnostic: gltf.Diagnostic) noreturn {
    std.debug.print("gltf-compiler: {s}: converting model: {s}\n", .{ path, @errorName(err) });
    if (diagnostic.mesh) |mesh| {
        const name = if (mesh < document.meshes.len) document.meshes[mesh].name else "";
        std.debug.print("  mesh {d} \"{s}\", primitive {d}\n", .{ mesh, name, diagnostic.primitive orelse 0 });
    }
    if (diagnostic.material) |material| {
        const name = if (material < document.materials.len) document.materials[material].name else "";
        std.debug.print("  material {d} \"{s}\"\n", .{ material, name });
    }
    if (diagnostic.vertex) |vertex| std.debug.print("  vertex {d}\n", .{vertex});
    if (diagnostic.uv) |uv| std.debug.print(
        "  TEXCOORD_0 ({d:.3}, {d:.3}) exceeds +/-({d:.2}, {d:.2}) repeats of a {d}x{d} texture; UVs are S10.5 texels.\n" ++
            "  Wrapping (repeat or mirror) samplers are rebased automatically; split the face or reduce tiling otherwise.\n",
        .{ uv[0], uv[1], diagnostic.uvLimit(0), diagnostic.uvLimit(1), diagnostic.texture_size[0], diagnostic.texture_size[1] },
    );
    std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("gltf-compiler: " ++ format ++ "\n", args);
    std.debug.print("usage: gltf-compiler <input.glb> <model.bin> <model.zig> <name> <scale> <max-vertices-per-batch> <preserve-triangle-order> [weighted|first_joint [material:width:height ...]] [--rom]\n", .{});
    std.process.exit(1);
}
