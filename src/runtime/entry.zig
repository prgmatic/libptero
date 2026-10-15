const std = @import("std");
const app = @import("app");
const config = @import("runtime_config");
const n64 = @import("n64");

pub const panic = std.debug.FullPanic(panicHandler);

extern var __bss_start: u8;
extern const __bss_end: u8;

export fn interruptHandler(frame: *n64.cpu.exception.TrapFrame) callconv(.c) noreturn {
    if (config.exception_handler.len != 0) {
        return @field(app, config.exception_handler)(frame);
    }
    n64.cpu.exception.exceptionHandler(frame);
}

export fn __MI_handler() callconv(.c) void {
    if (config.interrupt_handler.len != 0) {
        @field(app, config.interrupt_handler)();
        return;
    }
    n64.interrupt.interruptHandler();
}

const status_interrupt_enable: u32 = 1 << 0;
const status_mi_line: u32 = 1 << 10;

export fn __start() linksection(".text.startup") noreturn {
    // The ROM packer patches these exported values with the appended source
    // map's location. Referencing them keeps the metadata in a minimal ROM.
    _ = @as(*volatile u32, @ptrCast(&n64.debug.source_map.__srcmap_rom_offset)).*;
    _ = @as(*volatile u32, @ptrCast(&n64.debug.source_map.__srcmap_rom_size)).*;
    _ = @as(*volatile u32, @ptrCast(&n64.rom.__rom_assets_rom_offset)).*;
    _ = @as(*volatile u32, @ptrCast(&n64.rom.__rom_assets_rom_size)).*;

    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    @memset(@as([*]u8, @ptrCast(&__bss_start))[0..bss_len], 0);
    n64.debug.crash_screen.memory.initBootBounds();
    // Unmask the MI line only when the exception vector is linked (custom
    // assembly_files may omit it). MI's own mask starts clear; owners such as
    // audio.Output enable their sources.
    if (@extern(?*const u8, .{ .name = "__ptero_exception_vector", .linkage = .weak }) != null) {
        n64.cpu.cp0.regWrite(.Status, n64.cpu.cp0.regRead(.Status) | status_interrupt_enable | status_mi_line);
    }
    @field(app, config.entry)() catch |err| @panic(@errorName(err));
    while (true) {}
}

fn panicHandler(msg: []const u8, return_address: ?usize) noreturn {
    if (config.panic_handler.len != 0) {
        return @field(app, config.panic_handler)(msg, return_address);
    }

    n64.debug.panic_depth += 1;
    if (n64.debug.panic_depth > 1) {
        while (true) {}
    }
    n64.debug.writeAll("PANIC: ");
    n64.debug.writeAll(msg);
    n64.debug.writeAll("\n");
    const trace = n64.debug.backtrace.capture(1);
    if (trace) |captured| {
        n64.debug.backtrace.printTrace(captured);
    } else {
        n64.debug.writeAll("  <backtrace unavailable>\n");
    }
    n64.debug.crash_screen.show(.panic, msg, trace);
    n64.debug.crash_screen.waitForInput();
}
