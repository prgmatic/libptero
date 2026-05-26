const font = @embedFile("console_font");

const glyph_width = font[0];
const glyph_height = font[1];
const glyph_count = font[2];
const chars = font[3..3+glyph_count];
const glyph_start = 3 + glyph_count;
const glyphs: *const [glyph_count][glyph_height]u8 = @ptrCast(&font[glyph_start]);

pub fn testFont() void {
    const p = @import("../debug.zig").print;
    p("width {d} height {d}\n", .{font[0], font[1]});
}

pub fn drawGlyph(img: anytype, color: anytype, char: u8, x: u16, y: u16) void {
    var glyph_idx: usize = 0;
    if (char == ' ') return;
    for (chars, 0..) |c, i| {
        if (c == char) { glyph_idx = i; break; }
    }
    for (0..glyph_height) |row| {
        const line = glyphs[glyph_idx][row];
        for (0..glyph_width) |col| {
            if ((line >> @as(u3, @truncate(col))) & 1 != 0) {
                const idx = img.width * (y + row) + (x + col);
                img.texel_data[idx] = color;
            }
        }
    }
}

pub fn drawStr(img: anytype, color: anytype, str: []const u8, x: u16, y: u16) void {
    var cur_x = x;
    for (str) |char| {
        drawGlyph(img, color, char, cur_x, y);
        cur_x += glyph_width;
    }
}
