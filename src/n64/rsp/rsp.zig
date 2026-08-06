const std = @import("std");
const cache = @import("../cpu/cache.zig");

pub const io = @import("io.zig");
pub const programs = @import("programs.zig");
pub const ucode = @import("ucode.zig");

pub const UCode = ucode.UCode;
pub const Ucode = UCode;
pub const CommandQueue = @import("command_queue.zig").CommandQueue;

pub const overlay_load_count_dmem = 0x1c;

const overlay_text_address_dmem = 0x08;
const overlay_text_size_dmem = 0x0c;
const overlay_imem_address_dmem = 0x10;
const overlay_handler_address_dmem = 0x14;
const current_overlay_id_dmem = 0x18;
const overlay_data_address_dmem = 0x20;
const overlay_data_size_dmem = 0x24;
const overlay_dmem_address_dmem = 0x28;

var dma_staging: [io.dmem_len]u8 align(8) = undefined;

pub fn runUCode(program: UCode) void {
    halt();
    waitHalted();
    load(program);
    runAsync(program.pc_start);
}

pub fn submitCommands(queue: *const CommandQueue) void {
    if (!queue.isStopped()) {
        @panic("RSP command queue must end with stop()");
    }

    halt();
    waitHalted();

    const words = queue.words();
    cache.writebackData(words);
    io.readDmem(u32, 0).* = physicalAddress(@intFromPtr(words.ptr));
}

pub fn submitOverlay(
    overlay_id: u8,
    program: UCode,
    imem_offset: u32,
    dmem_offset: u32,
) void {
    if (overlay_id != 1) {
        @panic("only static RSP overlay 1 is currently supported");
    }
    if (program.text.len == 0 or program.text.len & 7 != 0) {
        @panic("RSP overlay text must have a nonzero DMA-aligned size");
    }
    if (imem_offset > io.imem_len or
        program.text.len > @as(usize, io.imem_len - imem_offset))
    {
        @panic("RSP overlay text does not fit in IMEM");
    }
    if (program.data.len == 0 or program.data.len & 7 != 0) {
        @panic("RSP overlay data must have a nonzero DMA-aligned size");
    }
    if (dmem_offset > io.dmem_len or
        program.data.len > @as(usize, io.dmem_len - dmem_offset))
    {
        @panic("RSP overlay data does not fit in DMEM");
    }

    const imem_address = io.dma_imem_addr + imem_offset;
    const dmem_address = io.dma_dmem_addr + dmem_offset;
    assertRspDma(program.text, imem_address);
    assertRspDma(program.data, dmem_address);

    halt();
    waitHalted();
    cache.writebackData(program.text);
    cache.writebackData(program.data);

    io.readDmem(u32, overlay_text_address_dmem).* = physicalAddress(@intFromPtr(program.text.ptr));
    io.readDmem(u32, overlay_text_size_dmem).* = @intCast(program.text.len - 1);
    io.readDmem(u32, overlay_imem_address_dmem).* = imem_address;
    io.readDmem(u32, overlay_handler_address_dmem).* = io.dma_imem_addr + program.pc_start;
    io.readDmem(u32, current_overlay_id_dmem).* = 0;
    io.readDmem(u32, overlay_load_count_dmem).* = 0;
    io.readDmem(u32, overlay_data_address_dmem).* = physicalAddress(@intFromPtr(program.data.ptr));
    io.readDmem(u32, overlay_data_size_dmem).* = @intCast(program.data.len - 1);
    io.readDmem(u32, overlay_dmem_address_dmem).* = dmem_address;
}

pub fn load(program: UCode) void {
    loadText(program.text, 0);
    loadData(program.data, 0);
}

pub fn loadText(text: []const u8, imem_offset: u32) void {
    if (imem_offset > io.imem_len or paddedDmaLen(text.len) > io.imem_len - imem_offset) {
        @panic("RSP text does not fit in IMEM");
    }
    dmaFromDramStaged(text, io.dma_imem_addr + imem_offset);
}

pub fn loadData(data: []const u8, dmem_offset: u32) void {
    if (dmem_offset > io.dmem_len or paddedDmaLen(data.len) > io.dmem_len - dmem_offset) {
        @panic("RSP data does not fit in DMEM");
    }
    dmaFromDramStaged(data, io.dma_dmem_addr + dmem_offset);
}

pub fn runAsync(pc_start: u32) void {
    setProgramCounter(pc_start);
    io.status_register_write.* = io.status_clear_halt | io.status_clear_broke;
}

pub inline fn halt() void {
    io.status_register_write.* = io.status_set_halt;
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

fn dmaFromDramStaged(data: []const u8, rsp_addr: u32) void {
    if (data.len == 0) {
        return;
    }
    const padded_len = paddedDmaLen(data.len);
    const rsp_offset = rsp_addr & 0xfff;
    if (padded_len > dma_staging.len or rsp_offset + padded_len > io.dmem_len) {
        @panic("RSP DMA transfer does not fit in memory");
    }

    const staged = dma_staging[0..padded_len];
    @memset(staged, 0);
    @memcpy(staged[0..data.len], data);
    dmaFromDram(staged, rsp_addr);
}

fn paddedDmaLen(len: usize) usize {
    return std.mem.alignForward(usize, len, 8);
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
