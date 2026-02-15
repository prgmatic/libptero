const pi = @import("pi.zig");

pub var write_len: *volatile u32 = @ptrFromInt(0xB3FF0014);
pub var buffer:       *[0x80]u32 = @ptrFromInt(0xB3FF0020);

pub fn print(fmt: []const u8) void {
    const len = fmt.len;
    const ptr: [*]const u8 = @ptrCast(fmt);
    var c = len / 4;
    const rem = @mod(len, 4);
    if(rem > 0)
        c += 1;
    for(0..c) |i| {
        var val: u32 = @as(u32, ptr[i * 4]) << 24;
        val |= @as(u32, ptr[i * 4 + 1]) << 16;
        val |= @as(u32, ptr[i * 4 + 2]) << 8;
        val |= @as(u32, ptr[i * 4 + 3]);
        buffer[i] = val;
        pi.waitIo();
    }
    write_len.* = fmt.len;
    pi.waitIo();
}
