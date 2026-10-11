//! EverDrive 3.0 and X7 USB text output. USB-less X5/2.5 carts are rejected.
const std = @import("std");
const pi = @import("../interfaces/parallel.zig");
const config: usize = 0xbf800004;

fn read(address: usize) u32 {
    pi.waitIo();
    return @as(*volatile u32, @ptrFromInt(address)).*;
}
fn write(address: usize, value: u32) void {
    pi.waitIo();
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}
pub fn detect() bool {
    write(0xbf808004, 0xaa55);
    if (!supportedVersion(read(0xbf800014))) return false;
    write(0xbf808000, 0);
    write(config, 0xc400);
    return read(config) & 0x1000 != 0;
}
fn supportedVersion(version: u32) bool {
    return version == 0xed640008 or version == 0xed640013;
}

pub fn print(text: []const u8) void {
    var offset: usize = 0;
    while (offset < text.len) {
        const chunk = text[offset..@min(text.len, offset + 499)];
        var buffer: [512]u8 = undefined;
        const packet = encode(&buffer, chunk);
        if (!send(packet)) return;
        offset += chunk.len;
    }
}

fn send(packet: []const u8) bool {
    if (!waitReady()) return false;
    const start = 512 - packet.len;
    write(config, 0xc000);
    var i: usize = 0;
    while (i < packet.len) : (i += 4) {
        write(0xbf800400 + start + i, std.mem.readInt(u32, packet[i..][0..4], .big));
    }
    write(config, 0xc200 | @as(u32, @intCast(start)));
    return waitReady();
}

fn waitReady() bool {
    var attempts: u32 = 1_000_000;
    while (read(config) & 0x0200 != 0) {
        if (attempts == 0) {
            write(config, 0xc400);
            return false;
        }
        attempts -= 1;
    }
    return true;
}

// Text packets are NUL padded so all MMIO writes remain word aligned.
// The host strips trailing NULs before forwarding the text stream.
pub fn encode(buffer: *[512]u8, text: []const u8) []const u8 {
    std.debug.assert(text.len <= 499);
    const size = std.mem.alignForward(usize, text.len + 1, 4);
    @memset(buffer, 0);
    buffer[0..4].* = "DMA@".*;
    std.mem.writeInt(u32, buffer[4..8], 0x01000000 | @as(u32, @intCast(size)), .big);
    @memcpy(buffer[8..][0..text.len], text);
    buffer[8 + size ..][0..4].* = "CMPH".*;
    return buffer[0 .. size + 12];
}

test "EverDrive text frames fit hardware buffer and use supported models" {
    try std.testing.expect(supportedVersion(0xed640008));
    try std.testing.expect(supportedVersion(0xed640013));
    try std.testing.expect(!supportedVersion(0xed640007));
    var buffer: [512]u8 = undefined;
    const packet = encode(&buffer, "abc");
    try std.testing.expectEqualStrings("DMA@\x01\x00\x00\x04abc\x00CMPH", packet);
    try std.testing.expectEqual(@as(usize, 512), encode(&buffer, &(@as([499]u8, @splat('x')))).len);
}
