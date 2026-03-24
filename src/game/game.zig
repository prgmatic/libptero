const n64 = @import("n64");
const std = @import("std");
const Rgba5551 = n64.graphics.Rgba5551;
const Img16 = n64.graphics.Img16;
const print = n64.debug.print;
var sys_buffer: [1024 * 512]u8 = undefined;
var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&sys_buffer);
const allocator = fixed_buffer_allocator.allocator();
pub const panic = std.debug.FullPanic(n64.crash);
const rdp = n64.graphics.rdp;

export fn interruptHandler(frame: *n64.debug.TrapFrame) callconv(.c) noreturn {
    n64.debug.exepction.exceptionHandler(frame);
}

export fn __start() linksection(".text.startup") void {
    n64.debug.init();
    n64.debug.initFmtBuffer(allocator);
    print("hello from n64\n", .{});
    showColors();

    while(true){}
}


fn showColors() void {
    const width: u16 = 320;
    const height: u16 = 240;

    n64.video.init(.{
        .tv = .Ntsc,
        .width = width,
        .height = height,
        .color_depth = .Rgba5551,
    });
    
    var frame_buffer = Img16.init(allocator, width, height) catch undefined;
    n64.video.setFrameBuffer(@intFromPtr(frame_buffer.pixel_data.ptr));

    for(0..height) |y| {
        for(0..width) |x| {
            const idx = y * width + x;
            const r: u8 = @intCast((x * 255) / width - 1);
            frame_buffer.pixel_data[idx] = Rgba5551.fromU8s(r, 0x2B, 0x40, 0xff); // .{ .r = r, .g = 0x2B, .b = 0x40, .a = 0xFF };
        }
    }
    n64.cache.writebackData(frame_buffer.pixel_data);
    rdpTest(frame_buffer);
}

fn rdpTest(frame_buffer: Img16) void {
    const queue_buffer = allocator.alignedAlloc(u64, std.mem.Alignment.@"32", 64) catch undefined;
    const queue = rdp.FixedQueue{ .buffer = queue_buffer };
    var cq = rdp.FixedCommandQueue.init(queue);
    var frame: u32 = 0;

    while(true) {
        var t:f32 = @floatFromInt(frame);
        t /= 60;
        const a = @sin(t) * 60;
        const y: u16 = frame_buffer.height / 2 + @as(u16, @intFromFloat(a));

        cq.clear();
        cq.setColorFrame(frame_buffer);
        cq.setOtherModes(.{.cycle_type = .Fill});
        cq.setFillColor(Rgba5551.fromU32(0xFF0000FF));
        cq.setScissor(0, 0, (frame_buffer.width - 1) << 2, (frame_buffer.height - 1) << 2);
        cq.fillRect(0, 0, (frame_buffer.width - 1) << 2, (frame_buffer.height - 1) << 2);
        cq.setFillColor(Rgba5551.fromU32(0x00FF00FF));
        cq.fillRect((frame_buffer.width / 2 - 20) << 2, (y - 20) << 2, 
            (frame_buffer.width / 2 + 20) << 2, (y + 20) << 2);
        cq.fullSync();
        n64.cache.writebackData(queue_buffer);
        cq.execute();

        frame += 1;

        const mh = 1000 * 1000;
        const speed = 100 * mh / 60;
        n64.cpu.waitCycles(speed);
        
    }
}


fn forceCrash() void {
    print("Force a crash?\n", .{});
    const null_ptr: *volatile u32 = @ptrFromInt(4);
    _ = null_ptr.*;
}
