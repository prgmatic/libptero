const std = @import("std");
const color = @import("color.zig");

/// Hardware packed far depth and maximum depth delta.
pub const clear_value: u16 = 0xffff;

/// Borrowed hardware depth image. The RDP requires 64-byte aligned storage.
pub const Image = struct {
    width: u16,
    height: u16,
    texel_data: []align(64) u16,

    // Depth clears temporarily bind this storage as a 16-bit color image.
    pub const format = color.Format.rgba;
    pub const bit_depth = color.BitDepth.@"16";

    pub fn initBuffer(buffer: []align(64) u16, width: u16, height: u16) !Image {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const count = @as(usize, width) * height;
        if (buffer.len < count) return error.BufferTooSmall;
        return .{ .width = width, .height = height, .texel_data = buffer[0..count] };
    }
};

/// Allocator-owned depth storage. Wait for GPU completion before freeing it.
pub const DepthBuffer = struct {
    width: u16,
    height: u16,
    pixels: []align(64) u16,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !DepthBuffer {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        return .{
            .width = width,
            .height = height,
            .pixels = try allocator.alignedAlloc(u16, .@"64", @as(usize, width) * height),
        };
    }

    pub fn deinit(self: *DepthBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn view(self: DepthBuffer) Image {
        return .{ .width = self.width, .height = self.height, .texel_data = self.pixels };
    }
};

test "depth storage is aligned and views validate dimensions" {
    var depth = try DepthBuffer.init(std.testing.allocator, 4, 3);
    defer depth.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(depth.pixels.ptr) % 64);
    const image = depth.view();
    try std.testing.expectEqual(@as(usize, 12), image.texel_data.len);
    try std.testing.expect(!@hasDecl(Image, "deinit"));
    try std.testing.expectError(error.BufferTooSmall, Image.initBuffer(depth.pixels, 4, 4));
    try std.testing.expectError(error.InvalidDimensions, Image.initBuffer(depth.pixels, 0, 3));
    try std.testing.expectError(error.InvalidDimensions, DepthBuffer.init(std.testing.allocator, 4, 0));
    try std.testing.expectError(error.OutOfMemory, DepthBuffer.init(std.testing.failing_allocator, 4, 3));
}
