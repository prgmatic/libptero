const n64 = @import("n64");
const std = @import("std");
const Rgba32 = n64.color.Rgba32;
const print = n64.debug.print;
var sys_buffer: [1024]u8 = undefined;
var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&sys_buffer);
const allocator = fixed_buffer_allocator.allocator();

export fn __start() linksection(".text.startup") void {
    n64.debug.init(.IsViewer);
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
    
    const frame_buffer: *[width * height]Rgba32 = @ptrFromInt(0xA0100000);
    n64.video.setFrameBuffer(@intFromPtr(frame_buffer));
    @import("simple-scene.zig").render(frame_buffer, width, height);
}
