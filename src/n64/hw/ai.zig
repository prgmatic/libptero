//! Audio Interface registers. Addresses and lengths are eight-byte aligned.
const address: *volatile u32 = @ptrFromInt(0xa4500000);
const length: *volatile u32 = @ptrFromInt(0xa4500004);
const control: *volatile u32 = @ptrFromInt(0xa4500008);
const status: *volatile u32 = @ptrFromInt(0xa450000c);
const dac_rate: *volatile u32 = @ptrFromInt(0xa4500010);
const bit_rate: *volatile u32 = @ptrFromInt(0xa4500014);

pub const busy = @as(u32, 1) << 30;
pub const full = @as(u32, 1) << 31;
pub fn readStatus() u32 {
    return status.*;
}
pub fn acknowledge() void {
    status.* = 0;
}
pub fn configure(dac: u32, bit: u32) void {
    dac_rate.* = dac;
    bit_rate.* = bit;
}
pub fn enqueue(physical_address: u32, byte_length: u32) void {
    address.* = physical_address;
    asm volatile ("sync" ::: .{ .memory = true });
    length.* = byte_length;
    asm volatile ("sync" ::: .{ .memory = true });
    control.* = 1;
}
pub fn stop() void {
    control.* = 0;
    configure(0, 0);
    acknowledge();
}
