const std = @import("std");
const n64 = @import("n64");
const elf = @import("elf.zig");
const print = n64.debug.print;


export fn __start() linksection(".loader") callconv(.c) noreturn {
    var sys_buffer: [256]u8 = undefined;
    var fixed_buffer_alloc = std.heap.FixedBufferAllocator.init(&sys_buffer);
    n64.debug.init();
    n64.debug.initFmtBuffer(fixed_buffer_alloc.allocator());
    
    const entry = loadElf();

    n64.io.serial.pifTerminateBoot();
    n64.cpu.cache.clear();
    print("Entry {x}\n", .{entry});
    while (entry == 0) {}

    asm volatile (
        \\ move $t9, %[addr]
        \\ jr $t9
        \\ nop
        :
        : [addr] "r" (entry)
        : .{.r25 = true }
    );

    unreachable;
}

fn loadElf() u32 {
    const elf_magic: u32 = 0x7F454C46;
    var elf_addr: u32 = 0xB0001000;
    var elf_found: bool = false;
    const search_count = 1 * 1026 * 1024 / 256;
    
    for(0..search_count) |_| {
        const ptr: *u32 = @ptrFromInt(elf_addr);
        if(ptr.* == elf_magic){
            elf_found = true;
            break;
        }
        elf_addr += 256;
    }
    if(!elf_found){
        print("No elf found :( \n)", .{});
        return 0;
    }

    const elf_type: *u32 = @ptrFromInt(elf_addr + 0x4);
    const elf64: bool = (elf_type.* >> 24) == 2;
    if(elf64) {
        print("64 bit currently supported\n", .{});
        return 0;
    }
    if(((elf_type.* >> 16) & 0xFF) == 1) {
        print("Little endian not supported\n", .{});
        return 0;
    }

    var elf_header: elf.ElfHeader32 align(8) = undefined;

    print("EH 0x{x}\n", .{@intFromPtr(&elf_header)});
    n64.io.pi.startDmaWrite(@intFromPtr(&elf_header), elf_addr - 0xA0000000, @sizeOf(elf.ElfHeader32));
    n64.io.pi.waitDma();

    var hdr_size: u32 = elf_header.program_header_offset + elf_header.program_header_count * elf_header.program_header_entry_size;
    if(hdr_size & 1 == 1) hdr_size += 1;
    if(hdr_size > 1024) {
        print("Header was larger than 1024 bytes", .{});
        return 0;
    }

    var hdr: [1024]u8 = undefined;
    n64.io.pi.startDmaWrite(@intFromPtr(&hdr), elf_addr - 0xA0000000, hdr_size);
    n64.io.pi.waitDma();

    for(0..elf_header.program_header_count - 1) |i| {
        const prg_addr = @intFromPtr(&hdr) + elf_header.program_header_offset + i * elf_header.program_header_entry_size;
        const prg_header: *elf.ProgramHeader32 = @ptrFromInt(prg_addr);

        if(prg_header.segment_type != 1)
            continue;

        if(prg_header.virtual_address % 8 != 0) {
            print("Elf: 0x{X} is not 8-byte aligned in segment\n", .{prg_header.virtual_address});
            continue;
        }
        if(prg_header.offset % 2 != 0) {
            print("ELF: file offset is not 2-byte aligned in segment\n", .{});
            continue;
        }

        const dma_size = if (prg_header.file_size & 1 > 0) prg_header.file_size + 1 else prg_header.file_size;
        n64.io.pi.startDmaWrite(prg_header.virtual_address, elf_addr + prg_header.offset - 0xA0000000, dma_size);
        n64.io.pi.waitDma();
        print("DMA: VADDR:0x{X} PADDR:0x{X} Size:0x{X}\n", .{prg_header.virtual_address, elf_addr + prg_header.offset - 0xA0000000, dma_size});
    }

    print("Elf Loaded\n", .{});
    return elf_header.entry_point;
}

