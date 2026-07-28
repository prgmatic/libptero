const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

const rsp = n64.rsp;

pub const tests = [_]runner.Test{
    .{ .name = "RSP API: direct DMEM word access", .run = directDmemWordAccess },
    .{ .name = "RSP API: DMA data load", .run = dmaDataLoad },
    .{ .name = "RSP: fill DMEM ucode", .run = fillDmemUcode },
};

fn directDmemWordAccess() !void {
    rsp.halt();
    rsp.waitHalted();

    rsp.io.readDmem(u32, 0).* = 0xa5001234;
    rsp.io.readDmem(u32, rsp.io.dmem_len - 4).* = 0x89abcdef;

    try testing.expectEqual(@as(u32, 0xa5001234), rsp.io.readDmem(u32, 0).*);
    try testing.expectEqual(
        @as(u32, 0x89abcdef),
        rsp.io.readDmem(u32, rsp.io.dmem_len - 4).*,
    );
}

fn dmaDataLoad() !void {
    const data align(8) = [_]u8{
        0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0xde, 0xf0,
        0x0f, 0x1e, 0x2d, 0x3c,
        0x4b, 0x5a, 0x69, 0x78,
    };

    rsp.halt();
    rsp.waitHalted();
    rsp.loadData(&data, 0x20);

    try testing.expectEqual(@as(u32, 0x12345678), rsp.io.readDmem(u32, 0x20).*);
    try testing.expectEqual(@as(u32, 0x9abcdef0), rsp.io.readDmem(u32, 0x24).*);
    try testing.expectEqual(@as(u32, 0x0f1e2d3c), rsp.io.readDmem(u32, 0x28).*);
    try testing.expectEqual(@as(u32, 0x4b5a6978), rsp.io.readDmem(u32, 0x2c).*);
}

fn fillDmemUcode() !void {
    rsp.runUCode(rsp.programs.fill_dmem);
    rsp.waitBroke();

    var offset: u32 = 0;
    while (offset < rsp.io.dmem_len) : (offset += 2) {
        try testing.expectEqual(
            @as(u16, @truncate(offset)),
            rsp.io.readDmem(u16, offset).*,
        );
    }
}
