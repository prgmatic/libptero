const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");

extern var __bss_start: u8;
extern const __bss_end: u8;

var debug_buffer: [1024]u8 = undefined;

const tests = [_]runner.Test{} ++
    @import("zsp_tests.zig").tests ++
    @import("rsp_tests.zig").tests;

export fn __start() linksection(".text.startup") noreturn {
    // The ROM packer patches these exported values with the appended source
    // map's location. Referencing them keeps the metadata in this minimal ROM.
    _ = @as(*volatile u32, @ptrCast(&n64.debug.srcmap.__srcmap_rom_offset)).*;
    _ = @as(*volatile u32, @ptrCast(&n64.debug.srcmap.__srcmap_rom_size)).*;

    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    @memset(@as([*]u8, @ptrCast(&__bss_start))[0..bss_len], 0);

    n64.debug.init();
    var debug_allocator = std.heap.FixedBufferAllocator.init(&debug_buffer);
    n64.debug.initFmtBuffer(debug_allocator.allocator()) catch {
        n64.debug.writeStr("Unable to initialize test output\n");
        while (true) {}
    };

    _ = runner.run(&tests);

    while (true) {}
}
