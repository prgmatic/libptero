//! ROM-only payloads are appended after all ELF load segments. Generated
//! handles contain relative offsets and logical sizes, never RDRAM pointers.
const std = @import("std");
const pi = @import("io/pi.zig");
pub export var __rom_assets_rom_offset: u32 = 0xffffffff;
pub export var __rom_assets_rom_size: u32 = 0xffffffff;
pub const Asset = struct {
    offset: u32,
    size: u32,
    pub fn validateRange(self: Asset, offset: u32, length: usize) !void {
        if (offset > self.size or length > self.size - offset) return error.AssetOutOfBounds;
    }
};

/// Reads arbitrary byte ranges using an owned aligned staging buffer. Keep the
/// Reader and destination stable until poll/wait returns completion. Timeouts
/// retain the operation; call wait again before reuse or destroying storage.
/// Call outside interrupts; other readers may progress between DMA chunks.
pub const Reader = struct {
    staging: [4096]u8 align(16) = undefined,
    transfer: pi.Transfer = .{},
    destination: ?[]u8 = null,
    rom_offset: u32 = 0,
    copied: usize = 0,
    chunk: usize = 0,
    leading: usize = 0,
    bytes_read: u64 = 0,
    transfers: u64 = 0,

    pub fn begin(self: *Reader, asset: Asset, offset: u32, destination: []u8) !void {
        if (self.destination != null) return error.ReaderBusy;
        try asset.validateRange(offset, destination.len);
        if (__rom_assets_rom_offset == 0xffffffff or __rom_assets_rom_size == 0xffffffff) return error.RomAssetsUnavailable;
        if (__rom_assets_rom_offset % 16 != 0 or @as(u64, __rom_assets_rom_offset) + __rom_assets_rom_size > 64 * 1024 * 1024) return error.InvalidAsset;
        if (asset.offset % 16 != 0 or @as(u64, asset.offset) + std.mem.alignForward(u64, asset.size, 16) > __rom_assets_rom_size) return error.InvalidAsset;
        self.rom_offset = __rom_assets_rom_offset + asset.offset + offset;
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
    pub fn read(self: *Reader, asset: Asset, offset: u32, destination: []u8, max_attempts: u32) !void {
        try self.begin(asset, offset, destination);
        try self.wait(max_attempts);
    }
};
test "logical asset bounds reject overflow and allow empty end reads" {
    const asset: Asset = .{ .offset = 16, .size = 19 };
    try asset.validateRange(19, 0);
    try asset.validateRange(1, 18);
    try std.testing.expectError(error.AssetOutOfBounds, asset.validateRange(20, 0));
    try std.testing.expectError(error.AssetOutOfBounds, asset.validateRange(0, std.math.maxInt(usize)));
    try std.testing.expectError(error.AssetOutOfBounds, asset.validateRange(std.math.maxInt(u32), 1));
}
