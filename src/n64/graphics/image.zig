const std = @import("std");
const Rbga5551 = @import("color.zig").Rgba5551;
const Rgba32 = @import("color.zig").Rgba32;

pub fn Image(comptime PixelFormat: type) type {
    return struct{
        const Self = @This();

        width: u16,
        height: u16,
        pixel_data: []PixelFormat,

        pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Self {
            const w: u32 = width;
            const h: u32 = height;
            const buffer_len = w * h;
            return .{
                .width = width,
                .height = height,
                // TODO: Configurable alignment
                .pixel_data = try allocator.alignedAlloc(PixelFormat, std.mem.Alignment.@"32", buffer_len)
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) !void {
            allocator.free(self.pixel_data);
        }

        pub fn fill(self: *Self, color: PixelFormat) void {
            @memset(self.pixel_data, color);
        }
        pub fn fillRegion(self: *Self, color: PixelFormat, x: u32, y: u32, width: u32, height: u32) void {
            for(y..y+height) |yi| {
                for(x..x+width) |xi| {
                    const idx = yi * self.width + xi;
                    self.pixel_data[idx] = color;
                }
            }
        }
    };
}
