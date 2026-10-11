const std = @import("std");
pub const max_size = 78 * 1024 * 1024;

pub fn normalize(bytes: []u8) !void {
    try validateSize(bytes.len);
    const magic = std.mem.readInt(u32, bytes[0..4], .big);
    switch (magic) {
        0x80371240 => {},
        0x37804012 => swapWords(u16, bytes),
        0x40123780 => swapWords(u32, bytes),
        else => return error.InvalidRomHeader,
    }
}

fn validateSize(len: usize) !void {
    if (len < 4096) return error.RomTooSmall;
    if (len > max_size) return error.RomTooLarge;
    if (len % 4 != 0) return error.UnalignedRom;
}

fn swapWords(comptime T: type, bytes: []u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += @sizeOf(T)) {
        const word = bytes[offset..][0..@sizeOf(T)];
        std.mem.writeInt(T, word, std.mem.readInt(T, word, .little), .big);
    }
}

test "normalize all three N64 byte orders and reject malformed ROMs" {
    var original: [4096]u8 = @splat(0);
    original[0..8].* = .{ 0x80, 0x37, 0x12, 0x40, 1, 2, 3, 4 };
    var bytes = original;
    try normalize(&bytes);
    try std.testing.expectEqualSlices(u8, &original, &bytes);
    swapWords(u16, &bytes);
    try normalize(&bytes);
    try std.testing.expectEqualSlices(u8, &original, &bytes);
    swapWords(u32, &bytes);
    try normalize(&bytes);
    try std.testing.expectEqualSlices(u8, &original, &bytes);
    try std.testing.expectError(error.RomTooSmall, normalize(bytes[0..5]));
    bytes[0] = 0;
    try std.testing.expectError(error.InvalidRomHeader, normalize(&bytes));
    var odd: [4097]u8 = @splat(0);
    try std.testing.expectError(error.UnalignedRom, normalize(&odd));
}
