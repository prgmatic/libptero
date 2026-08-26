const std = @import("std");
const texture_compiler = @import("texture_compiler");

pub const Error = error{ InvalidBmFont, MissingPage, InvalidPage, GlyphTooLarge, EllipsisGlyphMissing };
pub const Options = struct { kerning: bool = true, ellipsis_codepoint: u32 = '.', ellipsis_repetitions: u16 = 3 };
pub const Page = struct { id: u16, width: u32, height: u32, rgba: []const u8 };
pub const Range = struct { first_codepoint: u32, glyph_count: u16, first_glyph: u16 };
pub const Glyph = struct { x_advance: i16, x_offset: i16, y_offset: i16, width: u16, height: u16, s: u8, t: u8, atlas: u8 };
pub const Kerning = struct { first: u16, second: u16, amount: i16 };
pub const Atlas = struct { texel_offset: u32, texel_length: u32, width: u16, height: u16 };
pub const Ellipsis = struct { glyph: u16, repetitions: u16, advance: i16, width: i16 };

pub const Result = struct {
    point_size: u16,
    ascent: i16,
    descent: i16,
    line_height: u16,
    ranges: []Range,
    glyphs: []Glyph,
    kernings: []Kerning,
    atlases: []Atlas,
    texels: []u8,
    ellipsis: ?Ellipsis,
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
        allocator.free(self.glyphs);
        allocator.free(self.kernings);
        allocator.free(self.atlases);
        allocator.free(self.texels);
    }
};

const SourceGlyph = struct { codepoint: u32, x: u16, y: u16, width: u16, height: u16, x_offset: i16, y_offset: i16, x_advance: i16, page: u16 };
const SourceKerning = struct { first: u32, second: u32, amount: i16 };
const Parsed = struct {
    point_size: u16 = 0,
    line_height: u16 = 0,
    base: i16 = 0,
    pages: u16 = 0,
    glyphs: std.ArrayList(SourceGlyph) = .empty,
    kernings: std.ArrayList(SourceKerning) = .empty,
    fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        self.glyphs.deinit(allocator);
        self.kernings.deinit(allocator);
    }
};
const WorkingAtlas = struct { rgba: []u8, skyline: [64]u8 = @splat(0), used_width: u16 = 1, used_height: u16 = 1 };

pub fn compile(allocator: std.mem.Allocator, description: []const u8, pages: []const Page, options: Options) !Result {
    var parsed = try parse(allocator, description);
    defer parsed.deinit(allocator);
    if (parsed.pages != pages.len) return Error.MissingPage;
    if (parsed.glyphs.items.len > std.math.maxInt(u16)) return Error.InvalidBmFont;
    try validatePages(parsed.pages, pages);
    std.mem.sort(SourceGlyph, parsed.glyphs.items, {}, struct {
        fn less(_: void, a: SourceGlyph, b: SourceGlyph) bool {
            return a.codepoint < b.codepoint;
        }
    }.less);
    try rejectDuplicateCodepoints(parsed.glyphs.items);
    const ranges = try makeRanges(allocator, parsed.glyphs.items);
    errdefer allocator.free(ranges);
    var working: std.ArrayList(WorkingAtlas) = .empty;
    defer {
        for (working.items) |atlas| allocator.free(atlas.rgba);
        working.deinit(allocator);
    }
    const glyphs = try packGlyphs(allocator, parsed.glyphs.items, pages, parsed.base, &working);
    errdefer allocator.free(glyphs);
    const kernings = if (options.kerning) try makeKernings(allocator, parsed.kernings.items, parsed.glyphs.items) else try allocator.alloc(Kerning, 0);
    errdefer allocator.free(kernings);
    const ellipsis = try makeEllipsis(options, parsed.glyphs.items, glyphs, kernings);
    const encoded = try encodeAtlases(allocator, working.items);
    errdefer {
        allocator.free(encoded.atlases);
        allocator.free(encoded.texels);
    }
    const descent = std.math.cast(i16, @as(i32, parsed.base) - parsed.line_height) orelse return Error.InvalidBmFont;
    return .{ .point_size = parsed.point_size, .ascent = parsed.base, .descent = descent, .line_height = parsed.line_height, .ranges = ranges, .glyphs = glyphs, .kernings = kernings, .atlases = encoded.atlases, .texels = encoded.texels, .ellipsis = ellipsis };
}

fn validatePages(expected: u16, pages: []const Page) !void {
    for (pages, 0..) |page, i| {
        if (page.id >= expected or page.rgba.len != @as(usize, page.width) * page.height * 4) return Error.InvalidPage;
        for (pages[0..i]) |previous| if (page.id == previous.id) return Error.InvalidPage;
    }
}

fn parse(allocator: std.mem.Allocator, source: []const u8) !Parsed {
    if (!std.mem.startsWith(u8, source, "info ")) return Error.InvalidBmFont;
    var result: Parsed = .{};
    errdefer result.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, source, "\r\n");
    while (lines.next()) |line| try parseLine(allocator, line, &result);
    if (result.pages == 0 or result.glyphs.items.len == 0) return Error.InvalidBmFont;
    return result;
}
fn parseLine(allocator: std.mem.Allocator, line: []const u8, parsed: *Parsed) !void {
    var fields = FieldIterator.init(line);
    const command = fields.nextCommand() orelse return;
    if (std.mem.eql(u8, command, "info")) return parseInfo(&fields, parsed);
    if (std.mem.eql(u8, command, "common")) return parseCommon(&fields, parsed);
    if (std.mem.eql(u8, command, "char")) try parsed.glyphs.append(allocator, try parseGlyph(&fields));
    if (std.mem.eql(u8, command, "kerning")) try parsed.kernings.append(allocator, try parseKerning(&fields));
}
fn parseInfo(fields: *FieldIterator, parsed: *Parsed) !void {
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field.key, "size")) parsed.point_size = try number(u16, field.value);
    }
}
fn parseCommon(fields: *FieldIterator, parsed: *Parsed) !void {
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field.key, "lineHeight")) parsed.line_height = try number(u16, field.value);
        if (std.mem.eql(u8, field.key, "base")) parsed.base = try number(i16, field.value);
        if (std.mem.eql(u8, field.key, "pages")) parsed.pages = try number(u16, field.value);
    }
}
fn parseGlyph(fields: *FieldIterator) !SourceGlyph {
    var glyph: SourceGlyph = undefined;
    var seen: u16 = 0;
    while (fields.next()) |field| {
        inline for (glyph_descriptors) |descriptor| {
            if (std.mem.eql(u8, field.key, descriptor.key)) {
                @field(glyph, descriptor.member) = try number(@TypeOf(@field(glyph, descriptor.member)), field.value);
                seen |= descriptor.bit;
                break;
            }
        }
    }
    if (seen != 0x1ff) return Error.InvalidBmFont;
    return glyph;
}
const GlyphDescriptor = struct { key: []const u8, member: []const u8, bit: u16 };
const glyph_descriptors = [_]GlyphDescriptor{
    .{ .key = "id", .member = "codepoint", .bit = 1 },      .{ .key = "x", .member = "x", .bit = 2 },
    .{ .key = "y", .member = "y", .bit = 4 },               .{ .key = "width", .member = "width", .bit = 8 },
    .{ .key = "height", .member = "height", .bit = 16 },    .{ .key = "xoffset", .member = "x_offset", .bit = 32 },
    .{ .key = "yoffset", .member = "y_offset", .bit = 64 }, .{ .key = "xadvance", .member = "x_advance", .bit = 128 },
    .{ .key = "page", .member = "page", .bit = 256 },
};
fn parseKerning(fields: *FieldIterator) !SourceKerning {
    var kerning: SourceKerning = undefined;
    var seen: u8 = 0;
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field.key, "first")) {
            kerning.first = try number(u32, field.value);
            seen |= 1;
        }
        if (std.mem.eql(u8, field.key, "second")) {
            kerning.second = try number(u32, field.value);
            seen |= 2;
        }
        if (std.mem.eql(u8, field.key, "amount")) {
            kerning.amount = try number(i16, field.value);
            seen |= 4;
        }
    }
    if (seen != 7) return Error.InvalidBmFont;
    return kerning;
}
const FieldIterator = struct {
    rest: []const u8,
    fn init(line: []const u8) FieldIterator {
        return .{ .rest = line };
    }
    fn nextCommand(self: *FieldIterator) ?[]const u8 {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
        const end = std.mem.indexOfAny(u8, self.rest, " \t") orelse self.rest.len;
        defer self.rest = self.rest[end..];
        return if (end == 0) null else self.rest[0..end];
    }
    fn next(self: *FieldIterator) ?struct { key: []const u8, value: []const u8 } {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
        if (self.rest.len == 0) return null;
        const equal = std.mem.indexOfScalar(u8, self.rest, '=') orelse return null;
        const key = self.rest[0..equal];
        var start = equal + 1;
        if (start < self.rest.len and self.rest[start] == '"') {
            start += 1;
            const end = start + (std.mem.indexOfScalar(u8, self.rest[start..], '"') orelse return null);
            const value = self.rest[start..end];
            self.rest = self.rest[@min(end + 1, self.rest.len)..];
            return .{ .key = key, .value = value };
        }
        const end = start + (std.mem.indexOfAny(u8, self.rest[start..], " \t") orelse self.rest[start..].len);
        const value = self.rest[start..end];
        self.rest = self.rest[end..];
        return .{ .key = key, .value = value };
    }
};
fn number(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch Error.InvalidBmFont;
}
fn rejectDuplicateCodepoints(glyphs: []const SourceGlyph) !void {
    for (glyphs[1..], glyphs[0 .. glyphs.len - 1]) |current, previous| if (current.codepoint == previous.codepoint) return Error.InvalidBmFont;
}
fn pageById(pages: []const Page, id: u16) ?Page {
    for (pages) |page| if (page.id == id) return page;
    return null;
}

fn makeRanges(allocator: std.mem.Allocator, glyphs: []const SourceGlyph) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(allocator);
    var start: usize = 0;
    while (start < glyphs.len) {
        var end = start + 1;
        while (end < glyphs.len and glyphs[end].codepoint == glyphs[end - 1].codepoint + 1) end += 1;
        try ranges.append(allocator, .{ .first_codepoint = glyphs[start].codepoint, .glyph_count = @intCast(end - start), .first_glyph = @intCast(start) });
        start = end;
    }
    return ranges.toOwnedSlice(allocator);
}
fn packGlyphs(allocator: std.mem.Allocator, source: []const SourceGlyph, pages: []const Page, base: i16, atlases: *std.ArrayList(WorkingAtlas)) ![]Glyph {
    const glyphs = try allocator.alloc(Glyph, source.len);
    errdefer allocator.free(glyphs);
    const order = try allocator.alloc(usize, source.len);
    defer allocator.free(order);
    for (order, 0..) |*entry, index| entry.* = index;
    std.mem.sort(usize, order, source, struct {
        fn less(glyphs_source: []const SourceGlyph, a: usize, b: usize) bool {
            const ga = glyphs_source[a];
            const gb = glyphs_source[b];
            return ga.height > gb.height or (ga.height == gb.height and ga.width > gb.width);
        }
    }.less);
    var packer: Packer = .{};
    for (order) |index| {
        const glyph = source[index];
        const placement = try packer.place(allocator, atlases, glyph.width, glyph.height);
        const page = pageById(pages, glyph.page) orelse return Error.MissingPage;
        if (@as(u32, glyph.x) + glyph.width > page.width or @as(u32, glyph.y) + glyph.height > page.height) return Error.InvalidPage;
        const atlas = &atlases.items[placement.atlas];
        copyGlyph(atlas.rgba, placement.x, placement.y, page, glyph);
        atlas.used_width = @max(atlas.used_width, placement.x + glyph.width);
        atlas.used_height = @max(atlas.used_height, placement.y + glyph.height);
        const y_offset = std.math.cast(i16, @as(i32, glyph.y_offset) - base) orelse return Error.InvalidBmFont;
        glyphs[index] = .{ .x_advance = glyph.x_advance, .x_offset = glyph.x_offset, .y_offset = y_offset, .width = glyph.width, .height = glyph.height, .s = @intCast(placement.x), .t = @intCast(placement.y), .atlas = placement.atlas };
    }
    return glyphs;
}
const Packer = struct {
    fn place(self: *Packer, allocator: std.mem.Allocator, atlases: *std.ArrayList(WorkingAtlas), width: u16, height: u16) !Placement {
        _ = self;
        if (width > 64 or height > 32) return Error.GlyphTooLarge;
        for (atlases.items, 0..) |*atlas, atlas_index| if (findSkylinePlacement(atlas, width, height)) |position|
            return occupy(atlas, @intCast(atlas_index), position, width, height);
        try addAtlas(allocator, atlases);
        return occupy(&atlases.items[atlases.items.len - 1], @intCast(atlases.items.len - 1), .{ .x = 0, .y = 0 }, width, height);
    }
};
const Position = struct { x: u16, y: u16 };
const Placement = struct { x: u16, y: u16, atlas: u8 };
fn findSkylinePlacement(atlas: *const WorkingAtlas, width: u16, height: u16) ?Position {
    if (width == 0 or height == 0) return .{ .x = 0, .y = 0 };
    var best: ?Position = null;
    for (0..65 - width) |x| {
        var y: u8 = 0;
        for (atlas.skyline[x..][0..width]) |column| y = @max(y, column);
        if (@as(u16, y) + height > 32) continue;
        if (best == null or y < best.?.y) best = .{ .x = @intCast(x), .y = y };
    }
    return best;
}
fn occupy(atlas: *WorkingAtlas, atlas_index: u8, position: Position, width: u16, height: u16) Placement {
    const top: u8 = @intCast(position.y + height);
    @memset(atlas.skyline[position.x..][0..width], top);
    return .{ .x = position.x, .y = position.y, .atlas = atlas_index };
}
fn addAtlas(allocator: std.mem.Allocator, atlases: *std.ArrayList(WorkingAtlas)) !void {
    if (atlases.items.len >= 256) return Error.GlyphTooLarge;
    const rgba = try allocator.alloc(u8, 64 * 32 * 4);
    @memset(rgba, 0);
    try atlases.append(allocator, .{ .rgba = rgba });
}
fn copyGlyph(dst: []u8, dx: u16, dy: u16, page: Page, glyph: SourceGlyph) void {
    for (0..glyph.height) |row| {
        const from = ((@as(usize, glyph.y) + row) * page.width + glyph.x) * 4;
        const to = ((@as(usize, dy) + row) * 64 + dx) * 4;
        @memcpy(dst[to..][0 .. @as(usize, glyph.width) * 4], page.rgba[from..][0 .. @as(usize, glyph.width) * 4]);
    }
}
fn makeKernings(allocator: std.mem.Allocator, source: []const SourceKerning, glyphs: []const SourceGlyph) ![]Kerning {
    var result: std.ArrayList(Kerning) = .empty;
    errdefer result.deinit(allocator);
    for (source) |pair| {
        const first = sourceGlyphIndex(glyphs, pair.first) orelse continue;
        const second = sourceGlyphIndex(glyphs, pair.second) orelse continue;
        try result.append(allocator, .{ .first = @intCast(first), .second = @intCast(second), .amount = pair.amount });
    }
    std.mem.sort(Kerning, result.items, {}, struct {
        fn less(_: void, a: Kerning, b: Kerning) bool {
            return a.first < b.first or (a.first == b.first and a.second < b.second);
        }
    }.less);
    return result.toOwnedSlice(allocator);
}
fn sourceGlyphIndex(glyphs: []const SourceGlyph, cp: u32) ?usize {
    for (glyphs, 0..) |glyph, index| if (glyph.codepoint == cp) return index;
    return null;
}
fn makeEllipsis(options: Options, source: []const SourceGlyph, glyphs: []const Glyph, kernings: []const Kerning) !?Ellipsis {
    if (options.ellipsis_repetitions == 0) return null;
    const index = sourceGlyphIndex(source, options.ellipsis_codepoint) orelse return Error.EllipsisGlyphMissing;
    var advance: i32 = glyphs[index].x_advance;
    for (kernings) |pair| if (pair.first == index and pair.second == index) {
        advance += pair.amount;
        break;
    };
    const right_edge = @as(i32, glyphs[index].x_offset) + glyphs[index].width;
    return .{
        .glyph = @intCast(index),
        .repetitions = options.ellipsis_repetitions,
        .advance = std.math.cast(i16, advance) orelse return Error.InvalidBmFont,
        .width = std.math.cast(i16, advance * (options.ellipsis_repetitions - 1) + right_edge) orelse return Error.InvalidBmFont,
    };
}
fn encodeAtlases(allocator: std.mem.Allocator, working: []const WorkingAtlas) !struct { atlases: []Atlas, texels: []u8 } {
    const atlases = try allocator.alloc(Atlas, working.len);
    errdefer allocator.free(atlases);
    var texels: std.ArrayList(u8) = .empty;
    errdefer texels.deinit(allocator);
    for (working, 0..) |atlas, index| {
        const rgba = try cropAtlas(allocator, atlas);
        defer allocator.free(rgba);
        const converted = try texture_compiler.convertRgba(allocator, atlas.used_width, atlas.used_height, rgba, .{ .format = .rgba16 });
        defer converted.deinit(allocator);
        atlases[index] = .{ .texel_offset = @intCast(texels.items.len), .texel_length = @intCast(converted.base_texel_bytes), .width = atlas.used_width, .height = atlas.used_height };
        try texels.appendSlice(allocator, converted.texels[0..converted.base_texel_bytes]);
    }
    return .{ .atlases = atlases, .texels = try texels.toOwnedSlice(allocator) };
}
fn cropAtlas(allocator: std.mem.Allocator, atlas: WorkingAtlas) ![]u8 {
    const rgba = try allocator.alloc(u8, @as(usize, atlas.used_width) * atlas.used_height * 4);
    for (0..atlas.used_height) |row| {
        const count = @as(usize, atlas.used_width) * 4;
        @memcpy(rgba[row * count ..][0..count], atlas.rgba[row * 64 * 4 ..][0..count]);
    }
    return rgba;
}

test "compiles native font metadata and atlas texels" {
    const rgba = [_]u8{ 255, 255, 255, 255 } ** 4;
    const input =
        \\info face="fixture" size=8
        \\common lineHeight=10 base=8 pages=1
        \\page id=0 file="page.png"
        \\chars count=2
        \\char id=32 x=0 y=0 width=1 height=1 xoffset=0 yoffset=0 xadvance=3 page=0 chnl=15
        \\char id=46 x=1 y=0 width=1 height=1 xoffset=1 yoffset=1 xadvance=2 page=0 chnl=15
        \\kernings count=1
        \\kerning first=46 second=46 amount=-1
    ;
    const result = try compile(std.testing.allocator, input, &.{.{ .id = 0, .width = 2, .height = 2, .rgba = &rgba }}, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.glyphs.len);
    try std.testing.expectEqual(@as(usize, 1), result.atlases.len);
    try std.testing.expectEqual(@as(i16, 1), result.ellipsis.?.advance);
    try std.testing.expectEqual(@as(i16, 4), result.ellipsis.?.width);
    try std.testing.expectEqual(@as(usize, 4), result.texels.len);
}
