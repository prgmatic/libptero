const std = @import("std");
const Monitor = @import("monitor.zig").Monitor;
const protocol = @import("run_protocol");
pub const Relay = struct {
    io: std.Io,
    monitor: Monitor,
    output: ?*std.Io.Writer = null,
    pub fn init(io: std.Io, options: @import("options.zig").Options) Relay {
        return .{ .io = io, .monitor = Monitor.init(options, now(io)) };
    }
    pub fn feed(self: *Relay, bytes: []const u8) !?u8 {
        const text = std.mem.trimEnd(u8, bytes, "\x00");
        try self.write(text);
        const result = try self.monitor.feed(text, now(self.io));
        return code(result);
    }
    fn write(self: *Relay, text: []const u8) !void {
        if (self.output) |writer| return writer.writeAll(text);
        try std.Io.File.stdout().writeStreamingAll(self.io, text);
    }
    pub fn check(self: *Relay) !void {
        try @import("interrupt.zig").check();
        try self.monitor.check(now(self.io));
    }
};
fn code(result: ?protocol.Completion) ?u8 {
    const completed = result orelse return null;
    return completed.code;
}
pub fn now(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}
test "relay preserves completion exit status" {
    try std.testing.expectEqual(null, code(null));
    try std.testing.expectEqual(@as(?u8, 1), code(.{ .code = 1 }));
}
