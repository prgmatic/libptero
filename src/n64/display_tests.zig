const std = @import("std");
const display = @import("display.zig");
const color = @import("graphics/color.zig");
const Fence = @import("interrupt.zig").RdpFence;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const Swapchain = display.testing.withBackend(color.Rgba16, Backend);

const Backend = struct {
    var front: usize = 0;
    var fence_ready = true;
    var vblank_ready = true;
    var writebacks: usize = 0;
    var invalidations: usize = 0;
    var retirements: usize = 0;
    var swaps: usize = 0;

    pub fn start(comptime _: type, _: display.Options, first: anytype) void {
        front = @intFromPtr(first.texel_data.ptr);
        fence_ready = true;
        vblank_ready = true;
        writebacks = 0;
        invalidations = 0;
        retirements = 0;
        swaps = 0;
    }
    pub fn stop(_: u32) error{VBlankTimeout}!void {
        if (!vblank_ready) return error.VBlankTimeout;
        front = 0;
    }
    pub fn retire(_: u32) error{VBlankTimeout}!void {
        if (!vblank_ready) return error.VBlankTimeout;
        retirements += 1;
    }
    pub fn waitFence(_: Fence, _: u32) bool {
        return fence_ready;
    }
    pub fn swap(frame: anytype, mode: display.PresentMode, _: u32) error{VBlankTimeout}!void {
        if (mode == .vsync and !vblank_ready) return error.VBlankTimeout;
        front = @intFromPtr(frame.texel_data.ptr);
        swaps += 1;
    }
    pub fn writeback(_: anytype) void {
        writebacks += 1;
    }
    pub fn invalidate(_: anytype) void {
        invalidations += 1;
    }
};

test "acquire and present protect scanout across double and triple buffering" {
    for ([_]usize{ 2, 3 }) |count| {
        var chain = try Swapchain.init(std.testing.allocator, .{ .buffer_count = count });
        defer chain.deinit(std.testing.allocator) catch unreachable;
        for (0..12) |_| {
            const old_front = Backend.front;
            const frame = try chain.acquire();
            try expect(@intFromPtr(frame.image.texel_data.ptr) != old_front);
            try expectEqual(@as(u16, 320), frame.image.width);
            try expectEqual(@as(u16, 240), frame.image.height);
            try expectEqual(@as(usize, 0), @intFromPtr(frame.image.texel_data.ptr) % 64);
            try expectError(error.FrameAlreadyAcquired, chain.acquire());
            try chain.present(frame, .{ .target = 1 }, .{});
            try expectEqual(@intFromPtr(frame.image.texel_data.ptr), Backend.front);
            try expectError(error.InvalidFrame, chain.release(frame));
        }
        // GPU presentation never writes dirty CPU data over rendered pixels.
        try expectEqual(@as(usize, 0), Backend.writebacks);
        try expectEqual(@as(usize, 12), Backend.invalidations);
    }
}

test "timeouts preserve frame ownership and allow retry" {
    var chain = try Swapchain.init(std.testing.allocator, .{});
    defer chain.deinit(std.testing.allocator) catch unreachable;
    const frame = try chain.acquire();
    const old_front = Backend.front;
    Backend.fence_ready = false;
    try expectError(error.RdpFenceTimeout, chain.present(frame, .{ .target = 1 }, .{}));
    Backend.fence_ready = true;
    Backend.vblank_ready = false;
    try expectError(error.VBlankTimeout, chain.present(frame, .{ .target = 1 }, .{}));
    try expectEqual(old_front, Backend.front);
    try expectEqual(@as(usize, 0), Backend.swaps);
    try expectError(error.FrameAlreadyAcquired, chain.acquire());
    Backend.vblank_ready = true;
    try chain.present(frame, .{ .target = 1 }, .{});
}

test "immediate presentation does not recycle the previous scanout until retrace" {
    var chain = try Swapchain.init(std.testing.allocator, .{ .present_mode = .immediate });
    defer chain.deinit(std.testing.allocator) catch unreachable;
    const old_front = Backend.front;
    const frame = try chain.acquire();
    Backend.vblank_ready = false;
    try chain.present(frame, .{ .target = 1 }, .{});
    try expectError(error.VBlankTimeout, chain.acquire());
    try expectEqual(@as(usize, 0), Backend.retirements);
    Backend.vblank_ready = true;
    const recycled = try chain.acquire();
    try expectEqual(old_front, @intFromPtr(recycled.image.texel_data.ptr));
    try expectEqual(@as(usize, 1), Backend.retirements);
    try chain.release(recycled);
}

test "released and foreign acquisition tokens are rejected" {
    var chain = try Swapchain.init(std.testing.allocator, .{});
    defer chain.deinit(std.testing.allocator) catch unreachable;
    const frame = try chain.acquire();
    try chain.release(frame);
    const next = try chain.acquire();
    try expectError(error.InvalidFrame, chain.presentCpu(frame, .{}));
    var foreign = next;
    var other_buffer: [64]color.Rgba16 align(64) = undefined;
    foreign.buffer = &other_buffer;
    try expectError(error.InvalidFrame, chain.release(foreign));
    try chain.presentCpu(next, .{});
    try expectEqual(@as(usize, 1), Backend.writebacks);
}

test "borrowed storage is cleared only within the required portion and is never freed" {
    const count = try Swapchain.requiredPixelCount(.{});
    const pixels = try std.testing.allocator.alignedAlloc(color.Rgba16, .@"64", count + 32);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, color.Rgba16.red);
    var chain = try Swapchain.initBuffer(pixels, .{});
    for (pixels[0..count]) |pixel| try expectEqual(color.Rgba16.black, pixel);
    for (pixels[count..]) |pixel| try expectEqual(color.Rgba16.red, pixel);
    try chain.deinit(std.testing.failing_allocator);
}

test "invalid options and insufficient storage do not configure VI" {
    try expectError(error.InvalidBufferCount, Swapchain.requiredPixelCount(.{ .buffer_count = 1 }));
    try expectError(error.UnsupportedResolution, Swapchain.requiredPixelCount(.{ .resolution = .@"640x480i" }));
    try expectError(error.SizeOverflow, Swapchain.requiredPixelCount(.{ .buffer_count = std.math.maxInt(usize) }));
    var short: [64]color.Rgba16 align(64) = undefined;
    Backend.front = 123;
    try expectError(error.BufferTooSmall, Swapchain.initBuffer(&short, .{}));
    try expectEqual(@as(usize, 123), Backend.front);
    try expectError(error.OutOfMemory, Swapchain.init(std.testing.failing_allocator, .{}));
}

test "deinit timeout retains the allocation for retry" {
    var chain = try Swapchain.init(std.testing.allocator, .{});
    const storage = chain.buffer.ptr;
    Backend.vblank_ready = false;
    try expectError(error.VBlankTimeout, chain.deinit(std.testing.allocator));
    try expectEqual(storage, chain.buffer.ptr);
    Backend.vblank_ready = true;
    try chain.deinit(std.testing.allocator);
}

test "all progressive resolutions support both scanout pixel sizes" {
    inline for (.{ color.Rgba16, color.Rgba32 }) |Pixel| {
        const Chain = display.testing.withBackend(Pixel, Backend);
        inline for (.{ .@"256x240p", .@"320x240p", .@"512x240p", .@"640x240p" }) |resolution| {
            var chain = try Chain.init(std.testing.allocator, .{ .resolution = resolution });
            defer chain.deinit(std.testing.allocator) catch unreachable;
            const frame = try chain.acquire();
            const dimensions = chain.options.resolution.dimensions();
            try expectEqual(dimensions.width, frame.image.width);
            try expectEqual(dimensions.height, frame.image.height);
            try expectEqual(@as(usize, 0), @intFromPtr(frame.image.texel_data.ptr) % 64);
            try chain.presentCpu(frame, .{});
        }
    }
}
