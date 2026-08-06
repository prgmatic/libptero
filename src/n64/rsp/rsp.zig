const std = @import("std");
const cache = @import("../cpu/cache.zig");

pub const io = @import("io.zig");
pub const programs = @import("programs.zig");
pub const ucode = @import("ucode.zig");

pub const UCode = ucode.UCode;
pub const Ucode = UCode;
pub const command_queue = @import("command_queue.zig");
pub const CommandQueue = command_queue.CommandQueue;
pub const overlay = @import("overlay.zig");
pub const Overlay = overlay.Overlay;

pub const command_status_dmem = 0x5c;
pub const overlay_load_count_dmem = 0x64;

const overlay_table_dmem = 0x08;
const overlay_idmap_dmem = 0x48;
const queue_address_dmem = 0x58;
const current_overlay_id_dmem = 0x60;
const overlay_dmem_offset = overlay.dmem_offset;

var dma_staging: [io.dmem_len]u8 align(8) = undefined;

pub const OverlayHeader = extern struct {
    state_start: u16 = 0,
    state_size: u16 = 0,
    state_rdram: u32 = 0,
    command_base: u16,
    overlay_id: u16,
    text_rdram: u32,
    text_size: u16,
    text_start: u16,
    extra_rdram: u32 = 0,
    extra_size: u16 = 0,
    extra_start: u16 = 0,

    const byte_len = 28;

    fn write(self: OverlayHeader, destination: *[byte_len]u8) void {
        std.mem.writeInt(u16, destination[0..2], self.state_start, .big);
        std.mem.writeInt(u16, destination[2..4], self.state_size, .big);
        std.mem.writeInt(u32, destination[4..8], self.state_rdram, .big);
        std.mem.writeInt(u16, destination[8..10], self.command_base, .big);
        std.mem.writeInt(u16, destination[10..12], self.overlay_id, .big);
        std.mem.writeInt(u32, destination[12..16], self.text_rdram, .big);
        std.mem.writeInt(u16, destination[16..18], self.text_size, .big);
        std.mem.writeInt(u16, destination[18..20], self.text_start, .big);
        std.mem.writeInt(u32, destination[20..24], self.extra_rdram, .big);
        std.mem.writeInt(u16, destination[24..26], self.extra_size, .big);
        std.mem.writeInt(u16, destination[26..28], self.extra_start, .big);
    }
};

const overlay_payload_offset = overlay.payload_offset;

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
    io.readDmem(u32, queue_address_dmem).* = physicalAddress(@intFromPtr(words.ptr));
}

pub fn registerOverlay(registered: *Overlay) u8 {
    return registerOverlayInternal(registered, null);
}

pub fn registerOverlayStatic(registered: *Overlay, overlay_id: u8) void {
    _ = registerOverlayInternal(registered, overlay_id);
}

fn registerOverlayInternal(registered: *Overlay, static_id: ?u8) u8 {
    if (registered.id != 0) {
        @panic("RSP overlay is already registered");
    }
    const program = registered.program;
    if (program.text.len == 0 or program.text.len & 7 != 0) {
        @panic("RSP overlay text must have a nonzero DMA-aligned size");
    }
    const imem_offset = program.text_offset;
    if (imem_offset > io.imem_len or
        program.text.len > @as(usize, io.imem_len - imem_offset))
    {
        @panic("RSP overlay text does not fit in IMEM");
    }
    if (program.data.len == 0 or program.data.len & 7 != 0) {
        @panic("RSP overlay data must have a nonzero DMA-aligned size");
    }
    if (program.commandCount() == 0) {
        @panic("RSP overlay does not define any commands");
    }
    var highest_command_index: u8 = 0;
    for (0..program.commandCount()) |metadata_index| {
        highest_command_index = @max(highest_command_index, program.commandAt(metadata_index).index);
    }
    const slot_count: u8 = highest_command_index / overlay.commands_per_id + 1;
    if (program.state_len == 0 or program.state_offset & 7 != 0 or program.state_len & 7 != 0 or
        @as(u32, program.state_offset) + program.state_len > io.dmem_len)
    {
        @panic("RSP overlay must define DMA-aligned persistent state");
    }
    const overlay_data_len = overlay_payload_offset + program.data.len;
    if (overlay_data_len > io.dmem_len - overlay_dmem_offset) {
        @panic("RSP overlay data does not fit in DMEM");
    }

    const imem_address = io.dma_imem_addr + imem_offset;
    const dmem_address = io.dma_dmem_addr + overlay_dmem_offset;

    halt();
    waitHalted();
    const overlay_id = static_id orelse findFreeOverlayId(slot_count);
    if (overlay_id == 0 or @as(u16, overlay_id) + slot_count > overlay.max_id + 1) {
        @panic("RSP overlay ID range is outside the overlay table");
    }
    for (0..slot_count) |slot| {
        if (io.readDmem(u32, overlay_table_dmem + (@as(u32, overlay_id) + @as(u32, @intCast(slot))) * @sizeOf(u32)).* != 0) {
            @panic("RSP overlay table slot is already occupied");
        }
    }
    registered.id = overlay_id;
    registered.slot_count = slot_count;
    const overlay_data = registered.data[0..overlay_data_len];
    registered.data_len = overlay_data_len;
    @memset(overlay_data, 0);
    @memcpy(overlay_data[overlay_payload_offset..], program.data);

    const state = registered.state[0..program.state_len];
    const header = OverlayHeader{
        .state_start = program.state_offset,
        .state_size = program.state_len - 1,
        .state_rdram = physicalAddress(@intFromPtr(state.ptr)),
        .command_base = @as(u16, overlay_id) << 5,
        .overlay_id = @as(u16, overlay_id) << 2,
        .text_rdram = physicalAddress(@intFromPtr(program.text.ptr)),
        .text_size = @intCast(program.text.len - 1),
        .text_start = @intCast(imem_address),
    };
    header.write(overlay_data[0..OverlayHeader.byte_len]);
    for (0..program.commandCount()) |command_index| {
        const command = program.commandAt(command_index);
        if (command.handler_offset & 3 != 0 or command.handler_offset >> 2 > 0x3ff) {
            @panic("RSP overlay command metadata cannot be encoded");
        }
        const descriptor = @as(u16, command.size) << 8 | command.handler_offset >> 2;
        const descriptor_offset = OverlayHeader.byte_len + @as(usize, command.index) * @sizeOf(u16);
        std.mem.writeInt(u16, overlay_data[descriptor_offset..][0..2], descriptor, .big);
    }

    assertRspDma(program.text, imem_address);
    assertRspDma(overlay_data, dmem_address);

    cache.writebackData(program.text);
    cache.writebackData(overlay_data);
    cache.writebackData(state);

    const packed_data = physicalAddress(@intFromPtr(overlay_data.ptr)) & 0x00ffffff |
        @as(u32, @intCast((overlay_data.len - 1) >> 4)) << 24;
    for (0..slot_count) |slot| {
        const slot_id = overlay_id + @as(u8, @intCast(slot));
        io.readDmem(u32, overlay_table_dmem + @as(u32, slot_id) * @sizeOf(u32)).* = packed_data;
        writeDmemByte(overlay_idmap_dmem + slot_id, overlay_id << 2);
    }
    return overlay_id;
}

fn findFreeOverlayId(slot_count: u8) u8 {
    var candidate: u8 = 1;
    while (@as(u16, candidate) + slot_count <= overlay.max_id + 1) : (candidate += 1) {
        var free = true;
        for (0..slot_count) |slot| {
            const slot_id = candidate + @as(u8, @intCast(slot));
            if (io.readDmem(u32, overlay_table_dmem + @as(u32, slot_id) * @sizeOf(u32)).* != 0) {
                free = false;
                break;
            }
        }
        if (free) return candidate;
    }
    @panic("RSP overlay table does not have enough consecutive slots");
}

fn writeDmemByte(offset: u32, value: u8) void {
    const word_offset = offset & ~@as(u32, 3);
    const byte_offset = offset & 3;
    const shift: u5 = @intCast((3 - byte_offset) * 8);
    const value_mask = @as(u32, 0xff) << shift;
    const word = io.readDmem(u32, word_offset).*;
    io.readDmem(u32, word_offset).* = word & ~value_mask | @as(u32, value) << shift;
}

pub fn load(program: UCode) void {
    loadText(program.text, 0);
    loadData(program.data, 0);
}

pub fn loadResident(program: UCode) void {
    halt();
    waitHalted();
    clearDmem();
    load(program);
}

// The RSP must already be halted before directly accessing DMEM.
pub fn clearDmem() void {
    var offset: u32 = 0;
    while (offset < io.dmem_len) : (offset += @sizeOf(u32)) {
        io.readDmem(u32, offset).* = 0;
    }
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
