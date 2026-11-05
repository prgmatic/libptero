//! Semantic analysis shared by instruction selection: lifetimes and
//! liveness (`lifetimes.zig`, `lifetime_analysis.zig`, `flow.zig`), call
//! requirements (`call_requirements.zig`), interprocedural write contracts
//! (`clobbers.zig`), and register allocation (`context.zig`).
const std = @import("std");
const ast = @import("ast.zig");
const context = @import("context.zig");
const call_requirements = @import("call_requirements.zig");

pub const Diagnostic = @import("explain.zig").Diagnostic;
pub const ExplainReport = @import("explain.zig").ExplainReport;
pub const Symbol = context.Symbol;
pub const FunctionContext = context.FunctionContext;
pub const FunctionClobberRegistry = @import("clobbers.zig").FunctionClobberRegistry;
pub const ParameterWriteVisit = call_requirements.ParameterWriteVisit;

pub const bindParameters = context.bindParameters;
pub const validateVectorRegisterBinding = context.validateVectorRegisterBinding;
pub const reserveTransposeBank = context.reserveTransposeBank;
pub const vectorRegisterForView = context.vectorRegisterForView;
pub const isVectorType = context.isVectorType;
pub const countFlowStatements = @import("flow.zig").countFlowStatements;
pub const findFunction = call_requirements.findFunction;
pub const functionParameterIsWritten = call_requirements.functionParameterIsWritten;
pub const parameterIsLiveIn = call_requirements.parameterIsLiveIn;

/// Scalar expression trees may only combine names and constants.
pub fn isPureScalarExpression(value: ast.Value) bool {
    return switch (value) {
        .ident, .number, .bit_cast => true,
        .scalar_expression => |expression| isPureScalarExpression(expression.lhs) and isPureScalarExpression(expression.rhs),
        else => false,
    };
}

pub fn valueReadsName(value: ast.Value, name: []const u8) bool {
    return switch (value) {
        .ident => |identifier| std.mem.eql(u8, identifier, name),
        .bit_cast => |source| refNames(source, name),
        .scalar_expression => |expression| expressionReadsName(expression, name),
        else => false,
    };
}

fn refNames(ref: ast.ValueRef, name: []const u8) bool {
    return ref == .ident and std.mem.eql(u8, ref.ident, name);
}

fn expressionReadsName(expression: *const ast.ScalarExpression, name: []const u8) bool {
    return valueReadsName(expression.lhs, name) or valueReadsName(expression.rhs, name);
}

const testing = std.testing;
const registerBit = @import("registers.zig").registerBit;

fn parseProgram(source: []const u8) !@import("source.zig").Program {
    var diagnostic: ?@import("parser.zig").Diagnostic = null;
    return @import("source.zig").Program.parse(testing.allocator, source, &diagnostic);
}

test "analysis exposes transitive write contracts without emitting assembly" {
    var program = try parseProgram("fn leaf(reg($t2) value: u32) { value += 1; } fn entry(reg($t2) value: u32) { leaf(value); }");
    defer program.deinit();
    var registry = try FunctionClobberRegistry.init(testing.allocator, program.functions, null);
    defer registry.deinit();
    const leaf = registry.find("leaf").?;
    const entry = registry.find("entry").?;
    try testing.expect(leaf.scalar & registerBit(.t2) != 0);
    try testing.expect(entry.scalar & registerBit(.t2) != 0);
    try testing.expectEqual(@as(u32, 0), entry.vector);
}

test "lifetime analysis rejects an unassigned value before allocation" {
    var program = try parseProgram("fn entry() { reg value: u32; rsp.cp0.setSpStatus(value); }");
    defer program.deinit();
    var diagnostic: Diagnostic = .{};
    var function_context = FunctionContext.init(testing.allocator, "entry");
    defer function_context.deinit();
    function_context.functions = program.functions;
    function_context.diagnostic = &diagnostic;
    const function = program.functions[0];
    try testing.expectError(error.RegisterReadBeforeAssignment, function_context.prepareLifetimes(program.functions, function.parameters, function.statements));
    try testing.expectEqualStrings("value", diagnostic.symbol_name.?);
    try testing.expectEqual(@as(usize, 0), function_context.symbols.items.len);
}

test "in/out parameters read the caller's value; pure outputs do not" {
    var program = try parseProgram(
        \\fn advance(reg($t1) cursor: dmem) { cursor +%= 8; }
        \\fn produce(reg($t1) cursor: dmem) { cursor = 8; }
        \\fn opaque(reg($t1) cursor: dmem) { asm("nop"); cursor = 8; }
    );
    defer program.deinit();
    try testing.expect(parameterIsLiveIn(testing.allocator, program.functions[0], 0));
    try testing.expect(!parameterIsLiveIn(testing.allocator, program.functions[1], 0));
    try testing.expect(parameterIsLiveIn(testing.allocator, program.functions[2], 0));
    var external = program.functions[0];
    external.external = true;
    try testing.expect(!parameterIsLiveIn(testing.allocator, external, 0));
}

test "scalar expression helpers" {
    try testing.expect(valueReadsName(.{ .bit_cast = .{ .ident = "x" } }, "x"));
    try testing.expect(!valueReadsName(.{ .bit_cast = .{ .number = 1 } }, "x"));
    try testing.expect(!isPureScalarExpression(.{ .vector_access = .{ .name = "v" } }));
}
