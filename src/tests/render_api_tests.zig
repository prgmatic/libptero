const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

var geometry: n64.graphics.geometry.Context = undefined;
var pixels: [8 * 8]n64.graphics.color.Rgba32 align(64) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "Render API: submission completes RSP and RDP resources", .run = completion },
};

fn completion() !void {
    geometry.init();
    const image: n64.graphics.image.ImgRgba32 = .{ .width = 8, .height = 8, .texel_data = &pixels };
    const render = &geometry.render;
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
}
