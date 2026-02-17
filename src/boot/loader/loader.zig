const std = @import("std");
const n64 = @import("n64");


export fn __start() linksection(".loader") callconv(.c) noreturn {
    var b: [0x200]u8 = undefined;
    print(&b, "We can now format strings\n", .{});
    print(&b, "CPU Cycle Count: {d}\n", .{n64.cpu.cp0.regRead(.Count)});

    n64.video.setTvType(.Ntsc, .Progressive);
    n64.video.vi_width.* = 320;
    n64.video.vi_x_scale.* = 0x200;
    n64.video.vi_y_scale.* = 0x400;
    n64.video.control.* = @bitCast(@as(u32, 0x3202));
    
    const frame_buffer: *[320 * 240]u16 = @ptrFromInt(0xA0100000);
    n64.video.frame_buffer_addr.* = @intFromPtr(frame_buffer);


    for(0..240) |y| {
        for(0..320) |x| {
            const idx = y * 320 + x;
            const r: u32 = @intCast((x * 255) / 319);
            frame_buffer[idx] = colorFrom32(r << 16 | 0x2B40);
        }
    }

    print(&b, "Did we set burst?: 0x{X}\n", .{n64.video.vi_burst.*});
    while (true) { }
    undefined;
}

fn print(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.bufPrint(buf, fmt, args) catch "";
    n64.io.is_viewer.print(str);
}

fn colorFrom32(rgba32: u32) u16 {
    const r = (rgba32 >> 19) & 0x1F; 
    const g = (rgba32 >> 11) & 0x1F;
    const b = (rgba32 >> 3)  & 0x1F; 
    const a = (rgba32 >> 31) & 1;

    const result = r << 11 | g << 6 | b << 1 | a;
    return @as(u16, @intCast(result));
}
