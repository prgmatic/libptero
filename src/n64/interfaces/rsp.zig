const dma_rsp_addr:     *volatile u32 = @ptrFromInt(0xA4040000);
const dma_dram_addr:    *volatile u32 = @ptrFromInt(0xA4040004);
const dma_read_len:     *volatile u32 = @ptrFromInt(0xA4040008);
const dma_write_len:    *volatile u32 = @ptrFromInt(0xA404000C);
const status:           *volatile u32 = @ptrFromInt(0xA4040010);
const dma_full:         *volatile u32 = @ptrFromInt(0xA4040014);
const dma_busy:         *volatile u32 = @ptrFromInt(0xA4040018);
const semaphore:        *volatile u32 = @ptrFromInt(0xA404001C);
const program_counter:  *volatile u32 = @ptrFromInt(0xa4080000);

pub fn dmaToDram(rsp_addr: u32, dram_addr: u32, write_len: u32) void {
    dma_rsp_addr.* = rsp_addr;
    dma_dram_addr.* = dram_addr;
    dma_write_len.* = write_len;
}

pub fn dmaFromDram(rsp_addr: u32, dram_addr: u32, read_len: u32) void {
    dma_rsp_addr.* = rsp_addr;
    dma_dram_addr.* = dram_addr;
    dma_read_len.* = read_len;
}

pub fn waitDma() void {
    while(status.* > 0) { }
}
