const std = @import("std");
const n64 = @import("n64");
const testing = @import("assert.zig");
const runner = @import("runner.zig");
const crash = n64.debug.crash_screen;
const mem = crash.model.memory;
var pattern: [128]u8 align(16) = undefined;
var cart_owner: n64.io.pi.Transfer = .{};
var cart_destination: [16]u8 align(16) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "Crash memory: bounded RDRAM and cartridge snapshots", .run = rdramAndCart },
    .{ .name = "Crash memory: SP word reads preserve both memory banks", .run = spBanks },
    .{ .name = "Crash memory: cartridge ownership is not stolen", .run = cartOwnership },
};

fn rdramAndCart() !void {
    const limits = crash.memory.bounds();
    try testing.expect(limits.rdram_size == 4 * 1024 * 1024 or limits.rdram_size == 8 * 1024 * 1024);
    for (&pattern, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    n64.cache.writebackData(&pattern);
    var state: mem.State = .{};
    state.addresses[0] = @intFromPtr(&pattern) + 19;
    var view = crash.memory.capture(limits, state, 100_000);
    try testing.expectEqual(mem.Status.ready, view.status);
    try testing.expectEqual(@as(u8, 80), view.length);
    for (view.bytes, 0..) |byte, i| try testing.expectEqual(pattern[i], byte);
    state.addresses[0] |= 0x20000000;
    view = crash.memory.capture(limits, state, 100_000);
    try testing.expectEqual(mem.Status.ready, view.status);
    for (view.bytes, 0..) |byte, i| try testing.expectEqual(pattern[i], byte);
    state.addresses[0] = 0xa4040000;
    view = crash.memory.capture(limits, state, 100_000);
    try testing.expectEqual(mem.Status.invalid_address, view.status);
    try testing.expectEqual(@as(u8, 0), view.length);
    state = .{ .bank = .cart };
    view = crash.memory.capture(limits, state, 100_000);
    try testing.expectEqual(mem.Status.ready, view.status);
    try testing.expectEqual(@as(u32, 0x80371240), std.mem.readInt(u32, view.bytes[0..4], .big));
}

fn spBanks() !void {
    const limits = crash.memory.bounds();
    for ([_]mem.Bank{ .dmem, .imem }) |bank| {
        const base: u32 = if (bank == .dmem) 0xa4000000 else 0xa4001000;
        const words: [*]const volatile u32 = @ptrFromInt(base);
        const before = words[0];
        const view = crash.memory.capture(limits, .{ .bank = bank }, 100_000);
        try testing.expectEqual(mem.Status.ready, view.status);
        try testing.expectEqual(before, std.mem.readInt(u32, view.bytes[0..4], .big));
        try testing.expectEqual(before, words[0]);
        var state: mem.State = .{ .bank = bank };
        state.addresses[@intFromEnum(bank)] = base + 4095;
        const tail = crash.memory.capture(limits, state, 100_000);
        try testing.expectEqual(mem.Status.ready, tail.status);
        try testing.expectEqual(@as(u8, 32), tail.length);
        try testing.expectEqual(base + 4096 - 32, tail.address);
    }
}

fn cartOwnership() !void {
    try cart_owner.begin(0, &cart_destination);
    // Ownership remains held even if hardware completes before this read.
    const view = crash.memory.capture(crash.memory.bounds(), .{ .bank = .cart }, 100_000);
    try cart_owner.wait(100_000);
    try testing.expectEqual(mem.Status.pi_busy, view.status);
    try testing.expectEqual(@as(u8, 0), view.length);
    const recovered = crash.memory.capture(crash.memory.bounds(), .{ .bank = .cart }, 100_000);
    try testing.expectEqual(mem.Status.ready, recovered.status);
}
