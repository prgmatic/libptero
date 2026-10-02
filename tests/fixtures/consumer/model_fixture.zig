const std = @import("std");

/// Generate a tiny GLB in the build cache, so the consumer exercises conversion
/// without checking generated binary assets into the repository.
pub fn create(b: *std.Build) std.Build.LazyPath {
    const json =
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":42}],"bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],"materials":[{"name":"fixture","doubleSided":true}]}
    ;
    const json_len = std.mem.alignForward(usize, json.len, 4);
    const binary_len = 44;
    const output = b.allocator.alloc(u8, 12 + 8 + json_len + 8 + binary_len) catch @panic("OOM");
    @memset(output, 0);
    std.mem.writeInt(u32, output[0..4], 0x46546c67, .little);
    std.mem.writeInt(u32, output[4..8], 2, .little);
    std.mem.writeInt(u32, output[8..12], @intCast(output.len), .little);
    std.mem.writeInt(u32, output[12..16], @intCast(json_len), .little);
    std.mem.writeInt(u32, output[16..20], 0x4e4f534a, .little);
    @memset(output[20..][0..json_len], ' ');
    @memcpy(output[20..][0..json.len], json);
    const bin = output[20 + json_len ..];
    std.mem.writeInt(u32, bin[0..4], binary_len, .little);
    std.mem.writeInt(u32, bin[4..8], 0x004e4942, .little);
    const positions = [_]f32{ -1, -1, 0, 1, -1, 0, 0, 1, 0 };
    for (positions, 0..) |position, i| std.mem.writeInt(u32, bin[8 + i * 4 ..][0..4], @bitCast(position), .little);
    for (0..3) |i| std.mem.writeInt(u16, bin[44 + i * 2 ..][0..2], @intCast(i), .little);
    return b.addWriteFiles().add("fixture-model.glb", output);
}
