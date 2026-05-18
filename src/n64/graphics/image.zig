const std = @import("std");
const colors = @import("color.zig");
const ColorFormat = colors.Format;
const BitDepth = colors.BitDepth;

/// 32-bit RGBA image.
pub const ImgRgba32 = Image(colors.Rgba32);
/// 16-bit RGBA image.
pub const ImgRgba16 = Image(colors.Rgba16);
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

pub fn Image(comptime PixelFormat: type) type {
    return struct{
        const Self = @This();

        width: u16,
        height: u16,
        texel_data: []PixelFormat,

        pub const format: ColorFormat = PixelFormat.format;
        pub const bit_depth: BitDepth = PixelFormat.bit_depth;

        pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Self {
            const w: u32 = width;
            const h: u32 = height;
            const buffer_len = w * h;
            return .{
                .width = width,
                .height = height,
                // TODO: Configurable alignment
                .texel_data = try allocator.alignedAlloc(PixelFormat, std.mem.Alignment.@"32", buffer_len)
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.texel_data);
        }

        pub fn fill(self: *Self, color: PixelFormat) void {
            @memset(self.texel_data, color);
        }

        pub fn fillRegion(self: *Self, color: PixelFormat, x: u32, y: u32, width: u32, height: u32) void {
            for(y..y+height) |yi| {
                for(x..x+width) |xi| {
                    const idx = yi * self.width + xi;
                    self.texel_data[idx] = color;
                }
            }
        }
    };
}
