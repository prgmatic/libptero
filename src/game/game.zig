const n64 = @import("n64");
const std = @import("std");
const Rgba32 = n64.graphics.Rgba32;
const Img32 = n64.graphics.Img32;
const print = n64.debug.print;
var sys_buffer: [1024 * 512]u8 = undefined;
var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&sys_buffer);
const allocator = fixed_buffer_allocator.allocator();
var frame_buffer: Img32 = undefined;

export fn __start() linksection(".text.startup") void {
    n64.debug.init();
    n64.debug.initFmtBuffer(allocator);
    print("hello from n64\n", .{});
    showColors();
    joybusTest();

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
    
    frame_buffer = Img32.init(allocator, width, height) catch undefined;
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


fn joybusTest() void {
    n64.io.joypad.init(allocator);
    n64.io.joypad.updateJoypadStatus();
    
    print("Joypad status {s}\n", .{@tagName(n64.io.joypad.joypads[0].style)});
    while(true){
        n64.io.joypad.pollJoypadState();
        const s = n64.io.joypad.joypads[0].state;
        btn(0x0000FFFF, s.a, 1, 1);
        btn(0x00FF00FF, s.b, 2, 1);
        btn(0xfaea41FF, s.c_up, 4, 3);
        btn(0xfaea41FF, s.c_down, 4, 5);
        btn(0xfaea41FF, s.c_left, 3, 4);
        btn(0xfaea41FF, s.c_right, 5, 4);
        drawStick(160, 60, @divTrunc(s.x_axis, 4), @divTrunc(-s.y_axis, 4));
        n64.cpu.cache.writebackData(frame_buffer.pixel_data);
    }
}

fn btn(c: u32, active: bool, x: u32, y: u32) void {
    const fc: Rgba32 = if(active) @bitCast(@as(u32, c)) else @bitCast(@as(u32, 0x0));
    frame_buffer.fillRegion(fc, x * 20, y * 20, 20, 20);
}

fn drawStick(x: u32, y: u32, analog_x: i16, analog_y: i16) void {
    const black: Rgba32 = @bitCast(@as(u32, 0x0));
    const color: Rgba32 = @bitCast(@as(u32, 0x0000FFFF));
    const width = 64;
    const hw = @divTrunc(width, 2);
    const height = 64;
    for(y..y+height) |yi| {
        for(x..x+width) |xi| {
            const xr: i16 = @as(i16, @intCast(@as(u16, @intCast(xi)) - x)) - hw;
            const yr: i16 = @as(i16, @intCast(@as(u16, @intCast(yi)) - y)) - hw;
            const d2 = dist(xr - analog_x, yr - analog_y);
            if(d2 < 5) {
                const idx = yi * frame_buffer.width + xi;
                frame_buffer.pixel_data[idx] = color;
                continue;
            }
            const d = dist(xr, yr);
            if(d <= hw) {
                const idx = yi * frame_buffer.width + xi;
                frame_buffer.pixel_data[idx] = black;
            }
        }
    }
}

fn dist(x: i16, y: i16) u32 {
    const fx = @as(f64, @floatFromInt(x));
    const fy = @as(f64, @floatFromInt(y));
    const d = std.math.sqrt(fx * fx + fy * fy);
    return @as(u32, @intFromFloat(d));
}
