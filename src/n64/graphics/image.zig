const std = @import("std");
const colors = @import("color.zig");
const ColorFormat = colors.Format;
const BitDepth = colors.BitDepth;

/// 32-bit RGBA image.
pub const ImgRgba32 = Image(colors.Rgba32);
/// 16-bit RGBA image.
pub const ImgRgba16 = Image(colors.Rgba16);
/// 16-bit YUV image.
pub const ImgYuv16 = Image(colors.Yuv16);
/// 16-bit intensity+alpha image.
pub const ImgIa16 = Image(colors.Ia16);
/// 8-bit intensity+alpha image.
pub const ImgIa8 = Image(colors.Ia8);
/// 4-bit intensity+alpha image.
pub const ImgIa4 = Image(colors.Ia4Pair);
/// 8-bit grayscale image.
pub const ImgI8 = Image(colors.I8);
/// 4-bit grayscale image.
pub const ImgI4 = Image(colors.I4Pair);
/// 8-bit color-indexed image.
pub const ImgCi8 = Image(colors.Ci8);
/// 4-bit color-indexed image.
pub const ImgCi4 = Image(colors.Ci4Pair);

/// Errors returned when constructing a view over caller-owned storage.
pub const ViewError = error{ InvalidDimensions, BufferTooSmall };

/// Mutable borrowed image. Storage and cache visibility remain the caller's responsibility.
pub fn Image(comptime PixelFormat: type) type {
    return ImageView(PixelFormat, false);
}

/// Read-only borrowed image, suitable for embedded assets.
pub fn ConstImage(comptime PixelFormat: type) type {
    return ImageView(PixelFormat, true);
}

fn ImageView(comptime PixelFormat: type, comptime read_only: bool) type {
    return struct {
        const Self = @This();
        pub const Pixel = PixelFormat;
        pub const Value = if (PixelFormat.bit_depth == .@"4") u4 else PixelFormat;
        pub const format: ColorFormat = PixelFormat.format;
        pub const bit_depth: BitDepth = PixelFormat.bit_depth;
        const Storage = if (read_only) []const Pixel else []Pixel;

        width: u16,
        height: u16,
        texel_data: Storage,

        /// Four-bit images store two logical pixels per element, across row boundaries.
        pub fn elementCount(width: u16, height: u16) usize {
            const count = @as(usize, width) * height;
            return if (bit_depth == .@"4") (count + 1) / 2 else count;
        }

        pub fn initBuffer(buffer: Storage, width: u16, height: u16) ViewError!Self {
            if (width == 0 or height == 0) return error.InvalidDimensions;
            const count = elementCount(width, height);
            if (buffer.len < count) return error.BufferTooSmall;
            return .{ .width = width, .height = height, .texel_data = buffer[0..count] };
        }

        pub fn asConst(self: Self) ConstImage(Pixel) {
            return .{ .width = self.width, .height = self.height, .texel_data = self.texel_data };
        }

        pub fn get(self: Self, x: u16, y: u16) Value {
            std.debug.assert(x < self.width and y < self.height);
            const index = @as(usize, y) * self.width + x;
            if (bit_depth != .@"4") return self.texel_data[index];
            const byte: u8 = @bitCast(self.texel_data[index / 2]);
            return @truncate(if (index % 2 == 0) byte >> 4 else byte);
        }

        pub fn set(self: Self, x: u16, y: u16, value: Value) void {
            if (read_only) @compileError("cannot modify a ConstImage");
            std.debug.assert(x < self.width and y < self.height);
            const index = @as(usize, y) * self.width + x;
            if (bit_depth != .@"4") {
                self.texel_data[index] = value;
                return;
            }
            const previous: u8 = @bitCast(self.texel_data[index / 2]);
            const byte = if (index % 2 == 0)
                (previous & 0x0f) | (@as(u8, value) << 4)
            else
                (previous & 0xf0) | value;
            self.texel_data[index / 2] = @bitCast(byte);
        }

        pub fn fill(self: Self, value: Value) void {
            if (read_only) @compileError("cannot modify a ConstImage");
            const pixel: Pixel = if (bit_depth == .@"4") @bitCast(@as(u8, value) * 0x11) else value;
            @memset(self.texel_data[0..elementCount(self.width, self.height)], pixel);
        }

        pub fn fillRegion(self: Self, value: Value, x: u32, y: u32, width: u32, height: u32) void {
            std.debug.assert(x <= self.width and width <= self.width - x);
            std.debug.assert(y <= self.height and height <= self.height - y);
            for (y..y + height) |yi| {
                for (x..x + width) |xi| self.set(@intCast(xi), @intCast(yi), value);
            }
        }
    };
}

/// Allocator-owned image storage. Keep it alive until all submitted GPU work completes.
pub fn ImageBuffer(comptime PixelFormat: type) type {
    return struct {
        const Self = @This();
        width: u16,
        height: u16,
        pixels: []align(64) PixelFormat,

        pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Self {
            if (width == 0 or height == 0) return error.InvalidDimensions;
            return .{
                .width = width,
                .height = height,
                .pixels = try allocator.alignedAlloc(PixelFormat, .@"64", Image(PixelFormat).elementCount(width, height)),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.pixels);
            self.* = undefined;
        }

        pub fn view(self: Self) Image(PixelFormat) {
            return .{ .width = self.width, .height = self.height, .texel_data = self.pixels };
        }

        pub fn constView(self: Self) ConstImage(PixelFormat) {
            return self.view().asConst();
        }
    };
}

test "owned images retain alignment and borrow mutable and read-only views" {
    var buffer = try ImageBuffer(colors.Rgba16).init(std.testing.allocator, 3, 2);
    defer buffer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(buffer.pixels.ptr) % 64);
    const view = buffer.view();
    view.fill(.blue);
    view.fillRegion(.green, 1, 0, 1, 2);
    try std.testing.expectEqual(colors.Rgba16.green, buffer.constView().get(1, 1));
    try std.testing.expectEqual(colors.Rgba16.blue, buffer.constView().get(2, 1));
    try std.testing.expect(!@hasDecl(@TypeOf(view), "deinit"));
    try std.testing.expect(@typeInfo(@TypeOf(buffer.constView().texel_data)).pointer.is_const);
    try std.testing.expectError(error.BufferTooSmall, ImgRgba16.initBuffer(buffer.pixels[0..1], 3, 2));
    try std.testing.expectError(error.InvalidDimensions, ImgRgba16.initBuffer(buffer.pixels, 0, 2));
    try std.testing.expectError(error.InvalidDimensions, ImageBuffer(colors.Rgba16).init(std.testing.allocator, 0, 2));
    try std.testing.expectError(error.OutOfMemory, ImageBuffer(colors.Rgba16).init(std.testing.failing_allocator, 3, 2));
}

test "four-bit storage and regions address logical pixels including odd rows" {
    inline for (.{ colors.I4Pair, colors.Ia4Pair, colors.Ci4Pair }) |Pixel| {
        var buffer = try ImageBuffer(Pixel).init(std.testing.allocator, 3, 3);
        defer buffer.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 5), buffer.pixels.len);
        const view = buffer.view();
        view.fill(1);
        view.fillRegion(12, 1, 0, 1, 3);
        for (0..3) |y| {
            try std.testing.expectEqual(@as(u4, 1), view.get(0, @intCast(y)));
            try std.testing.expectEqual(@as(u4, 12), view.get(1, @intCast(y)));
            try std.testing.expectEqual(@as(u4, 1), view.get(2, @intCast(y)));
        }
        try std.testing.expectEqual(@as(u8, 0x11), @as(u8, @bitCast(buffer.pixels[4])));
    }
}

/// Borrowed color-indexed texture plus its RGBA16 lookup table. Both slices must
/// remain coherent and alive until GPU completion. The palette must be eight-byte
/// aligned and occupies upper TMEM.
pub fn PalettedImage(comptime PixelFormat: type) type {
    if (PixelFormat.format != .color_indexed) @compileError("palette textures require CI4 or CI8 pixels");
    return struct {
        pub const Pixel = PixelFormat;
        pub const format = Pixel.format;
        pub const bit_depth = Pixel.bit_depth;
        width: u16,
        height: u16,
        texel_data: []const Pixel,
        palette: []const colors.Rgba16,
        /// IA16 palettes use the same raw16-bit storage; bits are interpreted by TLUT.
        palette_format: enum { rgba16, ia16 } = .rgba16,
    };
}
