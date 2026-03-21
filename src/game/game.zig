const n64 = @import("n64");
const std = @import("std");
const Rgba32 = n64.graphics.Rgba32;
const Img32 = n64.graphics.Img32;
const print = n64.debug.print;
var sys_buffer: [1024 * 512]u8 = undefined;
var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&sys_buffer);
const allocator = fixed_buffer_allocator.allocator();
pub const panic = std.debug.FullPanic(n64.crash);

export fn interruptHandler(frame: *n64.debug.TrapFrame) callconv(.c) noreturn {
    n64.debug.exepction.exceptionHandler(frame);
}

export fn __start() linksection(".text.startup") void {
    n64.debug.init();
    n64.debug.initFmtBuffer(allocator);
    print("hello from n64\n", .{});
    showColors();
    forceCrash();

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
    
    var frame_buffer = Img32.init(allocator, width, height) catch undefined;
    n64.video.setFrameBuffer(@intFromPtr(frame_buffer.pixel_data.ptr));

    for(0..height) |y| {
        for(0..width) |x| {
            const idx = y * width + x;
            const r: u8 = @intCast((x * 255) / width - 1);
            frame_buffer.pixel_data[idx] = .{ .r = r, .g = 0x2B, .b = 0x40, .a = 0xFF };
        }
    }
    n64.cpu.cache.writebackData(frame_buffer.pixel_data);
}

fn forceCrash() void {
    print("Force a crash?\n", .{});
    const null_ptr: *volatile u32 = @ptrFromInt(4);
    _ = null_ptr.*;
}
