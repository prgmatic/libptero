const std = @import("std");
const n64 = @import("n64");
const main = @import("game.zig").main;
const print = n64.debug.print;
pub const panic = std.debug.FullPanic(panicHandler);

export fn interruptHandler(frame: *n64.debug.TrapFrame) callconv(.c) noreturn {
    n64.debug.exepction.exceptionHandler(frame);
}

export fn __MI_handler() callconv(.c) void {
    n64.interrupt.interruptHandler();
}

export fn __start() linksection(".text.startup") void {
    main() catch |err| {
        @panic(@errorName(err));
    };
}

fn panicHandler(msg: []const u8, _: ?usize) noreturn {
    print("PANIC: {s}\n", .{msg});
    while(true) { }
}
