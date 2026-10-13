const std = @import("std");
const cache = @import("../cpu/cache.zig");
const profiler = @import("../debug/profiler.zig");
const io = @import("../hw/sp.zig");
const rdp_io = @import("../hw/dp.zig");
const rsp = @import("../rsp.zig");
const command_queue = @import("CommandBuffer.zig");
const CommandBuffer = command_queue;
const Overlay = @import("Overlay.zig");
const Priority = rsp.Priority;
const rdp_dynamic_buffer_len = rsp.rdp_dynamic_buffer_len;
const physicalAddress = @import("../cpu.zig").physicalAddress;
const flush = rsp.flush;
const symbols = @import("programs.zig").command_dispatcher_symbols;
const rdp_current_dmem = symbols.rdp_current;
const rdp_sentinel_dmem = symbols.rdp_sentinel;
const rdp_buffers_dmem = symbols.rdp_buffers;

const Queue = @This();
storage: command_queue.QueueStorage,
priority: Priority,
recording: ?*CommandBuffer,
syncpoints_scheduled: u32,
syncpoints_completed: u32,
trace_sync: profiler.Scope = .{},
trace_high: profiler.Scope = .{},
high_return_address: u32 = 0,

pub fn init(self: *Queue, priority: Priority) void {
    self.storage.init();
    if (priority == .low) for (&self.storage.queues) |*commands| {
        commands.defer_head = true;
    };
    self.priority = priority;
    self.recording = null;
    self.syncpoints_scheduled = 0;
    self.syncpoints_completed = 0;
    self.trace_sync = .{};
    self.trace_high = .{};
    self.high_return_address = 0;
}

pub fn writeDmem(self: *Queue, offset: u32, value: u32) void {
    self.reserveCommandWords(2);
    self.current().writeDmem(offset, value);
}

pub fn writeOverlayCommand(
    self: *Queue,
    registered: *const Overlay,
    command_index: u8,
    inline_argument: u32,
    arguments: []const u32,
) void {
    self.reserveCommandWords(1 + arguments.len);
    self.current().writeOverlayCommand(registered, command_index, inline_argument, arguments);
}

// Fast path for typed wrappers whose command ABI is fixed in code. Generic
// callers should use writeOverlayCommand so metadata still validates them.
pub inline fn writeOverlayCommandKnown(
    self: *Queue,
    registered: *const Overlay,
    command_index: u8,
    inline_argument: u32,
    arguments: []const u32,
) void {
    self.reserveCommandWords(1 + arguments.len);
    self.current().writeRawCommand(registered.commandId(command_index), inline_argument, arguments);
}

pub inline fn reserveLowPriorityWords(self: *Queue, command_words: usize) void {
    if (self.priority != .low) @panic("low-priority queue reservation requires a low-priority queue");
    self.reserveCommandWords(command_words);
}

pub fn beginBlock(self: *Queue, block: *CommandBuffer) void {
    if (self.priority != .low) @panic("command blocks require a low-priority queue");
    if (self.recording != null) @panic("an RSP command block is already being recorded");
    block.clear();
    self.recording = block;
}

pub fn endBlock(self: *Queue, block: *CommandBuffer) void {
    if (self.recording != block) @panic("RSP command block recording mismatch");
    block.returnFromCall();
    cache.writebackData(block.buffer);
    self.recording = null;
}

pub fn runBlock(self: *Queue, block: *const CommandBuffer) void {
    if (self.recording != null) @panic("recorded command blocks cannot call another block");
    self.reserveCommandWords(2);
    self.current().callStatic(block);
}

pub fn dmaToDmem(
    self: *Queue,
    dmem_address: u32,
    rdram_source: []const u8,
    is_async: bool,
) void {
    validateQueueDma(rdram_source, dmem_address);
    cache.writebackData(rdram_source);
    self.reserveCommandWords(4);
    self.current().writeDmaCommand(
        physicalAddress(@intFromPtr(rdram_source.ptr)),
        dmem_address,
        @intCast(rdram_source.len - 1),
        if (is_async) 0 else io.status_dma_busy | io.status_dma_full,
    );
}

pub fn dmaToRdram(
    self: *Queue,
    rdram_destination: []u8,
    dmem_address: u32,
    is_async: bool,
) void {
    validateQueueDma(rdram_destination, dmem_address);
    cache.invalidateData(rdram_destination);
    self.reserveCommandWords(4);
    self.current().writeDmaCommand(
        physicalAddress(@intFromPtr(rdram_destination.ptr)),
        dmem_address,
        @intCast(rdram_destination.len - 1),
        0xffff8000 | if (is_async) 0 else io.status_dma_busy | io.status_dma_full,
    );
}

pub fn waitThenWriteStatus(self: *Queue, mask: u32, status: u32) void {
    self.reserveCommandWords(2);
    self.current().waitThenWriteStatus(mask, status);
}

pub fn setRdpBuffer(self: *Queue, end: u32, start: u32, sentinel: u32) void {
    self.reserveCommandWords(3);
    self.current().setRdpBuffer(end, start, sentinel);
}

pub fn appendRdpBuffer(self: *Queue, end: u32) void {
    self.reserveCommandWords(1);
    self.current().appendRdpBuffer(end);
}

pub fn configureRdpBuffers(
    self: *Queue,
    first: []align(16) u8,
    second: []align(16) u8,
) void {
    if (first.len != rdp_dynamic_buffer_len or second.len != rdp_dynamic_buffer_len) {
        @panic("RSP RDP dynamic buffers must each be 64 KiB");
    }
    const first_address = physicalAddress(@intFromPtr(first.ptr));
    const second_address = physicalAddress(@intFromPtr(second.ptr));
    const buffers_attached = io.readDmem(u32, rdp_current_dmem).* != 0 and
        io.readDmem(u32, rdp_sentinel_dmem).* != 0 and
        io.readDmem(u32, rdp_buffers_dmem).* == first_address and
        io.readDmem(u32, rdp_buffers_dmem + @sizeOf(u32)).* == second_address;
    // The CPU has not touched buffers which remain RSP-owned, so repeating
    // a 128 KiB invalidation is unnecessary. Keep the proven DMEM and DP
    // reattachment sequence below unchanged.
    if (!buffers_attached) {
        cache.invalidateData(first);
        cache.invalidateData(second);
    }
    self.writeDmem(rdp_current_dmem, first_address);
    self.writeDmem(rdp_sentinel_dmem, first_address + rdp_dynamic_buffer_len);
    self.writeDmem(rdp_buffers_dmem, first_address);
    self.writeDmem(rdp_buffers_dmem + @sizeOf(u32), second_address);
    // Match the resident state above before the queued SET_BUFFER command
    // attempts to terminate this initial empty dynamic buffer.
    // Match libdragon's rspq initialization: select RDRAM DMA and clear
    // stale freeze/flush state before installing the initial empty range.
    rdp_io.status_write.* = 0x15;
    var reset_wait: u16 = 500;
    while (reset_wait != 0 and
        (rdp_io.status.end_register_write_pending or
            rdp_io.status.is_start_register_write_pending))
    {
        reset_wait -= 1;
    }
    rdp_io.dma_start_addr.* = first_address;
    rdp_io.dma_end_addr.* = first_address;
    var accept_wait: u32 = 1_000_000;
    while (accept_wait != 0 and (@as(u32, @bitCast(rdp_io.status.*)) & 0x600) != 0) {
        accept_wait -= 1;
    }
    if (accept_wait == 0) @panic("timed out initializing RSP-owned RDP buffers");
}

/// Compatibility operation; prefer insertSyncpoint when retaining a token.
pub fn syncpoint(self: *Queue) void {
    _ = self.insertSyncpoint();
}

/// Append a completion marker and flush. Only one marker may be pending.
/// Keep this queue at a stable address until the token is complete.
pub fn insertSyncpoint(self: *Queue) Syncpoint {
    if (self.priority != .low) @panic("syncpoints require a low-priority RSP queue");
    self.pollSyncpoint();
    if (self.storage.syncpoint_pending) @panic("only one RSP syncpoint may be outstanding");
    self.reserveCommandWords(2);
    io.status_register_write.* = io.status_clear_signal2;
    self.syncpoints_scheduled +%= 1;
    self.current().waitThenWriteStatus(io.status_signal2, io.status_set_signal2);
    self.trace_sync = profiler.begin(.rsp_low, "RSP syncpoint (observed)", self.syncpoints_scheduled);
    flush(self);
    self.storage.syncpoint_pending = true;
    return .{ .queue = self, .target = self.syncpoints_scheduled };
}

pub fn waitSyncpointTimeout(self: *Queue, max_attempts: u32) bool {
    const point: Syncpoint = .{ .queue = self, .target = self.syncpoints_scheduled };
    var remaining = max_attempts;
    while (!point.isComplete()) {
        if (remaining == 0) return false;
        remaining -= 1;
    }
    return true;
}

fn pollSyncpoint(self: *Queue) void {
    if (!self.storage.syncpoint_pending or !io.status_register_read.signal2) return;
    io.status_register_write.* = io.status_clear_signal2;
    self.trace_sync.end();
    self.trace_sync = .{};
    self.syncpoints_completed = self.syncpoints_scheduled;
    self.storage.syncpoint_pending = false;
}

inline fn current(self: *Queue) *CommandBuffer {
    if (self.recording) |block| return block;
    return &self.storage.queues[self.storage.write_index];
}

/// Reserve command words, including the queue epilogue. Flushes low-priority work when full.
pub inline fn reserveCommandWords(self: *Queue, command_words: usize) void {
    if (self.recording) |block| {
        if (block.index + command_words + 1 <= block.buffer.len) return;
        @panic("recorded RSP command block is full");
    }
    const epilogue_words: usize = if (self.priority == .low) 3 else 6;
    if (self.current().index + command_words + epilogue_words <= self.current().buffer.len) return;
    if (self.priority == .high) @panic("high-priority RSP command queue is full");
    flush(self);
}

fn validateQueueDma(rdram: anytype, dmem_address: u32) void {
    if (rdram.len == 0 or rdram.len & 7 != 0 or @intFromPtr(rdram.ptr) & 7 != 0) {
        @panic("RSP queue DMA buffer must have a nonzero 8-byte-aligned size and address");
    }
    if (dmem_address & 7 != 0 or dmem_address > io.dmem_len or
        rdram.len > io.dmem_len - dmem_address)
    {
        @panic("RSP queue DMA transfer does not fit in DMEM");
    }
}

pub const Syncpoint = struct {
    queue: *Queue,
    target: u32,

    pub fn isComplete(self: Syncpoint) bool {
        self.queue.pollSyncpoint();
        return @as(i32, @bitCast(self.queue.syncpoints_completed -% self.target)) >= 0;
    }
};
