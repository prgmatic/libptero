const cache = @import("../cpu/cache.zig");

pub const io = @import("io.zig");
pub const programs = @import("programs.zig");
pub const ucode = @import("ucode.zig");

pub const UCode = ucode.UCode;
pub const Ucode = UCode;

pub fn runUCode(program: UCode) void {
    halt();
    clearBroke();
    load(program);
    runAsync(program.pc_start);
}

pub fn load(program: UCode) void {
    loadText(program.text, 0);
    loadData(program.data, 0);
}

pub fn loadText(text: []const u8, imem_offset: u32) void {
    if (imem_offset + text.len > io.imem_len) {
        @panic("RSP text does not fit in IMEM");
    }
    dmaFromDram(text, io.dma_imem_addr + imem_offset);
}

pub fn loadData(data: []const u8, dmem_offset: u32) void {
    if (dmem_offset + data.len > io.dmem_len) {
        @panic("RSP data does not fit in DMEM");
    }
    dmaFromDram(data, io.dma_dmem_addr + dmem_offset);
}

pub fn runAsync(pc_start: u32) void {
    setProgramCounter(pc_start);
    io.status_register_write.* = .{
        .clear_halt = true,
        .clear_broke = true,
    };
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

pub inline fn is_halted() bool {
    return io.status_register_read.is_halted;
}

pub inline fn is_broke() bool {
    return io.status_register_read.is_broke;
}

pub fn waitHalted() void {
    while (!is_halted() or io.isDmaBusy() or io.isDmaFull()) {}
}

pub fn waitBroke() void {
    while (!is_broke()) {}
}

fn dmaFromDram(data: []const u8, rsp_addr: u32) void {
    if (data.len == 0) {
        return;
    }

    assertRspDma(data, rsp_addr);
    cache.writebackData(data);

    io.waitDmaReady();
    io.dmaFromDram(rsp_addr, physicalAddress(@intFromPtr(data.ptr)), @intCast(data.len - 1));
    io.waitDma();
}

fn assertRspDma(data: []const u8, rsp_addr: u32) void {
    if ((@intFromPtr(data.ptr) & 7) != 0) {
        @panic("RSP DMA source must be 8-byte aligned");
    }
    if ((rsp_addr & 7) != 0) {
        @panic("RSP DMA destination must be 8-byte aligned");
    }
}

fn physicalAddress(addr: usize) u32 {
    return @truncate(addr & 0x1FFFFFFF);
}
