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

/// Decode a PNG file (given as raw bytes) and return an RGBA image.
/// Supports 8-bit grayscale, grayscale+alpha, RGB, RGBA, and indexed color.
/// Does not support 16-bit depth or interlaced images.
pub fn readRgba(allocator: Allocator, png_data: []const u8) !Image {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], png_sig))
        return error.InvalidPng;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: ColorType = undefined;
    var header_found = false;
    var palette: ?[][3]u8 = null;
    defer if (palette) |p| allocator.free(p);

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);

    while (pos + 12 <= png_data.len) {
        const chunk_len = std.mem.readInt(u32, png_data[pos..][0..4], .big);
        if (pos + 12 + chunk_len > png_data.len) return error.TruncatedPng;
        const chunk_type = png_data[pos + 4 ..][0..4];
        const chunk_data = png_data[pos + 8 ..][0..chunk_len];
        pos += 12 + chunk_len;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len != 13) return error.InvalidPng;
            width = std.mem.readInt(u32, chunk_data[0..4], .big);
            height = std.mem.readInt(u32, chunk_data[4..8], .big);
            if (chunk_data[8] != 8) return error.UnsupportedBitDepth;
            if (chunk_data[12] != 0) return error.UnsupportedInterlace;
            color_type = @enumFromInt(chunk_data[9]);
            header_found = true;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (chunk_len % 3 != 0) return error.InvalidPng;
            const pal = try allocator.alloc([3]u8, chunk_len / 3);
            for (pal, 0..) |*e, i| e.* = chunk_data[i * 3 ..][0..3].*;
            palette = pal;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    if (!header_found) return error.InvalidPng;
    if (color_type == .indexed and palette == null) return error.MissingPalette;

    const bpp: u32 = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1,
        .grayscale_alpha => 2,
        .rgba => 4,
    };
    const stride = width * bpp;

    // Decompress all IDAT data (zlib-wrapped deflate).
    const raw = raw: {
        const window = try allocator.alloc(u8, flate.max_window_len);
        defer allocator.free(window);
        var input = std.Io.Reader.fixed(idat.items);
        var decomp = flate.Decompress.init(&input, .zlib, window);
        const raw = try allocator.alloc(u8, height * (1 + stride));
        errdefer allocator.free(raw);
        decomp.reader.readSliceAll(raw) catch return error.DecompressFailed;
        break :raw raw;
    };
    defer allocator.free(raw);

    const pixels = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(pixels);

    for (0..height) |y| {
        const row_off = y * (1 + stride);
        const filter = raw[row_off];
        const row = raw[row_off + 1 ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) raw[(y - 1) * (1 + stride) + 1 ..][0..stride] else null;

        // Un-filter in place; rows above are already reconstructed.
        try unfilter(row, prev, bpp, filter);

        toRgba(row, pixels[y * width * 4 ..][0..width * 4], color_type, palette);
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn unfilter(row: []u8, prev: ?[]const u8, bpp: u32, filter: u8) !void {
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

fn toRgba(row: []const u8, out: []u8, color_type: ColorType, palette: ?[][3]u8) void {
    const n = out.len / 4;
    switch (color_type) {
        .grayscale => for (0..n) |i| {
            out[i * 4 ..][0..4].* = .{ row[i], row[i], row[i], 255 };
        },
        .rgb => for (0..n) |i| {
            out[i * 4 ..][0..4].* = .{ row[i * 3], row[i * 3 + 1], row[i * 3 + 2], 255 };
        },
        .indexed => for (0..n) |i| {
            const c = palette.?[row[i]];
            out[i * 4 ..][0..4].* = .{ c[0], c[1], c[2], 255 };
        },
        .grayscale_alpha => for (0..n) |i| {
            out[i * 4 ..][0..4].* = .{ row[i * 2], row[i * 2], row[i * 2], row[i * 2 + 1] };
        },
        .rgba => @memcpy(out, row),
    }
}
