pub const io = @import("io.zig");
pub const programs = @import("programs.zig");

pub fn runProgram(program: []const u8) void {
    halt();
    clearBroke();
    io.dmaFromDram(0x1000, @intFromPtr(program.ptr), program.len);
    io.waitDma();
    setProgramCounter(0);
    run();
}

pub inline fn halt() void {
    io.status_register_write.* = .{ .set_halt = true };
}

pub inline fn run() void {
    io.status_register_write.* = .{ .clear_halt = true };
}

pub inline fn clearBroke() void {
    io.status_register_write.* = .{ .clear_broke = true };
}

pub fn setProgramCounter(pc: u32) void {
    io.program_counter.* = pc;
}

pub inline fn is_broke() bool {
    return io.status_register_read.is_broke;
}

pub fn waitBroke() void {
    while(!is_broke()) { }
}
