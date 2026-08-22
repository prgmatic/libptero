const mi = @import("interfaces/mips.zig");
const vi = @import("interfaces/video.zig");
const print = @import("debug.zig").print;

var lock: u8 = 0;
var pending_interrupts: u32 = 0;
var rdp_fences_scheduled: u32 = 0;
var rdp_fences_completed: u32 = 0;

pub fn interruptHandler() void {
    const raised = mi.getCurrentInterrupt();

    if (raised.rdp) {
        serviceRdpInterrupt();
    } else if (raised.video) {
        vi.claerInterrupt();
    }

    // print("Int {} {}\n", .{raised.rdp, raised.video});
    const bits: u32 = @bitCast(raised);
    _ = @atomicRmw(u32, &pending_interrupts, .Or, bits, .release);
}

pub const RdpFence = struct {
    target: u32,

    pub fn isComplete(self: RdpFence) bool {
        pollRdpInterrupt();
        return @atomicLoad(u32, &rdp_fences_completed, .acquire) == self.target;
    }

    pub fn waitTimeout(self: RdpFence, max_attempts: u32) bool {
        var remaining = max_attempts;
        while (!self.isComplete()) {
            if (remaining == 0) return false;
            remaining -= 1;
        }
        return true;
    }
};

pub fn armRdpFence() RdpFence {
    pollRdpInterrupt();
    const scheduled = @atomicLoad(u32, &rdp_fences_scheduled, .acquire);
    const completed = @atomicLoad(u32, &rdp_fences_completed, .acquire);
    if (scheduled != completed) @panic("only one RDP completion fence may be outstanding");
    const target = scheduled +% 1;
    @atomicStore(u32, &rdp_fences_scheduled, target, .release);
    return .{ .target = target };
}

fn pollRdpInterrupt() void {
    if (mi.isRdpInterruptPending()) serviceRdpInterrupt();
}

fn serviceRdpInterrupt() void {
    mi.clearRdpInterrupt();
    const scheduled = @atomicLoad(u32, &rdp_fences_scheduled, .acquire);
    const completed = @atomicLoad(u32, &rdp_fences_completed, .acquire);
    if (scheduled != completed) {
        @atomicStore(u32, &rdp_fences_completed, scheduled, .release);
    }
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
