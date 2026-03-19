const pi = @import("../io/pi.zig");

pub var buffer:   *[0x80]u32 = @ptrFromInt(0xB3FF0020);
var write_len: *volatile u32 = @ptrFromInt(0xB3FF0014);

pub fn detect() bool {
    pi.waitIo();
    buffer[0] = 0x1234678;
    pi.waitIo();
    return buffer[0] == 0x12345678;
}

pub fn print(str: []const u8) void {
    const len = str.len;
    const ptr: [*]const u8 = @ptrCast(str);
    var c = len / 4;
    const rem = @mod(len, 4);
    if(rem > 0)
        c += 1;
    for(0..c) |i| {
        var val: u32 = @as(u32, ptr[i * 4]) << 24;
        val |= @as(u32, ptr[i * 4 + 1]) << 16;
        val |= @as(u32, ptr[i * 4 + 2]) << 8;
        val |= @as(u32, ptr[i * 4 + 3]);
        pi.waitIo();
        buffer[i] = val;
    }
    flushBuffer(len);
}

pub fn flushBuffer(len: u32) void {
    pi.waitIo();
    write_len.* = len;
}
