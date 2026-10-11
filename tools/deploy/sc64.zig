//! SC64 USB commands and asynchronous debug packets (firmware 2.20+).
const std = @import("std");
const wire = @import("packet.zig");
const Stream = @import("stream.zig").Stream;
const cic = @import("cic.zig");
pub const max_rom_size = 78 * 1024 * 1024;
const sdram_size = 64 * 1024 * 1024;
const shadow_size = 128 * 1024;

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: Stream,
    pending_text: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Client) void {
        self.pending_text.deinit(self.allocator);
    }

    pub fn connect(self: *Client) !void {
        try self.stream.resetSc64();
        const identity = try self.command('v', 0, 0, &.{});
        if (!std.mem.eql(u8, identity.slice(), "SCv2")) return error.NotSc64;
        const version = try self.command('V', 0, 0, &.{});
        try checkVersion(version.slice());
    }

    pub fn upload(self: *Client, rom: []const u8, save_type: u32, seed: ?u8) !void {
        if (rom.len > max_rom_size) return error.RomTooLarge;
        if (rom.len < 4096) return error.RomTooSmall;
        _ = try self.command('R', 0, 0, &.{});
        try self.uploadMemory(rom);
        try self.configure(save_type, cic.sign(rom[0x40..0x1000], seed));
    }

    fn configure(self: *Client, save_type: u32, signature: cic.Signature) !void {
        _ = try self.command('C', 6, save_type, &.{});
        _ = try self.command('C', 5, 3, &.{}); // direct ROM boot
        const high = (@as(u32, signature.seed) << 16) | @as(u32, @intCast(signature.checksum >> 32));
        _ = try self.command('B', high, @truncate(signature.checksum), &.{});
    }

    fn uploadMemory(self: *Client, rom: []const u8) !void {
        const main_end = @min(rom.len, sdram_size - shadow_size);
        try self.writeMemory(0, rom[0..main_end]);
        _ = try self.command('C', 2, @intFromBool(rom.len > main_end), &.{});
        if (rom.len > main_end) try self.programFlash(0x04fe0000, rom[main_end..@min(rom.len, sdram_size)]);
        _ = try self.command('C', 14, @intFromBool(rom.len > sdram_size), &.{});
        if (rom.len > sdram_size) try self.programFlash(0x04000000, rom[sdram_size..]);
    }

    pub fn writeMemory(self: *Client, base: u32, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const chunk = bytes[offset..@min(bytes.len, offset + 1024 * 1024)];
            _ = try self.command('M', base + @as(u32, @intCast(offset)), @intCast(chunk.len), chunk);
            offset += chunk.len;
        }
    }

    pub fn programFlash(self: *Client, base: u32, bytes: []const u8) !void {
        const reply = try self.command('p', 0, 0, &.{});
        const block_size = try flashBlockSize(reply.slice());
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += block_size) {
            _ = try self.command('P', base + @as(u32, @intCast(offset)), 0, &.{});
        }
        try self.writeMemory(base, bytes);
        _ = try self.command('p', 1, 0, &.{});
    }

    pub fn command(self: *Client, id: u8, first: u32, second: u32, data: []const u8) !Reply {
        try self.stream.writeAll(&wire.sc64Command(id, first, second));
        try self.stream.writeAll(data);
        const deadline = self.stream.now() + 5000;
        while (true) {
            try self.stream.checkDeadline(deadline);
            const packet = (try self.receive(true)).?;
            defer self.allocator.free(packet.data);
            if (packet.kind == .notification) {
                try self.queueText(packet);
                continue;
            }
            return response(packet, id);
        }
    }

    fn queueText(self: *Client, packet: wire.Packet) !void {
        if (packet.id != 'U') return;
        const debug = try wire.debug(packet.data);
        if (debug.datatype != 1) return;
        if (self.pending_text.items.len + debug.data.len > 1024 * 1024) return error.DebugQueueFull;
        try self.pending_text.appendSlice(self.allocator, std.mem.trimEnd(u8, debug.data, "\x00"));
    }

    pub fn receive(self: *Client, block: bool) !?wire.Packet {
        var header: [8]u8 = undefined;
        const n = try self.stream.read(&header);
        if (n == 0 and !block) return null;
        try self.stream.readExact(header[n..], self.stream.now() + 5000);
        const decoded = try wire.sc64Header(&header);
        if (decoded.size > 0x1000000) return error.PacketTooLarge;
        const data = try self.allocator.alloc(u8, decoded.size);
        errdefer self.allocator.free(data);
        try self.stream.readExact(data, self.stream.now() + 5000);
        return .{ .kind = decoded.kind, .id = decoded.id, .data = data };
    }
};

pub const Reply = struct {
    buffer: [16]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Reply) []const u8 {
        return self.buffer[0..self.len];
    }
};
fn response(packet: wire.Packet, id: u8) !Reply {
    if (packet.id != id) return error.UnexpectedResponse;
    if (packet.kind == .failure) return error.Sc64CommandFailed;
    if (packet.data.len > 16) return error.InvalidResponse;
    var result: Reply = .{ .len = packet.data.len };
    @memcpy(result.buffer[0..result.len], packet.data);
    return result;
}
fn checkVersion(bytes: []const u8) !void {
    if (bytes.len != 8) return error.InvalidResponse;
    if (std.mem.readInt(u16, bytes[0..2], .big) != 2) return error.UnsupportedFirmware;
    if (std.mem.readInt(u16, bytes[2..4], .big) < 20) return error.UnsupportedFirmware;
}
fn flashBlockSize(bytes: []const u8) !u32 {
    if (bytes.len != 4) return error.InvalidResponse;
    const size = std.mem.readInt(u32, bytes[0..4], .big);
    if (size == 0 or size > shadow_size) return error.InvalidFlashBlockSize;
    return size;
}

test "SC64 connection, upload and interleaved debug preserve command boundaries" {
    const Fake = @import("stream.zig").Fake;
    var fake: Fake = .{ .input = "CMPv\x00\x00\x00\x04SCv2CMPV\x00\x00\x00\x08\x00\x02\x00\x14\x00\x00\x00\x00" ++
        "CMPR\x00\x00\x00\x00PKTU\x00\x00\x00\x07\x01\x00\x00\x03hi\nCMPM\x00\x00\x00\x00" ++
        "CMPC\x00\x00\x00\x00" ** 4 ++ "CMPB\x00\x00\x00\x00" };
    defer fake.deinit();
    var client: Client = .{ .allocator = std.testing.allocator, .stream = fake.stream() };
    defer client.deinit();
    try client.connect();
    const rom: [4096]u8 = @splat(0);
    try client.upload(&rom, 0, null);
    try std.testing.expectEqualStrings("hi\n", client.pending_text.items);
    try std.testing.expectEqual(fake.input.len, fake.cursor);
    try std.testing.expectEqualSlices(u8, &wire.sc64Command('M', 0, 4096), fake.output.items[36..48]);
    try std.testing.expectEqual(null, try client.receive(false));
    try std.testing.expectError(error.RomTooSmall, client.upload("bad", 0, null));
}

test "SC64 flash erase and write sequence and protocol failures" {
    var fake: @import("stream.zig").Fake = .{ .input = "CMPp\x00\x00\x00\x04\x00\x01\x00\x00CMPP\x00\x00\x00\x00CMPM\x00\x00\x00\x00CMPp\x00\x00\x00\x04\x00\x01\x00\x00" };
    defer fake.deinit();
    var client: Client = .{ .allocator = std.testing.allocator, .stream = fake.stream() };
    defer client.deinit();
    try client.programFlash(0x04fe0000, "abcd");
    try std.testing.expectEqualSlices(u8, &wire.sc64Command('P', 0x04fe0000, 0), fake.output.items[12..24]);
    try std.testing.expectError(error.UnsupportedFirmware, checkVersion("\x00\x02\x00\x13\x00\x00\x00\x00"));
    try std.testing.expectError(error.InvalidResponse, checkVersion("bad"));
    try std.testing.expectError(error.InvalidFlashBlockSize, flashBlockSize("\x00\x00\x00\x00"));
    try std.testing.expectError(error.Sc64CommandFailed, response(.{ .kind = .failure, .id = 'M', .data = &.{} }, 'M'));
    try std.testing.expectError(error.UnexpectedResponse, response(.{ .kind = .response, .id = 'M', .data = &.{} }, 'v'));
}
