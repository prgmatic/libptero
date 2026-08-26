const std = @import("std");
const texture_compiler = @import("root.zig");

test "RGBA16 conversion contains texels without a runtime header" {
    const source = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0 };
    const result = try texture_compiler.convertRgba(std.testing.allocator, 2, 1, &source, .{ .format = .rgba16 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0xf8, 0x01, 0x07, 0xc0 }, result.texels);
    try std.testing.expectEqual(@as(usize, 4), result.base_texel_bytes);
    try std.testing.expectEqual(@as(usize, 0), result.palette.len);
}

test "automatic format preserves grayscale and alpha" {
    const gray = [_]u8{ 42, 42, 42, 255 };
    const alpha = [_]u8{ 42, 42, 42, 100 };
    const a = try texture_compiler.convertRgba(std.testing.allocator, 1, 1, &gray, .{});
    defer a.deinit(std.testing.allocator);
    const b = try texture_compiler.convertRgba(std.testing.allocator, 1, 1, &alpha, .{});
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(texture_compiler.Format.i8, a.format);
    try std.testing.expectEqual(texture_compiler.Format.ia16, b.format);
}

test "CI4 emits a separate palette" {
    const source = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const result = try texture_compiler.convertRgba(std.testing.allocator, 2, 1, &source, .{ .format = .ci4 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{0x01}, result.texels);
    try std.testing.expectEqual(@as(usize, 4), result.palette.len);
}

test "box mipmaps are packed after the base level" {
    const source = [_]u8{255} ** (4 * 4 * 4);
    const result = try texture_compiler.convertRgba(std.testing.allocator, 4, 4, &source, .{ .format = .rgba16, .mipmap = .box });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), result.levels);
    try std.testing.expectEqual(@as(usize, 32), result.base_texel_bytes);
    try std.testing.expectEqual(@as(usize, 42), result.texels.len);
}
