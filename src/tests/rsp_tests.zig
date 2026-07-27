const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

const rsp = n64.rsp;

pub const tests = [_]runner.Test{
    .{ .name = "RSP: DMEM typed access", .run = dmemTypedAccess },
    .{ .name = "RSP: DMEM byte order", .run = dmemByteOrder },
    .{ .name = "RSP: fill DMEM ucode", .run = fillDmemUcode },
};

fn dmemTypedAccess() !void {
    // SP memory is written through its 32-bit bus. Seed a complete word, then
    // verify that the typed accessor exposes the expected byte and halfword.
    rsp.io.readDmem(u32, 0).* = 0xa5001234;
    rsp.io.readDmem(u32, rsp.io.dmem_len - 4).* = 0x89abcdef;

    try testing.expectEqual(@as(u8, 0xa5), rsp.io.readDmem(u8, 0).*);
    try testing.expectEqual(@as(u16, 0x1234), rsp.io.readDmem(u16, 2).*);
    try testing.expectEqual(
        @as(u32, 0x89abcdef),
        rsp.io.readDmem(u32, rsp.io.dmem_len - 4).*,
    );
}

fn dmemByteOrder() !void {
    rsp.io.readDmem(u32, 8).* = 0x12345678;

    try testing.expectEqual(@as(u8, 0x12), rsp.io.readDmem(u8, 8).*);
    try testing.expectEqual(@as(u8, 0x34), rsp.io.readDmem(u8, 9).*);
    try testing.expectEqual(@as(u8, 0x56), rsp.io.readDmem(u8, 10).*);
    try testing.expectEqual(@as(u8, 0x78), rsp.io.readDmem(u8, 11).*);
}

fn fillDmemUcode() !void {
    rsp.runUCode(rsp.programs.fill_dmem);
    rsp.waitBroke();
    rsp.halt();

    var offset: u32 = 0;
    while (offset < rsp.io.dmem_len) : (offset += 2) {
        try testing.expectEqual(
            @as(u16, @truncate(offset)),
            rsp.io.readDmem(u16, offset).*,
        );
    }
}
