//! Small generated GLBs for asset-loading regressions; no binary fixtures in Git.
const std = @import("std");
const png = @import("../tools/framebuffer_capture/png.zig");

pub fn texture(b: *std.Build, name: []const u8, rgba: [16]u8) std.Build.LazyPath {
    return b.addWriteFiles().add(name, png.encode(b.allocator, 2, 2, &rgba) catch @panic("PNG fixture encoding failed"));
}

/// Embedded texture, two joints, weighted vertices, and a translation clip.
pub fn skinnedModel(b: *std.Build) std.Build.LazyPath {
    const image = png.encode(b.allocator, 2, 2, &(@as([16]u8, .{ 255, 0, 0, 255 } ** 4))) catch @panic("PNG fixture encoding failed");
    const json = b.fmt(
        \\{{"asset":{{"version":"2.0"}},"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[{{"buffer":0,"byteLength":36}},{{"buffer":0,"byteOffset":36,"byteLength":6}},{{"buffer":0,"byteOffset":44,"byteLength":24}},{{"buffer":0,"byteOffset":68,"byteLength":12}},{{"buffer":0,"byteOffset":80,"byteLength":48}},{{"buffer":0,"byteOffset":128,"byteLength":8}},{{"buffer":0,"byteOffset":136,"byteLength":24}},{{"buffer":0,"byteOffset":160,"byteLength":{d}}}],
        \\"accessors":[{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}},{{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}},{{"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"}},{{"bufferView":3,"componentType":5121,"count":3,"type":"VEC4"}},{{"bufferView":4,"componentType":5126,"count":3,"type":"VEC4"}},{{"bufferView":5,"componentType":5126,"count":2,"type":"SCALAR"}},{{"bufferView":6,"componentType":5126,"count":2,"type":"VEC3"}}],
        \\"nodes":[{{"mesh":0,"skin":0}},{{"name":"root","children":[2]}},{{"name":"joint","translation":[1,0,0]}}],"skins":[{{"joints":[1,2]}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0,"TEXCOORD_0":2,"JOINTS_0":3,"WEIGHTS_0":4}},"indices":1,"material":0}}]}}],
        \\"images":[{{"bufferView":7,"mimeType":"image/png"}}],"textures":[{{"source":0}}],"materials":[{{"doubleSided":true,"pbrMetallicRoughness":{{"baseColorTexture":{{"index":0}}}}}}],
        \\"animations":[{{"name":"move","samplers":[{{"input":5,"output":6}}],"channels":[{{"sampler":0,"target":{{"node":2,"path":"translation"}}}}]}}]}}
    , .{ 160 + image.len, image.len });
    const binary = b.allocator.alloc(u8, 160 + image.len) catch @panic("OOM");
    @memset(binary, 0);
    const positions = [_]f32{ -1, -1, 0, 1, -1, 0, 0, 1, 0 };
    for (positions, 0..) |position, i| std.mem.writeInt(u32, binary[i * 4 ..][0..4], @bitCast(position), .little);
    for (0..3) |i| {
        std.mem.writeInt(u16, binary[36 + i * 2 ..][0..2], @intCast(i), .little);
        binary[68 + i * 4] = @intCast(i % 2);
        binary[69 + i * 4] = @intCast(1 - i % 2);
        std.mem.writeInt(u32, binary[80 + i * 16 ..][0..4], @bitCast(@as(f32, 0.75)), .little);
        std.mem.writeInt(u32, binary[84 + i * 16 ..][0..4], @bitCast(@as(f32, 0.25)), .little);
    }
    std.mem.writeInt(u32, binary[132..136], @bitCast(@as(f32, 1)), .little);
    std.mem.writeInt(u32, binary[148..152], @bitCast(@as(f32, 1)), .little);
    @memcpy(binary[160..], image);
    return glb(b, "rom-skinned.glb", json, binary);
}

pub fn model(b: *std.Build) std.Build.LazyPath {
    const json =
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":42}],"bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],"materials":[{"name":"triangle","doubleSided":true}]}
    ;
    var binary: [42]u8 = @splat(0);
    const positions = [_]f32{ -1, -1, 0, 1, -1, 0, 0, 1, 0 };
    for (positions, 0..) |position, i| std.mem.writeInt(u32, binary[i * 4 ..][0..4], @bitCast(position), .little);
    for (0..3) |i| std.mem.writeInt(u16, binary[36 + i * 2 ..][0..2], @intCast(i), .little);
    return glb(b, "rom-model.glb", json, &binary);
}

fn glb(b: *std.Build, name: []const u8, json: []const u8, binary: []const u8) std.Build.LazyPath {
    const json_len = std.mem.alignForward(usize, json.len, 4);
    const binary_len = std.mem.alignForward(usize, binary.len, 4);
    const output = b.allocator.alloc(u8, 28 + json_len + binary_len) catch @panic("OOM");
    @memset(output, 0);
    std.mem.writeInt(u32, output[0..4], 0x46546c67, .little);
    std.mem.writeInt(u32, output[4..8], 2, .little);
    std.mem.writeInt(u32, output[8..12], @intCast(output.len), .little);
    std.mem.writeInt(u32, output[12..16], @intCast(json_len), .little);
    std.mem.writeInt(u32, output[16..20], 0x4e4f534a, .little);
    @memset(output[20..][0..json_len], ' ');
    @memcpy(output[20..][0..json.len], json);
    const bin = output[20 + json_len ..];
    std.mem.writeInt(u32, bin[0..4], @intCast(binary_len), .little);
    std.mem.writeInt(u32, bin[4..8], 0x004e4942, .little);
    @memcpy(bin[8..][0..binary.len], binary);
    return b.addWriteFiles().add(name, output);
}
