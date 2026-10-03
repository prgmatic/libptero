//! CPU-only, clipped 1-bit text with proportional baseline-relative glyphs.
const std = @import("std");
pub const assets = @import("fonts.zig");
pub const Font = assets.Font;

fn glyph(font: Font, char: u8) assets.Glyph {
    const code = if (char >= 32 and char <= 126) char else '?';
    return font.glyphs[code - 32];
}

pub fn measure64(font: Font, str: []const u8) i32 {
    var result: i32 = 0;
    for (str) |char| result += if (char == '\t') @as(i32, glyph(font, ' ').advance_64) * 4 else glyph(font, char).advance_64;
    return result;
}

pub fn measure(font: Font, str: []const u8) i32 {
    return @divFloor(measure64(font, str) + 32, 64);
}

/// Positions use an integer baseline. Fractional advances accumulate so a
/// proportional string does not drift through per-character rounding.
pub fn draw(img: anytype, color: anytype, font: Font, str: []const u8, x: i32, baseline: i32) void {
    drawClipped(img, color, font, str, x, baseline, .{ .right = img.width, .bottom = img.height });
}

pub const Clip = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32,
    bottom: i32,
};

/// A viewport can clip long source lines without painting the scrollbar gutter.
pub fn drawClipped(img: anytype, color: anytype, font: Font, str: []const u8, x: i32, baseline: i32, clip: Clip) void {
    var pen = x * 64;
    for (str) |char| {
        if (char == '\t') {
            pen += @as(i32, glyph(font, ' ').advance_64) * 4;
            continue;
        }
        const g = glyph(font, char);
        drawGlyph(img, color, g, @divFloor(pen + 32, 64), baseline, clip);
        pen += g.advance_64;
    }
}

fn drawGlyph(img: anytype, color: anytype, g: assets.Glyph, x: i32, baseline: i32, clip: Clip) void {
    for (0..g.height) |row| {
        const py = baseline + g.bearing_y + @as(i32, @intCast(row));
        if (py < @max(0, clip.top) or py >= @min(img.height, clip.bottom)) continue;
        for (0..g.width) |col| {
            const px = x + g.bearing_x + @as(i32, @intCast(col));
            if (px < @max(0, clip.left) or px >= @min(img.width, clip.right)) continue;
            const bit = row * g.width + col;
            const mask = @as(u8, 0x80) >> @as(u3, @intCast(bit % 8));
            if (assets.bitmap[g.offset + bit / 8] & mask != 0)
                img.set(@intCast(px), @intCast(py), color);
        }
    }
}

test "UI and diagnostic advances are proportional" {
    try std.testing.expect(measure(assets.ui, "WWW") > measure(assets.ui, "iii"));
    try std.testing.expect(measure(assets.data, "WWW") > measure(assets.data, "iii"));
    try std.testing.expectEqual(measure(assets.ui, "?"), measure(assets.ui, "\xff"));
    try std.testing.expectEqual(measure(assets.data, "    "), measure(assets.data, "\t"));
}

test "packed glyph bounds and fractional advances" {
    for ([_]Font{ assets.ui, assets.brand, assets.title, assets.data, assets.small, assets.bytes }) |font| {
        try std.testing.expectEqual(@as(usize, 95), font.glyphs.len);
        for (font.glyphs) |g| {
            const bytes = (@as(usize, g.width) * g.height + 7) / 8;
            try std.testing.expect(g.offset + bytes <= assets.bitmap.len);
            try std.testing.expect(g.advance_64 > 0);
        }
    }
    const g = glyph(assets.data, 'i');
    try std.testing.expectEqual(@as(i32, @intCast((@as(u32, g.advance_64) * 80 + 32) / 64)), measure(assets.data, &([_]u8{'i'} ** 80)));
}

test "glyph clipping preserves storage outside the image" {
    const Image = struct {
        width: u16 = 4,
        height: u16 = 4,
        texel_data: []u8,
        fn set(self: @This(), x: u16, y: u16, value: u8) void {
            self.texel_data[@as(usize, y) * self.width + x] = value;
        }
    };
    var storage = [_]u8{0xa5} ** 18;
    @memset(storage[1..17], 0);
    const img: Image = .{ .texel_data = storage[1..17] };
    draw(img, @as(u8, 1), assets.title, "W", -3, 7);
    draw(img, @as(u8, 1), assets.title, "W", 3, 12);
    try std.testing.expectEqual(@as(u8, 0xa5), storage[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), storage[17]);
    try std.testing.expect(std.mem.indexOfScalar(u8, storage[1..17], 1) != null);
}

test "source viewport clips all four edges while preserving transparent pixels" {
    const Image = struct {
        width: u16 = 16,
        height: u16 = 16,
        texel_data: []u8,
        fn set(self: @This(), x: u16, y: u16, value: u8) void {
            self.texel_data[@as(usize, y) * self.width + x] = value;
        }
    };
    var pixels = [_]u8{0} ** 256;
    const img: Image = .{ .texel_data = &pixels };
    drawClipped(img, @as(u8, 1), assets.title, "WWWW", 0, 12, .{ .left = 2, .top = 3, .right = 8, .bottom = 9 });
    var ink: usize = 0;
    var background: usize = 0;
    for (pixels, 0..) |value, index| {
        const x = index % 16;
        const y = index / 16;
        if (x < 2 or x >= 8 or y < 3 or y >= 9) {
            try std.testing.expectEqual(@as(u8, 0), value);
        } else if (value == 1) {
            ink += 1;
        } else background += 1;
    }
    try std.testing.expect(ink > 0 and background > 0);
}

test "lowercase r shares its neighbors' baseline and letters retain a clear gap" {
    const Image = struct {
        width: u16 = 192,
        height: u16 = 24,
        texel_data: []u8,
        fn set(self: @This(), x: u16, y: u16, value: u8) void {
            self.texel_data[@as(usize, y) * self.width + x] = value;
        }
    };
    var pixels = [_]u8{0} ** (192 * 24);
    const img: Image = .{ .texel_data = &pixels };
    for ([_]Font{ assets.ui, assets.data, assets.small }) |font| {
        for ("rne") |char| {
            @memset(&pixels, 0);
            draw(img, @as(u8, 1), font, &.{char}, 0, 20);
            var bottom: usize = 0;
            for (pixels, 0..) |pixel, index| {
                if (pixel != 0) bottom = index / img.width;
            }
            try std.testing.expectEqual(@as(usize, 19), bottom);
        }
        @memset(&pixels, 0);
        const sample = "re rn rr ir";
        draw(img, @as(u8, 1), font, sample, 0, 20);
        for (sample, 0..) |char, index| {
            if (index == 0 or char == ' ') continue;
            const gap: usize = @intCast(measure(font, sample[0..index]) - 1);
            for (0..img.height) |y| try std.testing.expectEqual(@as(u8, 0), pixels[y * img.width + gap]);
        }
    }
}
