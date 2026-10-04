pub const sc64 = @import("debug/sc64.zig");
pub const is_viewer = @import("debug/is_viewer.zig");
pub const exception = @import("debug/exception.zig");
pub const TrapFrame = @import("debug/cpu_state.zig").TrapFrame;
pub const backtrace = @import("debug/backtrace.zig");
pub const srcmap = @import("debug/srcmap.zig");
pub const crash_screen = @import("debug/crash_screen.zig");
pub const console_font = @import("debug/console_font.zig");
pub const profiler = @import("debug/profiler.zig");
pub const diagnostics = @import("debug/diagnostics.zig");

const std = @import("std");

pub const Backend = enum(u8) {
    none,
    is_viewer,
    sc64,
};

pub var current_backend = Backend.none;

pub fn init() void {
    current_backend = detect();
}

fn detect() Backend {
    if (sc64.detect())
        return .sc64;
    if (is_viewer.detect())
        return .is_viewer;
    return .none;
}

/// Best-effort formatting into a local 256-byte buffer; no heap setup is needed.
/// Oversized messages emit their buffered prefix followed by a truncation marker.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (current_backend == .none) return;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print(fmt, args) catch {
        writeStr(writer.buffered());
        writeStr("[truncated]\n");
        return;
    };
    writeStr(writer.buffered());
}

// Write a raw string to the debug backend without going through std.fmt.
// Safe to call from a panic handler (no safety checks, no allocations).
pub fn writeStr(str: []const u8) void {
    switch (current_backend) {
        .is_viewer => is_viewer.print(str),
        .sc64 => sc64.print(str),
        else => {},
    }
}

pub var panic_depth: u32 = 0;
