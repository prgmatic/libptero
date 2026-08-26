const std = @import("std");
const font_compiler = @import("font_compiler");
const png = @import("png");

const usage =
    \\Usage: font-compiler <input.fnt> <texels.bin> <font.zig> <name> [options]
    \\
    \\Options:
    \\  --no-kerning             Omit kerning pairs
    \\  --ellipsis <hex>,<reps>  Ellipsis glyph and repetitions (default: 2E,3)
    \\  -h, --help               Show this help
    \\
    \\Input must be a text-format AngelCode BMFont file with PNG pages.
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (args.len < 5) fatal("{s}", .{usage});
    var options: font_compiler.Options = .{};
    parseOptions(args[5..], &options);
    try compileOne(init.io, allocator, args[1], args[2], args[3], args[4], options);
}

fn parseOptions(args: []const []const u8, options: *font_compiler.Options) void {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--no-kerning")) options.kerning = false else if (std.mem.eql(u8, args[index], "--ellipsis")) {
            index += 1;
            if (index == args.len) fatal("missing argument for --ellipsis", .{});
            parseEllipsis(args[index], options) catch fatal("invalid ellipsis specification: {s}", .{args[index]});
        } else fatal("unknown option: {s}", .{args[index]});
    }
}

fn compileOne(io: std.Io, allocator: std.mem.Allocator, input: []const u8, texel_output: []const u8, source_output: []const u8, name: []const u8, options: font_compiler.Options) !void {
    if (!std.zig.isValidId(name)) fatal("'{s}' is not a valid Zig identifier", .{name});
    const description = try readFile(io, allocator, input);
    defer allocator.free(description);
    const specs = try parsePages(allocator, description);
    defer {
        for (specs) |spec| allocator.free(spec.name);
        allocator.free(specs);
    }
    const pages = try loadPages(io, allocator, std.fs.path.dirname(input) orelse ".", specs);
    defer {
        for (pages) |page| allocator.free(page.rgba);
        allocator.free(pages);
    }
    const result = font_compiler.compile(allocator, description, pages, options) catch |err| fatal("{s}: {s}", .{ input, @errorName(err) });
    defer result.deinit(allocator);
    const source = try generateSource(allocator, name, result);
    defer allocator.free(source);
    try writeFile(io, texel_output, result.texels);
    try writeFile(io, source_output, source);
}

const PageSpec = struct { id: u16, name: []u8 };
fn parsePages(allocator: std.mem.Allocator, source: []const u8) ![]PageSpec {
    var result: std.ArrayList(PageSpec) = .empty;
    errdefer {
        for (result.items) |spec| allocator.free(spec.name);
        result.deinit(allocator);
    }
    var lines = std.mem.tokenizeAny(u8, source, "\r\n");
    while (lines.next()) |line| {
        const spec = try parsePageLine(allocator, line) orelse continue;
        try result.append(allocator, spec);
    }
    return result.toOwnedSlice(allocator);
}
fn parsePageLine(allocator: std.mem.Allocator, line: []const u8) !?PageSpec {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "page ")) return null;
    const id = field(trimmed, "id") orelse return error.InvalidBmFont;
    const name = field(trimmed, "file") orelse return error.InvalidBmFont;
    return .{ .id = std.fmt.parseInt(u16, id, 10) catch return error.InvalidBmFont, .name = try allocator.dupe(u8, name) };
}
fn field(line: []const u8, key: []const u8) ?[]const u8 {
    var needle: [32]u8 = undefined;
    if (key.len + 1 > needle.len) return null;
    @memcpy(needle[0..key.len], key);
    needle[key.len] = '=';
    const position = std.mem.indexOf(u8, line, needle[0 .. key.len + 1]) orelse return null;
    var value = line[position + key.len + 1 ..];
    if (value.len > 0 and value[0] == '"') return quotedValue(value[1..]);
    return value[0 .. std.mem.indexOfAny(u8, value, " \t") orelse value.len];
}
fn quotedValue(value: []const u8) ?[]const u8 {
    return value[0 .. std.mem.indexOfScalar(u8, value, '"') orelse return null];
}
fn loadPages(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, specs: []const PageSpec) ![]font_compiler.Page {
    const pages = try allocator.alloc(font_compiler.Page, specs.len);
    errdefer allocator.free(pages);
    var loaded: usize = 0;
    errdefer for (pages[0..loaded]) |page| allocator.free(page.rgba);
    for (specs, 0..) |spec, index| {
        const path = try std.fs.path.join(allocator, &.{ directory, spec.name });
        defer allocator.free(path);
        const bytes = try readFile(io, allocator, path);
        defer allocator.free(bytes);
        const decoded = try png.readRgba(allocator, bytes);
        pages[index] = .{ .id = spec.id, .width = decoded.width, .height = decoded.height, .rgba = decoded.pixels };
        loaded += 1;
    }
    return pages;
}

fn generateSource(allocator: std.mem.Allocator, name: []const u8, result: font_compiler.Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("const std = @import(\"std\");\nconst n64 = @import(\"n64\");\nvar texels align(8) = @embedFile(\"font_texels\").*;\n", .{});
    try writer.print("const ranges = [_]n64.graphics.font.Range{{\n", .{});
    for (result.ranges) |range| try writer.print("    .{{ .first_codepoint = {d}, .glyph_count = {d}, .first_glyph = {d} }},\n", .{ range.first_codepoint, range.glyph_count, range.first_glyph });
    try writer.print("}};\n", .{});
    try writer.print("const glyphs = [_]n64.graphics.font.Glyph{{\n", .{});
    for (result.glyphs) |glyph| try writer.print("    .{{ .x_advance = {d}, .x_offset = {d}, .y_offset = {d}, .width = {d}, .height = {d}, .s = {d}, .t = {d}, .atlas = {d} }},\n", .{ glyph.x_advance, glyph.x_offset, glyph.y_offset, glyph.width, glyph.height, glyph.s, glyph.t, glyph.atlas });
    try writer.print("}};\n", .{});
    try writer.print("const kernings = [_]n64.graphics.font.Kerning{{\n", .{});
    for (result.kernings) |pair| try writer.print("    .{{ .first = {d}, .second = {d}, .amount = {d} }},\n", .{ pair.first, pair.second, pair.amount });
    try writer.print("}};\n", .{});
    try writer.print("const atlases = [_]n64.graphics.image.ImgRgba16{{\n", .{});
    for (result.atlases) |atlas| try writer.print("    .{{ .width = {d}, .height = {d}, .texel_data = std.mem.bytesAsSlice(n64.graphics.image.ImgRgba16.Pixel, texels[{d}..{d}]) }},\n", .{ atlas.width, atlas.height, atlas.texel_offset, atlas.texel_offset + atlas.texel_length });
    try writer.print("}};\n", .{});
    try writer.print("pub const {s}: n64.graphics.font.Font = .{{ .point_size = {d}, .ascent = {d}, .descent = {d}, .line_height = {d}, .ranges = &ranges, .glyphs = &glyphs, .atlases = &atlases, .kernings = &kernings, .ellipsis = ", .{ name, result.point_size, result.ascent, result.descent, result.line_height });
    if (result.ellipsis) |ellipsis| try writer.print(".{{ .glyph = {d}, .repetitions = {d}, .advance = {d}, .width = {d} }}", .{ ellipsis.glyph, ellipsis.repetitions, ellipsis.advance, ellipsis.width }) else try writer.print("null", .{});
    try writer.print(" }};\n", .{});
    return out.toOwnedSlice();
}
fn parseEllipsis(value: []const u8, options: *font_compiler.Options) !void {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return error.Invalid;
    options.ellipsis_codepoint = try std.fmt.parseInt(u32, value[0..comma], 16);
    options.ellipsis_repetitions = try std.fmt.parseInt(u16, value[comma + 1 ..], 10);
}
fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}
fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("font-compiler: " ++ format ++ "\n", args);
    std.process.exit(1);
}

test "generates typed native font source" {
    const result: font_compiler.Result = .{ .point_size = 8, .ascent = 7, .descent = -1, .line_height = 10, .ranges = &.{}, .glyphs = &.{}, .kernings = &.{}, .atlases = &.{}, .texels = &.{}, .ellipsis = null };
    const source = try generateSource(std.testing.allocator, "fixture", result);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const fixture: n64.graphics.font.Font") != null);
}
