pub const cp0 = @import("cpu/cp0.zig");
pub const pi = @import("io/pi.zig");

const mode:    *volatile u32 = @ptrFromInt(0xA4300000);
var version: *volatile u32 = @ptrFromInt(0xA4300004);

pub fn getVersion() u32 {
    return version.*;
}

pub fn isIQue() bool {
    return (version.* & 0xF0) == 0xB0;
}

pub fn waitCycles(cycles: u32) void {
    const start = cp0.regRead(.Count);
    while (cp0.regRead(.Count) - start < cycles) {}
}

pub fn enableRepeatMode(repeatCount: u7) void {
    mode.* = 0x100 | @as(u32 ,@intCast(repeatCount - 1));
}

pub fn setUpperMode() void {
    mode.* = 0x2000;
}

pub fn clearUpperMode() void {
    mode.* = 0x1000;
}
