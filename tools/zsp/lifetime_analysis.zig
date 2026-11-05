//! Builds a function's lifetimes: statement scan, backward-branch
//! extension, flow graph, and call requirements.
const std = @import("std");
const ast = @import("ast.zig");
const flow = @import("flow.zig");
const lifetime_scan = @import("lifetime_scan.zig");
const Lifetimes = @import("lifetimes.zig").Lifetimes;
const Requirements = @import("call_requirements.zig").Requirements;
const Diagnostic = @import("explain.zig").Diagnostic;

pub const Options = struct {
    /// Callees whose signatures shape argument requirements.
    functions: []const ast.Function = &.{},
    diagnostic: ?*Diagnostic = null,
    /// The program that diagnostics locate statements in.
    program: []const ast.Function = &.{},
};

/// Returns false when raw assembly hides the control flow; then only labels
/// are recorded and every lifetime spans the whole function.
pub fn prepare(lifetimes: *Lifetimes, options: Options, parameters: []const ast.Parameter, statements: []const ast.Statement) !bool {
    lifetimes.reset();
    lifetimes.reuse = !lifetime_scan.containsUnstructuredControlFlow(statements);
    if (!lifetimes.reuse) {
        try lifetime_scan.collectLabels(lifetimes, statements);
        return false;
    }
    for (parameters) |parameter| try declareParameter(lifetimes, parameter);
    var scan: lifetime_scan.Scan = .{ .lifetimes = lifetimes };
    try scan.statements(statements);
    lifetimes.extendBackwardEdges();
    var builder = try flow.Builder.init(lifetimes, scan.position);
    try builder.build(statements, 0);
    var requirements: Requirements = .{
        .lifetimes = lifetimes,
        .functions = options.functions,
        .diagnostic = options.diagnostic,
        .program = options.program,
    };
    try requirements.statements(statements);
    try lifetimes.indexEvents();
    return true;
}

/// Parameters are defined at entry; `_` reserves a register without a name.
fn declareParameter(lifetimes: *Lifetimes, parameter: ast.Parameter) !void {
    if (std.mem.eql(u8, parameter.name, "_")) return;
    try lifetimes.declare(.{
        .name = parameter.name,
        .position = 0,
        .automatic = false,
        .initially_defined = true,
        .data_type = parameter.data_type,
        .fixed_reg = parameter.reg,
        .fixed_vector_reg = parameter.vector_reg,
    });
}
