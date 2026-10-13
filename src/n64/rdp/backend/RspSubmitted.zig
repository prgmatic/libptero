const std = @import("std");
const cache = @import("../../cpu/cache.zig");
const rsp = @import("../../rsp.zig");
const BitDepth = @import("../../graphics/pixel.zig").BitDepth;
const cc = @import("../combiner.zig");
const blender = @import("../blender.zig");
const modes = @import("../modes.zig");

const CombineMode = cc.CombineMode;
const OtherModes = modes.OtherModes;
const Rgba32 = @import("../../graphics/pixel.zig").Rgba32;

const RspSubmitted = @This();
buffer: []align(8) u64,
dynamic_buffers: [2][]align(16) u8,
rsp_queue: *rsp.Queue,
index: usize = 0,
configured: bool = false,

pub fn init(
    rsp_queue: *rsp.Queue,
    buffer: []align(8) u64,
    dynamic_buffers: [2][]align(16) u8,
) RspSubmitted {
    if (buffer.len == 0) @panic("RSP-backed RDP queue buffer must not be empty");
    if (dynamic_buffers[0].len != rsp.rdp_dynamic_buffer_len or
        dynamic_buffers[1].len != rsp.rdp_dynamic_buffer_len)
    {
        @panic("RSP-backed RDP dynamic buffers must each be 64 KiB");
    }
    return .{
        .buffer = buffer,
        .dynamic_buffers = dynamic_buffers,
        .rsp_queue = rsp_queue,
    };
}

pub fn push(self: *RspSubmitted, value: u64) void {
    if (self.index >= self.buffer.len) @panic("RSP-backed RDP queue is full");
    self.buffer[self.index] = value;
    self.index += 1;
}

pub fn execute(self: *RspSubmitted) void {
    if (self.index == 0) return;
    if (!self.configured) {
        self.rsp_queue.configureRdpBuffers(self.dynamic_buffers[0], self.dynamic_buffers[1]);
        self.configured = true;
    }
    const commands = self.buffer[0..self.index];
    cache.writebackData(commands);
    const start: u32 = @truncate(@intFromPtr(commands.ptr) & 0x00ffffff);
    const end = start + @as(u32, @intCast(commands.len * @sizeOf(u64)));
    self.rsp_queue.setRdpBuffer(end, start, end);
    rsp.flush(self.rsp_queue);
}

pub fn clear(self: *RspSubmitted) void {
    self.index = 0;
}
