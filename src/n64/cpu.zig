pub const cp0 = @import("cpu/cp0.zig");
pub const cache = @import("cpu/cache.zig");

var version: *volatile u32 = @ptrFromInt(0xA4300004);

pub fn getVersion() u32 {
    return version.*;
}

pub fn isIQue() u32 {
    return (version.* & 0xF0) == 0xB0;
}

pub fn waitCycles(cycles: u32) void {
    const start = cp0.regRead(.Count);
    while (cp0.regRead(.Count) - start < cycles) {}
}
