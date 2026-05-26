const std = @import("std");
const font = @import("console_font.zig");
const vi = @import("../interfaces/video.zig");
const ImgRgba16 = @import("../graphics/image.zig").ImgRgba16;
const Rgba16 = @import("../graphics/color.zig").Rgba16;
const cache = @import("../cpu/cache.zig");

// colors
const colorBackground = Rgba16.fromInt(0x171717FF);
const colorPrimaryAccent = Rgba16.fromInt(0x4C3672FF);
const colorFont = Rgba16.fromInt(0xBCBFBEFF);

const addr = 0x80100000;

pub fn show(msg: []const u8) void {
    const buf: *[0x100000]u8 = @ptrFromInt(addr);
    var fb_alloc: std.heap.FixedBufferAllocator = .init(buf);
    const allocator = fb_alloc.allocator();

    fb_alloc = .init(buf);

    vi.init(.{
       .resolution = .@"640x240p",
       .color_depth = .Rgba5551,
    });

    var img = ImgRgba16.init(allocator, 640, 240) catch undefined;
    img.fillRegion(colorBackground, 0, 0, img.width, img.height);
    img.fillRegion(colorPrimaryAccent, 40, 20, img.width - 80, 1);
    const str = "Drawing Test";
    const width = str.len * 8;
    const x = 640 / 2 - width / 2;
    font.drawStr(img, colorFont, "Stack Trace", x, 8);
    font.drawStr(img, colorFont, msg, 20, 30);

    cache.writebackData(img.texel_data);
   
    vi.setFrameBuffer(@intFromPtr(img.texel_data.ptr));
    font.testFont();

}
