const std = @import("std");
const n64 = @import("n64");
const mi = n64.interfaces.mips;
const rsp = n64.rsp;
const vi = n64.interfaces.video;
const rdp = n64.graphics.rdp;
const print = n64.debug.print;

const Rgba32 = n64.graphics.color.Rgba32;
const Rgba16 = n64.graphics.color.Rgba16;
const Img16 = n64.graphics.image.ImgRgba16;
const Img32 = n64.graphics.image.ImgRgba32;

var sys_buffer: [1024 * 512]u8 = undefined;
var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&sys_buffer);
const allocator = fixed_buffer_allocator.allocator();

const width: u16 = 320;
const height: u16 = 240;
const queue_command_capacity = 2048;

var frame_buffer0: Img16 = undefined;
var frame_buffer1: Img16 = undefined;
var current_frame_buffer: *Img16 = undefined;

var queue_buffer: []u64 = undefined;
var rq: rdp.FixedRenderQueue = undefined;
var frame_count: u32 = 0;

var star_texture: Img32 = undefined;


var stars: [128]Star = undefined;
const colors = [_]Rgba32{
    .red,
    .blue,
    .green,
    .cyan,
    .magenta,
    .yellow,
};

pub fn main() !void {
    n64.debug.init();
    try n64.debug.initFmtBuffer(allocator);
    print("hello from n64\n", .{});
    runRspFillDmem();

    try init();

    while (true) {
        n64.interrupt.waitForInterrupt(.{ .rdp = true, .video = true });
        swapBuffer();
        update();
    }
}

fn runRspFillDmem() void {
    const prg = rsp.programs.fill_dmem;
    print("loading fill_dmem RSP program ({} bytes)\n", .{prg.text.len});
    rsp.runUCode(prg);
    rsp.waitBroke();

    var mismatch_count: u32 = 0;

    var offset: u32 = 0;
    while (offset < rsp.io.dmem_len) : (offset += 2) {
        const expected: u16 = @truncate(offset);
        const actual = rsp.io.readDmem(u16, offset).*;
        if (actual != expected) {
            mismatch_count += 1;
        }
    }

    if(mismatch_count == 0) {
        print("Success\n", .{});
    }
    else {
        print("Mismatches {d}\n", .{mismatch_count});
    }
}

fn init() !void {
    vi.init(.{
        .resolution = .@"320x240p",
        .color_depth = .Rgba5551,
    });

    frame_buffer0 = try Img16.init(allocator, width, height);
    frame_buffer1 = try Img16.init(allocator, width, height);
    current_frame_buffer = &frame_buffer0;

    try initStarTexture();

    queue_buffer = try allocator.alignedAlloc(u64, std.mem.Alignment.@"8", queue_command_capacity);
    rq = rdp.FixedRenderQueue.init(.{ .buffer = queue_buffer });

    initStars();
    update();
    vi.setFrameBuffer(@intFromPtr(current_frame_buffer.texel_data.ptr));
    enableInterrupts();
}


fn update() void {
    const elapsed = elapsedSeconds();

    rq.clear();
    rq.setFrameBuffer(current_frame_buffer.*);
    rq.clearScreen(Rgba16.fromInt(0x404040FF));

    // Mul texture color and prim
    rq.setCombineMode(.single(.{ 
        .rgb_a = .tex0, 
        .rgb_c = .primitive, 
        .alpha_d = .tex0 
    }));
    rq.setBlendMode(.alpha);

    var star_count: usize = @intFromFloat(elapsed * 10 + 1);
    star_count = @min(stars.len, star_count);
    for (0..star_count) |i| {
        stars[i].update(elapsed);
        stars[i].draw(&rq, star_texture, elapsed);
    }

    rq.fullSync();
    n64.cache.writebackData(queue_buffer);
    rq.execute();
    frame_count += 1;
}

fn elapsedSeconds() f32 {
    const frames: f32 = @floatFromInt(frame_count);
    return frames / 60;
}

fn initStarTexture() !void {
    star_texture = try .init(allocator, 32, 32);
    for (0..star_texture.height) |y| {
        for (0..star_texture.width) |x| {
            const idx = y * star_texture.width + x;
            var xf: f32 = @floatFromInt(x);
            xf /= star_texture.width;
            xf -= 0.5;
            var yf: f32 = @floatFromInt(y);
            yf /= star_texture.height;
            yf -= 0.5;

            var dist = distance(xf, yf);
            dist = @max(0, 1.0 - dist);

            const xp = std.math.atan2(xf, yf);
            const yp = distance(xf, yf);

            xf = xp + yp * 2;
            yf = yp;
            const cf = smoothstep(0, 0.1, @cos(xf * std.math.pi * 1.93) * 0.1 - yf + 0.4);
            const d: u8 = @intFromFloat(dist * 255);
            const c: u8 = @intFromFloat(cf * 255);

            star_texture.texel_data[idx] = .fromBytes(d, d, d, c);
        }
    }
    n64.cache.writebackData(star_texture.texel_data);
}

fn enableInterrupts() void {
    var status = n64.cpu.cp0.regRead(.Status);
    status |= 0x401;
    n64.cpu.cp0.regWrite(.Status, status);
    mi.updateInterrupts(.{
        .set_rdp = true,
        .set_video = true,
    });
}

fn initStars() void {
    for (0..stars.len) |i| {
        const f: f32 = @floatFromInt(i);
        const c = colors[i % colors.len];
        stars[i] = .init(c, f);
    }
}

fn swapBuffer() void {
    vi.setFrameBuffer(@intFromPtr(current_frame_buffer.texel_data.ptr));
    if (current_frame_buffer == &frame_buffer0) {
        current_frame_buffer = &frame_buffer1;
    } else {
        current_frame_buffer = &frame_buffer0;
    }
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn distance(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

const Star = struct {
    x: f32,
    y: f32,
    color: Rgba32,
    dir_x: f32 = 1,
    dir_y: f32 = 0,
    spawn_time: f32 = -1,
    bounce_time: f32 = -1,

    const grow_time: f32 = 0.5;
    const flip_time: f32 = 0.6;
    const speed: f32 = 2;

    pub fn init(color: Rgba32, rot: f32) Star {
        return .{
            .x = width / 2,
            .y = height / 2,
            .color = color,
            .dir_x = @cos(rot),
            .dir_y = @sin(rot),
        };
    }

    pub fn draw(self: Star, render_queue: *rdp.FixedRenderQueue, image: Img32, elapsed: f32) void {
        var scale_x: f32 = 1;
        var scale_y: f32 = 1;

        if (elapsed - self.spawn_time < grow_time) {
            const t = (elapsed - self.spawn_time) / grow_time;
            scale_x = @max(0.01, t);
            scale_y = @max(0.01, t);
        } else if (elapsed - self.bounce_time < flip_time) {
            const t = (elapsed - self.bounce_time) / flip_time;
            scale_x = @max(0.01, t);
        }

        render_queue.setPrimColor(self.color);
        render_queue.drawSprite(image, self.x, self.y, .{
            .rotation = std.math.pi * elapsed * 3,
            .pivot = .center,
            .scale_x = scale_x,
            .scale_y = scale_y,
        });
    }

    pub fn update(self: *Star, elapsed: f32) void {
        if (self.spawn_time < 0) {
            self.spawn_time = elapsed;
        }

        self.x += self.dir_x * speed;
        self.y += self.dir_y * speed;

        if (self.x > width) {
            self.x = width;
            self.dir_x = -self.dir_x;
            self.bounce_time = elapsed;
        } else if (self.x < 0) {
            self.x = 0;
            self.dir_x = -self.dir_x;
            self.bounce_time = elapsed;
        }
        if (self.y > height) {
            self.y = height;
            self.dir_y = -self.dir_y;
            self.bounce_time = elapsed;
        } else if (self.y < 0) {
            self.y = 0;
            self.dir_y = -self.dir_y;
            self.bounce_time = elapsed;
        }
    }
};

fn forceCrash() void {
    const null_ptr: *volatile u32 = @ptrFromInt(4);
    _ = null_ptr.*;
}
