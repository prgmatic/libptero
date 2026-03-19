pub const pi = @import("io/pi.zig");
pub const rdram = @import("io/rdram.zig");
pub const joybus = @import("io/joybus.zig");
pub const joypad = @import("io/joypad.zig");
pub const serial = @import("io/serial.zig");

pub const kseg0_addr = 0x80000000;
pub const kseg1_addr = 0xA0000000;

pub fn rspWrite(dest: []const u32, data: []const u32) void {
    for(data, 0..) |d, i| {
        dest[i] = d;
        pi.wait();
    }
}
