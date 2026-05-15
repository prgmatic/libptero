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

const width: u16 = 320;
const height: u16 = 240;
var frame_buffer0: Img16 = undefined;
var frame_buffer1: Img16 = undefined;
var current_frame_buffer: *Img16 = undefined;
var dummy_img: Img16 = undefined;

var queue_buffer: []u64 = undefined;
var queue: rdp.FixedQueue = undefined;
var cq: rdp.FixedCommandQueue = undefined;
var frame_count: u32 = 0;


export fn interruptHandler(frame: *n64.debug.TrapFrame) callconv(.c) noreturn {
    n64.debug.exepction.exceptionHandler(frame);
}

export fn __MI_handler() callconv(.c) void {

    n64.interrupt.interruptHandler();
}

export fn __start() linksection(".text.startup") void {
    n64.debug.init();
    n64.debug.initFmtBuffer(allocator);
    print("hello from n64\n", .{});
    

    initVideo();

    while(true) {
        n64.interrupt.waitForInterrupt(.{.rdp = true, .video = true});
        swapBuffer();
        update();
    }
}

fn swapBuffer() void {

    n64.video.setFrameBuffer(@intFromPtr(current_frame_buffer.pixel_data.ptr));
    if (current_frame_buffer == &frame_buffer0) {
        current_frame_buffer = &frame_buffer1;
    }
    else {
        current_frame_buffer = &frame_buffer0;
    }
}

fn update() void {
    const fb = current_frame_buffer;
    var t:f64 = @floatFromInt(frame_count);
    t /= 60;
    t *= std.math.pi;
    const a = @sin(t) * 60;
    const y: u16 = fb.height / 2 + @as(u16, @intFromFloat(a));

    cq.clear();
    cq.setColorFrame(fb.*);
    cq.setOtherModes(.{.cycle_type = .Fill});
    cq.setFillColor(Rgba5551.fromU32(0x404040FF));
    cq.setScissor(0, 0, (fb.width - 1) << 2, (fb.height - 1) << 2);
    cq.fillRect(0, 0, (fb.width - 1) << 2, (fb.height - 1) << 2);
    cq.setFillColor(Rgba5551.fromU32(0xAB5C0EFF));
    cq.fillRect((fb.width / 2 - 20) << 2, (y - 20) << 2, 
                (fb.width / 2 + 20) << 2, (y + 20) << 2);
    
    cq.setTextureImage(dummy_img);
    cq.setTile(.rgba, .@"16", @truncate((dummy_img.width * 16) / 64), 
        @truncate(@intFromPtr(dummy_img.pixel_data.ptr)), 7, 0, false, false, 0, 0, false, false, 0, 0);
    cq.loadSync();
    cq.loadBlock(0, 0, @truncate(dummy_img.width), 7, @truncate(1 << 11 / 16));
    cq.pipeSync();

    cq.fullSync();
    n64.cache.writebackData(queue_buffer);
    cq.execute();
    frame_count += 1;
}

fn initVideo() void {

    n64.video.init(.{
        .tv = .Ntsc,
        .width = width,
        .height = height,
        .color_depth = .Rgba5551,
    });
    
    frame_buffer0 = Img16.init(allocator, width, height) catch undefined;
    frame_buffer1 = Img16.init(allocator, width, height) catch undefined;
    current_frame_buffer = &frame_buffer0;

    dummy_img = Img16.init(allocator, 16, 16) catch undefined;
    for(0..16) |y| {
        for(0..16) |x| {
            const idx = y * dummy_img.width * x;
            dummy_img.pixel_data[idx] = .fromU8s(@truncate(x * 16), @truncate(y * 16), 0, 0xFF);
        }
    }

    queue_buffer = allocator.alignedAlloc(u64, std.mem.Alignment.@"32", 64) catch undefined;
    queue = rdp.FixedQueue{ .buffer = queue_buffer };
    cq = rdp.FixedCommandQueue.init(queue);
    update();
    n64.video.setFrameBuffer(@intFromPtr(current_frame_buffer.pixel_data.ptr));
    
    var status = n64.cpu.cp0.regRead(.Status);
    status |= 0x401;
    n64.cpu.cp0.regWrite(.Status, status);
    n64.cpu.updateInterrupts(.{
        .set_rdp = true,
        .set_video = true,
    });
}


fn forceCrash() void {
    print("Force a crash?\n", .{});
    const null_ptr: *volatile u32 = @ptrFromInt(4);
    _ = null_ptr.*;
}
