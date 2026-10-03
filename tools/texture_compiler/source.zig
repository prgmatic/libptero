const std = @import("std");

pub fn generateSourceWithStorage(allocator: std.mem.Allocator, name: []const u8, result: @import("types.zig").Result, storage: enum { resident, rom }) ![]u8 {
    if (!std.zig.isValidId(name)) return error.InvalidAssetName;
    if (storage == .resident) return generateSource(allocator, name, result);
    const pixel = pixelName(result.format);
    const palette_offset = std.mem.alignForward(usize, result.base_texel_bytes, 8);
    const byte_len = if (result.palette.len == 0) result.base_texel_bytes else palette_offset + result.palette.len;
    const palette_field = if (result.palette.len == 0) "" else try std.fmt.allocPrint(allocator,
        \\        .palette = std.mem.bytesAsSlice(n64.graphics.color.Rgba16, bytes[{d}..{d}]),
        \\
    , .{ palette_offset, byte_len });
    defer if (result.palette.len != 0) allocator.free(palette_field);
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\pub const {s}: n64.rom.TypedAsset(Definition) = .{{ .asset = @import("rom_data").{s} }};
        \\pub const Definition = struct {{
        \\    pub const byte_len = {d};
        \\    pub const Storage = struct {{}};
        \\    pub const Value = n64.graphics.image.{s}(n64.graphics.color.{s});
        \\    pub fn bind(bytes: []align(16) const u8, _: *Storage, content_id: u64) Value {{
        \\        return .{{ .width = {d}, .height = {d}, .content_id = content_id,
        \\        .texel_data = std.mem.bytesAsSlice(n64.graphics.color.{s}, bytes[0..{d}]),
        \\{s}        }};
        \\    }}
        \\}};
        \\
    , .{ name, name, byte_len, if (result.palette.len == 0) "ConstImage" else "PalettedImage", pixel, result.width, result.height, pixel, result.base_texel_bytes, palette_field });
}

pub fn generateSource(allocator: std.mem.Allocator, name: []const u8, result: @import("types.zig").Result) ![]u8 {
    if (!std.zig.isValidId(name)) return error.InvalidAssetName;
    const image_type = imageName(result.format);
    if (result.palette.len != 0) return generatePalettedSource(allocator, name, image_type, result);
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\const bytes align(8) = @embedFile("texture_data").*;
        \\pub const {s}: n64.graphics.image.ConstImage(n64.graphics.image.{s}.Pixel) = .{{
        \\    .width = {d},
        \\    .height = {d},
        \\    .texel_data = std.mem.bytesAsSlice(n64.graphics.image.{s}.Pixel, &bytes),
        \\}};
        \\
    , .{ name, image_type, result.width, result.height, image_type });
}

pub fn textureData(allocator: std.mem.Allocator, result: @import("types.zig").Result) ![]u8 {
    const palette_offset = std.mem.alignForward(usize, result.base_texel_bytes, 8);
    const length = if (result.palette.len == 0) result.base_texel_bytes else palette_offset + result.palette.len;
    const data = try allocator.alloc(u8, length);
    @memset(data, 0);
    @memcpy(data[0..result.base_texel_bytes], result.texels[0..result.base_texel_bytes]);
    if (result.palette.len != 0) @memcpy(data[palette_offset..], result.palette);
    return data;
}

fn generatePalettedSource(allocator: std.mem.Allocator, name: []const u8, image_type: []const u8, result: @import("types.zig").Result) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\const bytes align(8) = @embedFile("texture_data").*;
        \\pub const {s}: n64.graphics.image.PalettedImage(n64.graphics.image.{s}.Pixel) = .{{
        \\    .width = {d}, .height = {d},
        \\    .texel_data = std.mem.bytesAsSlice(n64.graphics.image.{s}.Pixel, bytes[0..{d}]),
        \\    .palette = std.mem.bytesAsSlice(n64.graphics.color.Rgba16, bytes[{d}..]),
        \\}};
        \\
    , .{ name, image_type, result.width, result.height, image_type, result.base_texel_bytes, std.mem.alignForward(usize, result.base_texel_bytes, 8) });
}

fn pixelName(format: @import("types.zig").Format) []const u8 {
    const names = [_][]const u8{ "", "", "Rgba16", "Rgba32", "", "", "Yuv16", "", "Ci4Pair", "Ci8", "", "", "Ia4Pair", "Ia8", "Ia16", "", "I4Pair", "I8" };
    return names[@intFromEnum(format)];
}
fn imageName(format: @import("types.zig").Format) []const u8 {
    const names = [_][]const u8{ "", "", "ImgRgba16", "ImgRgba32", "", "", "ImgYuv16", "", "ImgCi4", "ImgCi8", "", "", "ImgIa4", "ImgIa8", "ImgIa16", "", "ImgI4", "ImgI8" };
    return names[@intFromEnum(format)];
}

test "ROM source describes every texture format without embedding its payload" {
    const compiler = @import("root.zig");
    const allocator = std.testing.allocator;
    inline for (std.meta.tags(compiler.Format)) |format| {
        const result = try compiler.convertRgba(allocator, 2, 2, &(.{ 255, 0, 0, 255 } ** 4), .{ .format = format });
        defer result.deinit(allocator);
        const data = try textureData(allocator, result);
        defer allocator.free(data);
        const source = try generateSourceWithStorage(allocator, "texture", result, .rom);
        defer allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "@embedFile") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, pixelName(format)) != null);
        const expected = try std.fmt.allocPrint(allocator, "byte_len = {d};", .{data.len});
        defer allocator.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, source, expected) != null);
        try std.testing.expect((result.palette.len != 0) == (std.mem.indexOf(u8, source, ".palette =") != null));
        try std.testing.expectError(error.InvalidAssetName, generateSourceWithStorage(allocator, "not-valid", result, .rom));
        const resident = try generateSourceWithStorage(allocator, "texture", result, .resident);
        defer allocator.free(resident);
        try std.testing.expect(std.mem.indexOf(u8, resident, "@embedFile") != null);
    }
}
