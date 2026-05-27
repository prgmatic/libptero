const std = @import("std");
const n64 = @import("n64");
const main = @import("game.zig").main;
const print = n64.debug.print;
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
    main() catch |err| {
        @panic(@errorName(err));
    };
}

fn panicHandler(msg: []const u8, _: ?usize) noreturn {
    n64.debug.panic_depth += 1;
    if (n64.debug.panic_depth > 1) {
        while (true) {}
    }
    // Use writeStr to avoid std.fmt — {s} formatting in Debug mode triggers a
    // safety panic inside Writer.zig which would recurse back into panicHandler.
    n64.debug.writeStr("PANIC: ");
    n64.debug.writeStr(msg);
    n64.debug.writeStr("\n");
    // skip=1 to omit this panicHandler frame, so frame #0 is the panic call site.
    const trace = n64.debug.backtrace.capture(1);
    if (trace) |captured| {
        n64.debug.backtrace.printTrace(captured);
    } else {
        n64.debug.writeStr("  <backtrace unavailable>\n");
    }
    n64.debug.crash_screen.show(.panic, msg, trace);
    while (true) {}
}
