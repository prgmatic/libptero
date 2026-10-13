const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

pub const tests = [_]runner.Test{
    .{ .name = "Input API: fixed-storage controller polling", .run = controllerPolling },
    .{ .name = "Time API: hardware intervals and timer laps", .run = timerLaps },
};

fn controllerPolling() !void {
    var controllers = n64.input.Controllers.init();
    controllers.poll();
    const snapshot = controllers.get(.one);
    controllers.poll();
    const later = controllers.get(.one);
    try testing.expectEqual(@as(u32, @bitCast(snapshot.state)), @as(u32, @bitCast(later.previous)));
    inline for (.{ .one, .two, .three, .four }) |port| {
        const input = controllers.get(port);
        if (input.device_type == .none) try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(input.state)));
    }
}

fn timerLaps() !void {
    var timer = n64.time.Timer.start();
    n64.cpu.waitCycles(1000);
    const elapsed = timer.lap();
    try testing.expect(elapsed.ticks > 0);
    try testing.expect(elapsed.seconds() > 0);
    try testing.expect(elapsed.nanoseconds() > 0);
    n64.cpu.waitCycles(1000);
    try testing.expect(timer.read().ticks > 0);
    timer.reset();
    n64.cpu.waitCycles(1000);
    try testing.expect(timer.lap().ticks > 0);
}
