const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

var runtime: n64.rsp.Runtime = undefined;
var renderer: n64.graphics.Renderer = undefined;
var geometry: n64.graphics.geometry.Context = undefined;
var pixels: [8 * 8]n64.graphics.color.Rgba32 align(64) = undefined;

pub const tests = [_]runner.Test{
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
