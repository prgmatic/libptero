const std = @import("std");
const protocol = @import("run_protocol");
const options = @import("options.zig");
pub const Monitor = struct {
    parser: protocol.Parser = .{},
    mode: options.Mode,
    deadline: ?i64,
    test_timeout_ms: u32,

    pub fn init(o: options.Options, now: i64) Monitor {
        const timeout: ?u32 = switch (o.mode) {
            .interactive => null,
            .wait => o.timeout_ms,
            .tests => o.startupTimeout(),
        };
        return .{ .mode = o.mode, .deadline = if (timeout) |t| now + t else null, .test_timeout_ms = o.testTimeout() };
    }
    pub fn feed(self: *Monitor, bytes: []const u8, now: i64) !?protocol.Completion {
        const before = self.parser.test_starts;
        const result = try self.parser.feed(bytes);
        if (self.mode == .tests and self.parser.test_starts != before) self.deadline = now + self.test_timeout_ms;
        return result;
    }
    pub fn check(self: Monitor, now: i64) !void {
        if (self.deadline) |deadline| {
            if (now >= deadline) return error.RunTimeout;
        }
    }
    pub fn eof(self: Monitor) !u8 {
        if (self.mode != .interactive) return error.MissingCompletion;
        return 0;
    }
};

test "test deadlines begin at boot and refresh only on new test starts" {
    var monitor = Monitor.init(.{ .mode = .tests }, 0);
    try monitor.check(999);
    try std.testing.expectError(error.RunTimeout, monitor.check(1000));
    _ = try monitor.feed("[Run] first", 300);
    try monitor.check(499);
    try std.testing.expectError(error.RunTimeout, monitor.check(500));
    _ = try monitor.feed("diagnostic", 450);
    try std.testing.expectError(error.RunTimeout, monitor.check(500));
    try std.testing.expectError(error.MissingCompletion, monitor.eof());
    const wait = Monitor.init(.{ .mode = .wait, .timeout_ms = 20 }, 0);
    try std.testing.expectError(error.RunTimeout, wait.check(20));
    const interactive = Monitor.init(.{}, 0);
    try interactive.check(999999);
    try std.testing.expectEqual(@as(u8, 0), try interactive.eof());
}
