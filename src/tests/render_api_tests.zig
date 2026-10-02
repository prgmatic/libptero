const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

var runtime: n64.rsp.Runtime = undefined;
var renderer: n64.graphics.Renderer = undefined;
var geometry: n64.graphics.geometry.Context = undefined;
var owned_renderer: n64.graphics.geometry.Renderer = undefined;
var pixels: [8 * 8]n64.graphics.color.Rgba32 align(64) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "Render API: mutable models and automatic queue rollover", .run = mutableModelRollover },
    .{ .name = "Render API: model draw scopes a borrowed transform", .run = transformedModel },
    .{ .name = "Render API: owning geometry renderer lifecycle", .run = owningRenderer },
    .{ .name = "Render API: owned depth clears and restores color target", .run = depthClear },
    .{ .name = "Render API: standalone RDP setup and optional geometry", .run = standalone },
    .{ .name = "Render API: submission completes RSP and RDP resources", .run = completion },
};

fn completion() !void {
    runtime.init();
    renderer.init(&runtime);
    geometry.init(&renderer);
    const image: n64.graphics.image.ImgRgba32 = .{ .width = 8, .height = 8, .texel_data = &pixels };
    const render = geometry.render;
    render.clear();
    render.setFrameBuffer(image);
    render.clearScreen(n64.graphics.color.Rgba32.green);
    const first = geometry.submit();
    const copy = first;
    try testing.expect(first.rsp != null);
    try first.wait(.{ .max_attempts = 1_000_000 });
    try testing.expect(first.isComplete());
    try testing.expect(!geometry.queue.storage.syncpoint_pending);
    n64.cache.invalidateData(&pixels);
    for (pixels) |pixel| try testing.expectEqual(n64.graphics.color.Rgba32.green, pixel);

    render.clear();
    render.clearScreen(n64.graphics.color.Rgba32.blue);
    const second = geometry.submit();
    try second.wait(.{ .max_attempts = 1_000_000 });
    // Older completion copies remain valid after the next submission.
    try copy.wait(.{ .max_attempts = 0 });
    n64.cache.invalidateData(&pixels);
    for (pixels) |pixel| try testing.expectEqual(n64.graphics.color.Rgba32.blue, pixel);
    geometry.deinit();
    renderer.deinit();
    runtime.deinit();
}

fn standalone() !void {
    runtime.init();
    renderer.init(&runtime);
    const table = n64.rsp.programs.command_dispatcher_symbols.overlay_data_rdram;
    // Geometry occupies slot 1 only after it is explicitly attached.
    try testing.expectEqual(@as(u32, 0), n64.rsp.io.readDmem(u32, table + 4).*);
    const image: n64.graphics.image.ImgRgba32 = .{ .width = 8, .height = 8, .texel_data = &pixels };
    renderer.render.setFrameBuffer(image);
    renderer.render.clearScreen(n64.graphics.color.Rgba32.green);
    const before_geometry = renderer.submit();
    try before_geometry.wait(.{ .max_attempts = 1_000_000 });
    n64.cache.invalidateData(&pixels);
    for (pixels) |pixel| try testing.expectEqual(n64.graphics.color.Rgba32.green, pixel);
    geometry.init(&renderer);
    try testing.expect(renderer.geometry_attached);
    try testing.expect(geometry.queue == &renderer.queue);
    try testing.expect(geometry.render == &renderer.render);
    geometry.deinit();
    try testing.expect(!renderer.geometry_attached);
    try testing.expectEqual(@as(u32, 0), n64.rsp.io.readDmem(u32, table + 4).*);
    renderer.render.clearScreen(n64.graphics.color.Rgba32.blue);
    const after_geometry = renderer.submit();
    try after_geometry.wait(.{ .max_attempts = 1_000_000 });
    n64.cache.invalidateData(&pixels);
    for (pixels) |pixel| try testing.expectEqual(n64.graphics.color.Rgba32.blue, pixel);
    renderer.deinit();
    runtime.deinit();
}

fn depthClear() !void {
    var memory: [1024]u8 align(64) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fixed.allocator();
    var color = try n64.graphics.image.ImageBuffer(n64.graphics.color.Rgba16).init(allocator, 8, 8);
    defer color.deinit(allocator);
    var depth = try n64.graphics.DepthBuffer.init(allocator, 8, 8);
    defer depth.deinit(allocator);
    @memset(color.pixels, .black);
    @memset(depth.pixels, 0);
    n64.cache.writebackData(color.pixels);
    n64.cache.writebackData(depth.pixels);
    runtime.init();
    renderer.init(&runtime);
    renderer.beginFrame(color.view(), .{
        .depth = depth.view(),
        .clear_color = n64.graphics.color.Rgba16.green,
        .clear_depth = true,
    });
    const submitted = renderer.submit();
    try submitted.wait(.{ .max_attempts = 1_000_000 });
    n64.cache.invalidateData(depth.pixels);
    n64.cache.invalidateData(color.pixels);
    for (depth.pixels) |value| try testing.expectEqual(n64.graphics.depth.clear_value, value);
    for (color.pixels) |value| try testing.expectEqual(n64.graphics.color.Rgba16.green, value);
    renderer.deinit();
    runtime.deinit();
}

fn owningRenderer() !void {
    owned_renderer.init();
    try testing.expect(owned_renderer.geometry.render == &owned_renderer.rdp.render);
    try testing.expect(owned_renderer.geometry.queue == &owned_renderer.rdp.queue);
    const image = try n64.graphics.image.ImgRgba32.initBuffer(&pixels, 8, 8);
    owned_renderer.beginFrame(image, .{ .clear_color = .blue });
    const completion_token = owned_renderer.submit();
    try testing.expect(completion_token.rsp != null);
    try completion_token.wait(.{ .max_attempts = 1_000_000 });
    n64.cache.invalidateData(&pixels);
    for (pixels) |pixel| try testing.expectEqual(n64.graphics.color.Rgba32.blue, pixel);
    owned_renderer.deinit();
    const table = n64.rsp.programs.command_dispatcher_symbols.overlay_data_rdram;
    try testing.expectEqual(@as(u32, 0), n64.rsp.io.readDmem(u32, table + 4).*);
    try testing.expectEqual(@as(u32, 0), n64.rsp.io.readDmem(u32, table + 12 * 4).*);
    // All registrations can be acquired again after teardown.
    owned_renderer.init();
    owned_renderer.deinit();
}

var model_vertices: [2]n64.graphics.geometry.VertexPair align(16) = .{
    .{ .pos_a = .{ -1, -1, 0 }, .normal_a = 0, .pos_b = .{ 1, -1, 0 }, .normal_b = 0, .color_a = .white, .color_b = .white },
    .{ .pos_a = .{ 0, 1, 0 }, .normal_a = 0, .pos_b = .{ 0, 1, 0 }, .normal_b = 0, .color_a = .white, .color_b = .white },
};
var model_indices: [3]i16 align(8) = .{ 0, 36, 0x4048 };
var model_transform: n64.math.FixedMat4 align(16) = .identity;
var model_viewport = n64.graphics.geometry.Viewport.init(8, 8);

const TestMaterials = struct {
    pub fn get(_: @This(), _: u16) n64.graphics.model.Material {
        return .{
            .flags = .{ .no_light = true },
            .combine = .primitive,
            .primitive = .green,
        };
    }
    pub fn bind(_: @This(), context: *n64.graphics.geometry.Context, _: u16, material: n64.graphics.model.Material) void {
        material.apply(context);
    }
    pub fn apply(self: @This(), context: *n64.graphics.geometry.Context, index: u16) void {
        self.bind(context, index, self.get(index));
    }
};

fn mutableModelRollover() !void {
    var memory: [1024]u8 align(64) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fixed.allocator();
    const parts = [_]n64.graphics.model.Part{.{
        .vertices = &model_vertices,
        .strip_indices = &model_indices,
        .material_index = 0,
        .vertex_count = 3,
    }};
    const source: n64.graphics.model.Asset(TestMaterials) = .{
        .model = .{ .parts = &parts },
        .materials = .{},
    };
    var mesh = try n64.graphics.model.MutableModel.init(allocator, source.model);
    defer mesh.deinit(allocator);
    var vertices = mesh.vertices(0).iterator();
    while (vertices.next()) |vertex| vertex.position[0] += 1;
    try testing.expectEqual(@as(i16, -1), model_vertices[0].pos_a[0]);
    const asset = source.withModel(mesh.model()).withOverrides(.{.{ .primitive = n64.graphics.color.Rgba32.blue }});
    owned_renderer.init();
    const image = try n64.graphics.image.ImgRgba32.initBuffer(&pixels, 8, 8);
    owned_renderer.beginFrame(image, .{ .clear_color = .black });
    model_viewport = .init(8, 8);
    owned_renderer.geometry.attachViewport(&model_viewport);
    // A scene larger than the old example's 32-draw workaround must stream
    // without caller-selected batching or intermediate completion waits.
    for (0..250) |_| owned_renderer.geometry.drawModel(asset);
    try owned_renderer.submit().wait(.{ .max_attempts = 100_000_000 });
    defer owned_renderer.deinit();
    n64.cache.invalidateData(&pixels);
    var blue: usize = 0;
    for (pixels) |pixel| if (pixel.r == 0 and pixel.g == 0 and pixel.b == 255) {
        blue += 1;
    };
    try testing.expect(blue > 0 and blue < pixels.len);
}

fn transformedModel() !void {
    owned_renderer.init();
    const image = try n64.graphics.image.ImgRgba32.initBuffer(&pixels, 8, 8);
    owned_renderer.beginFrame(image, .{ .clear_color = .black });
    model_viewport = .init(8, 8);
    owned_renderer.geometry.attachViewport(&model_viewport);
    model_transform = n64.math.Mat4.fromSrtEuler(.splat(0.5), .zero, .init(0.25, 0, 0)).toFixed();
    const parts = [_]n64.graphics.model.Part{.{
        .vertices = &model_vertices,
        .strip_indices = &model_indices,
        .material_index = 0,
        .vertex_count = 3,
        .data_usage = .dynamic,
    }};
    const asset: n64.graphics.model.Asset(TestMaterials) = .{
        .model = .{ .parts = &parts },
        .materials = .{},
    };
    owned_renderer.geometry.drawModelWithTransform(asset, &model_transform);
    const submitted = owned_renderer.submit();
    try submitted.wait(.{ .max_attempts = 1_000_000 });
    defer owned_renderer.deinit();
    n64.cache.invalidateData(&pixels);
    var green_pixels: usize = 0;
    // Validate RGB independently of alpha written by rasterization.
    for (pixels) |pixel| {
        if (pixel.r == 0 and pixel.g == 255 and pixel.b == 0) green_pixels += 1;
    }
    try testing.expect(green_pixels > 0 and green_pixels < pixels.len);
    n64.cache.invalidateData(&owned_renderer.geometry.matrix_stack);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&model_transform), std.mem.asBytes(&owned_renderer.geometry.matrix_stack[1])));
    // Drawing restores the camera matrix and its original stack position.
    const symbols = n64.rsp.programs.geometry_overlay_symbols;
    const stack = @as(u32, @truncate(@intFromPtr(&owned_renderer.geometry.matrix_stack))) & 0x00ff_ffff;
    try testing.expectEqual(stack, n64.rsp.io.readDmem(u32, symbols.matrix_stack_pointer).*);
    const camera_bytes = std.mem.asBytes(&model_viewport.camera);
    for (0..16) |index| {
        const word = std.mem.readInt(u32, camera_bytes[index * 4 ..][0..4], .big);
        try testing.expectEqual(word, n64.rsp.io.readDmem(u32, symbols.matrix_mv + @as(u32, @intCast(index)) * 4).*);
    }
    // An explicitly loaded matrix with drawModel produces the same RGB image
    // as the scoped helper, including material binding and vertex submission.
    var expected_rgb: [pixels.len]u32 = undefined;
    for (&expected_rgb, pixels) |*expected, pixel| expected.* = @as(u32, @bitCast(pixel)) >> 8;
    owned_renderer.beginFrame(image, .{ .clear_color = .black });
    owned_renderer.geometry.setMatrix(&model_transform, false);
    owned_renderer.geometry.drawModel(asset);
    const direct = owned_renderer.submit();
    try direct.wait(.{ .max_attempts = 1_000_000 });
    n64.cache.invalidateData(&pixels);
    for (expected_rgb, pixels) |expected, pixel| {
        try testing.expectEqual(expected, @as(u32, @bitCast(pixel)) >> 8);
    }
}
