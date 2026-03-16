const n64 = @import("n64");
const std = @import("std");
const Rgba5551 = n64.color.Rgba5551;
var buf: [256]u8 = undefined;


export fn __start() linksection(".text.startup") void {
    n64.debug.init(.IsViewer);
    n64.io.is_viewer.print("hello from n64\n");
    showColors();
    joybusTest();


    while(true){}
}

fn print(comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.bufPrint(&buf, fmt, args) catch "";
    n64.io.is_viewer.print(str);
}

fn showColors() void {
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
}

fn joybusTest() void {
    var joybus_buffer: n64.io.joybus.JoybusBuffer align(32) = .{};
    joybus_buffer.clear();
    const t = joybus_buffer.as(n64.io.joybus.Commands.CommandIdentifyAll);
    t.* = .{};
    joybus_buffer.memory[15] = 1;
    
    print("t2 {x} {x} {x} {x}\n", .{@intFromPtr(&joybus_buffer), t.port0.command_len, t.port0.response_len, t.port0.command});
    

    n64.cpu.cache.writebackData(&joybus_buffer);
    n64.serial.waitDmaIo();
    joybus_buffer.sendCommand();
    n64.serial.waitDmaIo();
    joybus_buffer.readFromPif();
    n64.serial.waitDmaIo();
    n64.cpu.cache.invalidateData(&joybus_buffer);
    
    print("port 0 {x}\n", .{t.port0.response});
    print("port 1 {x}\n", .{t.port1.response});
    print("port 2 {x}\n", .{t.port2.response});
    print("port 3 {x}\n", .{t.port3.response});
    print("port 4 {x}\n", .{t.port4.response});
}
