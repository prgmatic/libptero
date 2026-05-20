const n64 = @import("n64");
const mi = n64.interfaces.mips;
const vi = n64.interfaces.video;
const std = @import("std");
const Rgba32 = n64.graphics.color.Rgba32;
const Rgba16 = n64.graphics.color.Rgba16;
const Img16 = n64.graphics.image.ImgRgba16;
const Img32 = n64.graphics.image.ImgRgba32;
const ImgIa8 = n64.graphics.image.ImgIa8;

const img = n64.graphics.image;
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
var cq: rdp.FixedCommandQueue = undefined;
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

    while(true) {
        n64.interrupt.waitForInterrupt(.{.rdp = true, .video = true});
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
    var t:f64 = @floatFromInt(frame_count);
    t /= 60;
    t *= std.math.pi;
    const a = @sin(t) * 60;
    const y: u16 = fb.height / 2 + @as(u16, @intFromFloat(a));

    cq.clear();
    cq.setColorFrame(fb.*);
    cq.setOtherModes(.{.cycle_type = .fill});
    cq.setFillColor(Rgba16.fromInt(0x404040FF));
    cq.setScissor(0, 0, (fb.width - 1) << 2, (fb.height - 1) << 2);
    cq.fillRect(0, 0, (fb.width - 1) << 2, (fb.height - 1) << 2);
    cq.setFillColor(Rgba16.fromInt(0xAB5C0EFF));
    cq.fillRect((fb.width / 2 - 20) << 2, (y - 20) << 2, 
                (fb.width / 2 + 20) << 2, (y + 20) << 2);
 
    // Load and draw sprite
    cq.setCycleType(.one_cycle);
    cq.setBlendMode(.alpha);
    cq.setCombineMode(.decal_rgba);
    cq.setPrimColor(.fromInt(0xAB5C0EFF));
    cq.queue.push(0xEE << 56);
    drawTexture(tex16, 100, 100);
    drawTexture(tex32, 60, 100);
    // (A-D)*C+D
    cq.setCombineMode(.single(.{.rgb_a = .noise, .rgb_c = .tex0, .alpha_d = .tex0}));
    drawTexture(texIa8, 80, 100);

    cq.fullSync();
    n64.cache.writebackData(queue_buffer);
    cq.execute();
    frame_count += 1;
}

fn drawTexture(image: anytype, x: u12, y: u12) void {
    cq.loadTexture(image, .{});
    cq.tileSync();
    cq.textureRectangle(.{
        .ulx = x << 2,
        .uly = y << 2,
        .lrx = @as(u12, @truncate(x + image.width)) << 2,
        .lry = @as(u12, @truncate(y + image.height)) << 2,
        .s = 0,
        .t = 0,
        .dsdx = 1 << 10,   // s5.10: 1 line per cycle
        .dtdy = 1 << 10,   // s5.10: 1 line per cycle
    });
    cq.pipeSync();
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

    tex16 = Img16.init(allocator, 16, 16) catch undefined;
    tex32 = Img32.init(allocator, 16, 16) catch undefined;
    texIa8 = ImgIa8.init(allocator, 16, 16) catch undefined;
    for(0..16) |y| {
        for(0..16) |x| {
            const idx = y * tex16.width + x;
            var d = distance(@as(f32, @floatFromInt(x)) - 7.5, @as(f32, @floatFromInt(y)) - 7.5) / 8;
            d = @max(0, 1.0 - d);
            const c: u8 = @intFromFloat(d * 255);
            const c2: u4 = @intFromFloat(d * 16);
            const r: u8 = @intCast(255 / 16 * x);
            const g: u8 = @intCast(255 / 16 * y);
            
            tex16.texel_data[idx] = .fromBytes(c, c, c, c);
            tex32.texel_data[idx] = .fromBytes(r, g, 0, c);
            texIa8.texel_data[idx] = .{.intensity = c2, .alpha = c2};
        }
    }
    n64.cache.writebackData(tex16.texel_data);
    n64.cache.writebackData(tex32.texel_data);
    n64.cache.writebackData(texIa8.texel_data);

    queue_buffer = allocator.alignedAlloc(u64, std.mem.Alignment.@"32", 64) catch undefined;
    queue = rdp.FixedQueue{ .buffer = queue_buffer };
    cq = rdp.FixedCommandQueue.init(queue);
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
