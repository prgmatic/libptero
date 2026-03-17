const std = @import("std");
const io = @import("io.zig");

var fmt_buffer: ?[]u8 = null;

pub const Backend = enum(u8) {
    None,
    IsViewer,
};

pub var current_backend = Backend.None;

pub fn init(backend: Backend) void {
    current_backend = backend;
}

pub fn initFmtBuffer(allocator: std.mem.Allocator) void {
    fmt_buffer = allocator.alloc(u8, 256) catch null;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.bufPrint(fmt_buffer.?, fmt, args) catch "";
    switch (current_backend) {
        .IsViewer => io.is_viewer.print(str),
        else => {}
    }
}
