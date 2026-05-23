const mi = @import("interfaces/mips.zig");
const vi = @import("interfaces/video.zig");
const print = @import("debug.zig").print;

var lock: u8 = 0;
var pending_interrupts: u32 = 0;

pub fn interruptHandler() void {
    const raised = mi.getCurrentInterrupt();

    if (raised.rdp) {
        mi.clearRdpInterrupt();
    }
    else if(raised.video) {
        vi.claerInterrupt();
    }

    // print("Int {} {}\n", .{raised.rdp, raised.video});
    const bits: u32 = @bitCast(raised);
    _ = @atomicRmw(u32, &pending_interrupts, .Or, bits, .release);
}

pub fn waitForInterrupt(interrupts: InterruptMask) void {
    const want: u32 = @bitCast(interrupts);
    while (true) {
        const current = @atomicLoad(u32, &pending_interrupts, .acquire);
        if ((want & current) == want) {
            _ = @atomicRmw(u32, &pending_interrupts, .And, ~want, .release);
            break;
        }
    }
}

pub const InterruptMask = packed struct(u32) {
    rsp: bool = false,
    serial: bool = false,
    audio: bool = false,
    video: bool = false,
    pif_dma: bool = false,
    rdp: bool = false,
    _pad: u26 = 0,
};
