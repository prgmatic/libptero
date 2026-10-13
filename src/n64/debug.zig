const sc64 = @import("debug/backends/sc64.zig");
const everdrive = @import("debug/backends/everdrive.zig");
const is_viewer = @import("debug/backends/is_viewer.zig");
pub const backtrace = @import("debug/backtrace.zig");
pub const source_map = @import("debug/source_map.zig");
pub const crash_screen = @import("debug/crash_screen.zig");
pub const console_font = @import("debug/console_font.zig");
pub const profiler = @import("debug/profiler.zig");
pub const diagnostics = @import("debug/diagnostics.zig");
const run_protocol = @import("debug/run_protocol.zig");

/// Notify a deploy listener that this run has finished. Returns to the caller;
/// the listener handles emulator exit or optional console power-off.
/// Initialize debug first and call from normal execution, never an interrupt.
pub fn finish(result: run_protocol.Result) void {
    var buffer: [128]u8 = undefined;
    const record = run_protocol.encode(&buffer, result) catch unreachable;
    writeAll("\n");
    writeAll(record);
}

const std = @import("std");

pub const Backend = enum(u8) {
    none,
    is_viewer,
    sc64,
    everdrive,
};

pub var current_backend = Backend.none;

pub fn init() void {
    current_backend = detect();
}

fn detect() Backend {
    if (sc64.detect())
        return .sc64;
    if (everdrive.detect())
        return .everdrive;
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
        writeAll(writer.buffered());
        writeAll("[truncated]\n");
        return;
    };
    writeAll(writer.buffered());
}

// Write a raw string to the debug backend without going through std.fmt.
// Safe to call from a panic handler (no safety checks, no allocations).
pub fn writeAll(str: []const u8) void {
    switch (current_backend) {
        .is_viewer => is_viewer.print(str),
        .sc64 => sc64.print(str),
        .everdrive => everdrive.print(str),
        else => {},
    }
}

pub var panic_depth: u32 = 0;

pub const RunResult = run_protocol.Result;
pub const backends = @import("debug/backends.zig");
