//! Synchronous framebuffer ownership and presentation for the VI.
//! One swapchain may control the VI at a time. The swapchain and its frames are
//! single-threaded; do not change VI configuration or origin while it is active.
const std = @import("std");
const video = @import("../hw/vi.zig");
const cache = @import("../cpu/cache.zig");
const image = @import("../graphics/image.zig");
const color = @import("../graphics/pixel.zig");
const rdp = @import("../rdp.zig");
const Fence = rdp.Fence;
const Completion = rdp.Completion;

const PresentationMode = enum {
    /// Swap during a fresh vertical blank. Does not consume interrupt events.
    vsync,
    /// Swap as soon as rendering finishes. May tear. Acquire waits for retrace
    /// only when the next buffer is still awaiting scanout retirement.
    immediate,
};

const InitOptions = struct {
    resolution: video.Resolution = .@"320x240p",
    buffer_count: usize = 2,
    tv: video.TvType = .ntsc,
    anti_alias_mode: video.AntiAliasMode = .Resample,
    divot_enabled: bool = false,
    gamma_enabled: bool = false,
    de_dither_enabled: bool = false,
    present_mode: PresentationMode = .vsync,
    /// GPU-only frames must not be read or written through cached CPU aliases.
    /// Skips acquisition's cache invalidation when every frame is GPU-rendered.
    framebuffer_access: enum { cpu_and_gpu, gpu_only } = .cpu_and_gpu,
    /// Register polling limit for acquire and deinit. This is not a duration.
    max_attempts: u32 = 100_000_000,
};

const PresentationOptions = struct {
    /// Polling limit applied separately to render completion and vertical blank.
    max_attempts: u32 = 100_000_000,
};

/// A swapchain for Rgba16 or Rgba32 pixels. Allocation is explicit, including
/// teardown: init/deinit use the caller's allocator; initBuffer borrows storage.
///
/// Frame 0 starts as a black front buffer. At least two buffers are required.
/// One frame may be acquired at a time. Presentation is synchronous and does
/// not submit commands; it waits for the supplied render completion. Complete outstanding rendering before deinit.
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
        pub const Options = InitOptions;
        pub const PresentOptions = PresentationOptions;
        pub const PresentMode = PresentationMode;
        pub const Image = image.Image(Pixel);
        pub const InitError = error{ InvalidBufferCount, UnsupportedResolution, BufferTooSmall, SizeOverflow };
        pub const FrameError = error{ FrameAlreadyAcquired, InvalidFrame };

        buffer: []align(64) Pixel,
        options: InitOptions,
        owns_buffer: bool,
        front_index: usize = 0,
        next_index: usize = 1,
        acquired_index: ?usize = null,
        generation: usize = 0,
        retired_index: ?usize = null,
        retirement_epoch: u32 = 0,

        /// A borrowed image and an acquisition token. Copies of the token are
        /// invalid after present/release. Do not modify the token's fields.
        /// The image must not be accessed while it is owned by VI scanout.
        pub const Frame = struct {
            image: Image,
            index: usize,
            generation: usize,
            buffer: [*]align(64) Pixel,
        };

        pub fn init(allocator: std.mem.Allocator, options: InitOptions) (InitError || std.mem.Allocator.Error)!Self {
            const count = try requiredPixelCount(options);
            const buffer = try allocator.alignedAlloc(Pixel, .@"64", count);
            errdefer allocator.free(buffer);
            var self = try initBuffer(buffer, options);
            self.owns_buffer = true;
            return self;
        }

        /// Required storage in pixels, not bytes. Every frame begins at a
        /// 64-byte boundary for the supported resolutions and pixel formats.
        pub fn requiredPixelCount(options: InitOptions) InitError!usize {
            if (options.buffer_count < 2) return error.InvalidBufferCount;
            if (options.resolution.isInterlaced()) return error.UnsupportedResolution;
            const dimensions = options.resolution.dimensions();
            return std.math.mul(usize, @as(usize, dimensions.width) * dimensions.height, options.buffer_count) catch error.SizeOverflow;
        }

        /// Initialize caller-owned, 64-byte-aligned storage. No allocation.
        /// Clears the used portion to black, writes it back, and configures VI.
        /// Storage must remain valid until deinit succeeds. Excess pixels are
        /// untouched. Use any allocator for deinit of a borrowed swapchain.
        pub fn initBuffer(buffer: []align(64) Pixel, options: InitOptions) InitError!Self {
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
        /// Usually does not wait; immediate presentation waits only when the
        /// next buffer still needs scanout retirement. With CPU access enabled,
        /// invalidates cache lines so reads see the last rendered contents.
        /// No allocation or command submission.
        pub fn acquire(self: *Self) (FrameError || error{VBlankTimeout})!Frame {
            if (self.acquired_index != null) return error.FrameAlreadyAcquired;
            self.refreshRetirement();
            var index = self.next_index;
            if (index == self.front_index) index = (index + 1) % self.options.buffer_count;
            if (self.retired_index == index) {
                try Backend.retire(self.retirement_epoch, self.options.max_attempts);
                self.retired_index = null;
            }
            const target = self.getImage(index);
            if (self.options.framebuffer_access == .cpu_and_gpu) Backend.invalidate(target.texel_data);
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

        /// Wait for the supplied RSP/RDP completion, then present the buffer.
        /// Does not write back CPU cache lines over RDP output. CPU writes used
        /// by the RDP must have been written back before command submission.
        /// On timeout the frame remains acquired for retry or release after
        /// completing outstanding rendering. Only one RDP fence may be pending.
        pub fn present(self: *Self, frame: Frame, completion: Completion, options: PresentationOptions) (FrameError || error{ RspTimeout, RdpFenceTimeout, VBlankTimeout })!void {
            try self.validateFrame(frame);
            try Backend.waitCompletion(completion, options.max_attempts);
            try self.show(frame.index, options);
        }

        /// Present a raw RDP fence. The caller must separately finish any RSP
        /// work using borrowed resources; prefer present with submit's result.
        pub fn presentFence(self: *Self, frame: Frame, fence: Fence, options: PresentationOptions) (FrameError || error{ RspTimeout, RdpFenceTimeout, VBlankTimeout })!void {
            try self.present(frame, .{ .rdp = fence }, options);
        }

        /// Present CPU-rendered pixels after writing back their cache lines.
        /// Do not use this for an image with uncompleted RSP/RDP writes.
        pub fn presentCpu(self: *Self, frame: Frame, options: PresentationOptions) (FrameError || error{VBlankTimeout})!void {
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

        fn show(self: *Self, index: usize, options: PresentationOptions) error{VBlankTimeout}!void {
            try Backend.swap(self.getImage(index), self.options.present_mode, options.max_attempts);
            if (self.options.present_mode == .immediate) {
                self.refreshRetirement();
                if (self.retired_index == null) self.retired_index = self.front_index;
                self.retirement_epoch = Backend.videoFrame();
            } else self.retired_index = null;
            self.front_index = index;
            self.acquired_index = null;
        }

        fn refreshRetirement(self: *Self) void {
            // All origins in this cohort were changed during the same retrace
            // epoch. In ring order, the oldest retired buffer is encountered
            // before any later one, including when an acquisition is released.
            if (self.retired_index != null and Backend.videoFrame() != self.retirement_epoch)
                self.retired_index = null;
        }
    };
}

const Hardware = struct {
    fn start(comptime Pixel: type, options: InitOptions, first: anytype) void {
        video.blank();
        video.setFrameBuffer(address(first));
        video.init(.{
            .resolution = options.resolution,
            .tv = options.tv,
            .color_depth = if (Pixel == color.Rgba16) .Rgba5551 else .Rgba32,
            .anti_alias_mode = options.anti_alias_mode,
            .divot_enabled = options.divot_enabled,
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

    fn videoFrame() u32 {
        return @import("../interrupt.zig").videoFrame();
    }

    fn retire(epoch: u32, max_attempts: u32) error{VBlankTimeout}!void {
        var remaining = max_attempts;
        while (videoFrame() == epoch) {
            if (remaining == 0) return error.VBlankTimeout;
            remaining -= 1;
        }
    }

    fn waitCompletion(completion: Completion, max_attempts: u32) error{ RspTimeout, RdpFenceTimeout }!void {
        try completion.wait(.{ .max_attempts = max_attempts });
    }

    fn swap(frame: anytype, mode: PresentationMode, max_attempts: u32) error{VBlankTimeout}!void {
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
    _ = @import("tests.zig");
}

// Test the public operations with a deterministic VI/RDP implementation.
pub const testing = if (@import("builtin").is_test) struct {
    pub const withBackend = SwapchainImpl;
} else struct {};
