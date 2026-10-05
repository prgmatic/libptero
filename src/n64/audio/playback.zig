//! Buffer ownership across mixer, decoder and output failures. Kept independent
//! of MMIO so timeout retries can be tested without freeing live DMA storage.
const std = @import("std");
const Pool = @import("voice_pool.zig").Pool;

pub fn service(player: anytype, options: anytype) !u8 {
    if (!player.mixer_initialized) return error.PlayerStopped;
    player.output.service();
    player.mixer.stream_read_attempts = options.max_attempts;
    var count: u8 = 0;
    if (player.pending_commit) {
        try finishMix(player, options.max_attempts);
        count = 1;
    }
    while (count < options.max_buffers) : (count += 1) {
        const buffer = (try player.output.acquire()) orelse break;
        player.mixer.submit(buffer) catch |err| {
            player.output.cancel();
            return err;
        };
        player.pending_commit = true;
        try finishMix(player, options.max_attempts);
    }
    return count;
}

pub fn finishMix(player: anytype, attempts: u32) !void {
    try player.mixer.wait(attempts);
    try player.output.commit();
    player.pending_commit = false;
    for (0..player.pool.count) |index| {
        const width = player.pool.widths[index];
        if ((width == 1 or width == 2) and player.mixer.settings.channels[index].address == 0) player.pool.retire(index);
    }
}

const Fake = struct {
    mixer_initialized: bool = true,
    pending_commit: bool = false,
    pool: Pool = .{ .count = 3 },
    mixer: struct {
        stream_read_attempts: u32 = 0,
        submissions: usize = 0,
        fail_submit: bool = false,
        fail_wait: bool = false,
        settings: struct { channels: [3]struct { address: u32 = 0 } = @splat(.{}) } = .{},
        pub fn submit(self: *@This(), _: []i16) !void {
            if (self.fail_submit) return error.PiTimeout;
            self.submissions += 1;
        }
        pub fn wait(self: *@This(), _: u32) !void {
            if (self.fail_wait) return error.RspTimeout;
        }
    } = .{},
    output: struct {
        buffer: [8]i16 = undefined,
        acquired: bool = false,
        available: u8 = 4,
        commits: usize = 0,
        fail_commit: bool = false,
        pub fn service(_: *@This()) void {}
        pub fn acquire(self: *@This()) !?[]i16 {
            if (self.acquired) return error.BufferAlreadyAcquired;
            if (self.available == 0) return null;
            self.acquired = true;
            return &self.buffer;
        }
        pub fn cancel(self: *@This()) void {
            self.acquired = false;
        }
        pub fn commit(self: *@This()) !void {
            if (self.fail_commit) return error.OutputBusy;
            std.debug.assert(self.acquired);
            self.acquired = false;
            self.available -= 1;
            self.commits += 1;
        }
    } = .{},
};
const TestOptions = @import("player.zig").ServiceOptions;

test "timed-out mixes retain acquired buffers and stereo voices until retry commits" {
    var player: Fake = .{};
    const voice = try player.pool.claim(2);
    player.mixer.fail_wait = true;
    try std.testing.expectError(error.RspTimeout, service(&player, TestOptions{}));
    try std.testing.expect(player.pending_commit and player.output.acquired);
    _ = try player.pool.resolve(voice);
    player.mixer.fail_wait = false;
    try std.testing.expectEqual(@as(u8, 1), try service(&player, TestOptions{ .max_buffers = 0 }));
    try std.testing.expectEqual(@as(usize, 1), player.mixer.submissions);
    try std.testing.expect(!player.pending_commit and !player.output.acquired);
    try std.testing.expectError(error.InvalidVoice, player.pool.resolve(voice));
    try std.testing.expectEqual(@as(u8, 0), player.pool.widths[1]);
}

test "submit failure releases the buffer; commit failure retains it without remixing" {
    var player: Fake = .{};
    player.mixer.fail_submit = true;
    try std.testing.expectError(error.PiTimeout, service(&player, TestOptions{}));
    try std.testing.expect(!player.pending_commit and !player.output.acquired);
    player.mixer.fail_submit = false;
    player.output.fail_commit = true;
    try std.testing.expectError(error.OutputBusy, service(&player, TestOptions{}));
    try std.testing.expect(player.pending_commit and player.output.acquired);
    player.output.fail_commit = false;
    try std.testing.expectEqual(@as(u8, 1), try service(&player, TestOptions{ .max_buffers = 1 }));
    try std.testing.expectEqual(@as(usize, 1), player.mixer.submissions);
    try std.testing.expectEqual(@as(usize, 1), player.output.commits);
}

test "service respects budget and full output while preserving active voices" {
    var player: Fake = .{};
    const voice = try player.pool.claim(1);
    player.mixer.settings.channels[voice.index].address = 16;
    try std.testing.expectEqual(@as(u8, 2), try service(&player, TestOptions{ .max_buffers = 2, .max_attempts = 17 }));
    try std.testing.expectEqual(@as(u32, 17), player.mixer.stream_read_attempts);
    _ = try player.pool.resolve(voice);
    try std.testing.expectEqual(@as(u8, 2), try service(&player, TestOptions{}));
    try std.testing.expectEqual(@as(u8, 0), try service(&player, TestOptions{}));
    player.mixer_initialized = false;
    try std.testing.expectError(error.PlayerStopped, service(&player, TestOptions{}));
}
