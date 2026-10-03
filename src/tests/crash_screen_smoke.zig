//! Deliberate real panic/CPU exception for crash-screen hardware validation.
const n64 = @import("n64");
const options = @import("crash_smoke_options");

pub fn main() !void {
    n64.debug.init();
    if (options.exception) {
        // Distinct HI/LO patterns verify the assembly snapshot's field order.
        asm volatile (
            \\mtlo %[lo]
            \\mthi %[hi]
            \\break 0x123
            :
            : [lo] "r" (@as(u32, 0x13579bdf)),
              [hi] "r" (@as(u32, 0x2468ace0)),
        );
        while (true) {}
    }
    triggerPanic();
}

noinline fn triggerPanic() noreturn {
    @panic("Crash screen hardware test\nCPU-only rendering / proportional 1-bit fonts");
}
