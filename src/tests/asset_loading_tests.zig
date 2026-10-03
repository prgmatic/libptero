const std = @import("std");
const n64 = @import("n64");
const assets = @import("audio_test_assets");
const testing = @import("assert.zig");
const runner = @import("runner.zig");
const timeout = 1_000_000;
var storage: [1024]u8 align(16) = undefined;
var other_storage: [1024]u8 align(16) = undefined;
var heap_storage: [16 * 1024]u8 align(16) = undefined;
var renderer: n64.graphics.geometry.Renderer = undefined;
var pixels: [64]n64.graphics.color.Rgba32 align(64) = undefined;
var depth_pixels: [64]u16 align(64) = undefined;
var viewport: n64.graphics.geometry.Viewport = undefined;
var transform: n64.math.FixedMat4 align(16) = undefined;
var poses: [3]n64.math.FixedMat4 align(16) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "Assets: all texture formats match resident bytes and palettes", .run = textures },
    .{ .name = "Assets: direct DMA retains ownership and handles PI contention", .run = ownership },
    .{ .name = "Assets: typed models preserve materials, weights and joint groups", .run = models },
    .{ .name = "Assets: recycled texture and TLUT addresses render new contents", .run = recycledTextures },
    .{ .name = "Assets: loaded weighted and first-joint models render identically", .run = renderedModels },
};

fn textures() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&heap_storage);
    const allocator = fixed.allocator();
    inline for (.{ "rgba16", "rgba32", "yuv16", "ci4", "ci8", "ia4", "ia8", "ia16", "i4", "i8" }) |format| {
        const source = @field(assets, "texture_rom_" ++ format);
        const resident = @field(assets, "texture_resident_" ++ format);
        var loaded = try source.init(allocator);
        try loaded.load(timeout);
        const image = try loaded.view();
        try testing.expectEqual(resident.width, image.width);
        try testing.expectEqual(resident.height, image.height);
        try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(resident.texel_data), std.mem.sliceAsBytes(image.texel_data)));
        if (@hasField(@TypeOf(image), "palette")) try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(resident.palette), std.mem.sliceAsBytes(image.palette)));
        try testing.expectEqual(@intFromPtr(loaded.bytes.ptr), @intFromPtr(image.texel_data.ptr));
        try testing.expect(image.content_id != 0);
        try loaded.deinit(allocator);
    }
}

fn ownership() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&heap_storage);
    const allocator = fixed.allocator();
    @memset(&storage, 0xaa);
    var first = try assets.texture_rom_rgba16.initBuffer(&storage);
    var second = try assets.texture_rom_rgba16.initBuffer(&other_storage);
    try first.begin();
    if (second.begin()) |_| return error.ExpectedPiBusy else |err| try testing.expect(err == error.PiBusy);
    if (first.deinit(allocator)) |_| return error.ExpectedAssetBusy else |err| try testing.expect(err == error.AssetBusy);
    first.wait(0) catch |err| try testing.expect(err == error.PiTimeout);
    try first.load(timeout);
    const old_id = (try first.view()).content_id;
    try first.load(timeout);
    try testing.expectEqual(old_id, (try first.view()).content_id);
    try testing.expectEqual(@as(u8, 0xaa), storage[assets.texture_rom_rgba16.storageSize()]);
    try second.load(timeout);
    try first.unload();
    try first.begin();
    try first.wait(timeout);
    try testing.expect(old_id != (try first.view()).content_id);
    try first.deinit(allocator);
    try second.deinit(allocator);
}

fn models() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&heap_storage);
    const allocator = fixed.allocator();
    inline for (.{ "model", "weighted", "joint" }) |name| {
        var loaded = try @field(assets, name ++ "_rom").init(allocator);
        try loaded.load(timeout);
        const value = try loaded.view();
        const reference = @field(assets, name ++ "_resident");
        try testing.expectEqual(reference.model.parts.len, value.model.parts.len);
        for (value.model.parts, reference.model.parts) |part, expected| {
            try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(expected.vertices), std.mem.sliceAsBytes(part.vertices)));
            try testing.expect(std.mem.eql(i16, expected.strip_indices, part.strip_indices));
            try testing.expectEqual(expected.vertex_count, part.vertex_count);
            try testing.expectEqual(expected.vertex_offset, part.vertex_offset);
            try testing.expectEqual(expected.bone, part.bone);
            try testing.expectEqual(expected.skin, part.skin);
            try testing.expect(std.meta.eql(value.material(part.material_index), reference.material(part.material_index)));
            for (expected.influences, part.influences) |a, b| try testing.expect(std.meta.eql(a, b));
            try testing.expect(@intFromPtr(part.vertices.ptr) >= @intFromPtr(loaded.bytes.ptr));
            try testing.expect(@intFromPtr(part.vertices.ptr) + std.mem.sliceAsBytes(part.vertices).len <= @intFromPtr(loaded.bytes.ptr) + loaded.bytes.len);
        }
        try testing.expectEqual(reference.model.nodes.len, value.model.nodes.len);
        try testing.expectEqual(reference.model.skins.len, value.model.skins.len);
        try testing.expectEqual(reference.model.animations.len, value.model.animations.len);
        if (value.model.animations.len != 0) {
            try testing.expect(value.model.findAnimation("move") != null);
            try testing.expectEqual(@as(f32, 1), value.model.animations[0].duration);
        }
        try loaded.deinit(allocator);
    }
}

fn drawTexture(image: anytype) !void {
    renderer.beginFrame(try n64.graphics.image.ImgRgba32.initBuffer(&pixels, 8, 8), .{ .clear_color = .black });
    renderer.rdp.render.setState(.textured_sprite);
    renderer.rdp.render.setPrimColor(.white);
    renderer.rdp.render.setTextureFilter(.point);
    renderer.rdp.render.drawSprite(image, 0, 0, .{});
    try renderer.submit().wait(.{ .max_attempts = timeout });
    n64.cache.invalidateData(&pixels);
}

fn recycledTextures() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&heap_storage);
    const allocator = fixed.allocator();
    renderer.init();
    defer renderer.deinit();
    inline for (.{ .{ "texture_rom_rgba16", "blue_rom" }, .{ "texture_rom_ci4", "blue_palette_rom" } }) |names| {
        var red = try @field(assets, names[0]).initBuffer(&storage);
        try red.load(timeout);
        try drawTexture(try red.view());
        try testing.expect(pixels[0].r > 240 and pixels[0].b < 10);
        try red.deinit(allocator);
        var blue = try @field(assets, names[1]).initBuffer(&storage);
        try blue.load(timeout);
        try drawTexture(try blue.view());
        try testing.expect(pixels[0].b > 240 and pixels[0].r < 10);
        try blue.deinit(allocator);
    }
}

fn drawModel(asset: anytype) ![64]u32 {
    renderer.beginFrame(try n64.graphics.image.ImgRgba32.initBuffer(&pixels, 8, 8), .{
        .depth = try n64.graphics.depth.Image.initBuffer(&depth_pixels, 8, 8),
        .clear_depth = true,
        .clear_color = .black,
    });
    renderer.geometry.attachViewport(&viewport);
    renderer.geometry.drawModelWithTransform(asset, &transform);
    try renderer.submit().wait(.{ .max_attempts = timeout });
    n64.cache.invalidateData(&pixels);
    var result: [64]u32 = undefined;
    for (&result, pixels) |*rgb, pixel| rgb.* = @as(u32, @bitCast(pixel)) >> 8;
    return result;
}

fn renderedModels() !void {
    var fixed = std.heap.FixedBufferAllocator.init(&heap_storage);
    const allocator = fixed.allocator();
    renderer.init();
    defer renderer.deinit();
    viewport = .init(8, 8);
    renderer.geometry.setAmbientLight(.white);
    transform = n64.math.Mat4.fromSrtEuler(.splat(1.0 / 128.0), .zero, .zero).toFixed();
    inline for (.{ "weighted", "joint" }) |name| {
        var loaded = try @field(assets, name ++ "_rom").initBuffer(&storage);
        try loaded.load(timeout);
        const value = try loaded.view();
        const reference = @field(assets, name ++ "_resident");
        var skeleton = try n64.graphics.animation.Skeleton.init(allocator, value.model.nodes);
        var player: n64.graphics.animation.Player = .{ .clip = value.model.findAnimation("move").? };
        player.seek(0.5);
        player.apply(&skeleton);
        skeleton.update();
        if (comptime std.mem.eql(u8, name, "weighted")) {
            var mesh = try n64.graphics.model.SkinnedModel.init(allocator, value.model);
            mesh.update(&skeleton);
            const actual = try drawModel(value.withModel(mesh.model()));
            try expectVisible(&actual);
            var expected_mesh = try n64.graphics.model.SkinnedModel.init(allocator, reference.model);
            var expected_skeleton = try n64.graphics.animation.Skeleton.init(allocator, reference.model.nodes);
            var expected_player: n64.graphics.animation.Player = .{ .clip = reference.model.findAnimation("move").? };
            expected_player.seek(0.5);
            expected_player.apply(&expected_skeleton);
            expected_skeleton.update();
            expected_mesh.update(&expected_skeleton);
            const expected = try drawModel(reference.withModel(expected_mesh.model()));
            try testing.expect(std.mem.eql(u32, &expected, &actual));
            expected_mesh.deinit(allocator);
            expected_skeleton.deinit(allocator);
            mesh.deinit(allocator);
        } else {
            skeleton.writeMatrices(&poses);
            renderer.geometry.setPose(&poses);
            const actual = try drawModel(value);
            try expectVisible(&actual);
            const expected = try drawModel(reference);
            try testing.expect(std.mem.eql(u32, &expected, &actual));
        }
        skeleton.deinit(allocator);
        try loaded.deinit(allocator);
    }
}

fn expectVisible(image: []const u32) !void {
    for (image) |pixel| if (pixel != 0) return;
    return error.EmptyModelRendering;
}
