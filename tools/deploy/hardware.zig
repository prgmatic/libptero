const std = @import("std");
const Options = @import("options.zig").Options;
const Stream = @import("stream.zig").Stream;
const sc64 = @import("sc64.zig");
const ed = @import("everdrive.zig");
const Relay = @import("relay.zig").Relay;
const Power = @import("power.zig").Session;

pub fn run(io: std.Io, a: std.mem.Allocator, options: Options, rom: []u8, power: ?*Power) !u8 {
    const serial = try serialString(a, options.serial);
    defer freeSerial(a, serial);
    var usb = try openUsb(io, options, serial);
    defer usb.close();
    if (options.target == .sc64) return runSc64(io, a, options, rom, usb.stream(), power);
    return runEverDrive(io, a, options, rom, usb.stream());
}
fn openUsb(io: std.Io, options: Options, serial: ?[:0]const u8) !@import("ftdi.zig").Device {
    return @import("ftdi.zig").Device.open(io, if (options.target == .sc64) .sc64 else .everdrive, serial, options.device_index);
}
fn serialString(a: std.mem.Allocator, serial: ?[]const u8) !?[:0]u8 {
    return if (serial) |s| try a.dupeZ(u8, s) else null;
}
fn freeSerial(a: std.mem.Allocator, serial: ?[:0]u8) void {
    if (serial) |s| a.free(s);
}

fn runSc64(io: std.Io, a: std.mem.Allocator, options: Options, rom: []const u8, stream: Stream, power: ?*Power) !u8 {
    var client: sc64.Client = .{ .allocator = a, .stream = stream };
    defer client.deinit();
    try client.connect();
    try client.upload(rom, @intFromEnum(options.save), options.cic_seed);
    try bootPower(power);
    std.debug.print("ptero-deploy: SC64 uploaded; listening for debug output (Ctrl-C to stop).\n", .{});
    var relay = Relay.init(io, options);
    if (try relay.feed(client.pending_text.items)) |code| return code;
    return listenSc64(&client, &relay);
}
fn bootPower(power: ?*Power) !void {
    if (power) |p| try p.boot(.sc64);
}
fn listenSc64(client: *sc64.Client, relay: *Relay) !u8 {
    while (true) {
        try relay.check();
        const packet = try client.receive(false) orelse continue;
        defer client.allocator.free(packet.data);
        if (try relaySc64Packet(packet, relay)) |code| return code;
    }
}
fn relaySc64Packet(packet: @import("packet.zig").Packet, relay: *Relay) !?u8 {
    if (packet.kind != .notification) return error.UnexpectedResponse;
    if (packet.id != 'U') return null;
    const debug = try @import("packet.zig").debug(packet.data);
    return relayDebug(debug, relay);
}
fn relayDebug(debug: @import("packet.zig").Debug, relay: *Relay) !?u8 {
    if (debug.datatype != 1) return null;
    return relay.feed(debug.data);
}

fn runEverDrive(io: std.Io, a: std.mem.Allocator, options: Options, rom: []u8, stream: Stream) !u8 {
    try ed.connect(stream);
    try applySave(rom, options.save);
    try ed.upload(stream, rom);
    if (hasSave(rom)) try ed.sendSaveName(stream, options.rom.?);
    std.debug.print("ptero-deploy: EverDrive uploaded; listening for debug output (Ctrl-C to stop).\n", .{});
    var relay = Relay.init(io, options);
    return listenEverDrive(a, stream, &relay);
}
fn listenEverDrive(a: std.mem.Allocator, stream: Stream, relay: *Relay) !u8 {
    while (true) {
        try relay.check();
        const debug = try ed.receive(a, stream) orelse continue;
        defer a.free(debug.data);
        if (try relayDebug(debug, relay)) |code| return code;
    }
}
fn hasSave(rom: []const u8) bool {
    return std.mem.eql(u8, rom[0x3c..0x3e], "ED") and rom[0x3f] & 0xf0 != 0;
}
fn applySave(rom: []u8, save: @import("options.zig").Save) !void {
    if (save == .none) return;
    const codes = [_]u8{ 0, 0x10, 0x20, 0x30, 0x50, 0x40 };
    if (save == .sram1m) return error.UnsupportedEverDriveSave;
    rom[0x3c..0x3e].* = "ED".*;
    rom[0x3f] = codes[@intFromEnum(save)];
}

test "EverDrive save selection uses ED header and rejects unsupported save size" {
    var rom: [64]u8 = @splat(0);
    try std.testing.expect(!hasSave(&rom));
    try applySave(&rom, .flashram);
    try std.testing.expect(hasSave(&rom));
    try std.testing.expectEqual(@as(u8, 0x50), rom[0x3f]);
    try std.testing.expectError(error.UnsupportedEverDriveSave, applySave(&rom, .sram1m));
    try applySave(&rom, .none);
}

test "both cartridge listeners relay completion and reject unexpected SC64 replies" {
    const Fake = @import("stream.zig").Fake;
    const text = "@@LIBPTERO_RUN_END@@ {\"code\":1}\n";
    var framed: [4 + text.len]u8 = undefined;
    std.mem.writeInt(u32, framed[0..4], 0x01000000 | text.len, .big);
    @memcpy(framed[4..], text);
    var input: [8 + framed.len]u8 = undefined;
    input[0..4].* = "PKTU".*;
    std.mem.writeInt(u32, input[4..8], framed.len, .big);
    @memcpy(input[8..], &framed);
    var fake: Fake = .{ .input = &input };
    defer fake.deinit();
    var client: sc64.Client = .{ .allocator = std.testing.allocator, .stream = fake.stream() };
    defer client.deinit();
    var relay = Relay.init(std.testing.io, .{ .mode = .wait });
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    relay.output = &output;
    try std.testing.expectEqual(@as(u8, 1), try listenSc64(&client, &relay));
    try std.testing.expectEqualStrings(text, output.buffered());
    try std.testing.expectError(error.UnexpectedResponse, relaySc64Packet(.{ .kind = .response, .id = 'M', .data = &.{} }, &relay));
    try std.testing.expectEqual(null, try relaySc64Packet(.{ .kind = .notification, .id = 'X', .data = &.{} }, &relay));
    try std.testing.expectEqual(null, try relayDebug(.{ .datatype = 5, .data = &.{} }, &relay));

    var ed_input: [4 + framed.len + 4 + text.len % 2]u8 = @splat(0);
    ed_input[0..4].* = "DMA@".*;
    @memcpy(ed_input[4..][0..framed.len], &framed);
    ed_input[4 + framed.len ..][0..4].* = "CMPH".*;
    fake.input = &ed_input;
    fake.cursor = 0;
    relay = Relay.init(std.testing.io, .{ .mode = .wait });
    relay.output = &output;
    try std.testing.expectEqual(@as(u8, 1), try listenEverDrive(std.testing.allocator, fake.stream(), &relay));
}
