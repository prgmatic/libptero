pub const sc64 = @import("debug/sc64.zig");
pub const is_viewer = @import("debug/is_viewer.zig");
pub const exepction = @import("debug/exception.zig");
pub const TrapFrame = @import("debug/cpu_state.zig").TrapFrame;
pub const backtrace = @import("debug/backtrace.zig");
pub const srcmap = @import("debug/srcmap.zig");
pub const crash_screen = @import("debug/crash_screen.zig");
pub const console_font = @import("debug/console_font.zig");
pub const diagnostics = @import("debug/diagnostics.zig");

const std = @import("std");
const io = @import("io.zig");

var fmt_buffer: ?[]u8 = null;

pub const Backend = enum(u8) {
    None,
    IsViewer,
    Sc64,
};

pub var current_backend = Backend.None;

pub fn init() void {
    current_backend = detect();
}

fn detect() Backend {
    if (sc64.detect())
        return .Sc64;
    if (is_viewer.detect())
        return .IsViewer;
    return .None;
}

pub fn initFmtBuffer(allocator: std.mem.Allocator) !void {
    fmt_buffer = try allocator.alloc(u8, 256);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.bufPrint(fmt_buffer.?, fmt, args) catch "";
    switch (current_backend) {
        .IsViewer => is_viewer.print(str),
        .Sc64 => sc64.print(str),
        else => {},
    }
}

// Write a raw string to the debug backend without going through std.fmt.
// Safe to call from a panic handler (no safety checks, no allocations).
pub fn writeStr(str: []const u8) void {
    switch (current_backend) {
        .IsViewer => is_viewer.print(str),
        .Sc64 => sc64.print(str),
        else => {},
    }
}

pub var panic_depth: u32 = 0;
