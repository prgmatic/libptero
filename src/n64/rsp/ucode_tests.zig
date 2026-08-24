const UCode = @import("ucode.zig").UCode;
const testing = @import("std").testing;

test "parse packed blob" {
    const blob align(8) = [_]u8{
        0x00, 0x04, // text length
        0x00, 0x02, // data length
        0x00, 0x20, // data offset
        0x00, 0x08, // initial PC
        0x00, 0x04, // IMEM text offset
        0x00, 0x22, // command metadata offset
        0x00, 0x01, // command count
        0x08, 0x50, // state DMEM offset
        0x00, 0x08, // state length
        0x00, 0x26, // initial state offset
        0x00, 0x08, // initial state length
        0x00, 0x00, // reserved
        0xaa, 0xbb, 0xcc, 0xdd, // text
        0x00, 0x00, 0x00, 0x00, // padding
        0x12, 0x34, // data
        0x03, 0x08, 0x02, 0x40, // command 3, 8 bytes, handler at IMEM offset 0x240
        1, 2, 3, 4, 5, 6, 7, 8, // initial state
    };
    const ucode = UCode.fromBlob(&blob);

    try testing.expectEqual(@as(usize, 4), ucode.text.len);
    try testing.expectEqual(@as(usize, 2), ucode.data.len);
    try testing.expectEqual(@as(u16, 8), ucode.pc_start);
    try testing.expectEqual(@as(u16, 4), ucode.text_offset);
    try testing.expectEqual(@as(u16, 0x850), ucode.state_offset);
    try testing.expectEqual(@as(u16, 8), ucode.state_len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, ucode.state_init);
    try testing.expectEqual(@as(u8, 0xaa), ucode.text[0]);
    try testing.expectEqual(@as(u8, 0x34), ucode.data[1]);
    try testing.expectEqual(@as(usize, 1), ucode.commandCount());
    const command = ucode.commandAt(0);
    try testing.expectEqual(@as(u8, 3), command.index);
    try testing.expectEqual(@as(u8, 8), command.size);
    try testing.expectEqual(@as(u16, 0x240), command.handler_offset);
}
