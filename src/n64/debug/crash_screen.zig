const std = @import("std");
const font = @import("console_font.zig");
const vi = @import("../interfaces/video.zig");
const ImgRgba16 = @import("../graphics/image.zig").ImgRgba16;
const Rgba16 = @import("../graphics/color.zig").Rgba16;
const cache = @import("../cpu/cache.zig");
const backtrace = @import("backtrace.zig");
const srcmap = @import("srcmap.zig");

// colors
const colorBackground = Rgba16.fromInt(0x171717FF);
const colorPrimaryAccent = Rgba16.fromInt(0x4C3672FF);
const colorFont = Rgba16.fromInt(0xBCBFBEFF);
const colorFontOrange = Rgba16.fromInt(0xF9AF4FFF);
const colorFontBlue = Rgba16.fromInt(0x53BDFAFF);
const colorFontTeal = Rgba16.fromInt(0x90E1C6FF);
const colorFontGray = Rgba16.fromInt(0x686868FF);

const addr = 0x80100000;
const line_chars = 75;

pub const CrashType = enum(u1) {
    panic,
    exception,
};

pub fn show(crash_type: CrashType, msg: []const u8, trace_opt: ?backtrace.Trace) void {
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
    img.fillRegion(colorPrimaryAccent, 0, 20, img.width, 1);
    const title = "Stack Trace";
    const width = title.len * 8;
    var x: u16 = 640 / 2 - width / 2;
    _ =font.drawStr(img, colorFont, title, x, 8);

    x = 40;
    if(crash_type == .panic)
        x = font.drawStr(img, colorFont, "Panic: ", x, 30)
    else
        x = font.drawStr(img, colorFont, "Exception: ", x, 30);
    _ = font.drawStr(img, colorFontOrange, msg, x, 30);

    drawBacktrace(img, trace_opt, 40, 46);

    cache.writebackData(img.texel_data);
    vi.setFrameBuffer(@intFromPtr(img.texel_data.ptr));
}

fn drawBacktrace(img: anytype, trace_opt: ?backtrace.Trace, x: u16, y: u16) void {
    const y_spacing = 9;
    var line_buf: [line_chars]u8 = undefined;
    var func_name_buf: [128]u8 align(8) = undefined;
    var file_name_buf: [192]u8 align(8) = undefined;
    var line_text_buf: [512]u8 align(8) = undefined;

    var cur_y = y;
    var trace = trace_opt orelse {
        _ = font.drawStr(img, colorFont, "  <backtrace unavailable>", x, cur_y);
        return;
    };

    while (trace.next()) |entry| {
        if (cur_y + 8 >= img.height) break;

        if (srcmap.getLineInfo(entry.addr, .{
            .func_name = &func_name_buf,
            .file_name = &file_name_buf,
            .line_text = &line_text_buf,
        })) |info| {
            const func_name = info.function_name orelse "";
            const file_name = info.file_name orelse "";

            var cur_x = x;
            cur_x = font.drawStr(img, colorFontBlue, func_name, cur_x, cur_y);

            var str = std.fmt.bufPrint( &line_buf, " {s}:{d}:{d} ",
                .{ file_name, info.line, info.column }) catch "";
            cur_x = font.drawStr(img, colorFont, str, cur_x, cur_y);

            str = std.fmt.bufPrint( &line_buf, "0x{x:0>8}", .{ entry.addr }) catch "";
            _ = font.drawStr(img, colorFontGray, str, cur_x, cur_y);

            cur_y += y_spacing;

            if(info.line_text) |line_text| {
                _ = font.drawStr(img, colorFont, line_text, x, cur_y);
                cur_y += y_spacing;
                const x_off = x + (info.column - 1) * 8;
                font.drawGlyph(img, colorFontTeal, '^', x_off, cur_y);
                cur_y += y_spacing - 2;
            }
        }
        else {
            const str = formatAddressLine(&line_buf, entry);
            _ = font.drawStr(img, colorFont, str, x, cur_y);
            cur_y += y_spacing;
        }
    }
}

fn formatAddressLine(buf: []u8, entry: backtrace.Entry) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "#{d}: 0x{x:0>8}",
        .{ entry.depth, entry.addr },
    ) catch buf[0..0];
}
