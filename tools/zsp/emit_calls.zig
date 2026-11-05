//! Calls, inline expansion, continuation pairs, and argument passing.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const common = @import("emit_common.zig");
const operands = @import("emit_operands.zig");
const statements_ = @import("emit_statements.zig");
const registers = @import("registers.zig");

const Gen = common.Gen;
const Register = ast.Register;
const Statement = ast.Statement;
const Tail = @FieldType(ast.Builtin, "tail");

pub fn writeCall(g: Gen, call: ast.Call) anyerror!void {
    try common.expectLocal(call.module);
    const function = try common.findFunction(g, call.name);
    try writeFunctionArguments(g, function, call.arguments, true);
    if (function.inline_call) return writeInlineCall(g, function, call.arguments);
    try g.out.jump(.jal, call.name);
    try statements_.writeDelaySlot(g, call.delay_slot);
}

/// Expands an inline body with the caller's live registers reserved.
fn writeInlineCall(g: Gen, function: ast.Function, arguments: []const ast.ValueRef) !void {
    const caller = g.context;
    var context = analysis.FunctionContext.init(caller.allocator, caller.label_prefix);
    defer context.deinit();
    context.next_label = caller.next_label;
    context.clobbers = caller.clobbers;
    context.functions = g.functions;
    context.function_forbidden_scalar = caller.function_forbidden_scalar;
    context.function_forbidden_vector = caller.function_forbidden_vector;
    try reserveCallerSymbols(&context, caller);
    try context.prepareLifetimes(g.functions, function.parameters, function.statements);
    for (function.parameters, arguments) |parameter, argument| try bindInlineParameter(&context, caller, parameter, argument);
    try statements_.writeStatements(g.with(&context), function.statements);
    caller.next_label = context.next_label;
}

fn reserveCallerSymbols(context: *analysis.FunctionContext, caller: *const analysis.FunctionContext) !void {
    for (caller.symbols.items) |symbol| {
        if (symbol.automatic and symbol.last_use < caller.statement_position) continue;
        var reserved = symbol;
        reserved.automatic = false;
        reserved.last_use = std.math.maxInt(usize);
        try context.add(reserved);
    }
}

/// A pinned parameter is the register its argument was moved into. An
/// unpinned one names the argument itself: its register, or its constant.
fn bindInlineParameter(
    context: *analysis.FunctionContext,
    caller: *const analysis.FunctionContext,
    parameter: ast.Parameter,
    argument: ast.ValueRef,
) !void {
    if (parameter.automatic) return bindArgument(context, caller, parameter, argument);
    const existing = context.lookup(parameter.name) catch return context.add(.{
        .name = parameter.name,
        .data_type = parameter.data_type,
        .reg = parameter.reg,
        .vector_reg = parameter.vector_reg,
        .constant = null,
    });
    if (existing.data_type != parameter.data_type) return error.FunctionArgumentTypeMismatch;
    if (existing.reg != parameter.reg or existing.vector_reg != parameter.vector_reg) return error.FunctionArgumentRegisterMismatch;
}

fn bindArgument(
    context: *analysis.FunctionContext,
    caller: *const analysis.FunctionContext,
    parameter: ast.Parameter,
    argument: ast.ValueRef,
) !void {
    const source = try argumentSymbol(caller, parameter, argument);
    if (!argumentTypeFits(source.data_type, parameter.data_type, true)) return error.FunctionArgumentTypeMismatch;
    // An argument with the parameter's own name is already reserved.
    if (std.mem.eql(u8, source.name, parameter.name) and argument == .ident) return;
    var alias = source;
    alias.name = parameter.name;
    alias.data_type = parameter.data_type;
    alias.automatic = false;
    alias.first_live = 0;
    alias.last_use = std.math.maxInt(usize);
    try context.add(alias);
}

/// The caller's symbol an argument names, or a constant for a literal.
fn argumentSymbol(caller: *const analysis.FunctionContext, parameter: ast.Parameter, argument: ast.ValueRef) !analysis.Symbol {
    return switch (argument) {
        .number => |value| .{ .name = parameter.name, .data_type = parameter.data_type, .reg = null, .constant = value },
        .ident => |name| caller.lookup(name),
        else => error.FunctionArgumentTypeMismatch,
    };
}

/// `call(); tail next();` where `next` takes no arguments.
pub fn isContinuationPairAt(statements: []const Statement, index: usize) bool {
    if (index + 1 >= statements.len or statements[index] != .call) return false;
    return statements[index].call.delay_slot == null and isBareTail(statements[index + 1]);
}

/// `tail target();` without arguments or a slot.
fn isBareTail(statement: Statement) bool {
    if (statement != .builtin or statement.builtin != .tail) return false;
    return statement.builtin.tail.delay_slot == null and statement.builtin.tail.arguments.len == 0;
}

/// Returns into the continuation by falling through when it is placed next,
/// else by loading it into `$ra` in the jump's delay slot.
pub fn writeContinuationPair(g: Gen, call: ast.Call, following: Tail) !void {
    try common.expectLocal(call.module);
    try common.expectLocal(following.target.module);
    const callee = try common.findFunction(g, call.name);
    const continuation = try common.findFunction(g, following.target.name);
    if (callee.inline_call or continuation.parameters.len != 0) return error.InvalidContinuationCall;
    g.advance(2);
    if (isOmittedTail(g, following.target.name)) return writeCall(g, call);
    try writeFunctionArguments(g, callee, call.arguments, true);
    try g.out.jump(.j, call.name);
    try g.out.immediateSymbol(.addiu, .ra, .zero, following.target.name, 0);
}

/// Whether placement put the tail target directly after this function.
pub fn isOmittedTail(g: Gen, target: []const u8) bool {
    const omitted = g.context.omitted_tail_target orelse return false;
    return g.context.statement_position == g.context.omitted_tail_position and std.mem.eql(u8, omitted, target);
}

// ---------------------------------------------------------------- arguments

const max_arguments = 64;

/// Moves register arguments into the callee's parameter registers as a
/// parallel assignment, then materializes constants and checks types.
pub fn writeFunctionArguments(g: Gen, function: ast.Function, arguments: []const ast.ValueRef, allow_signedness_change: bool) !void {
    if (arguments.len != function.parameters.len) return error.FunctionArgumentCountMismatch;
    if (arguments.len > max_arguments) return error.TooManyFunctionArguments;
    var moves = try collectMoves(g, function, arguments);
    try emitParallelMoves(g, &moves);
    for (arguments, function.parameters) |argument, parameter| {
        if (function.bindsArgument(parameter)) continue;
        try writeArgument(g, argument, parameter, allow_signedness_change);
    }
}

const Move = struct { destination: Register, source: Register };

const Moves = struct {
    items: [max_arguments]Move = undefined,
    pending: [max_arguments]bool = @splat(false),
    len: usize = 0,

    fn add(self: *Moves, move: Move) void {
        self.items[self.len] = move;
        self.pending[self.len] = true;
        self.len += 1;
    }

    fn uses(self: *const Moves, reg: Register) bool {
        for (self.items[0..self.len]) |move| {
            if (move.source == reg or move.destination == reg) return true;
        }
        return false;
    }

    /// Whether a pending move other than `index` still reads `reg`.
    fn reads(self: *const Moves, reg: Register, index: usize) bool {
        for (self.items[0..self.len], self.pending[0..self.len], 0..) |move, pending, other| {
            if (pending and other != index and move.source == reg) return true;
        }
        return false;
    }
};

fn collectMoves(g: Gen, function: ast.Function, arguments: []const ast.ValueRef) !Moves {
    var moves: Moves = .{};
    for (arguments, function.parameters, 0..) |argument, parameter, index| {
        if (function.bindsArgument(parameter)) continue;
        const source = try movedSource(g, argument, parameter) orelse continue;
        if (parameterIsWritten(g, function, index)) return error.FunctionArgumentRegisterMismatch;
        moves.add(.{ .destination = parameter.reg.?, .source = source });
    }
    return moves;
}

/// The register a scalar argument must be copied from, if any.
fn movedSource(g: Gen, argument: ast.ValueRef, parameter: ast.Parameter) !?Register {
    const name = common.refName(argument) orelse return null;
    const source = (try g.lookup(name)).reg orelse return null;
    if (analysis.isVectorType(parameter.data_type) or source == parameter.reg) return null;
    return source;
}

fn parameterIsWritten(g: Gen, function: ast.Function, index: usize) bool {
    var visited: [1024]analysis.ParameterWriteVisit = undefined;
    var visited_count: usize = 0;
    return analysis.functionParameterIsWritten(g.functions, function, index, &visited, &visited_count);
}

/// Emits each move once no other pending move still reads its destination.
/// A cycle, such as swapped arguments, is broken through a scratch register.
fn emitParallelMoves(g: Gen, moves: *Moves) !void {
    var remaining = std.mem.count(bool, moves.pending[0..moves.len], &.{true});
    while (remaining != 0) {
        const emitted = try emitReadyMoves(g, moves);
        if (emitted == 0) try breakCycle(g, moves);
        remaining -= emitted;
    }
}

/// Copies one blocked destination aside and redirects its readers to the copy.
fn breakCycle(g: Gen, moves: *Moves) !void {
    const scratch = try cycleScratch(g, moves);
    const blocked = moves.items[std.mem.indexOfScalar(bool, moves.pending[0..moves.len], true).?].destination;
    try g.out.register(.@"or", scratch, blocked, .zero);
    for (moves.items[0..moves.len], moves.pending[0..moves.len]) |*move, pending| {
        if (pending and move.source == blocked) move.source = scratch;
    }
}

/// `$at`, or `$v1` when an argument lives in `$at`.
fn cycleScratch(g: Gen, moves: *const Moves) !Register {
    if (!moves.uses(registers.compiler_scratch)) return registers.compiler_scratch;
    const second = operands.backendScratch2(g.context) catch return error.FunctionArgumentMoveCycle;
    return if (moves.uses(second)) error.FunctionArgumentMoveCycle else second;
}

fn emitReadyMoves(g: Gen, moves: *Moves) !usize {
    var emitted: usize = 0;
    for (moves.items[0..moves.len], 0..) |move, index| {
        if (!moves.pending[index] or moves.reads(move.destination, index)) continue;
        try g.out.register(.@"or", move.destination, move.source, .zero);
        moves.pending[index] = false;
        emitted += 1;
    }
    return emitted;
}

fn writeArgument(g: Gen, argument: ast.ValueRef, parameter: ast.Parameter, allow_signedness_change: bool) !void {
    return switch (argument) {
        .vector_access => error.FunctionArgumentTypeMismatch,
        .number => |number| writeConstantArgument(g, parameter, number),
        .ident => |name| writeSymbolArgument(g, try g.lookup(name), parameter, allow_signedness_change),
        .bit_cast => |name| writeBitCastArgument(g, try g.lookup(name), parameter),
    };
}

fn writeConstantArgument(g: Gen, parameter: ast.Parameter, value: i64) !void {
    if (analysis.isVectorType(parameter.data_type)) return error.VectorArgumentMustBeRegister;
    try operands.loadImmediateInto(g.out, parameter.reg orelse return error.InvalidScalarRegister, value);
}

/// Register arguments were moved above; vectors must already match and
/// named constants are materialized.
fn writeSymbolArgument(g: Gen, symbol: analysis.Symbol, parameter: ast.Parameter, allow_signedness_change: bool) !void {
    if (!argumentTypeFits(symbol.data_type, parameter.data_type, allow_signedness_change)) return error.FunctionArgumentTypeMismatch;
    if (analysis.isVectorType(parameter.data_type)) return expectSameVector(symbol, parameter);
    if (symbol.reg != null) return;
    try writeConstantArgument(g, parameter, symbol.constant orelse return error.ExpectedConstant);
}

fn argumentTypeFits(argument: ast.DataType, parameter: ast.DataType, allow_signedness_change: bool) bool {
    if (argument == parameter) return true;
    return allow_signedness_change and common.scalarAbiTypesCompatible(argument, parameter);
}

fn expectSameVector(symbol: analysis.Symbol, parameter: ast.Parameter) !void {
    if (symbol.vector_reg != parameter.vector_reg) return error.FunctionArgumentRegisterMismatch;
}

fn writeBitCastArgument(g: Gen, symbol: analysis.Symbol, parameter: ast.Parameter) !void {
    if (analysis.isVectorType(symbol.data_type) or analysis.isVectorType(parameter.data_type)) {
        return error.FunctionArgumentTypeMismatch;
    }
    const destination = parameter.reg orelse return error.InvalidScalarRegister;
    const source = symbol.reg orelse return error.InvalidScalarRegister;
    if (destination != source) try g.out.register(.@"or", destination, .zero, source);
}

test "pending moves report readers other than themselves" {
    var moves: Moves = .{};
    moves.add(.{ .destination = .a0, .source = .a1 });
    moves.add(.{ .destination = .a1, .source = .t0 });
    try std.testing.expect(moves.reads(.a1, 1));
    try std.testing.expect(!moves.reads(.a1, 0));
    try std.testing.expect(!moves.reads(.t0, 1));
}
