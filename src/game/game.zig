const n64 = @import("n64");
const Rgba5551 = n64.color.Rgba5551;

export fn __start() linksection(".text.startup") void {
    n64.debug.init(.IsViewer);
    n64.io.is_viewer.print("hello from n64\n");
    showColors();
    while(true) {}
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
