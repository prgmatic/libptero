// This is a simple tool for exporting the debug console font.
// Each pixel is only 1 bit and only used for software rendering
// This is probably a one off and won't be used for other fonts
const std = @import("std");
const png = @import("../tools/imgparse/png.zig");

const glyph_width = 8;
const glyph_height = 8;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const io = init.io;

    const font_img_path = args[1];
    const img = try getImg(io, allocator, font_img_path);
    defer img.deinit(allocator);

    const glyphs_per_row = img.width / glyph_width;
    const glyphs_per_column = img.height / glyph_height;
    const glyph_count = glyphs_per_row * glyphs_per_column;

    const out_file_path = args[2];
    const out_file = try std.Io.Dir.cwd().createFile(io, out_file_path, .{});
    defer out_file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = out_file.writer(io, &buf);
    var w = &writer.interface;

    for (0..glyph_count) |i| {
        const glyph_x = i % glyphs_per_row;
        const glyph_y = i / glyphs_per_row;

        const img_x = glyph_x * glyph_width;
        const img_y = glyph_y * glyph_height;

        for (img_y..img_y + glyph_height) |y| {
            var line: u8 = 0;
            for (img_x..img_x + glyph_width) |x| {
                const idx = y * img.width + x;
                const p: u8 = if (img.pixels[idx * 4 + 3] > 200) 1 else 0;
                line |= p << @truncate(x);
            }
            // std.debug.print("{b:0>8}\n", .{line});
            try w.writeInt(u8, line, .big);
        }
    }

    try w.flush();
}

fn getImg(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !png.Image {
    const img_file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer img_file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = img_file.reader(io, &buf);
    const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(bytes);
    return try png.readRgba(allocator, bytes);
}
