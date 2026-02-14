pub const is_viewer = @import("io/is_viewer.zig");
pub const pi = @import("io/pi.zig");
pub const mips = @import("io/mips.zig");

pub fn rspWrite(dest: []const u32, data: []const u32) void {
    for(data, 0..) |d, i| {
        dest[i] = d;
        pi.wait();
    }
}
