const std = @import("std");
const n64 = @import("n64");


export fn __start() linksection(".loader") callconv(.c) noreturn {
    var b: [0x200]u8 = undefined;
    print(&b, "We can now format strings\n", .{});
    print(&b, "CPU Cycle Count: {d}", .{n64.cpu.cp0.regRead(.Count)});
    
    while (true) { }
    undefined;
}

fn print(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.bufPrint(buf, fmt, args) catch "";
    n64.io.is_viewer.print(str);
}
