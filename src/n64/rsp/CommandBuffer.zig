const io = @import("../hw/sp.zig");
const Overlay = @import("Overlay.zig");

pub const fetch_window_byte_len = @import("host_abi.zig").fetch_window_byte_len;
pub const batch_word_count = fetch_window_byte_len / @sizeOf(u32);
// Match libdragon's low-priority RSPQ buffer capacity. Correct turnover makes
// capacity a latency/memory tradeoff rather than a correctness requirement.
pub const rdram_buffer_word_count = 0x200;

comptime {
    if (rdram_buffer_word_count % batch_word_count != 0) {
        @compileError("resident queue buffer stride must preserve fetch-window alignment");
    }
}

pub const InternalCommand = @import("internal_commands.zig").InternalCommand;

const CommandBuffer = @This();

buffer: []align(8) u32,
index: usize,
sealed: bool,
next: ?*const CommandBuffer,
call_target: ?*const CommandBuffer,
swap_target: ?*const CommandBuffer,
/// Live cached streams retain an invalid first word until the entire batch
/// has been written back. Recorded/direct queues publish normally.
defer_head: bool = false,
pending_head: ?u32 = null,

pub fn init(buffer: []align(8) u32) CommandBuffer {
    var queue = CommandBuffer{
        .buffer = buffer,
        .index = 0,
        .sealed = false,
        .next = null,
        .call_target = null,
        .swap_target = null,
    };
    queue.clear();
    return queue;
}

pub fn clear(self: *CommandBuffer) void {
    @memset(self.buffer[0..], 0);
    self.index = 0;
    self.sealed = false;
    self.next = null;
    self.call_target = null;
    self.swap_target = null;
    self.pending_head = null;
}

pub fn clearStreaming(self: *CommandBuffer) void {
    // The resident dispatcher fetches a complete 256-byte window. Clear
    // that whole window before reuse so no stale command from the fetched
    // cache line can survive beyond the invalid guard.
    @memset(self.buffer[0..batch_word_count], 0);
    self.index = 0;
    self.sealed = false;
    self.next = null;
    self.call_target = null;
    self.swap_target = null;
    self.pending_head = null;
}

/// Call after writing back the sealed batch, then write back its first word.
/// An RSP refetch must never observe a header before its arguments/epilogue.
pub fn publishHead(self: *CommandBuffer) void {
    if (!self.sealed) @panic("cannot publish an open RSP command batch");
    if (self.pending_head) |header| {
        self.buffer[0] = header;
        self.pending_head = null;
    }
}

pub fn writeDmem(self: *CommandBuffer, offset: u32, value: u32) void {
    if (offset & 3 != 0 or offset > io.dmem_len - @sizeOf(u32)) {
        @panic("RSP command queue DMEM offset is invalid");
    }
    self.writeRawCommand(@intFromEnum(InternalCommand.write_word), offset, &.{value});
}

pub inline fn writeRawCommand(
    self: *CommandBuffer,
    command_id: u8,
    inline_argument: u32,
    arguments: []const u32,
) void {
    if (self.sealed) {
        @panic("cannot append to a sealed RSP command queue");
    }
    if (inline_argument > 0x00ffffff) {
        @panic("RSP command queue inline argument is too large");
    }
    if (arguments.len > 62) {
        @panic("RSP command queue command exceeds the 252-byte descriptor limit");
    }
    const command_words = 1 + arguments.len;
    if (self.index + command_words >= self.buffer.len) {
        @panic("RSP command queue is full");
    }

    const header = @as(u32, command_id) << 24 | inline_argument;
    if (self.defer_head and self.index == 0) {
        self.pending_head = header;
    } else self.buffer[self.index] = header;
    @memcpy(self.buffer[self.index + 1 ..][0..arguments.len], arguments);
    self.index += command_words;

    // Keep an invalid guard after the last complete command while open.
    self.buffer[self.index] = 0;
}

/// writeRawCommand for a compile-time argument count: stores the words
/// directly instead of calling memcpy, for per-draw RDP commands.
pub inline fn writeRawCommandFixed(
    self: *CommandBuffer,
    command_id: u8,
    inline_argument: u32,
    comptime argument_count: usize,
    arguments: [argument_count]u32,
) void {
    if (argument_count > 62) @compileError("RSP command exceeds the 252-byte descriptor limit");
    if (self.sealed) @panic("cannot append to a sealed RSP command queue");
    if (@import("builtin").mode == .Debug and inline_argument > 0x00ffffff) @panic("RSP command queue inline argument is too large");
    const index = self.index;
    if (index + 1 + argument_count >= self.buffer.len) @panic("RSP command queue is full");
    const header = @as(u32, command_id) << 24 | inline_argument;
    if (self.defer_head and index == 0) {
        self.pending_head = header;
    } else self.buffer[index] = header;
    inline for (0..argument_count) |i| self.buffer[index + 1 + i] = arguments[i];
    self.index = index + 1 + argument_count;
    // Keep an invalid guard after the last complete command while open.
    self.buffer[self.index] = 0;
}

pub fn writeOverlayCommand(
    self: *CommandBuffer,
    registered: *const Overlay,
    command_index: u8,
    inline_argument: u32,
    arguments: []const u32,
) void {
    var command_size: ?u8 = null;
    for (0..registered.program.commandCount()) |metadata_index| {
        const candidate = registered.program.commandAt(metadata_index);
        if (candidate.index == command_index) {
            command_size = candidate.size;
            break;
        }
    }
    if (command_size == null) {
        @panic("RSP overlay command is not defined");
    }
    if (command_size.? != (1 + arguments.len) * @sizeOf(u32)) {
        @panic("RSP overlay command arguments do not match its declared size");
    }
    self.writeRawCommand(registered.commandId(command_index), inline_argument, arguments);
}

pub fn writeDmaCommand(
    self: *CommandBuffer,
    rdram_address: u32,
    dmem_address: u32,
    dma_length: u32,
    flags: u32,
) void {
    self.writeRawCommand(
        @intFromEnum(InternalCommand.dma),
        rdram_address,
        &.{ dmem_address, dma_length, flags },
    );
}

pub fn waitThenWriteStatus(self: *CommandBuffer, mask: u32, status: u32) void {
    self.writeRawCommand(@intFromEnum(InternalCommand.wait_then_write_status), status, &.{mask});
}

pub fn setRdpBuffer(self: *CommandBuffer, current: u32, start: u32, sentinel: u32) void {
    self.writeRawCommand(@intFromEnum(InternalCommand.rdp_set_buffer), current, &.{ start, sentinel });
}

pub fn appendRdpBuffer(self: *CommandBuffer, current: u32) void {
    self.writeRawCommand(@intFromEnum(InternalCommand.rdp_append_buffer), current, &.{});
}

pub fn call(self: *CommandBuffer, block: *const CommandBuffer) void {
    if (!block.sealed) @panic("RSP command block must end with returnFromCall()");
    if (block.call_target != null) @panic("nested RSP command blocks are not supported yet");
    if (self.call_target != null and self.call_target != block) {
        @panic("minimal RSP command queues support one call target");
    }
    const target: u32 = @truncate((@intFromPtr(block.buffer.ptr) & 0x1fffffff) & 0x00ffffff);
    self.writeRawCommand(@intFromEnum(InternalCommand.call), target, &.{0});
    self.call_target = block;
}

/// Call an immutable command block whose cache coherency is managed by
/// its owner. Unlike `call`, this does not attach the block to the queue's
/// one-target command graph and is suitable for resident streaming queues
/// which may invoke many independently recorded blocks.
pub fn callStatic(self: *CommandBuffer, block: *const CommandBuffer) void {
    if (!block.sealed) @panic("RSP command block must end with returnFromCall()");
    const target: u32 = @truncate((@intFromPtr(block.buffer.ptr) & 0x1fffffff) & 0x00ffffff);
    self.writeRawCommand(@intFromEnum(InternalCommand.call), target, &.{0});
}

pub fn callIndirect(self: *CommandBuffer, block: *const CommandBuffer, dmem_address: u32) void {
    if (!block.sealed) @panic("RSP command block must end with returnFromCall()");
    if (block.call_target != null) @panic("nested RSP command blocks are not supported yet");
    if (dmem_address & 3 != 0 or dmem_address > io.dmem_len - @sizeOf(u32)) {
        @panic("RSP indirect call DMEM address is invalid");
    }
    if (self.call_target != null and self.call_target != block) {
        @panic("minimal RSP command queues support one call target");
    }
    self.writeRawCommand(@intFromEnum(InternalCommand.call), dmem_address, &.{0x80000000});
    self.call_target = block;
}

pub fn returnFromCall(self: *CommandBuffer) void {
    if (self.sealed) return;
    self.writeRawCommand(@intFromEnum(InternalCommand.ret), 0, &.{});
    while (self.index < self.buffer.len) : (self.index += 1) self.buffer[self.index] = 0;
    self.sealed = true;
}

pub fn swapBuffers(self: *CommandBuffer, alternate: *const CommandBuffer, status: u32) void {
    if (!alternate.sealed) @panic("alternate RSP command queue must be sealed");
    self.writeRawCommand(@intFromEnum(InternalCommand.swap_buffers), 9 * 4, &.{ 8 * 4, status });
    self.swap_target = alternate;
}

pub fn swapBuffersToCaller(self: *CommandBuffer, status: u32) void {
    self.writeRawCommand(@intFromEnum(InternalCommand.swap_buffers), 8 * 4, &.{ 9 * 4, status });
}

pub fn stop(self: *CommandBuffer) void {
    if (self.sealed) {
        return;
    }

    self.buffer[self.index] = @as(u32, @intFromEnum(InternalCommand.invalid)) << 24;
    self.index += 1;
    while (self.index < self.buffer.len) : (self.index += 1) {
        self.buffer[self.index] = 0;
    }
    self.sealed = true;
}

pub fn jump(self: *CommandBuffer, next: *const CommandBuffer) void {
    const full_physical_address = @intFromPtr(next.buffer.ptr) & 0x1fffffff;
    const physical_address: u32 = @truncate(full_physical_address & 0x00ffffff);
    self.writeRawCommand(@intFromEnum(InternalCommand.jump), physical_address, &.{});
    self.sealed = true;
    self.next = next;
}

pub const QueueStorage = struct {
    // The resident dispatcher fetches a complete 256-byte window at a time.
    // Keep both the base and stride on that boundary so code/data layout
    // changes cannot alter which neighboring cache lines a fetch observes.
    buffers: [2][rdram_buffer_word_count]u32 align(fetch_window_byte_len),
    queues: [2]CommandBuffer,
    write_index: u1,
    submitted: bool,
    syncpoint_pending: bool,

    pub fn init(self: *QueueStorage) void {
        self.queues[0] = CommandBuffer.init(self.buffers[0][0..]);
        self.queues[1] = CommandBuffer.init(self.buffers[1][0..]);
        self.write_index = 0;
        self.submitted = false;
        self.syncpoint_pending = false;
    }

    pub fn writeDmem(self: *QueueStorage, offset: u32, value: u32) void {
        self.queues[self.write_index].writeDmem(offset, value);
    }
};
