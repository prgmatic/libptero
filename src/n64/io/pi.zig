//! Cache-line-owned, bounded cartridge DMA. Keep Transfer and its destination
//! stable until completion; a timeout does not release either resource.
const std = @import("std");
const raw = @import("../interfaces/parallel.zig");
const cache = @import("../cpu/cache.zig");
const cp0 = @import("../cpu/cp0.zig");
var owner: ?*Transfer = null;
pub const Transfer = struct {
    destination: ?[]align(16) u8 = null,

    pub fn begin(self: *Transfer, rom_offset: u32, destination: []align(16) u8) !void {
        if (self.destination != null) return error.TransferBusy;
        try validate(rom_offset, destination.len);
        const address = @intFromPtr(destination.ptr);
        if ((address & 0xe0000000 != 0x80000000 and address & 0xe0000000 != 0xa0000000) or (address & 0x1fffffff) + destination.len > 8 * 1024 * 1024) return error.InvalidRdramAddress;
        const status = cp0.regRead(.Status);
        cp0.regWrite(.Status, status & ~@as(u32, 1));
        defer cp0.regWrite(.Status, status);
        if (owner != null or raw.readStatus() & 3 != 0) return error.PiBusy;
        // PI error is sticky across earlier raw/boot accesses. Reset only an
        // idle controller before acquiring it; never abort another transfer.
        if (raw.readStatus() & 4 != 0) raw.writeStatus(1);
        cache.writebackData(destination);
        cache.invalidateData(destination);
        self.destination = destination;
        owner = self;
        raw.dmaToDram(@intCast(address & 0x1fffffff), 0x10000000 + rom_offset, @intCast(destination.len - 1));
    }

    pub fn poll(self: *Transfer) !bool {
        const destination = self.destination orelse return true;
        if (raw.readStatus() & 3 != 0) return false;
        const failed = raw.readStatus() & 4 != 0;
        cache.invalidateData(destination);
        raw.writeStatus(2); // acknowledge PI completion without resetting it
        self.destination = null;
        owner = null;
        if (failed) return error.PiError;
        return true;
    }

    pub fn wait(self: *Transfer, max_attempts: u32) !void {
        var remaining = max_attempts;
        while (!try self.poll()) {
            if (remaining == 0) return error.PiTimeout;
            remaining -= 1;
        }
    }
};
fn validate(offset: u32, length: usize) !void {
    if (length == 0 or length % 16 != 0 or offset % 16 != 0) return error.InvalidDmaAlignment;
    if (length > 0x1000000 or @as(u64, offset) + length > 64 * 1024 * 1024) return error.InvalidRomRange;
}
test "DMA checks aligned cache ownership and cartridge limits" {
    try validate(0, 16);
    try validate(64 * 1024 * 1024 - 16, 16);
    try std.testing.expectError(error.InvalidDmaAlignment, validate(1, 16));
    try std.testing.expectError(error.InvalidDmaAlignment, validate(0, 15));
    try std.testing.expectError(error.InvalidDmaAlignment, validate(0, 0));
    try std.testing.expectError(error.InvalidRomRange, validate(64 * 1024 * 1024, 16));
    try std.testing.expectError(error.InvalidRomRange, validate(0, 0x1000010));
}
