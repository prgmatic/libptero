pub const dmem_base = 0xA4000000;
pub const imem_base = 0xA4001000;
pub const dma_dmem_addr = 0x0000;
pub const dma_imem_addr = 0x1000;
pub const dmem_len = 0x1000;
pub const imem_len = 0x1000;

pub const dma_rsp_addr: *volatile u32 = @ptrFromInt(0xA4040000);
pub const dma_dram_addr: *volatile u32 = @ptrFromInt(0xA4040004);
pub const dma_read_len: *volatile u32 = @ptrFromInt(0xA4040008);
pub const dma_write_len: *volatile u32 = @ptrFromInt(0xA404000C);
pub const status_register_read: *volatile Status = @ptrFromInt(0xA4040010);
pub const status_register_write: *volatile u32 = @ptrFromInt(0xA4040010);
pub const dma_full: *volatile u32 = @ptrFromInt(0xA4040014);
pub const dma_busy: *volatile u32 = @ptrFromInt(0xA4040018);
pub const semaphore: *volatile bool = @ptrFromInt(0xA404001C);
pub const program_counter: *volatile u32 = @ptrFromInt(0xA4080000);

pub const status_clear_halt: u32 = 1 << 0;
pub const status_set_halt: u32 = 1 << 1;
pub const status_clear_broke: u32 = 1 << 2;

pub fn readDmem(comptime T: type, offset: u32) *volatile T {
    return @ptrFromInt(dmem_base + offset);
}

pub fn dmaToDram(rsp_addr: u32, dram_addr: u32, write_len: u32) void {
    dma_dram_addr.* = dram_addr;
    dma_rsp_addr.* = rsp_addr;
    dma_write_len.* = write_len;
}

pub fn dmaFromDram(rsp_addr: u32, dram_addr: u32, read_len: u32) void {
    dma_dram_addr.* = dram_addr;
    dma_rsp_addr.* = rsp_addr;
    dma_read_len.* = read_len;
}

pub fn waitDma() void {
    while (isDmaBusy()) {}
}

pub fn waitDmaReady() void {
    while (isDmaBusy() or isDmaFull()) {}
}

pub fn isDmaBusy() bool {
    const status = status_register_read.*;
    return status.is_dma_busy or status.is_io_busy;
}

pub fn isDmaFull() bool {
    return status_register_read.is_dma_full;
}

pub const Status = packed struct(u32) {
    is_halted: bool,
    is_broke: bool,
    is_dma_busy: bool,
    is_dma_full: bool,
    is_io_busy: bool,
    is_single_step: bool,
    is_interrupt_on_break: bool,
    signal0: bool,
    signal1: bool,
    signal2: bool,
    signal3: bool,
    signal4: bool,
    signal5: bool,
    signal6: bool,
    signal7: bool,
    _unused: u17 = 0,
};
