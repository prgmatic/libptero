const io = @import("io.zig");
const Overlay = @import("overlay.zig").Overlay;

pub const batch_word_count = 16;

pub const CommandQueue = struct {
    buffer: *align(8) [batch_word_count]u32,
    index: usize,
    stopped: bool,

    pub fn init(buffer: *align(8) [batch_word_count]u32) CommandQueue {
        var queue = CommandQueue{
            .buffer = buffer,
            .index = 0,
            .stopped = false,
        };
        queue.clear();
        return queue;
    }

    pub fn clear(self: *CommandQueue) void {
        @memset(self.buffer[0..], 0);
        self.index = 0;
        self.stopped = false;
    }

    pub fn writeDmem(self: *CommandQueue, offset: u32, value: u32) void {
        if (offset & 3 != 0 or offset > io.dmem_len - @sizeOf(u32)) {
            @panic("RSP command queue DMEM offset is invalid");
        }
        self.writeCommand(0x01, offset, &.{value});
    }

    pub fn writeCommand(
        self: *CommandQueue,
        command_id: u8,
        inline_argument: u32,
        arguments: []const u32,
    ) void {
        if (self.stopped) {
            @panic("cannot append to a stopped RSP command queue");
        }
        if (inline_argument > 0x00ffffff) {
            @panic("RSP command queue inline argument is too large");
        }
        if (arguments.len > 3) {
            @panic("RSP command queue supports at most three argument words");
        }
        const command_words = 1 + arguments.len;
        if (self.index + command_words >= self.buffer.len) {
            @panic("RSP command queue is full");
        }

        self.buffer[self.index] = @as(u32, command_id) << 24 | inline_argument;
        @memcpy(self.buffer[self.index + 1 ..][0..arguments.len], arguments);
        self.index += command_words;

        // Keep a STOP after the last complete command while the queue is open.
        self.buffer[self.index] = 0;
    }

    pub fn writeOverlay(
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
        self.writeCommand(registered.commandId(command_index), inline_argument, arguments);
    }

    pub fn stop(self: *CommandQueue) void {
        if (self.stopped) {
            return;
        }

        self.buffer[self.index] = 0;
        self.index += 1;
        while (self.index < self.buffer.len) : (self.index += 1) {
            self.buffer[self.index] = 0;
        }
        self.stopped = true;
    }

    pub fn isStopped(self: *const CommandQueue) bool {
        return self.stopped;
    }

    pub fn words(self: *const CommandQueue) []const u32 {
        return self.buffer[0..];
    }
};
