const std = @import("std");
const rom = @import("../rom.zig");

const Region = @This();

offset: u32,
size: u32,
pub fn validateRange(self: Region, offset: u32, length: usize) !void {
    if (offset > self.size or length > self.size - offset) return error.AssetOutOfBounds;
}

/// Absolute cartridge offset, including validation of the padded DMA tail.
pub fn romOffset(self: Region) !u32 {
    if (rom.__rom_assets_rom_offset == 0xffffffff or rom.__rom_assets_rom_size == 0xffffffff) return error.RomAssetsUnavailable;
    if (rom.__rom_assets_rom_offset % 16 != 0 or @as(u64, rom.__rom_assets_rom_offset) + rom.__rom_assets_rom_size > 64 * 1024 * 1024) return error.InvalidAsset;
    if (self.offset % 16 != 0 or @as(u64, self.offset) + std.mem.alignForward(u64, self.size, 16) > rom.__rom_assets_rom_size) return error.InvalidAsset;
    return rom.__rom_assets_rom_offset + self.offset;
}
