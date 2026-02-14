const debug = @import("debug.zig");
const print = debug.dmemPrint;
const n64 = @import("n64");

comptime { _ = @import("header.zig"); }

export fn prestage() linksection(".stage1.pre") callconv(.naked) noreturn {
  asm volatile (
        \\ .set noreorder
        \\ .word 0x3044d236

        // sp = 0xa4000ff0
        \\ lui $sp, 0xa400
        \\ ori $sp, $sp, 0x0ff0

        // LLVM wants to pad this inline asm
        // Add a nop so we fall through to stage1
        \\ nop
    );
    unreachable;
}

export fn stage1() linksection(".stage1") callconv(.c) noreturn {
    debug.init();

    print("Libptero", .{});
    print("Mips Ver:", .{n64.io.mips.getVersion()});
    
    while(true) { }
    unreachable;
}
