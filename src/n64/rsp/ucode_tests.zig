const UCode = @import("ucode.zig").UCode;
const testing = @import("std").testing;

test "parse packed blob" {
    const blob align(8) = [_]u8{
        0x00, 0x04, // text length
        0x00, 0x02, // data length
        0x00, 0x10, // data offset
        0x00, 0x08, // initial PC
        0xaa, 0xbb, 0xcc, 0xdd, // text
        0x00, 0x00, 0x00, 0x00, // padding
        0x12, 0x34, // data
    };
    const ucode = UCode.fromBlob(&blob);

    try testing.expectEqual(@as(usize, 4), ucode.text.len);
    try testing.expectEqual(@as(usize, 2), ucode.data.len);
    try testing.expectEqual(@as(u16, 8), ucode.pc_start);
    try testing.expectEqual(@as(u8, 0xaa), ucode.text[0]);
    try testing.expectEqual(@as(u8, 0x34), ucode.data[1]);
}
