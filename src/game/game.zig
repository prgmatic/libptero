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
    // joybusTest();

    while(true){}
}


fn showColors() void {
    const width: u32 = 320;
    const height: u32 = 240;

    n64.video.init(.{
        .tv = .Ntsc,
        .width = width,
        .height = height,
        .color_depth = .Rgba32,
    });
    
    const frame_buffer: *[width * height]Rgba32 = @ptrFromInt(0xA0100000);
    n64.video.setFrameBuffer(@intFromPtr(frame_buffer));

    for(0..height) |y| {
        for(0..width) |x| {
            const idx = y * width + x;
            const r: u8 = @intCast((x * 255) / width - 1);
            frame_buffer[idx] = .{ .r = r, .g = 0x2B, .b = 0x40, .a = 0xFF };
        }
    }
}

fn joybusTest() void {
    n64.io.joypad.init(allocator);
    n64.io.joypad.updateJoypadStatus();
    
    print("Joypad status {s}\n", .{@tagName(n64.io.joypad.joypads[0].style)});
    while(true){
        n64.io.joypad.pollJoypadState();
        const s = n64.io.joypad.joypads[0].state;
        print("U: {} D: {} L: {} R: {}\n", .{s.d_up, s.d_down, s.d_left, s.d_right});
    }
}
