const std = @import("std");
const Rbga5551 = @import("color.zig").Rgba5551;
const Rgba32 = @import("color.zig").Rgba32;

pub fn Image(comptime PixelFormat: type) type {
    return struct{
        const Self = @This();

        width: u32,
        height: u32,
        pixel_data: []PixelFormat,

        pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Self {
            return .{
                .width = width,
                .height = height,
                .pixel_data = try allocator.alignedAlloc(PixelFormat, std.mem.Alignment.@"8", width * height)
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) !void {
            allocator.free(self.pixel_data);
        }

        pub fn fill(self: *Self, color: PixelFormat) void {
            @memset(self.pixel_data, color);
        }
    };
}
