const std = @import("std");
const n64 = @import("n64");
const Rgba5551 = n64.color.Rgba5551;


export fn __start() linksection(".loader") callconv(.c) noreturn {
    var b: [0x200]u8 = undefined;
    print(&b, "We can now format strings\n", .{});
    print(&b, "CPU Cycle Count: {d}\n", .{n64.cpu.cp0.regRead(.Count)});

    const width: u32 = 320;
    const height: u32 = 240;

    n64.video.init(.{
        .tv = .Ntsc,
        .width = width
    });
    
    const frame_buffer: *[width * height]Rgba5551 = @ptrFromInt(0xA0100000);
    n64.video.frame_buffer_addr.* = @intFromPtr(frame_buffer);

    for(0..height) |y| {
        for(0..width) |x| {
            const idx = y * width + x;
            const r: u32 = @intCast((x * 255) / width - 1);
            frame_buffer[idx] = Rgba5551.fromU32(r << 16 | 0x2B40);
        }
    }

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
