//! Optimization passes over the instruction IR, in order: relocation
//! folding, dead-write removal, CP0 polling loops, list scheduling, and
//! delay-slot filling. See `peephole.zig` and `schedule.zig`.
const std = @import("std");
const ir_parse = @import("ir_parse.zig");
const ir_print = @import("ir_print.zig");
const peephole = @import("peephole.zig");
const schedule = @import("schedule.zig");
const Emitter = @import("Emitter.zig");

pub const pass_names = "relocation folding, dead writes, polling loops, list scheduling, delay slots";

pub fn optimize(out: *Emitter) !void {
    peephole.foldSymbolOffsets(&out.items);
    peephole.removeDeadWrites(&out.items);
    try peephole.foldPollingLoops(&out.items);
    try schedule.scheduleItems(out.arena.child_allocator, &out.items);
    peephole.fillDelaySlots(&out.items);
}

/// Parses assembly text, optimizes it, and prints the result. Used by tests.
pub fn writeOptimized(allocator: std.mem.Allocator, writer: *std.Io.Writer, assembly: []const u8) !void {
    var out = Emitter.init(allocator);
    defer out.deinit();
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        try out.item(ir_parse.parseLine(line));
    }
    try optimize(&out);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    try ir_print.writeItems(&text.writer, out.items.items);
    // Keep the input's final-newline convention.
    const printed = text.written();
    const keep_newline = std.mem.endsWith(u8, assembly, "\n") or printed.len == 0;
    try writer.writeAll(if (keep_newline) printed else printed[0 .. printed.len - 1]);
}
