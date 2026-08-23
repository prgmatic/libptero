const std = @import("std");
const n64 = @import("n64");

pub const panic = std.debug.FullPanic(panicHandler);

extern var __bss_start: u8;
extern const __bss_end: u8;

export fn interruptHandler(frame: *n64.debug.TrapFrame) callconv(.c) noreturn {
    n64.debug.exepction.exceptionHandler(frame);
}

export fn __MI_handler() callconv(.c) void {
    n64.interrupt.interruptHandler();
}

export fn __start() linksection(".text.startup") noreturn {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    @memset(@as([*]u8, @ptrCast(&__bss_start))[0..bss_len], 0);
    while (true) {}
}

fn panicHandler(_: []const u8, _: ?usize) noreturn {
    while (true) {}
}
