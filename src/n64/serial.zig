const registers = struct {
    // DRAM address used in SI DMAs
    const dramAddress: *volatile u32 = @ptrFromInt(0xA4800000);
    const pifReadAddress: *volatile u32 = @ptrFromInt(0xA4800004);
    const pifWriteAddress: *volatile u32 = @ptrFromInt(0xA4800010);
    const status: *volatile Status = @ptrFromInt(0xA4800018);
};

const pif_ram_addr = 0x1FC007C0;


pub fn pifTerminateBoot() void {
    // Notify the PIF that the boot process is finished. If this is not written,
    // the PIF will halt the CPU after 5 seconds.
    waitDmaIo();
    const ptr: *volatile u32 = @ptrFromInt(0xBFC00000 + 0x7FC);
    ptr.* = 0x8;
}


pub fn waitDmaIo() void {
    while(registers.status.is_dma_busy or registers.status.is_io_busy) { }
}

pub fn waitDma() void {
    while(registers.status.is_dma_busy) { }
}

pub fn waitIo() void {
    while(registers.status.is_io_busy) { }
}

pub fn dmaPifToDram(dramAddr: u32) void {
    registers.dramAddress.* = dramAddr;
    registers.pifReadAddress.* = pif_ram_addr;
}

pub fn dmaDramToPif(dramAddr: u32) void {
    registers.dramAddress.* = dramAddr;
    registers.pifWriteAddress.* = pif_ram_addr;
}

const Status = packed struct(u32) {
    is_dma_busy: bool,
    is_io_busy: bool,
    unused1: u1,
    dma_error: bool,
    pch_state: u3,
    dma_state :u3,
    reserved:u22,
};
