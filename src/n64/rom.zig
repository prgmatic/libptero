//! ROM-only payloads are appended after all ELF load segments. Generated
//! handles contain relative offsets and logical sizes, never RDRAM pointers.
pub const Slot = @import("rom/slot.zig").Slot;
pub const Scheduler = @import("rom/scheduler.zig").Scheduler;
const scheduling = @import("rom/scheduler.zig");
const std = @import("std");
const pi = @import("pi/Transfer.zig");
pub export var __rom_assets_rom_offset: u32 = 0xffffffff;
pub export var __rom_assets_rom_size: u32 = 0xffffffff;
pub const Region = @import("rom/Region.zig");

pub const Asset = @import("rom/asset.zig").Asset;
pub const LoadedAsset = @import("rom/asset.zig").LoadedAsset;
pub const Priority = scheduling.Priority;

/// Reads arbitrary byte ranges using an owned aligned staging buffer. Keep the
/// Reader and destination stable until poll/wait returns completion. Timeouts
/// retain the operation; call wait again before reuse or destroying storage.
/// Call outside interrupts; other readers may progress between DMA chunks.
pub const Reader = @import("rom/Reader.zig");
test "logical asset bounds reject overflow and allow empty end reads" {
    const asset: Region = .{ .offset = 16, .size = 19 };
    try asset.validateRange(19, 0);
    try asset.validateRange(1, 18);
    try std.testing.expectError(error.AssetOutOfBounds, asset.validateRange(20, 0));
    try std.testing.expectError(error.AssetOutOfBounds, asset.validateRange(0, std.math.maxInt(usize)));
    try std.testing.expectError(error.AssetOutOfBounds, asset.validateRange(std.math.maxInt(u32), 1));
}

test {
    _ = scheduling;
    _ = @import("rom/slot.zig");
    _ = @import("rom/asset.zig");
}
