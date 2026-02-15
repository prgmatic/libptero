const debug = @import("debug.zig");
const print = debug.dmemPrint;
const n64 = @import("n64");

const loader align(8) linksection(".loader") = @embedFile("loader.bin").*;
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
    print("Mips Ver:", .{n64.cpu.getVersion()});

    n64.cpu.cp0.init();
    const mem_size = n64.io.rdram.init();

    print("Mem Size:", .{mem_size});

    const dram_addr = 0x80000000 + 0x2000;
    const cart_addr = @intFromPtr(&loader) - 0xA0000000;
    n64.io.pi.start_dma(dram_addr, cart_addr, loader.len);
    n64.io.pi.wait();
    const reloc_addr = dram_addr + loader.len - 8;
    const reloc_ptr: *u32 = @ptrFromInt(reloc_addr + 0x20000000);
    reloc_ptr.* = dram_addr;

    // asm volatile ("" ::: .{.memory = true});
    asm volatile (
        \\ move $t9, %[addr]
        \\ move $sp, $t9
        \\ addiu $sp, $t9, 0x2000
        \\ li $gp, 0x80D8
        \\ jr $t9
        \\ nop
        :
        : [addr] "r" (dram_addr)
        : .{.r28 = true, .r29 = true, .r25 = true }
    );
    
    unreachable;
}
