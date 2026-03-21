const TrapFrame = @import("cpu_state.zig").TrapFrame;
const GprIndex = @import("cpu_state.zig").GprIndex;
const debug = @import("../debug.zig");

pub inline fn exceptionHandler(frame: *TrapFrame) noreturn {
    debug.print("Interrupt Handler\n", .{});
    debug.print("Addr: 0x{X:0>8}\n", .{frame.epc});
    printCause(frame);
    debug.print("General Purpose Registers\n", .{});
    var i: u8 = 0;
    while(i < frame.gpr.len) : (i += 4) {
        const n0 = @tagName(@as(GprIndex, @enumFromInt(i)));
        const n1 = @tagName(@as(GprIndex, @enumFromInt(i + 1)));
        const n2 = @tagName(@as(GprIndex, @enumFromInt(i + 2)));
        const n3 = @tagName(@as(GprIndex, @enumFromInt(i + 3)));
        const v0: u32 = @truncate(frame.gpr[i]);
        const v1: u32 = @truncate(frame.gpr[i + 1]);
        const v2: u32 = @truncate(frame.gpr[i + 2]);
        const v3: u32 = @truncate(frame.gpr[i + 3]);
        debug.print("  {s}: 0x{X:0>8} {s}: 0x{X:0>8} {s}: 0x{X:0>8} {s}: 0x{X:0>8}\n", 
            .{n0, v0, n1, v1, n2, v2, n3, v3});
    }
    while(true) { }
}

fn printCause(frame: *TrapFrame) void {
    const print = debug.print;
    const cop0 = @import("../cpu/cp0.zig");
    const badVAddr = cop0.regRead(.BadVAddr);
    var epc = frame.epc;
    if((frame.cause & (1 << 31)) > 0)
        epc += 4;

    const code = ExceptionCode.fromCauseReg(frame.cause);
    switch (code) {
        // TODO: Finish strings
        .TlbModification => print("Write to read-only memory", .{}),
        .TlbLoad => {
            if(epc == badVAddr) {
                print("Invalid program counter address\n", .{});
            }
            else if(badVAddr < 120) {
                print("NULL pointer dereference (read)\n", .{});
            }
            else {
                if (badVAddr >= TLS_INVALID_MIN and badVAddr < (TLS_INVALID_MIN + TP_OFFSET)) {
                    print("Read from TLS in interrupt handler\n", .{});
                } 
                else {
                    print("Read from invalid memory address\n", .{});
                }
            }
        },
        .TlbStore => {
            if(badVAddr < 120) {
                print("NULL pointer dereference (write)\n", .{});
            }
            else {
                if (badVAddr >= TLS_INVALID_MIN and badVAddr < (TLS_INVALID_MIN + TP_OFFSET)) {
                    print("Write to TLS in interrupt handler\n", .{});
                } 
                else {
                    print("Write to invalid memory address\n", .{});
                }
            }
        },
        else => print("Cause: {s}\n", .{@tagName(code)})
    }
}

pub const ExceptionCode = enum(u5) {
    Interrupt = 0,
    TlbModification = 1,
    TlbLoad = 2,
    TlbStore = 3,
    AddrLoad = 4,
    AddrStore = 5,
    BusInst = 6,
    BusData = 7,
    SysCall = 8,
    Breakpoint = 9,
    CoProcessorUnusable = 11,
    ArithmaticOverflow = 12,
    Trap = 13,
    FloatingPoint = 15,
    Watch = 23, 
    Cache = 30,

    pub fn fromCauseReg(cause: u32) ExceptionCode {
        const shifted = cause >> 2;
        return @enumFromInt(@as(u5, @truncate(shifted)));
    }
};

const KERNEL_TP_INVALID = 0x5FFF8001;
const TLS_INVALID_MIN = KERNEL_TP_INVALID - TP_OFFSET;
const TP_OFFSET = 0x7000; 

