const image = @import("image.zig");
const color = @import("color.zig");

pub const TextOptions = struct {
    color: color.Rgba32 = color.Rgba32.white,
    scale: f32 = 1,
    outline_color: color.Rgba32 = .fromInt(0x40404040),
    line_spacing: i16 = 0,
};

pub const TextMetrics = struct {
    width: f32 = 0,
    height: f32 = 0,
    lines: u16 = 0,
    glyphs: u32 = 0,
};

pub const Error = error{InvalidUtf8};

/// IA16 TLUT banks for two independent fill/outline glyph layers in CI4.
pub const outline_palette: [32]color.Rgba16 align(8) = blk: {
    var result: [32]color.Rgba16 = undefined;
    for (0..2) |layer| for (0..16) |index| {
        const pixel = (index >> (layer * 2)) & 3;
        result[layer * 16 + index] = @bitCast(@as(u16, if (pixel == 0) 0 else if (pixel == 1) 0x00ff else 0xffff));
    };
    break :blk result;
};

pub const Font = struct {
    point_size: u16,
    ascent: i16,
    descent: i16,
    line_height: u16,
    ranges: []const Range,
    glyphs: []const Glyph,
    atlases: []const image.ConstImage(image.ImgRgba16.Pixel) = &.{},
    outline_atlases: []const image.PalettedImage(color.Ci4Pair) = &.{},
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
            if (kerningBefore(pair, first, second))
                low = middle + 1
            else
                high = middle;
        }
        if (low < self.kernings.len) {
            const pair = self.kernings[low];
            if (kerningMatches(pair, first, second)) return pair.amount;
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
        if (self.outline_atlases.len != 0) {
            render_queue.setCombineMode(.single(.{ .rgb_a = .primitive, .rgb_b = .environment, .rgb_c = .tex0, .rgb_d = .environment, .alpha_a = .tex0, .alpha_c = .primitive }));
            render_queue.setEnvironmentColor(options.outline_color);
            render_queue.setBlendMode(.alpha);
            var modes = render_queue.getModes();
            modes.antialias_en = true;
            modes.blender_alpha = .cvg_times_cc;
            render_queue.setModes(modes);
            render_queue.setPrimColor(options.color);
            return self.layout(@as(?@TypeOf(render_queue), render_queue), x, baseline_y, utf8, options);
        }
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

    /// Format and draw using caller-owned scratch storage. The text is consumed
    /// while recording: scratch may be reused immediately after this returns.
    /// Formatting errors occur before any render commands are emitted.
    pub fn drawPrint(self: Font, render_queue: anytype, x: f32, baseline_y: f32, buffer: []u8, options: TextOptions, comptime fmt: []const u8, args: anytype) (Error || error{NoSpaceLeft})!TextMetrics {
        const text = try @import("std").fmt.bufPrint(buffer, fmt, args);
        return self.draw(render_queue, x, baseline_y, text, options);
    }

    fn layout(self: *const Font, render_queue: anytype, origin_x: f32, baseline_y: f32, utf8: []const u8, options: TextOptions) Error!TextMetrics {
        if (options.scale <= 0) return .{};
        const view = @import("std").unicode.Utf8View.init(utf8) catch return Error.InvalidUtf8;
        var iterator = view.iterator();
        var cursor = TextCursor.init(origin_x, baseline_y, self.line_height, options);
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                cursor.newline();
                continue;
            }
            const glyph_index = self.glyphIndex(codepoint) orelse {
                cursor.previous = null;
                continue;
            };
            cursor.place(self, render_queue, glyph_index);
        }
        cursor.metrics.width = @max(cursor.metrics.width, cursor.x - origin_x);
        return cursor.metrics;
    }
};

fn kerningBefore(pair: Kerning, first: u16, second: u16) bool {
    return pair.first < first or (pair.first == first and pair.second < second);
}

fn kerningMatches(pair: Kerning, first: u16, second: u16) bool {
    return pair.first == first and pair.second == second;
}

const TextCursor = struct {
    origin_x: f32,
    origin_y: f32,
    x: f32,
    y: f32,
    line_height: u16,
    options: TextOptions,
    previous: ?u16 = null,
    metrics: TextMetrics,

    fn init(x: f32, y: f32, line_height: u16, options: TextOptions) TextCursor {
        return .{
            .origin_x = x,
            .origin_y = y,
            .x = x,
            .y = y,
            .line_height = line_height,
            .options = options,
            .metrics = .{ .height = @as(f32, @floatFromInt(line_height)) * options.scale, .lines = 1 },
        };
    }
    fn newline(self: *TextCursor) void {
        self.metrics.width = @max(self.metrics.width, self.x - self.origin_x);
        self.x = self.origin_x;
        self.y += @as(f32, @floatFromInt(@as(i32, self.line_height) + self.options.line_spacing)) * self.options.scale;
        self.previous = null;
        self.metrics.lines += 1;
        self.metrics.height = self.y - self.origin_y + @as(f32, @floatFromInt(self.line_height)) * self.options.scale;
    }
    fn place(self: *TextCursor, font: *const Font, render_queue: anytype, index: u16) void {
        const glyph = font.glyphs[index];
        if (self.previous) |prior| self.x += @as(f32, @floatFromInt(font.kerning(prior, index))) * self.options.scale;
        if (render_queue) |queue| {
            if (glyph.width != 0 and glyph.height != 0 and font.outline_atlases.len != 0) {
                const x = self.x + @as(f32, @floatFromInt(glyph.x_offset)) * self.options.scale;
                const y = self.y + @as(f32, @floatFromInt(glyph.y_offset)) * self.options.scale;
                if (self.options.scale == 1 and x == @trunc(x) and y == @trunc(y)) {
                    queue.drawGlyph(font.outline_atlases[glyph.atlas], @intFromFloat(x), @intFromFloat(y), glyph.s, glyph.t, glyph.width, glyph.height, glyph.layer);
                } else queue.drawSprite(font.outline_atlases[glyph.atlas], x, y, .{ .s0 = glyph.s, .t0 = glyph.t, .width = @intCast(glyph.width), .height = @intCast(glyph.height), .scale_x = self.options.scale, .scale_y = self.options.scale, .palette = glyph.layer });
            } else if (glyph.width != 0 and glyph.height != 0) queue.drawSprite(
                font.atlases[glyph.atlas],
                self.x + @as(f32, @floatFromInt(glyph.x_offset)) * self.options.scale,
                self.y + @as(f32, @floatFromInt(glyph.y_offset)) * self.options.scale,
                .{ .s0 = glyph.s, .t0 = glyph.t, .width = @intCast(glyph.width), .height = @intCast(glyph.height), .scale_x = self.options.scale, .scale_y = self.options.scale },
            );
        }
        self.x += @as(f32, @floatFromInt(glyph.x_advance)) * self.options.scale;
        self.previous = index;
        self.metrics.glyphs += 1;
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
    layer: u1 = 0,
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

test "formatted drawing consumes scratch and reports overflow before rendering" {
    const std = @import("std");
    const combiner = @import("rdp/combiner.zig");
    const blender = @import("rdp/blender.zig");
    const texture = @import("rdp/texture.zig");
    const Queue = struct {
        glyph_count: usize = 0,
        commands: usize = 0,
        pub fn setCombineMode(self: *@This(), _: combiner.CombineMode) void {
            self.commands += 1;
        }
        pub fn setBlendMode(self: *@This(), _: blender.BlendMode) void {
            self.commands += 1;
        }
        pub fn setPrimColor(self: *@This(), _: color.Rgba32) void {
            self.commands += 1;
        }
        pub fn setEnvironmentColor(_: *@This(), _: color.Rgba32) void {}
        pub fn getModes(_: *@This()) @import("rdp/modes.zig").OtherModes {
            return .{};
        }
        pub fn setModes(_: *@This(), _: @import("rdp/modes.zig").OtherModes) void {}
        pub fn drawGlyph(_: *@This(), _: anytype, _: i16, _: i16, _: u8, _: u8, _: u16, _: u16, _: u4) void {
            unreachable;
        }
        pub fn drawSprite(self: *@This(), _: anytype, _: f32, _: f32, _: texture.SpriteDrawOptions) void {
            self.glyph_count += 1;
        }
    };
    const pixels = [_]color.Rgba16{.white};
    const font: Font = .{
        .point_size = 8,
        .ascent = 7,
        .descent = -1,
        .line_height = 10,
        .ranges = &.{.{ .first_codepoint = 'A', .glyph_count = 1, .first_glyph = 0 }},
        .glyphs = &.{.{ .x_advance = 5, .x_offset = 0, .y_offset = 0, .width = 1, .height = 1, .s = 0, .t = 0, .atlas = 0 }},
        .atlases = &.{.{ .width = 1, .height = 1, .texel_data = &pixels }},
    };
    var queue: Queue = .{};
    var scratch: [8]u8 = undefined;
    const metrics = try font.drawPrint(&queue, 0, 0, &scratch, .{}, "{s}\n{s}", .{ "AA", "A" });
    @memset(&scratch, 0); // Recorded draws do not borrow formatted text.
    try std.testing.expectEqual(@as(u32, 3), metrics.glyphs);
    try std.testing.expectEqual(@as(u16, 2), metrics.lines);
    try std.testing.expectEqual(@as(usize, 3), queue.glyph_count);
    const commands = queue.commands;
    try std.testing.expectError(error.NoSpaceLeft, font.drawPrint(&queue, 0, 0, scratch[0..1], .{}, "{s}", .{"AA"}));
    try std.testing.expectEqual(commands, queue.commands);
    try std.testing.expectError(error.InvalidUtf8, font.drawPrint(&queue, 0, 0, &scratch, .{}, "{s}", .{"\xff"}));
}
