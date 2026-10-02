//! Synchronous framebuffer ownership and presentation for the VI.
//! One swapchain may control the VI at a time. The swapchain and its frames are
//! single-threaded; do not change VI configuration or origin while it is active.
const std = @import("std");
const video = @import("interfaces/video.zig");
const cache = @import("cpu/cache.zig");
const image = @import("graphics/image.zig");
const color = @import("graphics/color.zig");
const Fence = @import("interrupt.zig").RdpFence;

pub const PresentMode = enum {
    /// Swap during a fresh vertical blank. Does not consume interrupt events.
    vsync,
    /// Swap as soon as rendering finishes. May tear. The next acquire waits for
    /// a fresh vertical blank before making the previous front buffer reusable.
    immediate,
};

pub const Options = struct {
    resolution: video.Resolution = .@"320x240p",
    buffer_count: usize = 2,
    tv: video.TvType = .ntsc,
    anti_alias_mode: video.AntiAliasMode = .Resample,
    gamma_enabled: bool = false,
    de_dither_enabled: bool = false,
    present_mode: PresentMode = .vsync,
    /// Register polling limit for acquire and deinit. This is not a duration.
    max_attempts: u32 = 100_000_000,
};

pub const PresentOptions = struct {
    /// Polling limit applied separately to RDP completion and vertical blank.
    max_attempts: u32 = 100_000_000,
};

/// A swapchain for Rgba16 or Rgba32 pixels. Allocation is explicit, including
/// teardown: init/deinit use the caller's allocator; initBuffer borrows storage.
///
/// Frame 0 starts as a black front buffer. At least two buffers are required.
/// One frame may be acquired at a time. Presentation is synchronous and does
/// not submit commands or wait for an RSP queue; retain resources used by that
/// queue until it completes. Complete outstanding rendering before deinit.
///
/// Progressive VI modes are supported. Interlaced modes require field-aware
/// scanout setup and are rejected rather than silently treated as progressive.
pub fn Swapchain(comptime Pixel: type) type {
    return SwapchainImpl(Pixel, Hardware);
}

fn SwapchainImpl(comptime Pixel: type, comptime Backend: type) type {
    if (Pixel != color.Rgba16 and Pixel != color.Rgba32)
        @compileError("display swapchains require Rgba16 or Rgba32 pixels");
    return struct {
        const Self = @This();
        pub const Image = image.Image(Pixel);
        pub const InitError = error{ InvalidBufferCount, UnsupportedResolution, BufferTooSmall, SizeOverflow };
        pub const FrameError = error{ FrameAlreadyAcquired, InvalidFrame };

        buffer: []align(64) Pixel,
        options: Options,
        owns_buffer: bool,
        front_index: usize = 0,
        next_index: usize = 1,
        acquired_index: ?usize = null,
        generation: usize = 0,
        needs_retirement: bool = false,

        /// A borrowed image and an acquisition token. Copies of the token are
        /// invalid after present/release. Do not modify the token's fields.
        /// The image must not be accessed while it is owned by VI scanout.
        pub const Frame = struct {
            image: Image,
            index: usize,
            generation: usize,
            buffer: [*]align(64) Pixel,
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) (InitError || std.mem.Allocator.Error)!Self {
            const count = try requiredPixelCount(options);
            const buffer = try allocator.alignedAlloc(Pixel, .@"64", count);
            errdefer allocator.free(buffer);
            var self = try initBuffer(buffer, options);
            self.owns_buffer = true;
            return self;
        }

        /// Required storage in pixels, not bytes. Every frame begins at a
        /// 64-byte boundary for the supported resolutions and pixel formats.
        pub fn requiredPixelCount(options: Options) InitError!usize {
            if (options.buffer_count < 2) return error.InvalidBufferCount;
            if (options.resolution.isInterlaced()) return error.UnsupportedResolution;
            const dimensions = options.resolution.dimensions();
            return std.math.mul(usize, @as(usize, dimensions.width) * dimensions.height, options.buffer_count) catch error.SizeOverflow;
        }

        /// Initialize caller-owned, 64-byte-aligned storage. No allocation.
        /// Clears the used portion to black, writes it back, and configures VI.
        /// Storage must remain valid until deinit succeeds. Excess pixels are
        /// untouched. Use any allocator for deinit of a borrowed swapchain.
        pub fn initBuffer(buffer: []align(64) Pixel, options: Options) InitError!Self {
            const count = try requiredPixelCount(options);
            if (buffer.len < count) return error.BufferTooSmall;
            const self: Self = .{ .buffer = buffer[0..count], .options = options, .owns_buffer = false };
            @memset(self.buffer, Pixel.black);
            Backend.writeback(self.buffer);
            Backend.start(Pixel, options, self.getImage(0));
            return self;
        }

        /// Blank VI and wait for a fresh retrace before releasing owned memory.
        /// On timeout storage remains owned and deinit may be retried. Borrowed
        /// storage is never freed. Do not call with outstanding GPU work.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) error{VBlankTimeout}!void {
            try Backend.stop(self.options.max_attempts);
            if (self.owns_buffer) allocator.free(self.buffer);
            self.* = undefined;
        }

        /// Obtain a writable buffer distinct from the current front buffer.
        /// Usually does not wait; after immediate presentation it first waits
        /// for scanout retirement. Invalidates CPU cache lines so CPU reads see
        /// the last rendered contents. No allocation or command submission.
        pub fn acquire(self: *Self) (FrameError || error{VBlankTimeout})!Frame {
            if (self.acquired_index != null) return error.FrameAlreadyAcquired;
            if (self.needs_retirement) {
                try Backend.retire(self.options.max_attempts);
                self.needs_retirement = false;
            }
            var index = self.next_index;
            if (index == self.front_index) index = (index + 1) % self.options.buffer_count;
            const target = self.getImage(index);
            Backend.invalidate(target.texel_data);
            self.acquired_index = index;
            self.generation +%= 1;
            self.next_index = (index + 1) % self.options.buffer_count;
            return .{ .image = target, .index = index, .generation = self.generation, .buffer = self.buffer.ptr };
        }

        /// Return an unpresented frame. The caller must first complete any work
        /// using it. A later acquire may discard CPU changes to this buffer.
        pub fn release(self: *Self, frame: Frame) FrameError!void {
            try self.validateFrame(frame);
            self.acquired_index = null;
        }

        /// Wait for the supplied RDP fence, then present the acquired buffer.
        /// Does not write back CPU cache lines over RDP output. CPU writes used
        /// by the RDP must have been written back before command submission.
        /// On timeout the frame remains acquired for retry or release after
        /// completing outstanding rendering. Only one RDP fence may be pending.
        pub fn present(self: *Self, frame: Frame, completion: Fence, options: PresentOptions) (FrameError || error{ RdpFenceTimeout, VBlankTimeout })!void {
            try self.validateFrame(frame);
            if (!Backend.waitFence(completion, options.max_attempts)) return error.RdpFenceTimeout;
            try self.show(frame.index, options);
        }

        /// Present CPU-rendered pixels after writing back their cache lines.
        /// Do not use this for an image with uncompleted RSP/RDP writes.
        pub fn presentCpu(self: *Self, frame: Frame, options: PresentOptions) (FrameError || error{VBlankTimeout})!void {
            try self.validateFrame(frame);
            Backend.writeback(self.getImage(frame.index).texel_data);
            try self.show(frame.index, options);
        }

        fn getImage(self: *const Self, index: usize) Image {
            const dimensions = self.options.resolution.dimensions();
            const count = @as(usize, dimensions.width) * dimensions.height;
            return .{ .width = dimensions.width, .height = dimensions.height, .texel_data = self.buffer[index * count ..][0..count] };
        }

        fn validateFrame(self: *const Self, frame: Frame) FrameError!void {
            if (frame.buffer != self.buffer.ptr or frame.generation != self.generation or self.acquired_index != frame.index)
                return error.InvalidFrame;
        }

        fn show(self: *Self, index: usize, options: PresentOptions) error{VBlankTimeout}!void {
            try Backend.swap(self.getImage(index), self.options.present_mode, options.max_attempts);
            self.front_index = index;
            self.acquired_index = null;
            self.needs_retirement = self.options.present_mode == .immediate;
        }
    };
}

const Hardware = struct {
    fn start(comptime Pixel: type, options: Options, first: anytype) void {
        video.blank();
        video.setFrameBuffer(address(first));
        video.init(.{
            .resolution = options.resolution,
            .tv = options.tv,
            .color_depth = if (Pixel == color.Rgba16) .Rgba5551 else .Rgba32,
            .anti_alias_mode = options.anti_alias_mode,
            .gamma_enabled = options.gamma_enabled,
            .de_dither_enabled = options.de_dither_enabled,
        });
    }

    fn address(frame: anytype) u32 {
        return @as(u32, @intCast(@intFromPtr(frame.texel_data.ptr))) & 0x1fff_ffff;
    }

    fn stop(max_attempts: u32) error{VBlankTimeout}!void {
        video.blank();
        try video.waitVBlank(max_attempts);
    }

    fn retire(max_attempts: u32) error{VBlankTimeout}!void {
        try video.waitVBlank(max_attempts);
    }

    fn waitFence(fence: Fence, max_attempts: u32) bool {
        return fence.waitTimeout(max_attempts);
    }

    fn swap(frame: anytype, mode: PresentMode, max_attempts: u32) error{VBlankTimeout}!void {
        switch (mode) {
            .vsync => try video.setFrameBufferAtVBlank(address(frame), max_attempts),
            .immediate => video.setFrameBuffer(address(frame)),
        }
    }

    fn invalidate(pixels: anytype) void {
        cache.invalidateData(pixels);
    }

    fn writeback(pixels: anytype) void {
        cache.writebackData(pixels);
    }
};

test {
    _ = @import("display_tests.zig");
}

// Test the public operations with a deterministic VI/RDP implementation.
pub const testing = if (@import("builtin").is_test) struct {
    pub const withBackend = SwapchainImpl;
} else struct {};
