const n64 = @import("n64");
const std = @import("std");
const Rgba32 = n64.graphics.Rgba32;
const Img32 = n64.graphics.Img32;
const print = n64.debug.print;
var sys_buffer: [1024 * 812]u8 = undefined;
var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&sys_buffer);
const allocator = fixed_buffer_allocator.allocator();

export fn __start() linksection(".text.startup") void {
    n64.debug.init();
    n64.debug.initFmtBuffer(allocator);
    print("hello from n64\n", .{});
    showColors();

    while(true){}
}



fn showColors() void {
    const width: u32 = 640;
    const height: u32 = 240;

    n64.video.init(.{
        .tv = .Ntsc,
        .width = width,
        .height = height,
        .color_depth = .Rgba32,
        .scan = .Progressive,
        .gamma_enabled = true,
    });
    
    var frame_buffer = Img32.init(allocator, width, height) catch undefined;
    frame_buffer.fill(.{.r = 0, .g = 0, .b = 0, .a = 0});
    n64.video.setFrameBuffer(@intFromPtr(frame_buffer.pixel_data.ptr));
    @import("simple-scene.zig").render(frame_buffer.pixel_data, width, height);

    n64.cpu.cache.writebackData(frame_buffer.pixel_data);
}
