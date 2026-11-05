//! Hardware half of the RSP timing calibration: runs the shared
//! microbenchmarks and prints their self-timed RCP cycle counts. Record them
//! in `tools/rsp_interp/calibration.zig`; the host test then keeps the
//! interpreter's timing model within tolerance of real hardware.
const n64 = @import("n64");
const runner = @import("runner.zig");
const calibration = @import("rsp_calibration");

const rsp = n64.rsp;

pub const tests = [_]runner.Test{
    .{ .name = "RSP calibration: microbenchmark cycles", .run = measure },
};

fn measure() !void {
    inline for (calibration.all) |benchmark| {
        rsp.runProgram(.{ .text = @ptrCast(benchmark.text) });
        var remaining: u32 = 1_000_000;
        while (!rsp.isBroke()) : (remaining -= 1) {
            if (remaining == 0) return error.RspTimeout;
        }
        const cycles = n64.hw.sp.readDmem(u32, calibration.result_offset).*;
        if (cycles == 0) return error.ClockDidNotAdvance;
        n64.debug.print(" {s}={d}", .{ benchmark.name, cycles });
    }
}
