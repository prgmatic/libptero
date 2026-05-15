const dma_dram_addr:    *volatile u32 = @ptrFromInt(0xa4600000);
const dma_address: *volatile u32 = @ptrFromInt(0xa4600004);
const dma_read_len:     *volatile u32 = @ptrFromInt(0xa4600008);
const dma_write_len:    *volatile u32 = @ptrFromInt(0xa460000C);
const status:           *volatile u32 = @ptrFromInt(0xa4600010);

/// Start DMA from PI bus (eg. cartridge) to RDRAM.
pub fn dmaToDram(dram_addr: u32, cart_addr: u32, write_len: u32) void {
    dma_dram_addr.* = dram_addr;
    dma_address.* = cart_addr;
    dma_write_len.* = write_len;
}

/// Start DMA from RDRAM to PI bus
pub fn dmaFromDram(dram_addr: u32, cart_addr: u32, read_len: u32) void {
    dma_dram_addr.* = dram_addr;
    dma_address.* = cart_addr;
    dma_read_len.* = read_len;
}

pub fn waitDmaIo() void {
    while(status.* & 0b11 > 0) { }
}

pub fn waitDma() void {
    while(status.* & 1 > 0) { }
}

pub fn waitIo() void {
    while(status.* & 0b10 > 0) { }
}
