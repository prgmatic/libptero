pub const cp0 = @import("cpu/cp0.zig");

pub fn waitCycles(cycles: u64) void {
    const start = cp0.regRead(.Count);
    while (cp0.regRead(.Count) - start < cycles) {}
}

/// Data and instruction cache operations.
pub const cache = @import("cpu/cache.zig");
pub const exception = @import("cpu/exception.zig");
pub const kseg0_addr: u32 = 0x80000000;
pub const kseg1_addr: u32 = 0xa0000000;
pub fn physicalAddress(address: usize) u32 {
    return @truncate(address & 0x1fffffff);
}
