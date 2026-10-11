//! EverDrive 3.0 / X7 upload and USB+Debug v2 framing, as documented by UNFLoader.
const std = @import("std");
const wire = @import("packet.zig");
const Stream = @import("stream.zig").Stream;
pub const max_rom_size = 64 * 1024 * 1024;

pub fn connect(stream: Stream) !void {
    try stream.writeAll(&wire.everdriveCommand('t', 0, 0));
    var reply: [16]u8 = undefined;
    try stream.readExact(&reply, stream.now() + 2000);
    if (reply[3] != 'r') return error.EverDriveMenuNotReady;
}

pub fn upload(stream: Stream, rom: []const u8) !void {
    if (rom.len > max_rom_size) return error.RomTooLarge;
    if (rom.len < 4096) return error.RomTooSmall;
    const padded = std.mem.alignForward(u32, @intCast(rom.len), 512);
    if (padded < 0x101000) try stream.writeAll(&wire.everdriveCommand('c', 0x10000000, 0x101000));
    try stream.writeAll(&wire.everdriveCommand('W', 0x10000000, padded));
    try uploadBytes(stream, rom, padded);
    try stream.sleep(500); // Required by the EverDrive OS before the PIF boot command.
    try stream.writeAll(&wire.everdriveCommand('s', 0, 0));
}

fn uploadBytes(stream: Stream, rom: []const u8, padded: usize) !void {
    var offset: usize = 0;
    while (offset < rom.len) {
        const chunk = rom[offset..@min(rom.len, offset + 0x8000)];
        try stream.writeAll(chunk);
        offset += chunk.len;
    }
    const zeros: [512]u8 = @splat(0);
    try stream.writeAll(zeros[0 .. padded - rom.len]);
}

/// Send a zero-terminated, bounded save name after a boot using an ED save header.
pub fn sendSaveName(stream: Stream, path: []const u8) !void {
    var name: [256]u8 = @splat(0);
    const stem = std.fs.path.stem(path);
    const n = @min(stem.len, name.len - 1);
    @memcpy(name[0..n], stem[0..n]);
    try stream.writeAll(&name);
}

pub fn receive(allocator: std.mem.Allocator, stream: Stream) !?wire.Debug {
    var header: [8]u8 = undefined;
    const n = try stream.read(&header);
    if (n == 0) return null;
    try stream.readExact(header[n..], stream.now() + 5000);
    if (!std.mem.eql(u8, header[0..4], "DMA@")) return error.InvalidEverDrivePacket;
    const size = std.mem.readInt(u32, header[4..8], .big) & 0xffffff;
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    try stream.readExact(data, stream.now() + 5000);
    try readTrailer(stream, size);
    return .{ .datatype = header[4], .data = data };
}

fn readTrailer(stream: Stream, size: usize) !void {
    var trailer: [5]u8 = undefined;
    try stream.readExact(trailer[0 .. 4 + size % 2], stream.now() + 5000);
    if (!std.mem.eql(u8, trailer[0..4], "CMPH")) return error.InvalidEverDriveTrailer;
}

test "EverDrive probes, pads uploads, delays boot and bounds save names" {
    var fake: @import("stream.zig").Fake = .{ .input = "cmdr" ++ "\x00" ** 12, .fragment = 71 };
    defer fake.deinit();
    const stream = fake.stream();
    try connect(stream);
    const rom: [4100]u8 = @splat(0x55);
    try upload(stream, &rom);
    try sendSaveName(stream, "/games/example.z64");
    try std.testing.expectEqualSlices(u8, &wire.everdriveCommand('W', 0x10000000, 4608), fake.output.items[32..48]);
    try std.testing.expectEqualSlices(u8, &rom, fake.output.items[48..4148]);
    try std.testing.expectEqual(@as(u8, 0), fake.output.items[4148]);
    try std.testing.expectEqualStrings("example", fake.output.items[4672..4679]);
    try std.testing.expect(fake.clock >= 500);
    try std.testing.expectError(error.RomTooSmall, upload(stream, "tiny"));
}

test "EverDrive receives odd-size debug packets and rejects corrupt trailer" {
    var fake: @import("stream.zig").Fake = .{ .input = "DMA@\x01\x00\x00\x03abcCMPH\x00DMA@\x01\x00\x00\x00oops" };
    defer fake.deinit();
    const packet = (try receive(std.testing.allocator, fake.stream())).?;
    defer std.testing.allocator.free(packet.data);
    try std.testing.expectEqualStrings("abc", packet.data);
    try std.testing.expectError(error.InvalidEverDriveTrailer, receive(std.testing.allocator, fake.stream()));
    try std.testing.expectEqual(null, try receive(std.testing.allocator, fake.stream()));
}
