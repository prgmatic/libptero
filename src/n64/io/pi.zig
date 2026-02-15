const dram_address: *volatile u32 = @ptrFromInt(0xa4600000);
const cart_address: *volatile u32 = @ptrFromInt(0xa4600004);
const read_len: *volatile u32 = @ptrFromInt(0xa4600008);
const write_len: *volatile u32 = @ptrFromInt(0xa460000C);
const status: *volatile u32 = @ptrFromInt(0xa4600010);

pub fn wait() void {
    while(status.* & 0b11 > 0) { }
}

pub fn start_dma(dram_addr: u32, cart_addr: u32, len: u32) void {
    dram_address.* = dram_addr;
    cart_address.* = cart_addr;
    write_len.* = len;
}
