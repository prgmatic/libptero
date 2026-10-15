const std = @import("std");
const ast = @import("ast.zig");
const backend = @import("asm_writer.zig");
const optimizer = @import("asm_optimizer.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    optimize: bool = true,
    explain: ?*backend.ExplainReport = null,
};

pub const Result = struct {
    assembly: []u8,
    raw_stats: diagnostics.AssemblyReport,
    final_stats: diagnostics.AssemblyReport,
    changed: bool,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.assembly);
        self.* = undefined;
    }
};

/// Both compilation and explain validate the final IMEM size before publishing
/// output. Optimization may bring an oversized raw program within the limit.
pub fn compile(
    allocator: std.mem.Allocator,
    functions: []const ast.Function,
    options: Options,
    diagnostic: ?*backend.Diagnostic,
) !Result {
    var raw = std.Io.Writer.Allocating.init(allocator);
    defer raw.deinit();
    try backend.writeWithExplain(&raw.writer, functions, diagnostic, options.explain);
    var final = std.Io.Writer.Allocating.init(allocator);
    defer final.deinit();
    if (options.optimize) {
        try optimizer.writeOptimized(allocator, &final.writer, raw.written());
    } else {
        try final.writer.writeAll(raw.written());
    }
    const final_stats = diagnostics.analyzeAssembly(final.written());
    if (final_stats.text_bytes > 4096) return error.ImemOverflow;
    const changed = !std.mem.eql(u8, raw.written(), final.written());
    return .{
        .assembly = try final.toOwnedSlice(),
        .raw_stats = diagnostics.analyzeAssembly(raw.written()),
        .final_stats = final_stats,
        .changed = changed,
    };
}

test "compile and explain reject oversized exact programs" {
    const allocator = std.testing.allocator;
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeAll("export fn entry() noreturn { exact {\n");
    for (0..1025) |_| try source.writer.writeAll("rsp.nop();\n");
    try source.writer.writeAll("} rsp.halt(); }");
    var parser = try @import("parser.zig").Parser.init(allocator, source.written());
    const functions = try parser.parse();
    defer ast.freeFunctions(allocator, functions);
    var report: backend.ExplainReport = .{};
    try std.testing.expectError(error.ImemOverflow, compile(allocator, functions, .{}, null));
    try std.testing.expectError(error.ImemOverflow, compile(allocator, functions, .{ .explain = &report }, null));
    try std.testing.expectError(error.ImemOverflow, compile(allocator, functions, .{ .optimize = false }, null));
}

test "compile exposes stable output and explain allocations" {
    const allocator = std.testing.allocator;
    var parser = try @import("parser.zig").Parser.init(allocator, "export fn entry() noreturn { reg value: u32 = 1; rsp.cp0.setSpStatus(value); rsp.halt(); }");
    const functions = try parser.parse();
    defer ast.freeFunctions(allocator, functions);
    var report: backend.ExplainReport = .{};
    var direct = try compile(allocator, functions, .{ .optimize = false, .explain = &report }, null);
    defer direct.deinit(allocator);
    var optimized = try compile(allocator, functions, .{}, null);
    defer optimized.deinit(allocator);
    try std.testing.expect(!direct.changed);
    try std.testing.expectEqual(direct.raw_stats.text_bytes, direct.final_stats.text_bytes);
    try std.testing.expect(report.allocation_count > 0);
    try std.testing.expect(optimized.final_stats.text_bytes <= direct.final_stats.text_bytes);
}
