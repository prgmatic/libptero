const n64 = @import("n64");
const mi = n64.interfaces.mips;
const vi = n64.interfaces.video;
const std = @import("std");
const Rgba16 = n64.graphics.color.Rgba16;
const Img16 = n64.graphics.image.ImgRgba16;
const Img32 = n64.graphics.image.ImgRgba32;
const ImgIa8 = n64.graphics.image.ImgIa8;

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

var queue_buffer: []u64 = undefined;
var queue: rdp.FixedQueue = undefined;
var rq: rdp.FixedRenderQueue = undefined;
var frame_count: u32 = 0;

var tex32: Img32 = undefined;
var tex16: Img16 = undefined;
var texIa8: ImgIa8 = undefined;

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

    while (true) {
        n64.interrupt.waitForInterrupt(.{ .rdp = true, .video = true });
        swapBuffer();
        update();
    }
}

fn swapBuffer() void {
    vi.setFrameBuffer(@intFromPtr(current_frame_buffer.texel_data.ptr));
    if (current_frame_buffer == &frame_buffer0) {
        current_frame_buffer = &frame_buffer1;
    }
    else {
        current_frame_buffer = &frame_buffer0;
    }
}

fn update() void {
    const fb = current_frame_buffer;
    var t: f32 = @floatFromInt(frame_count % 120);
    t /= 60;
    t *= std.math.pi;
    const a = @sin(t) * 60;
    const y: u16 = fb.height / 2 + @as(u16, @intFromFloat(a));

    rq.clear();
    rq.setFrameBuffer(fb.*);
    rq.clearScreen(Rgba16.fromInt(0x404040FF));
    rq.drawRect(fb.width / 2 - 20, y - 20, 40, 40, Rgba16.fromInt(0xAB5C0EFF));

    rq.setBlendMode(.alpha);
    rq.setCombineMode(.decal_rgba);
    rq.setPrimColor(.fromInt(0xAB5C0EFF));
    rq.drawSprite(tex32, 60, 100, .{.rotation = t, .pivot = .center });
    var s:f32 = @sin(t * 4) * 4;
    if(s < 0)
        s = @min(-0.01, s)
    else
        s = @max(0.01, s);
    rq.drawSprite(tex32, 60, 50, .{
        .scale_x = s,
        .scale_y = 4,
        .pivot = .center,
        .s0 = 4,
        .width = 8,
        .rotation = t,
    });


    // (A -B)C + D
    rq.setCombineMode(.single(.{ .rgb_a = .noise, .rgb_c = .tex0, .alpha_d = .tex0 }));
    rq.drawSprite(tex32, 160, 100, .{
        .scale_x = s,
        .scale_y = 4,
        .pivot = .center,
        .rotation = t,
    });
    rq.setCombineMode(.single(.{ .rgb_a = .noise, .rgb_c = .tex0, .alpha_d = .tex0 }));
    rq.drawSprite(texIa8, 80, 100, .{});

    rq.fullSync();
    n64.cache.writebackData(queue_buffer);
    rq.execute();
    frame_count += 1;
}

fn initVideo() void {
    vi.init(.{
        .tv = .ntsc,
        .resolution = .@"320x240p",
        .color_depth = .Rgba5551,
    });

    frame_buffer0 = Img16.init(allocator, width, height) catch undefined;
    frame_buffer1 = Img16.init(allocator, width, height) catch undefined;
    current_frame_buffer = &frame_buffer0;

    tex16  = Img16.init(allocator, 16, 16) catch undefined;
    tex32  = Img32.init(allocator, 16, 16) catch undefined;
    texIa8 = ImgIa8.init(allocator, 16, 16) catch undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            const idx = y * tex16.width + x;
            var d = distance(@as(f32, @floatFromInt(x)) - 7.5, @as(f32, @floatFromInt(y)) - 7.5) / 8;
            d = @max(0, 1.0 - d);
            const c: u8  = @intFromFloat(d * 255);
            const c2: u4 = @intFromFloat(d * 16);
            const r: u8  = @intCast(255 / 16 * x);
            const g: u8  = @intCast(255 / 16 * y);
            tex16.texel_data[idx]  = .fromBytes(c, c, c, c);
            tex32.texel_data[idx]  = .fromBytes(r, g, 0, c);
            texIa8.texel_data[idx] = .{ .intensity = c2, .alpha = c2 };
        }
    }
    n64.cache.writebackData(tex16.texel_data);
    n64.cache.writebackData(tex32.texel_data);
    n64.cache.writebackData(texIa8.texel_data);

    queue_buffer = allocator.alignedAlloc(u64, std.mem.Alignment.@"32", 512) catch undefined;
    queue = rdp.FixedQueue{ .buffer = queue_buffer };
    rq = rdp.FixedRenderQueue.init(queue);
    update();
    vi.setFrameBuffer(@intFromPtr(current_frame_buffer.texel_data.ptr));

    var status = n64.cpu.cp0.regRead(.Status);
    status |= 0x401;
    n64.cpu.cp0.regWrite(.Status, status);
    mi.updateInterrupts(.{
        .set_rdp = true,
        .set_video = true,
    });
}

fn forceCrash() void {
    print("Force a crash?\n", .{});
    const null_ptr: *volatile u32 = @ptrFromInt(4);
    _ = null_ptr.*;
}

fn distance(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}
