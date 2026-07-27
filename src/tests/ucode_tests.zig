const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

pub const tests = [_]runner.Test{
    .{ .name = "RSP: parse ucode blob", .run = parseUcodeBlob },
};

fn parseUcodeBlob() !void {
    const blob align(8) = [_]u8{
        0x00, 0x04, // text length
        0x00, 0x02, // data length
        0x00, 0x0c, // data offset
        0x00, 0x08, // initial PC
        0xaa, 0xbb, 0xcc, 0xdd, // text
        0x12, 0x34, // data
    };
    const ucode = n64.rsp.UCode.fromBlob(&blob);

    try testing.expectEqual(@as(usize, 4), ucode.text.len);
    try testing.expectEqual(@as(usize, 2), ucode.data.len);
    try testing.expectEqual(@as(u16, 8), ucode.pc_start);
    try testing.expectEqual(@as(u8, 0xaa), ucode.text[0]);
    try testing.expectEqual(@as(u8, 0x34), ucode.data[1]);
}
