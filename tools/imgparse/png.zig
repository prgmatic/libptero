const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA pixels, row-major, 4 bytes per pixel.
    pixels: []u8,

    pub fn deinit(self: Image, allocator: Allocator) void {
        allocator.free(self.pixels);
    }
};

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

const png_sig = "\x89PNG\r\n\x1a\n";

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: ColorType,

    fn read(data: []const u8) !Header {
        if (data.len != 13) return error.InvalidPng;
        const color = std.enums.fromInt(ColorType, data[9]) orelse return error.UnsupportedColorType;
        const depth = data[8];
        switch (color) {
            .grayscale, .indexed => if (depth != 1 and depth != 2 and depth != 4 and depth != 8) return error.UnsupportedBitDepth,
            else => if (depth != 8) return error.UnsupportedBitDepth,
        }
        if (data[10] != 0 or data[11] != 0) return error.InvalidPng;
        if (data[12] != 0) return error.UnsupportedInterlace;
        const width = std.mem.readInt(u32, data[0..4], .big);
        const height = std.mem.readInt(u32, data[4..8], .big);
        if (width == 0 or height == 0) return error.InvalidPng;
        return .{ .width = width, .height = height, .depth = depth, .color = color };
    }

    fn channels(self: Header) usize {
        return switch (self.color) {
            .grayscale, .indexed => 1,
            .rgb => 3,
            .grayscale_alpha => 2,
            .rgba => 4,
        };
    }

    fn stride(self: Header) !usize {
        const bits = std.math.mul(usize, self.width, self.channels() * self.depth) catch return error.ImageTooLarge;
        return (std.math.add(usize, bits, 7) catch return error.ImageTooLarge) / 8;
    }

    fn filterBytes(self: Header) usize {
        return @max(1, (self.channels() * self.depth + 7) / 8);
    }
};

const Metadata = struct {
    header: ?Header = null,
    palette: ?[]const u8 = null,
    transparency: ?[]const u8 = null,

    fn readPalette(self: *Metadata, data: []const u8) !void {
        const header = self.header orelse return error.InvalidPng;
        if (self.palette != null or self.transparency != null or data.len == 0 or data.len % 3 != 0 or data.len > 768) return error.InvalidPng;
        if (header.color == .indexed and data.len / 3 > (@as(usize, 1) << @intCast(header.depth))) return error.InvalidPng;
        self.palette = data;
    }

    fn readTransparency(self: *Metadata, data: []const u8) !void {
        const header = self.header orelse return error.InvalidPng;
        if (self.transparency != null) return error.InvalidPng;
        switch (header.color) {
            .grayscale => if (data.len != 2) return error.InvalidPng,
            .rgb => if (data.len != 6) return error.InvalidPng,
            .indexed => {
                const palette = self.palette orelse return error.MissingPalette;
                if (data.len == 0 or data.len > palette.len / 3) return error.InvalidPng;
            },
            .grayscale_alpha, .rgba => return error.InvalidPng,
        }
        self.transparency = data;
    }
};

/// Decode PNG bytes to RGBA. Supports 1/2/4/8-bit grayscale and indexed color,
/// 8-bit RGB, grayscale+alpha and RGBA, and palette/grayscale/RGB tRNS.
/// Does not support 16-bit samples or interlaced images.
pub fn readRgba(allocator: Allocator, png_data: []const u8) !Image {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], png_sig)) return error.InvalidPng;
    var metadata: Metadata = .{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var pos: usize = 8;
    var ended = false;
    while (png_data.len - pos >= 12) {
        const chunk_len = std.mem.readInt(u32, png_data[pos..][0..4], .big);
        if (chunk_len > png_data.len - pos - 12) return error.TruncatedPng;
        const chunk_type = png_data[pos + 4 ..][0..4];
        const chunk_data = png_data[pos + 8 ..][0..chunk_len];
        pos += 12 + @as(usize, chunk_len);
        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (metadata.header != null or pos != 33) return error.InvalidPng;
            metadata.header = try Header.read(chunk_data);
        } else if (metadata.header == null) {
            return error.InvalidPng;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (idat.items.len != 0) return error.InvalidPng;
            try metadata.readPalette(chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            if (idat.items.len != 0) return error.InvalidPng;
            try metadata.readTransparency(chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (chunk_len != 0) return error.InvalidPng;
            ended = true;
            break;
        }
    }
    const header = metadata.header orelse return error.InvalidPng;
    if (!ended) return error.TruncatedPng;
    if (header.color == .indexed and metadata.palette == null) return error.MissingPalette;
    const stride = try header.stride();
    const raw_len = std.math.mul(usize, header.height, std.math.add(usize, stride, 1) catch return error.ImageTooLarge) catch return error.ImageTooLarge;
    const raw = try decompress(allocator, idat.items, raw_len);
    defer allocator.free(raw);
    const pixel_count = std.math.mul(usize, header.width, header.height) catch return error.ImageTooLarge;
    const pixels = try allocator.alloc(u8, std.math.mul(usize, pixel_count, 4) catch return error.ImageTooLarge);
    errdefer allocator.free(pixels);
    for (0..header.height) |y| {
        const row_off = y * (1 + stride);
        const row = raw[row_off + 1 ..][0..stride];
        const previous: ?[]const u8 = if (y > 0) raw[(y - 1) * (1 + stride) + 1 ..][0..stride] else null;
        try unfilter(row, previous, header.filterBytes(), raw[row_off]);
        try toRgba(row, pixels[y * header.width * 4 ..][0 .. @as(usize, header.width) * 4], metadata);
    }
    return .{ .width = header.width, .height = header.height, .pixels = pixels };
}

fn decompress(allocator: Allocator, data: []const u8, length: usize) ![]u8 {
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var input = std.Io.Reader.fixed(data);
    var decomp = flate.Decompress.init(&input, .zlib, window);
    const raw = try allocator.alloc(u8, length);
    errdefer allocator.free(raw);
    decomp.reader.readSliceAll(raw) catch return error.DecompressFailed;
    return raw;
}

fn unfilter(row: []u8, prev: ?[]const u8, bpp: usize, filter: u8) !void {
    switch (filter) {
        0 => {},
        1 => {
            for (bpp..row.len) |i| row[i] +%= row[i - bpp];
        },
        2 => {
            if (prev) |p| {
                for (row, p) |*r, b| r.* +%= b;
            }
        },
        3 => {
            for (row, 0..) |*r, i| {
                const a: u9 = if (i >= bpp) row[i - bpp] else 0;
                const b: u9 = if (prev) |p| p[i] else 0;
                r.* +%= @truncate((a + b) / 2);
            }
        },
        4 => {
            for (row, 0..) |*r, i| {
                const a: u8 = if (i >= bpp) row[i - bpp] else 0;
                const b: u8 = if (prev) |p| p[i] else 0;
                const c: u8 = if (i >= bpp) (if (prev) |p| p[i - bpp] else 0) else 0;
                r.* +%= paeth(a, b, c);
            }
        },
        else => return error.UnknownFilter,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn sample(row: []const u8, index: usize, depth: u8) u8 {
    const bit = index * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
    return (row[bit / 8] >> shift) & mask;
}

fn colorKey(transparency: ?[]const u8, components: []const u8) bool {
    const key = transparency orelse return false;
    for (components, 0..) |value, i| {
        if (value != std.mem.readInt(u16, key[i * 2 ..][0..2], .big)) return false;
    }
    return true;
}

fn toRgba(row: []const u8, out: []u8, metadata: Metadata) !void {
    const header = metadata.header.?;
    const n = out.len / 4;
    switch (header.color) {
        .grayscale => for (0..n) |i| {
            const value = sample(row, i, header.depth);
            const maximum: u16 = (@as(u16, 1) << @intCast(header.depth)) - 1;
            const gray: u8 = @intCast(@as(u16, value) * 255 / maximum);
            out[i * 4 ..][0..4].* = .{ gray, gray, gray, if (colorKey(metadata.transparency, &.{value})) 0 else 255 };
        },
        .rgb => for (0..n) |i| {
            const rgb = row[i * 3 ..][0..3];
            out[i * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], if (colorKey(metadata.transparency, rgb)) 0 else 255 };
        },
        .indexed => for (0..n) |i| {
            const index = sample(row, i, header.depth);
            const palette = metadata.palette.?;
            if (index >= palette.len / 3) return error.InvalidPaletteIndex;
            const rgb = palette[@as(usize, index) * 3 ..][0..3];
            const alpha = if (metadata.transparency) |values| (if (index < values.len) values[index] else 255) else 255;
            out[i * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], alpha };
        },
        .grayscale_alpha => for (0..n) |i| {
            out[i * 4 ..][0..4].* = .{ row[i * 2], row[i * 2], row[i * 2], row[i * 2 + 1] };
        },
        .rgba => @memcpy(out, row),
    }
}

const Fixture = struct {
    fn chunk(bytes: *std.ArrayList(u8), name: *const [4]u8, data: []const u8) !void {
        var number: [4]u8 = undefined;
        std.mem.writeInt(u32, &number, @intCast(data.len), .big);
        try bytes.appendSlice(std.testing.allocator, &number);
        try bytes.appendSlice(std.testing.allocator, name);
        try bytes.appendSlice(std.testing.allocator, data);
        var crc = std.hash.Crc32.init();
        crc.update(name);
        crc.update(data);
        std.mem.writeInt(u32, &number, crc.final(), .big);
        try bytes.appendSlice(std.testing.allocator, &number);
    }

    fn png(header: Header, palette: ?[]const u8, transparency: ?[]const u8, rows: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, png_sig);
        var ihdr: [13]u8 = @splat(0);
        std.mem.writeInt(u32, ihdr[0..4], header.width, .big);
        std.mem.writeInt(u32, ihdr[4..8], header.height, .big);
        ihdr[8] = header.depth;
        ihdr[9] = @intFromEnum(header.color);
        try chunk(&bytes, "IHDR", &ihdr);
        if (palette) |data| try chunk(&bytes, "PLTE", data);
        if (transparency) |data| try chunk(&bytes, "tRNS", data);

        // A stored DEFLATE block makes test scanlines independent of an encoder.
        var zlib: std.ArrayList(u8) = .empty;
        defer zlib.deinit(allocator);
        try zlib.appendSlice(allocator, &.{ 0x78, 0x01, 0x01 });
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(rows.len), .little);
        try zlib.appendSlice(allocator, &length);
        std.mem.writeInt(u16, &length, ~@as(u16, @intCast(rows.len)), .little);
        try zlib.appendSlice(allocator, &length);
        try zlib.appendSlice(allocator, rows);
        var checksum: [4]u8 = undefined;
        std.mem.writeInt(u32, &checksum, std.hash.Adler32.hash(rows), .big);
        try zlib.appendSlice(allocator, &checksum);
        // Exercise concatenation of separate IDAT chunks.
        try chunk(&bytes, "IDAT", zlib.items[0..3]);
        try chunk(&bytes, "IDAT", zlib.items[3..]);
        try chunk(&bytes, "IEND", &.{});
        return bytes.toOwnedSlice(allocator);
    }

    fn encodeFilter(row: []const u8, previous: ?[]const u8, out: []u8, bpp: usize, filter: u8) void {
        for (row, 0..) |value, i| {
            const left = if (i >= bpp) row[i - bpp] else 0;
            const above = if (previous) |p| p[i] else 0;
            const upper_left = if (i >= bpp) (if (previous) |p| p[i - bpp] else 0) else 0;
            const predictor = switch (filter) {
                0 => 0,
                1 => left,
                2 => above,
                3 => @as(u8, @intCast((@as(u9, left) + above) / 2)),
                4 => paeth(left, above, upper_left),
                else => unreachable,
            };
            out[i] = value -% predictor;
        }
    }
};

test "indexed depths unpack high bits, ignore row padding and retain partial palette alpha through every filter" {
    const allocator = std.testing.allocator;
    for ([_]u8{ 1, 2, 4, 8 }) |depth| {
        const header: Header = .{ .width = 11, .height = 5, .depth = depth, .color = .indexed };
        const stride = try header.stride();
        const count: usize = @as(usize, 1) << @intCast(depth);
        var palette: [256 * 3]u8 = undefined;
        for (0..count) |i| palette[i * 3 ..][0..3].* = .{ @intCast(i), @intCast(255 - i), 123 };
        var rows: [5 * 12]u8 = @splat(0);
        var previous: [11]u8 = @splat(0);
        for (0..5) |y| {
            var packed_row: [11]u8 = @splat(0);
            for (0..11) |x| {
                const index: u8 = @intCast((x + y) % count);
                const bit = x * depth;
                packed_row[bit / 8] |= index << @as(u3, @intCast(8 - depth - bit % 8));
            }
            // Padding is deliberately nonzero: it must not become extra pixels.
            if ((11 * depth) % 8 != 0) packed_row[stride - 1] |= (@as(u8, 1) << @as(u3, @intCast(8 - (11 * depth) % 8))) - 1;
            rows[y * (stride + 1)] = @intCast(y);
            Fixture.encodeFilter(packed_row[0..stride], if (y == 0) null else previous[0..stride], rows[y * (stride + 1) + 1 ..][0..stride], 1, @intCast(y));
            previous = packed_row;
        }
        const png = try Fixture.png(header, palette[0 .. count * 3], &.{ 0, 96 }, rows[0 .. 5 * (stride + 1)]);
        defer allocator.free(png);
        const image = try readRgba(allocator, png);
        defer image.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 11), image.width);
        try std.testing.expectEqual(@as(u32, 5), image.height);
        for (0..5) |y| for (0..11) |x| {
            const index: u8 = @intCast((x + y) % count);
            try std.testing.expectEqualDeep([4]u8{ index, 255 - index, 123, if (index == 0) 0 else if (index == 1) 96 else 255 }, image.pixels[(y * 11 + x) * 4 ..][0..4].*);
        };
    }
}

test "grayscale transparency compares original samples before expanding packed depths" {
    const allocator = std.testing.allocator;
    for ([_]u8{ 1, 2, 4, 8 }) |depth| {
        const png = try Fixture.png(.{ .width = 2, .height = 1, .depth = depth, .color = .grayscale }, null, &.{ 0, 1 }, if (depth == 8) &.{ 0, 1, 0 } else &.{ 0, @as(u8, 1) << @as(u3, @intCast(8 - depth)) });
        defer allocator.free(png);
        const image = try readRgba(allocator, png);
        defer image.deinit(allocator);
        const gray: u8 = @intCast(255 / ((@as(u16, 1) << @intCast(depth)) - 1));
        try std.testing.expectEqualSlices(u8, &.{ gray, gray, gray, 0, 0, 0, 0, 255 }, image.pixels);
    }
}

test "RGB transparency matches the complete 16-bit key without truncation" {
    const allocator = std.testing.allocator;
    const header: Header = .{ .width = 2, .height = 1, .depth = 8, .color = .rgb };
    const rows = [_]u8{ 0, 12, 34, 56, 12, 34, 57 };
    const png = try Fixture.png(header, null, &.{ 0, 12, 0, 34, 0, 56 }, &rows);
    defer allocator.free(png);
    const image = try readRgba(allocator, png);
    defer image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56, 0, 12, 34, 57, 255 }, image.pixels);
    const high_key_png = try Fixture.png(header, null, &.{ 1, 12, 0, 34, 0, 56 }, &rows);
    defer allocator.free(high_key_png);
    const high_key_image = try readRgba(allocator, high_key_png);
    defer high_key_image.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 255), high_key_image.pixels[3]);
}

test "invalid palettes and transparency return errors without invalid indexing" {
    const allocator = std.testing.allocator;
    const indexed: Header = .{ .width = 1, .height = 1, .depth = 4, .color = .indexed };
    const missing = try Fixture.png(indexed, null, null, &.{ 0, 0 });
    defer allocator.free(missing);
    try std.testing.expectError(error.MissingPalette, readRgba(allocator, missing));
    const invalid_index = try Fixture.png(indexed, &.{ 10, 20, 30 }, null, &.{ 0, 0x10 });
    defer allocator.free(invalid_index);
    try std.testing.expectError(error.InvalidPaletteIndex, readRgba(allocator, invalid_index));
    const excessive_alpha = try Fixture.png(indexed, &.{ 10, 20, 30 }, &.{ 0, 255 }, &.{ 0, 0 });
    defer allocator.free(excessive_alpha);
    try std.testing.expectError(error.InvalidPng, readRgba(allocator, excessive_alpha));
    const rgba = try Fixture.png(.{ .width = 1, .height = 1, .depth = 8, .color = .rgba }, null, &.{0}, &.{ 0, 1, 2, 3, 4 });
    defer allocator.free(rgba);
    try std.testing.expectError(error.InvalidPng, readRgba(allocator, rgba));
}

test "alpha channel images keep their explicit alpha" {
    const allocator = std.testing.allocator;
    const gray = try Fixture.png(.{ .width = 2, .height = 1, .depth = 8, .color = .grayscale_alpha }, null, null, &.{ 0, 12, 34, 56, 78 });
    defer allocator.free(gray);
    const gray_image = try readRgba(allocator, gray);
    defer gray_image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 12, 12, 12, 34, 56, 56, 56, 78 }, gray_image.pixels);
    const rgba = try Fixture.png(.{ .width = 1, .height = 1, .depth = 8, .color = .rgba }, null, null, &.{ 0, 12, 34, 56, 78 });
    defer allocator.free(rgba);
    const rgba_image = try readRgba(allocator, rgba);
    defer rgba_image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56, 78 }, rgba_image.pixels);
}
