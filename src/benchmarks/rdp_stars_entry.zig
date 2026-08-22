const std = @import("std");
const n64 = @import("n64");
const main = @import("rdp_stars.zig").main;
pub const panic = std.debug.FullPanic(panicHandler);

extern var __bss_start: u8;
extern const __bss_end: u8;

export fn interruptHandler(frame: *n64.debug.TrapFrame) callconv(.c) noreturn {
    n64.debug.exepction.exceptionHandler(frame);
}

export fn __MI_handler() callconv(.c) void {
    n64.interrupt.interruptHandler();
}

export fn __start() linksection(".text.startup") void {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    @memset(@as([*]u8, @ptrCast(&__bss_start))[0..bss_len], 0);
    main() catch |err| @panic(@errorName(err));
}

fn panicHandler(msg: []const u8, _: ?usize) noreturn {
    n64.debug.writeStr("PANIC: ");
    n64.debug.writeStr(msg);
    n64.debug.writeStr("\n");
    while (true) {}
}
