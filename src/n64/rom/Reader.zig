const std = @import("std");
const pi = @import("../pi/Transfer.zig");
const Region = @import("Region.zig");

const Reader = @This();

staging: [4096]u8 align(16) = undefined,
transfer: pi = .{},
destination: ?[]u8 = null,
rom_offset: u32 = 0,
copied: usize = 0,
chunk: usize = 0,
leading: usize = 0,
bytes_read: u64 = 0,
transfers: u64 = 0,

pub fn begin(self: *Reader, asset: Region, offset: u32, destination: []u8) !void {
    if (self.destination != null) return error.ReaderBusy;
    try asset.validateRange(offset, destination.len);
    self.rom_offset = try asset.romOffset() + offset;
    self.destination = destination;
    self.copied = 0;
    self.chunk = 0;
}

pub fn poll(self: *Reader) !bool {
    const destination = self.destination orelse return true;
    if (self.chunk != 0) {
        const completed = self.transfer.poll() catch |err| {
            self.destination = null;
            self.chunk = 0;
            return err;
        };
        if (!completed) return false;
        @memcpy(destination[self.copied..][0..self.chunk], self.staging[self.leading..][0..self.chunk]);
        self.copied += self.chunk;
        self.bytes_read += self.chunk;
        self.chunk = 0;
    }
    if (self.copied == destination.len) {
        self.destination = null;
        return true;
    }
    const address = self.rom_offset + @as(u32, @intCast(self.copied));
    self.leading = address % 16;
    const chunk = @min(destination.len - self.copied, self.staging.len - self.leading);
    const length = std.mem.alignForward(usize, self.leading + chunk, 16);
    self.transfer.begin(address & ~@as(u32, 15), self.staging[0..length]) catch |err| {
        if (err == error.PiBusy) return false;
        self.destination = null;
        return err;
    };
    self.chunk = chunk;
    self.transfers += 1;
    return false;
}

pub fn wait(self: *Reader, max_attempts: u32) !void {
    var remaining = max_attempts;
    while (!try self.poll()) {
        if (remaining == 0) return error.PiTimeout;
        remaining -= 1;
    }
}
pub fn read(self: *Reader, asset: Region, offset: u32, destination: []u8, max_attempts: u32) !void {
    try self.begin(asset, offset, destination);
    try self.wait(max_attempts);
}
