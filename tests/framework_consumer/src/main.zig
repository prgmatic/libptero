const n64 = @import("n64");

pub fn main() !void {}

pub fn alternateMain() !void {}

pub fn panicHandler(_: []const u8, _: ?usize) noreturn {
    while (true) {}
}

pub fn exceptionHandler(_: *n64.debug.TrapFrame) noreturn {
    while (true) {}
}

pub fn interruptHandler() void {}
