const debug = @import("debug.zig");
const rdram = @import("rdram.zig");
const n64 = @import("n64");
const mi = n64.interfaces.mips;
const pi = n64.interfaces.parallel;
const print = debug.dmemPrint;

const loader align(8) linksection(".loader") = @embedFile("loader.bin").*;
comptime { _ = @import("header.zig"); }

const dmem_ptr: [*]volatile u32 = @ptrFromInt(0xA4000000);

export fn prestage() linksection(".stage1.pre") callconv(.c) noreturn {
  asm volatile (
        \\ .set noreorder
        \\ .word 0x3044D236

        // Compile boot flags into single
        // 32bit register
        \\ sll $s3, $s3, 24
        \\ sll $s4, $s4, 16
        \\ sll $s5, $s5, 8

        \\ or $s3, $s3, $s4
        \\ or $s3, $s3, $s5

        // Save boot flags to DMEM
        \\ li $t0, 0xA4000008
        \\ sw $s3, 0($t0)

        \\ li $sp, 0xA4000FF0
    ); 
    
    debug.init();
    
    print("Libptero", &.{});
    print("Mips Ver:", &.{mi.getVersion()});

    n64.cpu.cp0.init();

    const mem_size = rdram.init();
    print("Mem Size:", &.{mem_size});
    
    dmem_ptr[0] = mem_size;
    dmem_ptr[2] |= if(mi.isIQue()) 1 else 0;


    // DMA loader program into RDRAM
    const dram_addr = 0x80000000 + mem_size - loader.len;
    const cart_addr = @intFromPtr(&loader) - 0xA0000000;
    print("DMA: ", &.{dram_addr, cart_addr, loader.len});
    pi.dmaToDram(dram_addr, cart_addr, loader.len);
    pi.waitDma();
    
    // Loader is a PIC program. update the values in got section
    pi.waitIo();
    const got_len: *u32 = @ptrFromInt(dram_addr + 0x20000000 + loader.len - 4);
    const reloc_addr = dram_addr + loader.len - got_len.*;
    const count = got_len.* / 4;
    const reloc_ptr: [*]u32 = @ptrFromInt(reloc_addr + 0x20000000);
    for(0..count) |i| {
        pi.waitIo();
        reloc_ptr[i] += mem_size - loader.len;
    }

    // Clear Data/Inst Cache
    n64.cache.clear();

    asm volatile (
        \\ move $t9, %[addr]
        \\ addiu $sp, $t9, -0x10
        \\ li $gp, (_gp)
        \\ jr $t9
        \\ nop
        :
        : [addr] "r" (dram_addr)
        : .{.r28 = true, .r29 = true, .r25 = true }
    );
    unreachable;
}

