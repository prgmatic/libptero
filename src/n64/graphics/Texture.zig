//! Format-erased, borrowed texture reference. Materials store textures as this
//! plain data so every model shares one material type; the RDP texture path
//! reads the format at runtime instead of instantiating code per pixel type.
//! Texel and palette storage must stay alive and coherent until GPU completion.
const std = @import("std");
const pixel = @import("pixel.zig");

const Texture = @This();

pub const PaletteFormat = enum { rgba16, ia16 };

format: pixel.Format,
bit_depth: pixel.BitDepth,
width: u16,
height: u16,
texels: [*]const u8,
/// Color-indexed lookup table, empty for direct-color formats.
palette: []const pixel.Rgba16 = &.{},
palette_format: PaletteFormat = .rgba16,
/// Residency identity; zero is ordinary caller-managed/embedded storage.
content_id: u64 = 0,

/// Describe a typed `Image`, `ConstImage`, `PalettedImage`, or `Texture`.
/// Color-indexed images must carry their palette.
pub fn from(image: anytype) Texture {
    const Source = @TypeOf(image);
    if (Source == Texture) return image;
    if (Source.format == .color_indexed and !@hasField(Source, "palette"))
        @compileError("CI textures require PalettedImage with an RGBA16 palette");
    return .{
        .format = Source.format,
        .bit_depth = Source.bit_depth,
        .width = image.width,
        .height = image.height,
        .texels = @ptrCast(image.texel_data.ptr),
        .palette = if (@hasField(Source, "palette")) image.palette else &.{},
        .palette_format = if (@hasField(Source, "palette_format")) switch (image.palette_format) {
            .rgba16 => .rgba16,
            .ia16 => .ia16,
        } else .rgba16,
        .content_id = if (@hasField(Source, "content_id")) image.content_id else 0,
    };
}

pub fn isIndexed(self: Texture) bool {
    return self.format == .color_indexed;
}

/// Bits per texel as stored in RDRAM and TMEM.
pub fn bitsPerTexel(self: Texture) u32 {
    return @as(u32, 4) << @intFromEnum(self.bit_depth);
}

/// TMEM 64-bit words occupied by the full image.
pub fn tmemWords(self: Texture) u32 {
    return ((@as(u32, self.width) * self.bitsPerTexel() + 63) / 64) * self.height;
}

/// Whether both references name the same resident texels and layout.
pub fn sharesTexels(self: Texture, other: Texture) bool {
    return self.format == other.format and self.bit_depth == other.bit_depth and
        self.width == other.width and self.height == other.height and
        self.texels == other.texels and self.content_id == other.content_id;
}

test "typed images keep format, dimensions, palette and residency identity" {
    const image = @import("image.zig");
    const texels = [_]pixel.Rgba16{.white} ** 8;
    const direct: image.ConstImage(pixel.Rgba16) = .{ .width = 4, .height = 2, .texel_data = &texels, .content_id = 9 };
    const texture = Texture.from(direct);
    try std.testing.expectEqual(pixel.Format.rgba, texture.format);
    try std.testing.expectEqual(pixel.BitDepth.@"16", texture.bit_depth);
    try std.testing.expectEqual(@as(u64, 9), texture.content_id);
    try std.testing.expectEqual(@as(u32, 2), texture.tmemWords());
    try std.testing.expect(!texture.isIndexed());
    try std.testing.expectEqual(texture, Texture.from(texture));

    const indices = [_]pixel.Ci4Pair{@bitCast(@as(u8, 0x12))} ** 8;
    const palette align(8) = [_]pixel.Rgba16{.red} ** 16;
    const paletted: image.PalettedImage(pixel.Ci4Pair) = .{ .width = 4, .height = 4, .texel_data = &indices, .palette = &palette, .palette_format = .ia16 };
    const indexed = Texture.from(paletted);
    try std.testing.expect(indexed.isIndexed());
    try std.testing.expectEqual(@as(usize, 16), indexed.palette.len);
    try std.testing.expectEqual(PaletteFormat.ia16, indexed.palette_format);
    try std.testing.expectEqual(@as(u32, 4), indexed.bitsPerTexel());
}

test "shared texels require identical layout and content identity" {
    const texels = [_]u8{0} ** 64;
    const base: Texture = .{ .format = .intensity, .bit_depth = .@"8", .width = 8, .height = 8, .texels = &texels };
    try std.testing.expect(base.sharesTexels(base));
    var other = base;
    other.content_id = 1;
    try std.testing.expect(!base.sharesTexels(other));
    other = base;
    other.width = 4;
    try std.testing.expect(!base.sharesTexels(other));
    other = base;
    other.bit_depth = .@"4";
    try std.testing.expect(!base.sharesTexels(other));
}
