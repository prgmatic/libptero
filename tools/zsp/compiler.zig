const std = @import("std");
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const optimizer = @import("optimizer.zig");
const diagnostics = @import("diagnostics.zig");
const ir_print = @import("ir_print.zig");
const Emitter = @import("Emitter.zig");

pub const Options = struct {
    optimize: bool = true,
    explain: ?*codegen.ExplainReport = null,
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

fn print(allocator: std.mem.Allocator, out: *const Emitter) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    try ir_print.writeItems(&text.writer, out.items.items);
    return text.toOwnedSlice();
}

/// Both compilation and explain validate the final IMEM size before publishing
/// output. Optimization may bring an oversized raw program within the limit.
pub fn compile(
    allocator: std.mem.Allocator,
    functions: []const ast.Function,
    options: Options,
    diagnostic: ?*codegen.Diagnostic,
) !Result {
    var out = Emitter.init(allocator);
    defer out.deinit();
    try codegen.generate(&out, functions, diagnostic, options.explain);
    const raw = try print(allocator, &out);
    defer allocator.free(raw);
    if (options.optimize) try optimizer.optimize(&out);
    const final = try print(allocator, &out);
    errdefer allocator.free(final);
    const final_stats = diagnostics.analyzeAssembly(final);
    if (final_stats.text_bytes > 4096) return error.ImemOverflow;
    return .{
        .assembly = final,
        .raw_stats = diagnostics.analyzeAssembly(raw),
        .final_stats = final_stats,
        .changed = !std.mem.eql(u8, raw, final),
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
    var report: codegen.ExplainReport = .{};
    try std.testing.expectError(error.ImemOverflow, compile(allocator, functions, .{}, null));
    try std.testing.expectError(error.ImemOverflow, compile(allocator, functions, .{ .explain = &report }, null));
    try std.testing.expectError(error.ImemOverflow, compile(allocator, functions, .{ .optimize = false }, null));
}

test "compile exposes stable output and explain allocations" {
    const allocator = std.testing.allocator;
    var parser = try @import("parser.zig").Parser.init(allocator, "export fn entry() noreturn { reg value: u32 = 1; rsp.cp0.setSpStatus(value); rsp.halt(); }");
    const functions = try parser.parse();
    defer ast.freeFunctions(allocator, functions);
    var report: codegen.ExplainReport = .{};
    var direct = try compile(allocator, functions, .{ .optimize = false, .explain = &report }, null);
    defer direct.deinit(allocator);
    var optimized = try compile(allocator, functions, .{}, null);
    defer optimized.deinit(allocator);
    try std.testing.expect(!direct.changed);
    try std.testing.expectEqual(direct.raw_stats.text_bytes, direct.final_stats.text_bytes);
    try std.testing.expect(report.allocation_count > 0);
    try std.testing.expect(optimized.final_stats.text_bytes <= direct.final_stats.text_bytes);
}
