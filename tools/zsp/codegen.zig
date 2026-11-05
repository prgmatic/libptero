//! Instruction selection for a linked program: storage, command metadata,
//! and every function in placement order, emitted as IR.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const common = @import("emit_common.zig");
const ir_print = @import("ir_print.zig");
const placement = @import("placement.zig");
const registers = @import("registers.zig");
const rspq = @import("rspq.zig");
const statements_ = @import("emit_statements.zig");
const storage = @import("emit_storage.zig");
const Emitter = @import("Emitter.zig");

pub const Diagnostic = @import("explain.zig").Diagnostic;
pub const ExplainReport = @import("explain.zig").ExplainReport;

const FunctionContext = analysis.FunctionContext;

pub fn generate(out: *Emitter, program: []const ast.Function, diagnostic: ?*Diagnostic, explain: ?*ExplainReport) !void {
    try out.text(".set noreorder");
    try out.text(".set noat");
    const allocator = out.arena.allocator();
    const functions = try @import("param_alloc.zig").assign(allocator, program);
    var clobbers = try analysis.FunctionClobberRegistry.init(allocator, functions, diagnostic);
    defer clobbers.deinit();
    if (explain) |report| try recordWrites(report, functions, &clobbers);
    const commands = try rspq.analyzeCommands(functions);
    var top_level = FunctionContext.init(allocator, "top_level");
    defer top_level.deinit();
    top_level.clobbers = &clobbers;
    top_level.functions = functions;
    top_level.diagnostic = diagnostic;
    top_level.explain = explain;
    try storage.writeStorageBlocks(out, functions, &top_level);
    try storage.writeCommandTable(out, &commands, &top_level);
    try out.text(".text");
    try out.blank();
    const plan = try placement.Plan.init(functions);
    const g: common.Gen = .{ .out = out, .functions = functions, .context = &top_level };
    for (plan.order[0..plan.len]) |index| {
        writeFunction(g, index, plan.fallthrough[index]) catch |err| {
            if (diagnostic) |value| value.function_name = functions[index].source_name;
            return err;
        };
    }
    try storage.writeCommandManifest(out, functions, &commands);
}

fn recordWrites(report: *ExplainReport, functions: []const ast.Function, clobbers: *const analysis.FunctionClobberRegistry) !void {
    for (functions) |function| {
        if (report.writes_count >= report.writes.len) return error.TooManyFunctions;
        const contract = clobbers.find(function.name) orelse return error.UnknownFunction;
        report.writes[report.writes_count] = .{
            .function_name = function.source_name,
            .scalar = contract.scalar,
            .vector = contract.vector,
        };
        report.writes_count += 1;
    }
}

/// Generates unoptimized assembly text, as used by the backend tests.
pub fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, functions: []const ast.Function) !void {
    return writeWithDiagnostic(allocator, writer, functions, null);
}

pub fn writeWithDiagnostic(allocator: std.mem.Allocator, writer: *std.Io.Writer, functions: []const ast.Function, diagnostic: ?*Diagnostic) !void {
    var out = Emitter.init(allocator);
    defer out.deinit();
    try generate(&out, functions, diagnostic, null);
    try ir_print.writeItems(writer, out.items.items);
}

// --------------------------------------------------------------- functions

fn endsWithTerminalTransfer(statements: []const ast.Statement) bool {
    if (statements.len == 0) return false;
    return switch (statements[statements.len - 1]) {
        .ordered_block => |items| endsWithTerminalTransfer(items),
        .builtin => |builtin| @import("emit_control.zig").isTerminalBuiltin(builtin),
        else => false,
    };
}

fn isEmittedCall(functions: []const ast.Function, statement: *const ast.Statement) bool {
    if (statement.* != .call) return false;
    const call = statement.call;
    if (call.module != null) return true;
    const callee = analysis.findFunction(functions, call.name) orelse return true;
    return !callee.inline_call or containsEmittedCall(functions, callee.statements);
}

/// Whether lowering emits a `jal`, including through inline bodies.
fn containsEmittedCall(functions: []const ast.Function, statements: []const ast.Statement) bool {
    return @import("ast_walk.zig").any(statements, functions, isEmittedCall);
}

/// Command handlers that call other code keep the dispatcher's return
/// address in `$k1`.
fn savesCommandReturn(functions: []const ast.Function, function: ast.Function) bool {
    return function.command_indices.len != 0 and containsEmittedCall(functions, function.statements);
}

fn needsReturn(function: ast.Function) bool {
    return !function.no_return and !endsWithTerminalTransfer(function.statements);
}

fn writeFunctionHeader(out: *Emitter, function: ast.Function) !void {
    if (!function.emit_label) return;
    if (function.export_symbol or function.command_indices.len != 0) try out.textFmt(".globl {s}", .{function.name});
    try out.label(function.name);
}

fn writeFunction(top: common.Gen, index: usize, fallthrough: ?usize) !void {
    const function = top.functions[index];
    if (!function.emitsBody()) return;
    const saves_return = savesCommandReturn(top.functions, function);
    try writeFunctionHeader(top.out, function);
    if (saves_return and needsReturn(function)) try saveCommandReturn(top.out);
    var function_context = try top.context.child(function.name);
    defer function_context.deinit();
    function_context.explain_function_name = function.source_name;
    const context = if (function.emit_label) &function_context else top.context;
    try writeBody(top, context, index, fallthrough);
    if (needsReturn(function)) try writeReturn(top.out, saves_return);
    try @import("emit_control.zig").writeColdBlocks(top.with(context));
    try top.out.blank();
}

fn saveCommandReturn(out: *Emitter) !void {
    try out.register(.@"or", registers.command_return, .ra, .zero);
}

fn writeBody(top: common.Gen, context: *FunctionContext, index: usize, fallthrough: ?usize) !void {
    const function = top.functions[index];
    try prepareContext(top, context, function);
    if (fallthrough) |target| omitTail(context, function, top.functions[target]);
    // Out-of-line bodies need a transfer before them, not a fall-through.
    context.cold_blocks_allowed = fallthrough == null and (needsReturn(function) or endsWithTerminalTransfer(function.statements));
    try analysis.bindParameters(context, function.parameters);
    try statements_.writeStatements(top.with(context), function.statements);
}

/// The tail call to a function placed right after this one falls through.
fn omitTail(context: *FunctionContext, function: ast.Function, target: ast.Function) void {
    context.omitted_tail_target = target.name;
    context.omitted_tail_position = analysis.countFlowStatements(function.statements);
}

fn writeReturn(out: *Emitter, saves_return: bool) !void {
    try out.jumpRegister(.jr, if (saves_return) registers.command_return else .ra);
    try out.nop();
}

/// Applies the function's inferred call contract and lifetime analysis.
fn prepareContext(top: common.Gen, context: *FunctionContext, function: ast.Function) !void {
    if (!function.emit_label) return;
    if (top.context.clobbers.?.find(function.name)) |contract| {
        context.function_forbidden_scalar = contract.forbidden_scalar;
        context.function_forbidden_vector = contract.forbidden_vector;
    }
    try context.prepareLifetimes(top.functions, function.parameters, function.statements);
}

test "terminal transfers end inside exact blocks too" {
    var tail = [_]ast.Statement{.{ .builtin = .{ .tail = .{ .target = .{ .name = "f" }, .arguments = &.{} } } }};
    var ordered = [_]ast.Statement{.{ .ordered_block = &tail }};
    try std.testing.expect(endsWithTerminalTransfer(&ordered));
    try std.testing.expect(!endsWithTerminalTransfer(&.{}));
    var nop = [_]ast.Statement{.{ .builtin = .nop }};
    try std.testing.expect(!endsWithTerminalTransfer(&nop));
    var label = [_]ast.Statement{.{ .label = "x" }};
    try std.testing.expect(!endsWithTerminalTransfer(&label));
}
