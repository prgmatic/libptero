pub const cp0 = @import("cpu/cp0.zig");
pub const pi = @import("io/pi.zig");

const mode:    *volatile u32 = @ptrFromInt(0xA4300000);
const version: *volatile u32 = @ptrFromInt(0xA4300004);
const interrupt_mask: *volatile u32 = @ptrFromInt(0xA430000C);

pub fn updateInterrupts(mask: InterruptMask) void {
    interrupt_mask.* = @bitCast(mask);
}

pub fn clearRdpInterrupt() void {
    mode.* = 1 << 11;
}

pub fn getVersion() u32 {
    return version.*;
}

pub fn isIQue() bool {
    return (version.* & 0xF0) == 0xB0;
}

pub fn waitCycles(cycles: u64) void {
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

pub const InterruptMask = packed struct(u32) {
    clear_rsp: bool = false,
    set_rsp: bool = false,
    clear_pif_dma: bool = false,
    set_pif_dma: bool = false,
    clear_audio: bool = false,
    set_audio: bool = false,
    clear_video: bool = false,
    set_video: bool = false,
    clear_parallel: bool = false,
    set_parallel: bool = false,
    clear_rdp: bool = false,
    set_rdp: bool = false,
    _unused: u20 = 0,
};
