//! Matched hardware benchmark for the RSP-backed RDP overlay.
//! Keep constants and workload synchronized with benchmarks/libdragon-rdp-stars/main.c.
const std = @import("std");
const n64 = @import("n64");

const rsp = n64.rsp;
const rdp = n64.graphics.rdp;
const Rgba16 = n64.graphics.color.Rgba16;
const Rgba32 = n64.graphics.color.Rgba32;
const Img16 = n64.graphics.image.ImgRgba16;
const Img32 = n64.graphics.image.ImgRgba32;

const width: u16 = 320;
const height: u16 = 240;
const warmup_count = 2;
const sample_count = 8;
const star_counts = [_]usize{ 32, 64, 128 };
const rotation: f32 = 0.25;
const timeout = 100_000_000;
const colors = [_]Rgba32{ .red, .blue, .green, .cyan, .magenta, .yellow };

var memory: [1024 * 384]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&memory);
var framebuffer: Img16 = undefined;
var texture: Img32 = undefined;
var queue: rsp.Queue = undefined;
var overlay: rsp.Overlay = undefined;
var dynamic_buffers: [2][rsp.rdp_dynamic_buffer_len]u8 align(16) = undefined;

pub fn main() !void {
    n64.debug.init();
    try n64.debug.initFmtBuffer(fba.allocator());
    n64.interfaces.video.init(.{ .resolution = .@"320x240p", .color_depth = .Rgba5551 });
    framebuffer = try Img16.init(fba.allocator(), width, height);
    texture = try Img32.init(fba.allocator(), 32, 32);
    initTexture();
    initRdp();
    enableInterrupts();

    n64.debug.print("RDP stars benchmark: libptero overlay, warmup={}, samples={}\n", .{ warmup_count, sample_count });
    for (star_counts) |count| try measure(count);
    n64.debug.writeStr("@@RDP_STARS_BENCH_END@@\n");
    while (true) {}
}

fn initRdp() void {
    rsp.halt();
    rsp.waitHalted();
    rsp.loadResident(rsp.programs.command_dispatcher);
    overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&overlay, 12);
    queue.init(.low);
}

fn render(count: usize) !struct { submit: u32, total: u32 } {
    // Recreating the state tracker intentionally makes texture upload once per sample/frame.
    var rq = rdp.DefaultRenderQueue.init(rdp.OverlayQueue.init(
        &queue,
        &overlay,
        .{ dynamic_buffers[0][0..], dynamic_buffers[1][0..] },
    ));
    const start = n64.cpu.cp0.regRead(.Count);
    rq.clear();
    rq.setFrameBuffer(framebuffer);
    rq.clearScreen(Rgba16.fromInt(0x404040FF));
    rq.setCombineMode(.single(.{ .rgb_a = .tex0, .rgb_c = .primitive, .alpha_d = .tex0 }));
    rq.setBlendMode(.alpha);
    for (0..count) |i| {
        rq.setPrimColor(colors[i % colors.len]);
        rq.drawSprite(texture, width / 2, height / 2, .{ .rotation = rotation, .pivot = .center });
    }
    const fence = rdp.syncFull(&rq);
    const submitted = n64.cpu.cp0.regRead(.Count);
    if (!fence.waitTimeout(timeout)) return error.RdpFenceTimeout;
    const completed = n64.cpu.cp0.regRead(.Count);
    rsp.io.status_register_write.* = rsp.io.status_clear_signal1;
    return .{ .submit = submitted -% start, .total = completed -% start };
}

fn measure(count: usize) !void {
    for (0..warmup_count) |_| _ = try render(count);
    var submit_sum: u64 = 0;
    var total_sum: u64 = 0;
    for (0..sample_count) |_| {
        const result = try render(count);
        submit_sum += result.submit;
        total_sum += result.total;
    }
    n64.debug.print("@@RDP_STARS_BENCH@@ impl=libptero stars={} warmup={} samples={} submit_ticks={} total_ticks={}\n", .{
        count, warmup_count, sample_count, submit_sum / sample_count, total_sum / sample_count,
    });
}

fn initTexture() void {
    for (0..texture.height) |y| for (0..texture.width) |x| {
        const index = y * texture.width + x;
        var xf: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(texture.width)) - 0.5;
        var yf: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(texture.height)) - 0.5;
        var dist = @sqrt(xf * xf + yf * yf);
        dist = @max(0, 1.0 - dist);
        const xp = std.math.atan2(xf, yf);
        const yp = @sqrt(xf * xf + yf * yf);
        xf = xp + yp * 2;
        yf = yp;
        const t = std.math.clamp((@cos(xf * std.math.pi * 1.93) * 0.1 - yf + 0.4) / 0.1, 0.0, 1.0);
        const d: u8 = @intFromFloat(dist * 255);
        const c: u8 = @intFromFloat(t * t * (3.0 - 2.0 * t) * 255);
        texture.texel_data[index] = .fromBytes(d, d, d, c);
    };
    n64.cache.writebackData(texture.texel_data);
}

fn enableInterrupts() void {
    var status = n64.cpu.cp0.regRead(.Status);
    status |= 0x401;
    n64.cpu.cp0.regWrite(.Status, status);
    n64.interfaces.mips.updateInterrupts(.{ .set_rdp = true });
}
