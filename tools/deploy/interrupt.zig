const std = @import("std");
var requested = std.atomic.Value(bool).init(false);
pub fn install() void {
    requested.store(false, .monotonic);
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}
fn handler(_: std.c.SIG) callconv(.c) void {
    requested.store(true, .monotonic);
}
pub fn check() !void {
    if (requested.load(.monotonic)) return error.Interrupted;
}
test "signal handler only records cancellation" {
    handler(std.posix.SIG.INT);
    try std.testing.expectError(error.Interrupted, check());
    requested.store(false, .monotonic);
    try check();
}
