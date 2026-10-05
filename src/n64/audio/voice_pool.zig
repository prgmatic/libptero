const std = @import("std");

pub const Voice = struct { owner: *const Pool, index: u8, generation: u32 };

/// Fixed slots with explicit exhaustion. Stereo reservations are indivisible.
pub const Pool = struct {
    count: u8,
    widths: [32]u8 = @splat(0), // 0 free, 1/2 primary, 255 stereo secondary
    generations: [32]u32 = @splat(0),

    pub fn claim(self: *Pool, channels: u8) !Voice {
        if (channels != 1 and channels != 2) return error.InvalidChannels;
        for (0..self.count) |index| {
            if (!self.fits(index, channels)) continue;
            self.widths[index] = channels;
            if (channels == 2) self.widths[index + 1] = 255;
            self.generations[index] +%= 1;
            if (self.generations[index] == 0) self.generations[index] = 1;
            return .{ .owner = self, .index = @intCast(index), .generation = self.generations[index] };
        }
        return error.VoiceLimit;
    }
    fn fits(self: *const Pool, index: usize, channels: u8) bool {
        if (self.widths[index] != 0) return false;
        if (channels == 1) return true;
        return index + 1 < self.count and self.widths[index + 1] == 0;
    }
    pub fn resolve(self: *const Pool, voice: Voice) !usize {
        if (voice.owner != self or voice.index >= self.count) return error.InvalidVoice;
        const width = self.widths[voice.index];
        if (width == 0 or width == 255 or voice.generation != self.generations[voice.index]) return error.InvalidVoice;
        return voice.index;
    }
    pub fn retire(self: *Pool, index: usize) void {
        std.debug.assert(self.widths[index] == 1 or self.widths[index] == 2);
        if (self.widths[index] == 2) self.widths[index + 1] = 0;
        self.widths[index] = 0;
    }
};

test "stereo voices reserve two slots and retired handles never control replacements" {
    var pool: Pool = .{ .count = 3 };
    const music = try pool.claim(2);
    const effect = try pool.claim(1);
    try std.testing.expectEqual(@as(u8, 2), effect.index);
    try std.testing.expectError(error.VoiceLimit, pool.claim(1));
    pool.retire(try pool.resolve(music));
    const replacement = try pool.claim(2);
    try std.testing.expectError(error.InvalidVoice, pool.resolve(music));
    try std.testing.expectEqual(@as(usize, 0), try pool.resolve(replacement));
    var other: Pool = .{ .count = 3 };
    try std.testing.expectError(error.InvalidVoice, other.resolve(replacement));
    try std.testing.expectError(error.InvalidChannels, pool.claim(0));
    try std.testing.expectError(error.InvalidVoice, pool.resolve(.{ .owner = &pool, .index = 31, .generation = 0 }));
}

test "fragmentation never lets a stereo voice overwrite a neighbor" {
    var pool: Pool = .{ .count = 3 };
    const a = try pool.claim(1);
    _ = try pool.claim(1);
    _ = try pool.claim(1);
    pool.retire(try pool.resolve(a));
    try std.testing.expectError(error.VoiceLimit, pool.claim(2));
}
