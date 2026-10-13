//! Four-buffer stereo output with libdragon's DAC rounding and 25 Hz cadence.
const std = @import("std");
const ai = @import("../hw/ai.zig");
const vi = @import("../hw/vi.zig");
const mi = @import("../hw/mi.zig");
const cp0 = @import("../cpu/cp0.zig");
const interrupts = @import("../interrupt.zig");
const profiler = @import("../debug/profiler.zig");
const cache = @import("../cpu/cache.zig");

pub const Options = struct { frequency: u32 = 48000, buffer_count: u6 = 4, tv: vi.TvType = .ntsc };
pub const Timing = struct {
    frequency: u32,
    frames: u32,
    dac: u32,
    bit: u32,
    pub fn calculate(options: Options) !Timing {
        if (options.buffer_count < 2 or options.buffer_count > 32) return error.InvalidBufferCount;
        if (options.frequency < 3000 or options.frequency > 48000) return error.InvalidFrequency;
        const clock: u32 = switch (options.tv) {
            .ntsc => 48681818,
            .pal => 49656530,
            .m_pal => 48628322,
        };
        const divisor = ((2 * clock / options.frequency) + 1) / 2;
        const frequency = 2 * clock / ((2 * clock / options.frequency) + 1);
        return .{ .frequency = frequency, .frames = (frequency / 25) & ~@as(u32, 7), .dac = divisor - 1, .bit = @min(divisor / 66, 16) - 1 };
    }
};

/// Buffer ownership and AI FIFO accounting, kept independent of MMIO.
const Ring = struct {
    count: u6,
    full_mask: u32 = 0,
    playing: u6 = 0,
    emptied: u6 = 0,
    writing: u6 = 0,
    queued: u2 = 0,
    acquired: bool = false,
    draining: bool = false,
    underruns: u32 = 0,
    fn next(self: Ring, index: u6) u6 {
        return @intCast((@as(u32, index) + 1) % self.count);
    }
    fn retire(self: *Ring, status: u32) void {
        if (!self.draining and self.queued != 0 and status & ai.busy == 0) self.underruns +%= 1;
        if (self.queued > 1 and status & ai.full == 0) self.retireOne();
        if (self.queued > 0 and status & ai.busy == 0) self.retireOne();
    }
    fn retireOne(self: *Ring) void {
        self.queued -= 1;
        self.emptied = self.next(self.emptied);
        self.full_mask &= ~(@as(u32, 1) << @as(u5, @intCast(self.emptied)));
    }
    fn acquire(self: *Ring) !?u6 {
        if (self.acquired) return error.BufferAlreadyAcquired;
        const index = self.next(self.writing);
        if (self.full_mask & (@as(u32, 1) << @as(u5, @intCast(index))) != 0) return null;
        self.acquired = true;
        return index;
    }
    fn commit(self: *Ring) void {
        std.debug.assert(self.acquired);
        self.writing = self.next(self.writing);
        self.full_mask |= @as(u32, 1) << @as(u5, @intCast(self.writing));
        self.acquired = false;
    }
    fn enqueue(self: *Ring) ?u6 {
        if (self.queued == 2) return null;
        const index = self.next(self.playing);
        if (self.full_mask & (@as(u32, 1) << @as(u5, @intCast(index))) == 0) return null;
        self.playing = index;
        self.queued += 1;
        return index;
    }
};

var owner: ?*Output = null;
fn callback() void {
    if (owner) |output| output.serviceLocked();
}
fn lock() u32 {
    const status = cp0.regRead(.Status);
    cp0.regWrite(.Status, status & ~@as(u32, 1));
    return status;
}
fn unlock(status: u32) void {
    cp0.regWrite(.Status, status);
}

/// Owns AI and its backing storage. Keep at a stable address until deinit.
/// Acquire/commit borrows one stereo buffer; do not access it after commit.
/// Interrupts only enqueue completed buffers, never run the RSP mixer.
const Output = @This();

storage: []align(16) i16,
stride: usize,
timing: Timing,
ring: Ring,
submitted_buffers: u32 = 0,

/// Counts AI FIFO exhaustion after playback starts; intentional shutdown
/// drain is excluded. Poll/service regularly or enable AI interrupts.
pub fn underruns(self: *Output) u32 {
    const status = lock();
    defer unlock(status);
    return self.ring.underruns;
}

pub fn init(self: *Output, allocator: std.mem.Allocator, options: Options) !void {
    if (owner != null) return error.AudioAlreadyInitialized;
    const timing = try Timing.calculate(options);
    const stride = std.mem.alignForward(usize, timing.frames * 2 + 4, 8);
    const storage = try allocator.alignedAlloc(i16, .@"16", stride * options.buffer_count);
    @memset(storage, 0);
    cache.writebackData(storage);
    self.* = .{ .storage = storage, .stride = stride, .timing = timing, .ring = .{ .count = options.buffer_count } };
    const status = lock();
    defer unlock(status);
    ai.configure(timing.dac, timing.bit);
    ai.acknowledge();
    owner = self;
    interrupts.audio_handler = callback;
    mi.updateInterrupts(.{ .set_audio = true });
}

pub fn acquire(self: *Output) !?[]align(4) i16 {
    const status = lock();
    defer unlock(status);
    self.serviceLocked();
    const index = (try self.ring.acquire()) orelse return null;
    return self.buffer(index);
}

/// Complete RSP writes before commit. CPU-written PCM is written back too.
pub fn commit(self: *Output) !void {
    const status = lock();
    defer unlock(status);
    if (!self.ring.acquired) return error.NoBufferAcquired;
    cache.writebackData(self.buffer(self.ring.next(self.ring.writing)));
    self.ring.commit();
    self.serviceLocked();
}

pub fn cancel(self: *Output) void {
    self.ring.acquired = false;
}

pub fn service(self: *Output) void {
    const status = lock();
    defer unlock(status);
    self.serviceLocked();
}

fn serviceLocked(self: *Output) void {
    const previous_underruns = self.ring.underruns;
    const previous_queued = self.ring.queued;
    self.ring.retire(ai.readStatus());
    if (previous_queued != self.ring.queued) profiler.counter(.audio, "AI queued buffers", self.ring.queued);
    if (previous_underruns != self.ring.underruns) profiler.counter(.audio, "AI underruns", self.ring.underruns);
    while (self.ring.enqueue()) |index| {
        self.submitted_buffers +%= 1;
        ai.enqueue(@truncate(@intFromPtr(self.buffer(index).ptr) & 0x1fffffff), self.timing.frames * 4);
        profiler.instant(.audio, "AI enqueue", self.submitted_buffers);
        profiler.counter(.audio, "AI queued buffers", self.ring.queued);
    }
}

fn buffer(self: *Output, index: u6) []align(4) i16 {
    var first = @as(usize, index) * self.stride;
    // Avoid AI's delayed carry when a DMA ends exactly on an 8 KiB edge.
    if ((@intFromPtr(self.storage[first..].ptr) + self.timing.frames * 4) & 0x1fff == 0) first += 4;
    return @alignCast(self.storage[first..][0 .. self.timing.frames * 2]);
}

/// Waits for queued AI buffers. A timeout retains storage for retry.
pub fn deinit(self: *Output, allocator: std.mem.Allocator, max_attempts: u32) !void {
    if (self.ring.acquired) return error.BufferAlreadyAcquired;
    self.ring.draining = true;
    var remaining = max_attempts;
    while (self.ring.full_mask != 0) {
        self.service();
        if (remaining == 0) return error.AudioTimeout;
        remaining -= 1;
    }
    const status = lock();
    defer unlock(status);
    mi.updateInterrupts(.{ .clear_audio = true });
    interrupts.audio_handler = null;
    owner = null;
    ai.stop();
    allocator.free(self.storage);
    self.* = undefined;
}

test "DAC and buffer sizes match libdragon for all regions" {
    const ntsc = try Timing.calculate(.{});
    try std.testing.expectEqual(@as(u32, 47986), ntsc.frequency);
    try std.testing.expectEqual(@as(u32, 1912), ntsc.frames);
    try std.testing.expectEqual(@as(u32, 1013), ntsc.dac);
    for ([_]vi.TvType{ .ntsc, .pal, .m_pal }) |tv| {
        const timing = try Timing.calculate(.{ .frequency = 44100, .tv = tv });
        try std.testing.expect(timing.frames % 8 == 0);
        try std.testing.expect(timing.bit < 16);
    }
    try std.testing.expectError(error.InvalidFrequency, Timing.calculate(.{ .frequency = 0 }));
}

test "ring preserves AI-owned buffers through FIFO drain and restart" {
    var ring: Ring = .{ .count = 4 };
    for (0..4) |_| {
        _ = (try ring.acquire()).?;
        ring.commit();
    }
    try std.testing.expectEqual(@as(?u6, null), try ring.acquire());
    try std.testing.expectEqual(@as(?u6, 1), ring.enqueue());
    try std.testing.expectEqual(@as(?u6, 2), ring.enqueue());
    ring.retire(ai.busy | ai.full);
    try std.testing.expectEqual(@as(u32, 15), ring.full_mask);
    ring.retire(ai.busy);
    try std.testing.expectEqual(@as(?u6, 1), try ring.acquire());
    ring.acquired = false;
    try std.testing.expectEqual(@as(?u6, 3), ring.enqueue());
    ring.retire(0); // both hardware entries consumed while CPU was busy
    try std.testing.expectEqual(@as(u32, 1), ring.full_mask);
    try std.testing.expectEqual(@as(?u6, 0), ring.enqueue());
    ring.retire(0);
    try std.testing.expectEqual(@as(u32, 0), ring.full_mask);
}

test "FIFO exhaustion counts once and intentional draining is excluded" {
    var ring: Ring = .{ .count = 4 };
    _ = (try ring.acquire()).?;
    ring.commit();
    _ = ring.enqueue();
    ring.retire(ai.busy);
    try std.testing.expectEqual(@as(u32, 0), ring.underruns);
    ring.retire(0);
    ring.retire(0);
    try std.testing.expectEqual(@as(u32, 1), ring.underruns);
    _ = (try ring.acquire()).?;
    ring.commit();
    _ = ring.enqueue();
    ring.draining = true;
    ring.retire(0);
    try std.testing.expectEqual(@as(u32, 1), ring.underruns);
}
