pub const cp0 = @import("cpu/cp0.zig");

pub fn waitCycles(cycles: u64) void {
    const start = cp0.regRead(.Count);
    while (cp0.regRead(.Count) - start < cycles) {}
}
