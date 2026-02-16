pub const is_viewer = @import("io/is_viewer.zig");
pub const pi = @import("io/pi.zig");
pub const rdram = @import("io/rdram.zig");

pub const kseg0_addr = 0x80000000;
pub const kseg1_addr = 0xA0000000;

pub fn rspWrite(dest: []const u32, data: []const u32) void {
    for(data, 0..) |d, i| {
        dest[i] = d;
        pi.wait();
    }
}
