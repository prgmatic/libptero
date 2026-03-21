const TrapFrame = @import("cpu_state.zig").TrapFrame;
const GprIndex = @import("cpu_state.zig").GprIndex;
const debug = @import("../debug.zig");

pub inline fn exceptionHandler(frame: *TrapFrame) noreturn {
    debug.print("Interrupt Handler\n", .{});
    debug.print("Addr: 0x{X:0>8}\n", .{frame.epc});
    debug.print("General Purpose Registers\n", .{});
    var i: u8 = 0;
    while(i < frame.gpr.len) : (i += 4) {
        const n0 = @tagName(@as(GprIndex, @enumFromInt(i)));
        const n1 = @tagName(@as(GprIndex, @enumFromInt(i + 1)));
        const n2 = @tagName(@as(GprIndex, @enumFromInt(i + 2)));
        const n3 = @tagName(@as(GprIndex, @enumFromInt(i + 3)));
        const v0: u32 = @intCast(frame.gpr[i]);
        const v1: u32 = @intCast(frame.gpr[i + 1]);
        const v2: u32 = @intCast(frame.gpr[i + 2]);
        const v3: u32 = @intCast(frame.gpr[i + 3]);
        debug.print("  {s}: 0x{X:0>8} {s}: 0x{X:0>8} {s}: 0x{X:0>8} {s}: 0x{X:0>8}\n", 
            .{n0, v0, n1, v1, n2, v2, n3, v3});
    }
    while(true) { }
}
