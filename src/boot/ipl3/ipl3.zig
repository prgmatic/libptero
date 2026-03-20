const debug = @import("debug.zig");
const rdram = @import("rdram.zig");
const print = debug.dmemPrint;
const n64 = @import("n64");
const pi = n64.io.pi;

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
    print("Mips Ver:", &.{n64.cpu.getVersion()});

    n64.cpu.cp0.init();

    const mem_size = rdram.init();
    print("Mem Size:", &.{mem_size});
    
    dmem_ptr[0] = mem_size;
    dmem_ptr[2] |= if(n64.cpu.isIQue()) 1 else 0;


    // DMA loader program into RDRAM
    const dram_addr = 0x80000000 + mem_size - loader.len;
    const cart_addr = @intFromPtr(&loader) - 0xA0000000;
    print("DMA: ", &.{dram_addr, cart_addr, loader.len});
    n64.io.pi.startDmaWrite(dram_addr, cart_addr, loader.len);
    n64.io.pi.waitDma();
    
    // Loader is a PIC program. update the values in got section
    const got_len: *u32 = @ptrFromInt(dram_addr + loader.len - 4);
    const reloc_addr = dram_addr + loader.len - got_len.*;
    const reloc_ptr: [*]u32 = @ptrFromInt(reloc_addr + 0x20000000);
    const count = got_len.* / 4;
    for(0..count) |i| {
        reloc_ptr[i] += mem_size - loader.len;
    }

    // Clear Data/Inst Cache
    n64.cpu.cache.invadidateDataAll();
    n64.cpu.cache.invadidateDataAll();

    asm volatile (
        \\ move $t9, %[addr]
        \\ move $sp, $t9
        \\ addiu $sp, $t9, -0x10
        \\ li $gp, 0x80D8
        \\ jr $t9
        \\ nop
        :
        : [addr] "r" (dram_addr)
        : .{.r28 = true, .r29 = true, .r25 = true }
    );
    unreachable;
}

