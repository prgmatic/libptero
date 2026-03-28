const print = @import("debug.zig").print;
var lock: u8 = 0;


pub fn interruptHandler() void { 
    @atomicStore(u8, &lock, 0, .release);
    const cpu = @import("cpu.zig");
    cpu.clearRdpInterrupt();
}


pub fn waitForInterrupt() void {
    while (true) {
        if (@cmpxchgWeak(u8, &lock, 0, 1, .acquire, .monotonic) == null) {
            break;
        }
    }
}
