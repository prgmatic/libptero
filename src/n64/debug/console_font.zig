const font = @embedFile("console_font");

// Glyph width is one byte so assume 8
const glyph_height = 8;
const glyph_count = font.len / glyph_height;

pub fn drawGlyph(img: anytype, color: anytype, char: u8, x: u16, y: u16) void {
    if(char >= glyph_count) return;
    const base = @as(u32, char) * 8;
    for (0..8) |row| {
        const line = font[base + row];
        for (0..8) |col| {
            if ((line >> @as(u3, @truncate(col))) & 1 != 0) {
                const idx = img.width * (y + row) + (x + col);
                img.texel_data[idx] = color;
            }
        }
    }
}

pub fn drawStr(img: anytype, color: anytype, str: []const u8, x: u16, y: u16) u16 {
    var cur_x = x;
    for (str) |char| {
        drawGlyph(img, color, char, cur_x, y);
        cur_x += 8;
    }
    return @truncate(str.len * 8 + x);
}
