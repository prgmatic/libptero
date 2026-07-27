const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");

const width = 640;
const height = 240;
const framebuffer_address = 0x80100000;

const Img = n64.graphics.image.ImgRgba16;
const Color = n64.graphics.color.Rgba16;
const font = n64.debug.console_font;
const vi = n64.interfaces.video;

const background = Color.fromInt(0x171717ff);
const foreground = Color.fromInt(0xd8d8d8ff);
const green = Color.fromInt(0x55d68aff);
const red = Color.fromInt(0xff6666ff);
const accent = Color.fromInt(0x7060d0ff);

pub fn show(results: []const runner.Result, summary: runner.Summary) void {
    const pixels: [*]Color = @ptrFromInt(framebuffer_address);
    var framebuffer: Img = .{
        .width = width,
        .height = height,
        .texel_data = pixels[0 .. width * height],
    };

    vi.init(.{
        .resolution = .@"640x240p",
        .color_depth = .Rgba5551,
    });

    framebuffer.fill(background);
    framebuffer.fillRegion(accent, 0, 22, width, 2);
    _ = font.drawStr(framebuffer, foreground, "Libptero Tests", 16, 8);

    var y: u16 = 34;
    var first_failure: ?runner.Result = null;
    for (results) |result| {
        const status = if (result.failure == null) "PASS" else "FAIL";
        const color = if (result.failure == null) green else red;

        _ = font.drawStr(framebuffer, color, status, 16, y);
        _ = font.drawStr(framebuffer, foreground, result.name, 64, y);
        if (result.failure) |failure| {
            if (first_failure == null) first_failure = result;
            _ = font.drawStr(framebuffer, red, @errorName(failure.err), 360, y);
        }
        y += 10;
    }

    if (first_failure) |failed_result| {
        drawFailure(framebuffer, failed_result, 16, 182);
    }

    var summary_buffer: [40]u8 = undefined;
    const summary_text = std.fmt.bufPrint(
        &summary_buffer,
        "{d} passed, {d} failed",
        .{ summary.passed, summary.failed },
    ) catch "";
    _ = font.drawStr(
        framebuffer,
        if (summary.failed == 0) green else red,
        summary_text,
        16,
        226,
    );

    n64.cache.writebackData(framebuffer.texel_data);
    vi.setFrameBuffer(framebuffer_address);
}

fn drawFailure(framebuffer: Img, result: runner.Result, x: u16, y: u16) void {
    const failure = result.failure.?;
    var line_buffer: [76]u8 = undefined;

    const title = std.fmt.bufPrint(
        &line_buffer,
        "First failure: {s}",
        .{result.name},
    ) catch "";
    _ = font.drawStr(framebuffer, red, title, x, y);

    if (failure.diagnostic) |diagnostic| {
        _ = font.drawStr(framebuffer, foreground, diagnostic.messageSlice(), x, y + 11);
        drawLocation(framebuffer, diagnostic.address, x, y + 22);
    }
}

fn drawLocation(framebuffer: Img, address: u32, x: u16, y: u16) void {
    var func_name_buffer: [128]u8 align(8) = undefined;
    var file_name_buffer: [192]u8 align(8) = undefined;
    var source_line_buffer: [256]u8 align(8) = undefined;
    var line_buffer: [76]u8 = undefined;

    if (n64.debug.srcmap.getLineInfo(address, .{
        .func_name = &func_name_buffer,
        .file_name = &file_name_buffer,
        .line_text = &source_line_buffer,
    })) |info| {
        const location = std.fmt.bufPrint(
            &line_buffer,
            "{s}:{d}:{d}",
            .{ info.file_name orelse "<unknown>", info.line, info.column },
        ) catch "";
        _ = font.drawStr(framebuffer, foreground, location, x, y);
    } else {
        const location = std.fmt.bufPrint(
            &line_buffer,
            "at 0x{x:0>8}",
            .{address},
        ) catch "";
        _ = font.drawStr(framebuffer, foreground, location, x, y);
    }
}
