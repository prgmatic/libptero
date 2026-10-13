pub const TrapFrame = @import("trap_frame.zig").TrapFrame;
const GprIndex = @import("trap_frame.zig").GprIndex;
const debug = @import("../debug.zig");
const crash_screen = @import("../debug/crash_screen.zig");

pub inline fn exceptionHandler(frame: *TrapFrame) noreturn {
    debug.panic_depth += 1;
    if (debug.panic_depth > 1) while (true) {};
    const cop0 = @import("cp0.zig");
    const badvaddr = cop0.regRead(.BadVAddr);
    const code = ExceptionCode.fromCauseReg(frame.cause);
    const pc = exceptionPc(frame);
    const instruction: ?u32 = if ((code == .FloatingPoint or code == .Trap or code == .Breakpoint) and debug.backtrace.isValidCodeAddr(pc))
        @as(*const volatile u32, @ptrFromInt(pc)).*
    else
        null;
    const causeStr = describe(.{ .cause = frame.cause, .epc = frame.epc, .badvaddr = badvaddr, .fcsr = frame.fcsr, .fpr = &frame.fpr, .instruction = instruction, .cache_error = if (code == .Emux) cop0.regRead(.CacheErr) else 0 });
    debug.print("CPU Exception\n", .{});
    debug.print("Addr: 0x{X:0>8}\n", .{frame.epc});
    debug.writeAll(causeStr);
    debug.writeAll("\n");
    const trace = debug.backtrace.captureFrom(
        exceptionPc(frame),
        @truncate(frame.gpr[@intFromEnum(GprIndex.sp)]),
        @truncate(frame.gpr[@intFromEnum(GprIndex.ra)]),
    );
    debug.print("Backtrace\n", .{});
    debug.backtrace.printTrace(trace);
    debug.print("General Purpose Registers\n", .{});
    debug.print("HI: 0x{x:0>16} LO: 0x{x:0>16} FCSR: 0x{x:0>8}\n", .{ frame.hi, frame.lo, frame.fcsr });
    var i: u8 = 0;
    while (i < frame.gpr.len) : (i += 4) {
        const n0 = @tagName(@as(GprIndex, @enumFromInt(i)));
        const n1 = @tagName(@as(GprIndex, @enumFromInt(i + 1)));
        const n2 = @tagName(@as(GprIndex, @enumFromInt(i + 2)));
        const n3 = @tagName(@as(GprIndex, @enumFromInt(i + 3)));
        const v0: u32 = @truncate(frame.gpr[i]);
        const v1: u32 = @truncate(frame.gpr[i + 1]);
        const v2: u32 = @truncate(frame.gpr[i + 2]);
        const v3: u32 = @truncate(frame.gpr[i + 3]);
        debug.print("  {s}: 0x{X:0>8} {s}: 0x{X:0>8} {s}: 0x{X:0>8} {s}: 0x{X:0>8}\n", .{ n0, v0, n1, v1, n2, v2, n3, v3 });
    }
    crash_screen.showException(causeStr, trace, frame, badvaddr);
    crash_screen.waitForInput();
}

pub fn exceptionPc(frame: *const TrapFrame) u32 {
    return @import("exception_codes.zig").faultPc(frame.cause, frame.epc);
}

pub const ExceptionCode = @import("exception_codes.zig").ExceptionCode;
pub const describe = @import("exception_codes.zig").describe;
