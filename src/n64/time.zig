//! Count-register intervals. The 32-bit counter wraps about every 91.6 seconds;
//! read/lap at least once per wrap. No interrupts or global clock state required.
const std = @import("std");
const cp0 = @import("cpu/cp0.zig");

pub const ticks_per_second: u32 = 46_875_000;

pub const Duration = struct {
    ticks: u32,

    pub fn seconds(self: Duration) f32 {
        return @as(f32, @floatFromInt(self.ticks)) / ticks_per_second;
    }
    pub fn milliseconds(self: Duration) f32 {
        return self.seconds() * 1000;
    }
    pub fn nanoseconds(self: Duration) u64 {
        return @as(u64, self.ticks) * std.time.ns_per_s / ticks_per_second;
    }
};

pub const Instant = struct {
    ticks: u32,

    pub fn now() Instant {
        return .{ .ticks = cp0.regRead(.Count) };
    }
    pub fn since(self: Instant, earlier: Instant) Duration {
        return .{ .ticks = self.ticks -% earlier.ticks };
    }
};

pub const Timer = struct {
    started: Instant,

    pub fn start() Timer {
        return .{ .started = .now() };
    }
    pub fn read(self: Timer) Duration {
        return Instant.now().since(self.started);
    }
    pub fn reset(self: *Timer) void {
        self.started = .now();
    }
    pub fn lap(self: *Timer) Duration {
        return self.lapAt(.now());
    }
    fn lapAt(self: *Timer, now: Instant) Duration {
        const elapsed = now.since(self.started);
        self.started = now;
        return elapsed;
    }
};

const FpsOptions = struct {
    initial_fps: f32 = 60,
    smoothing: f32 = 0.01,
    /// Quantize vsync frame times into refresh intervals. Omit for immediate
    /// presentation, whose frame times can fall between refresh intervals.
    refresh_rate: ?f32 = null,
};

/// An exponentially filtered frame duration, separate from the hardware timer.
pub const FpsCounter = struct {
    pub const Options = FpsOptions;
    options: FpsOptions,
    filtered_seconds: f32,

    pub fn init(options: FpsOptions) FpsCounter {
        std.debug.assert(options.initial_fps > 0);
        std.debug.assert(options.smoothing > 0 and options.smoothing <= 1);
        if (options.refresh_rate) |rate| std.debug.assert(rate > 0);
        return .{ .options = options, .filtered_seconds = 1 / options.initial_fps };
    }
    pub fn update(self: *FpsCounter, elapsed: Duration) f32 {
        var seconds = @max(elapsed.seconds(), @as(f32, 1) / ticks_per_second);
        if (self.options.refresh_rate) |rate| seconds = @max(1, @round(seconds * rate)) / rate;
        self.filtered_seconds += (seconds - self.filtered_seconds) * self.options.smoothing;
        return self.fps();
    }
    pub fn fps(self: FpsCounter) f32 {
        return 1 / self.filtered_seconds;
    }
};

test "intervals and timer laps survive Count wraparound" {
    var timer: Timer = .{ .started = .{ .ticks = 0xfffffff0 } };
    try std.testing.expectEqual(@as(u32, 32), timer.lapAt(.{ .ticks = 16 }).ticks);
    try std.testing.expectEqual(@as(u32, 84), timer.lapAt(.{ .ticks = 100 }).ticks);
    const second: Duration = .{ .ticks = ticks_per_second };
    try std.testing.expectEqual(@as(f32, 1), second.seconds());
    try std.testing.expectEqual(@as(f32, 1000), second.milliseconds());
    try std.testing.expectEqual(@as(u64, 1_000_000_000), second.nanoseconds());
    try std.testing.expectEqual(@as(u64, 21), (Duration{ .ticks = 1 }).nanoseconds());
}

test "FPS supports continuous and refresh-quantized frame durations" {
    const elapsed: Duration = .{ .ticks = ticks_per_second / 40 };
    var immediate = FpsCounter.init(.{ .smoothing = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 40), immediate.update(elapsed), 0.001);
    var vsync = FpsCounter.init(.{ .refresh_rate = 60, .smoothing = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 30), vsync.update(elapsed), 0.001);
    var filtered = FpsCounter.init(.{ .smoothing = 0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 48), filtered.update(elapsed), 0.001);
    try std.testing.expect(std.math.isFinite(immediate.update(.{ .ticks = 0 })));
}
