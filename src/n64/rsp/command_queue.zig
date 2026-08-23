const io = @import("io.zig");
const Overlay = @import("overlay.zig").Overlay;

pub const fetch_window_byte_len = 0x100;
pub const batch_word_count = fetch_window_byte_len / @sizeOf(u32);
pub const rdram_buffer_word_count = 0x140;

comptime {
    if (rdram_buffer_word_count % batch_word_count != 0) {
        @compileError("resident queue buffer stride must preserve fetch-window alignment");
    }
}

pub const InternalCommand = enum(u8) {
    invalid = 0x00,
    write_word = 0x01,
    jump = 0x02,
    call = 0x03,
    ret = 0x04,
    dma = 0x05,
    write_status = 0x06,
    swap_buffers = 0x07,
    wait_then_write_status = 0x08,
    rdp_set_buffer = 0x09,
    rdp_append_buffer = 0x0a,
    rdp_release_buffer = 0x0b,
    rdp_begin_batch = 0x0c,
};

pub const CommandQueue = struct {
    buffer: []align(8) u32,
    index: usize,
    sealed: bool,
    next: ?*const CommandQueue,
    call_target: ?*const CommandQueue,
    swap_target: ?*const CommandQueue,

    pub fn init(buffer: []align(8) u32) CommandQueue {
        var queue = CommandQueue{
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

    pub fn clear(self: *CommandQueue) void {
        @memset(self.buffer[0..], 0);
        self.index = 0;
        self.sealed = false;
        self.next = null;
        self.call_target = null;
        self.swap_target = null;
    }

    pub fn clearStreaming(self: *CommandQueue) void {
        // The resident dispatcher fetches a complete 256-byte window. Clear
        // that whole window before reuse so no stale command from the fetched
        // cache line can survive beyond the invalid guard.
        @memset(self.buffer[0..batch_word_count], 0);
        self.index = 0;
        self.sealed = false;
        self.next = null;
        self.call_target = null;
        self.swap_target = null;
    }

    pub fn writeDmem(self: *CommandQueue, offset: u32, value: u32) void {
        if (offset & 3 != 0 or offset > io.dmem_len - @sizeOf(u32)) {
            @panic("RSP command queue DMEM offset is invalid");
        }
        self.writeRawCommand(@intFromEnum(InternalCommand.write_word), offset, &.{value});
    }

    pub fn writeRawCommand(
        self: *CommandQueue,
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

        self.buffer[self.index] = @as(u32, command_id) << 24 | inline_argument;
        @memcpy(self.buffer[self.index + 1 ..][0..arguments.len], arguments);
        self.index += command_words;

        // Keep an invalid guard after the last complete command while open.
        self.buffer[self.index] = 0;
    }

    pub fn writeOverlayCommand(
        self: *CommandQueue,
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
        self: *CommandQueue,
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

    pub fn waitThenWriteStatus(self: *CommandQueue, mask: u32, status: u32) void {
        self.writeRawCommand(@intFromEnum(InternalCommand.wait_then_write_status), status, &.{mask});
    }

    pub fn setRdpBuffer(self: *CommandQueue, current: u32, start: u32, sentinel: u32) void {
        self.writeRawCommand(@intFromEnum(InternalCommand.rdp_set_buffer), current, &.{ start, sentinel });
    }

    pub fn appendRdpBuffer(self: *CommandQueue, current: u32) void {
        self.writeRawCommand(@intFromEnum(InternalCommand.rdp_append_buffer), current, &.{});
    }

    pub fn releaseRdpBuffer(self: *CommandQueue) void {
        self.writeRawCommand(@intFromEnum(InternalCommand.rdp_release_buffer), 0, &.{});
    }

    pub fn beginRdpBatch(self: *CommandQueue) void {
        self.writeRawCommand(@intFromEnum(InternalCommand.rdp_begin_batch), 0, &.{0});
    }

    pub fn call(self: *CommandQueue, block: *const CommandQueue) void {
        if (!block.sealed) @panic("RSP command block must end with returnFromCall()");
        if (block.call_target != null) @panic("nested RSP command blocks are not supported yet");
        if (self.call_target != null and self.call_target != block) {
            @panic("minimal RSP command queues support one call target");
        }
        const target: u32 = @truncate((@intFromPtr(block.buffer.ptr) & 0x1fffffff) & 0x00ffffff);
        self.writeRawCommand(@intFromEnum(InternalCommand.call), target, &.{0});
        self.call_target = block;
    }

    pub fn callIndirect(self: *CommandQueue, block: *const CommandQueue, dmem_address: u32) void {
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

    pub fn returnFromCall(self: *CommandQueue) void {
        if (self.sealed) return;
        self.writeRawCommand(@intFromEnum(InternalCommand.ret), 0, &.{});
        while (self.index < self.buffer.len) : (self.index += 1) self.buffer[self.index] = 0;
        self.sealed = true;
    }

    pub fn swapBuffers(self: *CommandQueue, alternate: *const CommandQueue, status: u32) void {
        if (!alternate.sealed) @panic("alternate RSP command queue must be sealed");
        self.writeRawCommand(@intFromEnum(InternalCommand.swap_buffers), 9 * 4, &.{ 8 * 4, status });
        self.swap_target = alternate;
    }

    pub fn swapBuffersToCaller(self: *CommandQueue, status: u32) void {
        self.writeRawCommand(@intFromEnum(InternalCommand.swap_buffers), 8 * 4, &.{ 9 * 4, status });
    }

    pub fn stop(self: *CommandQueue) void {
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

    pub fn jump(self: *CommandQueue, next: *const CommandQueue) void {
        const full_physical_address = @intFromPtr(next.buffer.ptr) & 0x1fffffff;
        const physical_address: u32 = @truncate(full_physical_address & 0x00ffffff);
        self.writeRawCommand(@intFromEnum(InternalCommand.jump), physical_address, &.{});
        self.sealed = true;
        self.next = next;
    }
};

pub const QueueStorage = struct {
    // The resident dispatcher fetches a complete 256-byte window at a time.
    // Keep both the base and stride on that boundary so code/data layout
    // changes cannot alter which neighboring cache lines a fetch observes.
    buffers: [2][rdram_buffer_word_count]u32 align(fetch_window_byte_len),
    queues: [2]CommandQueue,
    write_index: u1,
    submitted: bool,
    syncpoint_pending: bool,

    pub fn init(self: *QueueStorage) void {
        self.queues[0] = CommandQueue.init(self.buffers[0][0..]);
        self.queues[1] = CommandQueue.init(self.buffers[1][0..]);
        self.write_index = 0;
        self.submitted = false;
        self.syncpoint_pending = false;
    }

    pub fn writeDmem(self: *QueueStorage, offset: u32, value: u32) void {
        self.queues[self.write_index].writeDmem(offset, value);
    }
};
