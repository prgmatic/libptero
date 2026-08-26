const image = @import("image.zig");
const color = @import("color.zig");

pub const TextOptions = struct {
    color: color.Rgba32 = color.Rgba32.white,
    scale: f32 = 1,
    line_spacing: i16 = 0,
};

pub const TextMetrics = struct {
    width: f32 = 0,
    height: f32 = 0,
    lines: u16 = 0,
    glyphs: u32 = 0,
};

pub const Error = error{InvalidUtf8};

pub const Font = struct {
    point_size: u16,
    ascent: i16,
    descent: i16,
    line_height: u16,
    ranges: []const Range,
    glyphs: []const Glyph,
    atlases: []const image.ImgRgba16,
    kernings: []const Kerning = &.{},
    ellipsis: ?Ellipsis = null,

    pub fn glyphIndex(self: Font, codepoint: u32) ?u16 {
        for (self.ranges) |range| {
            if (codepoint >= range.first_codepoint and codepoint < range.first_codepoint + range.glyph_count)
                return range.first_glyph + @as(u16, @intCast(codepoint - range.first_codepoint));
        }
        return null;
    }

    pub fn glyph(self: Font, codepoint: u32) ?Glyph {
        const index = self.glyphIndex(codepoint) orelse return null;
        return self.glyphs[index];
    }

    pub fn kerning(self: Font, first: u16, second: u16) i16 {
        var low: usize = 0;
        var high: usize = self.kernings.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const pair = self.kernings[middle];
            if (pair.first < first or (pair.first == first and pair.second < second))
                low = middle + 1
            else
                high = middle;
        }
        if (low < self.kernings.len) {
            const pair = self.kernings[low];
            if (pair.first == first and pair.second == second) return pair.amount;
        }
        return 0;
    }

    /// Measure UTF-8 text. The origin used by `draw` is the first baseline.
    pub fn measure(self: Font, utf8: []const u8, options: TextOptions) Error!TextMetrics {
        return self.layout(null, 0, 0, utf8, options);
    }

    /// Draw UTF-8 text through a graphics RDP RenderQueue. The queue may be the
    /// default RSP overlay queue or one of the lower-level queue variants.
    pub fn draw(self: Font, render_queue: anytype, x: f32, baseline_y: f32, utf8: []const u8, options: TextOptions) Error!TextMetrics {
        render_queue.setCombineMode(.single(.{
            .rgb_a = .tex0,
            .rgb_c = .primitive,
            .alpha_c = .primitive,
            .alpha_d = .tex0,
        }));
        render_queue.setBlendMode(.alpha);
        render_queue.setPrimColor(options.color);
        return self.layout(@as(?@TypeOf(render_queue), render_queue), x, baseline_y, utf8, options);
    }

    fn layout(self: Font, render_queue: anytype, origin_x: f32, baseline_y: f32, utf8: []const u8, options: TextOptions) Error!TextMetrics {
        if (options.scale <= 0) return .{};
        const view = @import("std").unicode.Utf8View.init(utf8) catch return Error.InvalidUtf8;
        var iterator = view.iterator();
        var pen_x = origin_x;
        var pen_y = baseline_y;
        var previous: ?u16 = null;
        var metrics: TextMetrics = .{ .height = @as(f32, @floatFromInt(self.line_height)) * options.scale, .lines = 1 };
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                metrics.width = @max(metrics.width, pen_x - origin_x);
                pen_x = origin_x;
                pen_y += @as(f32, @floatFromInt(@as(i32, self.line_height) + options.line_spacing)) * options.scale;
                previous = null;
                metrics.lines += 1;
                metrics.height = (pen_y - baseline_y) + @as(f32, @floatFromInt(self.line_height)) * options.scale;
                continue;
            }
            const glyph_index = self.glyphIndex(codepoint) orelse {
                previous = null;
                continue;
            };
            const glyph_info = self.glyphs[glyph_index];
            if (previous) |prior| pen_x += @as(f32, @floatFromInt(self.kerning(prior, glyph_index))) * options.scale;
            if (render_queue) |queue| {
                if (glyph_info.width != 0 and glyph_info.height != 0) queue.drawSprite(
                    self.atlases[glyph_info.atlas],
                    pen_x + @as(f32, @floatFromInt(glyph_info.x_offset)) * options.scale,
                    pen_y + @as(f32, @floatFromInt(glyph_info.y_offset)) * options.scale,
                    .{
                        .s0 = glyph_info.s,
                        .t0 = glyph_info.t,
                        .width = @intCast(glyph_info.width),
                        .height = @intCast(glyph_info.height),
                        .scale_x = options.scale,
                        .scale_y = options.scale,
                    },
                );
            }
            pen_x += @as(f32, @floatFromInt(glyph_info.x_advance)) * options.scale;
            previous = glyph_index;
            metrics.glyphs += 1;
        }
        metrics.width = @max(metrics.width, pen_x - origin_x);
        return metrics;
    }
};

pub const Range = struct {
    first_codepoint: u32,
    glyph_count: u16,
    first_glyph: u16,
};

pub const Glyph = struct {
    x_advance: i16,
    x_offset: i16,
    y_offset: i16,
    width: u16,
    height: u16,
    s: u8,
    t: u8,
    atlas: u8,
};

pub const Kerning = struct {
    first: u16,
    second: u16,
    amount: i16,
};

pub const Ellipsis = struct {
    glyph: u16,
    repetitions: u16,
    advance: i16,
    width: i16,
};

test "glyph lookup and kerning" {
    const testing = @import("std").testing;
    const font: Font = .{
        .point_size = 8,
        .ascent = 7,
        .descent = -1,
        .line_height = 10,
        .ranges = &.{.{ .first_codepoint = 'A', .glyph_count = 2, .first_glyph = 0 }},
        .glyphs = &.{
            .{ .x_advance = 5, .x_offset = 0, .y_offset = -7, .width = 4, .height = 7, .s = 0, .t = 0, .atlas = 0 },
            .{ .x_advance = 5, .x_offset = 0, .y_offset = -7, .width = 4, .height = 7, .s = 4, .t = 0, .atlas = 0 },
        },
        .atlases = &.{},
        .kernings = &.{.{ .first = 0, .second = 1, .amount = -1 }},
    };
    try testing.expectEqual(@as(?u16, 1), font.glyphIndex('B'));
    try testing.expectEqual(@as(?u16, null), font.glyphIndex('C'));
    try testing.expectEqual(@as(i16, -1), font.kerning(0, 1));
    try testing.expectEqual(@as(i16, 0), font.kerning(1, 0));
}

test "measure applies UTF-8 lookup, kerning, and newlines" {
    const testing = @import("std").testing;
    const font: Font = .{
        .point_size = 8,
        .ascent = 7,
        .descent = -1,
        .line_height = 10,
        .ranges = &.{.{ .first_codepoint = 'A', .glyph_count = 2, .first_glyph = 0 }},
        .glyphs = &.{
            .{ .x_advance = 5, .x_offset = 0, .y_offset = -7, .width = 4, .height = 7, .s = 0, .t = 0, .atlas = 0 },
            .{ .x_advance = 6, .x_offset = 0, .y_offset = -7, .width = 4, .height = 7, .s = 4, .t = 0, .atlas = 0 },
        },
        .atlases = &.{},
        .kernings = &.{.{ .first = 0, .second = 1, .amount = -1 }},
    };
    const metrics = try font.measure("AB\nA?", .{ .scale = 2, .line_spacing = 1 });
    try testing.expectEqual(@as(f32, 20), metrics.width);
    try testing.expectEqual(@as(f32, 42), metrics.height);
    try testing.expectEqual(@as(u16, 2), metrics.lines);
    try testing.expectEqual(@as(u32, 3), metrics.glyphs);
    try testing.expectError(Error.InvalidUtf8, font.measure("\xff", .{}));
}
