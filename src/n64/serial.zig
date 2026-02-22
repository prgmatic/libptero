const status: *volatile u32 = @ptrFromInt(0xA4800018);

pub fn pifTerminateBoot() void {
    waitDmaIo();
    const ptr: *volatile u32 = @ptrFromInt(0xBFC00000 + 0x7FC);
    ptr.* = 0x8;
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
