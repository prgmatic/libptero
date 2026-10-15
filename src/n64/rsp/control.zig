const std = @import("std");
const cache = @import("../cpu/cache.zig");
const cpu = @import("../cpu.zig");
const profiler = @import("../debug/profiler.zig");
const rdp_io = @import("../hw/dp.zig");

const io = @import("../hw/sp.zig");
pub const programs = @import("programs.zig");
pub const Program = @import("Program.zig");
const command_queue = @import("CommandBuffer.zig");
pub const CommandBuffer = command_queue;
const overlay = @import("Overlay.zig");
pub const Overlay = overlay;
pub const Runtime = @import("Runtime.zig");

pub const Priority = enum { low, high };
pub const rdp_dynamic_buffer_len = 64 * 1024;

var resident_queue_started = false;
var idle_queue_buffer: [command_queue.batch_word_count]u32 align(8) = @splat(0);

pub const Queue = @import("Queue.zig");

/// A stable completion token for one queue marker. Tokens remain completed
/// across later submissions; comparisons are valid within 2^31 markers.
pub const Syncpoint = Queue.Syncpoint;

pub const rdp_syncfull_ongoing_dmem = programs.command_dispatcher_symbols.rdp_syncfull_ongoing;
pub const rdp_target_bitdepth_dmem = programs.command_dispatcher_symbols.rdp_target_bitdepth;
pub const rdp_mode_dmem = programs.command_dispatcher_symbols.rdp_mode;

const overlay_table_dmem = programs.command_dispatcher_symbols.overlay_data_rdram;
const overlay_idmap_dmem = programs.command_dispatcher_symbols.overlay_idmap;
const pointer_stack_dmem = programs.command_dispatcher_symbols.pointer_stack;
const queue_address_dmem = programs.command_dispatcher_symbols.queue_rdram_address;
const current_overlay_id_dmem = overlay_dmem_offset + 10;
const rdp_current_dmem = programs.command_dispatcher_symbols.rdp_current;
const rdp_sentinel_dmem = programs.command_dispatcher_symbols.rdp_sentinel;
const rdp_buffers_dmem = programs.command_dispatcher_symbols.rdp_buffers;
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

pub fn runProgram(program: Program) void {
    halt();
    waitHalted();
    load(program);
    runAsync(program.pc_start);
}

pub fn submitCommands(queue: *const CommandBuffer) void {
    if (!queue.sealed) {
        @panic("RSP command queue must end with stop() or jump()");
    }

    halt();
    waitHalted();

    writebackCommandGraph(queue, 0);
    if (queue.swap_target) |alternate| {
        io.readDmem(u32, pointer_stack_dmem + 9 * @sizeOf(u32)).* =
            physicalAddress(@intFromPtr(alternate.buffer.ptr));
    }
    io.readDmem(u32, queue_address_dmem).* = physicalAddress(@intFromPtr(queue.buffer.ptr));
    writeDmemByte(rdp_target_bitdepth_dmem, 0);
    io.status_register_write.* = io.status_set_signal7;
}

// Transfer DP ownership away from the resident RSP queue after the caller has
// completed a full-sync fence and waited for its RSP Queue. Restore the empty
// boot-state range expected by direct submitters and low-level test programs.
pub fn releaseRdpToDirect() void {
    // Queue signal6 is raised just before the dispatcher jumps to the next
    // (empty) buffer. Do not rewrite its live DP/DMEM state until that jump has
    // completed and the resident program has actually halted.
    waitHalted();
    rdp_io.status_write.* = (1 << 5) | (1 << 3);
    rdp_io.status_write.* = 0x15;
    rdp_io.dma_start_addr.* = 0;
    rdp_io.dma_end_addr.* = 0;
    var accept_wait: u32 = 1_000_000;
    while (accept_wait != 0 and (@as(u32, @bitCast(rdp_io.status.*)) & 0x600) != 0) {
        accept_wait -= 1;
    }
    if (accept_wait == 0) @panic("timed out releasing RDP to direct submission");
    io.readDmem(u32, rdp_current_dmem).* = 0;
    io.readDmem(u32, rdp_sentinel_dmem).* = 0;
    writeDmemByte(rdp_syncfull_ongoing_dmem, 0);
}

fn writebackCommandGraph(queue: *const CommandBuffer, depth: usize) void {
    if (depth >= 256) @panic("RSP command queue graph is cyclic or too deep");
    if (!queue.sealed) @panic("RSP command queue graph contains an incomplete batch");
    cache.writebackData(queue.buffer[0..]);
    if (queue.call_target) |block| writebackCommandGraph(block, depth + 1);
    if (queue.swap_target) |alternate| writebackCommandGraph(alternate, depth + 1);
    if (queue.next) |next| writebackCommandGraph(next, depth + 1);
}

pub fn flush(queue: *Queue) void {
    const trace_scope = profiler.scope("RSP low submit CPU");
    defer trace_scope.end();
    if (queue.priority != .low) @panic("use submitHighPriority for a high-priority RSP queue");
    if (queue.recording != null) @panic("cannot flush while recording an RSP command block");
    const storage = &queue.storage;
    const current = &storage.queues[storage.write_index];
    if (current.index == 0) return;
    const next_index: u1 = storage.write_index ^ 1;
    const next = &storage.queues[next_index];

    if (storage.submitted) {
        // Space uncached SP_STATUS reads while the RDP owns the shared RCP bus.
        // Libdragon gets equivalent pacing from its timed RSP_WAIT_LOOP.
        const poll_interval_cycles = 64;
        while (!io.status_register_read.signal6) cpu.waitCycles(poll_interval_cycles);
        io.status_register_write.* = io.status_clear_signal6;
        next.clearStreaming();
    }

    profiler.instant(.rsp_low, "RSP queue submit", @intCast(current.index));
    current.writeRawCommand(
        @intFromEnum(command_queue.InternalCommand.write_status),
        io.status_set_signal6,
        &.{},
    );
    current.jump(next);
    cache.writebackData(current.buffer[0..current.index]);
    cache.writebackData(next.buffer[0..command_queue.batch_word_count]);
    current.publishHead();
    cache.writebackData(current.buffer[0..1]);

    if (!storage.submitted) {
        halt();
        waitHalted();
        io.status_register_write.* = io.status_clear_signal6;
        io.readDmem(u32, queue_address_dmem).* = physicalAddress(@intFromPtr(current.buffer.ptr));
        setProgramCounter(programs.command_dispatcher.pc_start);
        resident_queue_started = true;
        wakeContinuous();
    } else {
        wakeContinuous();
    }
    storage.write_index = next_index;
    storage.submitted = true;
}

pub fn wait(queue: *const Queue) void {
    if (queue.priority != .low) @panic("use waitHighPriorityTimeout for a high-priority RSP queue");
    if (!queue.storage.submitted) return;
    while (!io.status_register_read.signal6) {}
}

pub fn waitTimeout(queue: *const Queue, max_attempts: u32) bool {
    const trace_scope = profiler.scope("RSP low wait CPU");
    defer trace_scope.end();
    if (queue.priority != .low) @panic("use waitHighPriorityTimeout for a high-priority RSP queue");
    if (!queue.storage.submitted) return true;
    var remaining = max_attempts;
    while (!io.status_register_read.signal6) {
        if (remaining == 0) return false;
        remaining -= 1;
    }
    return true;
}

pub fn submitHighPriority(queue: *Queue) void {
    const trace_scope = profiler.scope("RSP high submit CPU");
    defer trace_scope.end();
    if (queue.priority != .high) @panic("high-priority submission requires a high-priority RSP queue");
    if (queue.storage.submitted) @panic("high-priority RSP queue is already submitted");
    queue.reserveCommandWords(0);
    const current = &queue.storage.queues[queue.storage.write_index];
    current.writeRawCommand(
        @intFromEnum(command_queue.InternalCommand.write_status),
        io.status_set_signal5,
        &.{},
    );
    current.swapBuffersToCaller(io.status_clear_signal3);
    queue.high_return_address = physicalAddress(@intFromPtr(current.buffer.ptr)) + @as(u32, @intCast(current.index * 4));
    current.stop();
    cache.writebackData(current.buffer[0..]);

    const batch_address = physicalAddress(@intFromPtr(current.buffer.ptr));
    if (high_resume_address) |resume_address| {
        // The dispatcher resumes high-priority execution at the word after
        // the previous batch's epilogue (its swap saved that address in slot
        // 9). Chain this batch from there with a jump written to RDRAM. The
        // running RSP is neither halted nor has its DMEM written: halting it
        // mid-frame, or writing DMEM while it DMAs, intermittently corrupted
        // its RDP buffer state on hardware (DP_END left behind DP_START, so
        // the RDP ran past its buffer and never completed).
        const word: *u32 = @ptrFromInt(0x8000_0000 | resume_address);
        word.* = @as(u32, @intFromEnum(command_queue.InternalCommand.jump)) << 24 | (batch_address & 0x00ff_ffff);
        cache.writebackData(@as(*const [1]u32, word));
        io.status_register_write.* = io.status_clear_signal5;
    } else {
        // First batch: publish slot 9 while scalar execution is stopped.
        // Preserve the PC: low-priority work resumes immediately afterwards.
        halt();
        waitHalted();
        // Audio may be the first user of the resident runtime. Give the priority
        // switch a valid low-priority return stream before waking the dispatcher.
        if (!resident_queue_started) {
            cache.writebackData(&idle_queue_buffer);
            io.readDmem(u32, queue_address_dmem).* = physicalAddress(@intFromPtr(&idle_queue_buffer));
            setProgramCounter(programs.command_dispatcher.pc_start);
            resident_queue_started = true;
        }
        io.status_register_write.* = io.status_clear_signal5;
        io.readDmem(u32, pointer_stack_dmem + 9 * @sizeOf(u32)).* = batch_address;
    }
    queue.trace_high = profiler.begin(.rsp_high, "RSP high batch (observed)", @intCast(current.index));
    io.status_register_write.* = io.status_set_signal4;
    wakeContinuous();
    queue.storage.submitted = true;
}

pub fn waitHighPriorityTimeout(queue: *Queue, max_attempts: u32) bool {
    const trace_scope = profiler.scope("RSP high wait CPU");
    defer trace_scope.end();
    if (queue.priority != .high) @panic("high-priority wait requires a high-priority RSP queue");
    if (!queue.storage.submitted) return true;
    var remaining = max_attempts;
    while (true) {
        const status = io.status_register_read.*;
        // swapBuffers clears signal3 before saving the outgoing high pointer.
        // Wait for that final store too: otherwise the CPU's next submission
        // can publish a new slot 9 pointer which the old epilogue overwrites.
        if (status.signal5 and !status.signal3 and !status.signal4) {
            if (io.readDmem(u32, pointer_stack_dmem + 9 * @sizeOf(u32)).* == queue.high_return_address) break;
        }
        if (remaining == 0) return false;
        remaining -= 1;
    }
    io.status_register_write.* = io.status_clear_signal5;
    queue.trace_high.end();
    queue.trace_high = .{};
    queue.storage.queues[queue.storage.write_index].clear();
    // The next batch is chained from this batch's resume word, so it must be
    // written into the other buffer.
    queue.storage.write_index ^= 1;
    high_resume_address = queue.high_return_address;
    queue.storage.submitted = false;
    return true;
}

/// RDRAM address at which the dispatcher resumes its next high-priority
/// switch (slot 9 as saved by the last completed batch's epilogue).
var high_resume_address: ?u32 = null;

fn wakeContinuous() void {
    const wake_status = io.status_set_signal7 | io.status_clear_halt | io.status_clear_broke;
    io.status_register_write.* = wake_status;
    asm volatile ("nop; nop; nop; b 1f; 1: nop; nop; nop; nop; nop; nop");
    io.status_register_write.* = wake_status;
}

pub fn registerOverlay(registered: *Overlay) u8 {
    return registerOverlayInternal(registered, null);
}

pub fn registerOverlayStatic(registered: *Overlay, overlay_id: u8) void {
    _ = registerOverlayInternal(registered, overlay_id);
}

pub fn unregisterOverlay(registered: *Overlay) void {
    if (registered.id == 0) {
        @panic("RSP overlay is not registered");
    }

    halt();
    waitHalted();
    syncOverlayState(registered);

    const overlay_id = registered.id;
    for (0..registered.slot_count) |slot| {
        const slot_id = overlay_id + @as(u8, @intCast(slot));
        io.readDmem(u32, overlay_table_dmem + @as(u32, slot_id) * @sizeOf(u32)).* = 0;
        writeDmemByte(overlay_idmap_dmem + slot_id, 0);
    }
    if (io.readDmem(u16, current_overlay_id_dmem).* == @as(u16, overlay_id) << 2) {
        io.readDmem(u16, current_overlay_id_dmem).* = 0;
    }
    std.mem.writeInt(u16, registered.data[8..10], 0, .big);
    cache.writebackData(registered.data[0..registered.data_len]);
    registered.id = 0;
    registered.slot_count = 0;
}

pub fn overlayState(registered: *Overlay) []u8 {
    halt();
    waitHalted();
    if (registered.id != 0) syncOverlayState(registered);
    const state = registered.state[registered.program.state_offset..][0..registered.program.state_len];
    cache.invalidateData(state);
    return state;
}

pub fn writebackOverlayState(registered: *Overlay) void {
    halt();
    waitHalted();
    const state = registered.state[registered.program.state_offset..][0..registered.program.state_len];
    cache.writebackData(state);
    if (registered.id == 0 or
        io.readDmem(u16, current_overlay_id_dmem).* != @as(u16, registered.id) << 2)
    {
        return;
    }
    io.waitDmaReady();
    io.dmaFromDram(
        registered.program.state_offset,
        physicalAddress(@intFromPtr(state.ptr)),
        @intCast(state.len - 1),
    );
    io.waitDma();
}

fn syncOverlayState(registered: *Overlay) void {
    if (io.readDmem(u16, current_overlay_id_dmem).* != @as(u16, registered.id) << 2) return;
    const state = registered.state[registered.program.state_offset..][0..registered.program.state_len];
    io.waitDmaReady();
    io.dmaToDram(
        registered.program.state_offset,
        physicalAddress(@intFromPtr(state.ptr)),
        @intCast(state.len - 1),
    );
    io.waitDma();
    cache.invalidateData(state);
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
    if (program.data.len & 7 != 0) {
        @panic("RSP overlay data must be DMA-aligned");
    }
    const data_address = overlay.dataAddress(program);
    if (@as(usize, data_address) + program.data.len > io.dmem_len) {
        @panic("RSP overlay program data does not fit in DMEM");
    }
    if (program.commandCount() == 0) {
        @panic("RSP overlay does not define any commands");
    }
    var highest_command_index: u8 = 0;
    for (0..program.commandCount()) |metadata_index| {
        highest_command_index = @max(highest_command_index, program.commandAt(metadata_index).index);
    }
    const slot_count: u8 = highest_command_index / overlay.commands_per_id + 1;
    if ((program.state_len != 0 and (program.state_offset & 7 != 0 or program.state_len & 7 != 0)) or
        @as(u32, program.state_offset) + program.state_len > io.dmem_len)
    {
        @panic("RSP overlay persistent state must be DMA-aligned");
    }
    const overlay_data_len = std.mem.alignForward(
        usize,
        OverlayHeader.byte_len + (@as(usize, highest_command_index) + 1) * @sizeOf(u16),
        16,
    );
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

    const state = registered.state[program.state_offset..][0..program.state_len];
    const image_start: u16 = if (program.data.len == 0)
        program.state_offset
    else
        @min(data_address, program.state_offset);
    const image_end: u16 = @intCast(@max(
        @as(usize, data_address) + program.data.len,
        @as(usize, program.state_offset) + program.state_len,
    ));
    const image = registered.state[image_start..image_end];
    const has_image = program.data.len != 0 or program.state_init.len != 0;
    const header_dmem_end: u16 = @intCast(overlay_dmem_offset + overlay_data.len);
    if (has_image and header_dmem_end > image_start) {
        const overlap_start: u16 = @max(@as(u16, overlay_dmem_offset), image_start);
        const overlap_end: u16 = @min(header_dmem_end, image_end);
        if (overlap_end > overlap_start) {
            @memcpy(
                overlay_data[overlap_start - overlay_dmem_offset ..][0 .. overlap_end - overlap_start],
                registered.state[overlap_start..overlap_end],
            );
        }
    }
    const header = OverlayHeader{
        .state_start = program.state_offset,
        .state_size = if (program.state_len == 0) std.math.maxInt(u16) else program.state_len - 1,
        .state_rdram = physicalAddress(@intFromPtr(state.ptr)),
        .command_base = @as(u16, overlay_id) << 5,
        .overlay_id = @as(u16, overlay_id) << 2,
        .text_rdram = physicalAddress(@intFromPtr(program.text.ptr)) |
            if (has_image) @as(u32, 0x80000000) else 0,
        .text_size = @intCast(program.text.len - 1),
        .text_start = @intCast(imem_address),
        .extra_rdram = if (has_image) physicalAddress(@intFromPtr(image.ptr)) else 0,
        .extra_size = if (has_image) @intCast(image.len - 1) else 0,
        .extra_start = if (has_image) image_start else 0,
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
    cache.writebackData(image);

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

pub fn writeDmemByte(offset: u32, value: u8) void {
    const word_offset = offset & ~@as(u32, 3);
    const byte_offset = offset & 3;
    const shift: u5 = @intCast((3 - byte_offset) * 8);
    const value_mask = @as(u32, 0xff) << shift;
    const word = io.readDmem(u32, word_offset).*;
    io.readDmem(u32, word_offset).* = word & ~value_mask | @as(u32, value) << shift;
}

pub fn load(program: Program) void {
    loadText(program.text, 0);
    loadData(program.data, program.data_address orelse 0);
}

pub fn loadResident(program: Program) void {
    halt();
    waitHalted();
    clearDmem();
    load(program);
    resident_queue_started = false;
    high_resume_address = null;
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

pub inline fn isHalted() bool {
    return io.status_register_read.is_halted;
}

pub inline fn isBroke() bool {
    return io.status_register_read.is_broke;
}

pub fn waitHalted() void {
    while (!isHalted() or io.isDmaBusy() or io.isDmaFull()) {}
}

pub fn waitBroke() void {
    while (!isBroke()) {}
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

const physicalAddress = cpu.physicalAddress;
