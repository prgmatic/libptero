const status: *volatile u32 = @ptrFromInt(0xa4600010);

pub fn wait() void {
    while(status.* & 0b11 > 0) { }
}
