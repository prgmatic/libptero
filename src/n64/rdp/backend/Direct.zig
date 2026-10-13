const io = @import("../../hw/dp.zig");
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

const Direct = @This();
buffer: []u64,
index: usize = 0,

pub fn push(self: *Direct, value: u64) void {
    if (self.index >= self.buffer.len) @panic("RDP Queue Full");
    self.buffer[self.index] = value;
    self.index += 1;
}

pub fn execute(self: *Direct) void {
    if (self.index == 0) return;
    const commands = self.buffer[0..self.index];
    cache.writebackData(commands);
    const addr: u32 = @intFromPtr(self.buffer.ptr) & 0xFFFFFF;
    io.status_write.* = 1;
    io.dma_start_addr.* = addr;
    io.dma_end_addr.* = addr + @sizeOf(u64) * commands.len;
}

pub fn clear(self: *Direct) void {
    self.index = 0;
}
