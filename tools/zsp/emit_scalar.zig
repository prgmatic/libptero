//! Scalar instruction selection: declarations, assignments, expressions,
//! comparisons, shifts, and materialized addresses.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const common = @import("emit_common.zig");
const ir = @import("ir.zig");
const memory = @import("emit_memory.zig");
const operands = @import("emit_operands.zig");
const vectors = @import("emit_vectors.zig");
const registers = @import("registers.zig");

const Gen = common.Gen;
const Register = ast.Register;
const Symbol = analysis.Symbol;
const ValueTag = std.meta.Tag(ast.Value);

// ----------------------------------------------------------- declarations

pub fn writeVarDecl(g: Gen, decl: ast.VarDecl) !void {
    if (decl.is_const) return declareConstant(g, decl);
    if (analysis.isVectorType(decl.data_type)) return declareVector(g, decl);
    return declareScalar(g, decl);
}

fn declareConstant(g: Gen, decl: ast.VarDecl) !void {
    if (analysis.isVectorType(decl.data_type)) return error.VectorConstUnsupported;
    const value = decl.value orelse return error.ExpectedConstant;
    try g.context.add(.{
        .name = decl.name,
        .data_type = decl.data_type,
        .reg = null,
        .constant = try operands.valueAsImmediate(g, value),
    });
}

fn declareVector(g: Gen, decl: ast.VarDecl) !void {
    if (decl.reg != null) return error.InvalidVectorRegister;
    const reg = decl.vector_reg orelse try g.context.allocVectorRegister(decl.data_type, decl.name);
    try analysis.validateVectorRegisterBinding(g.context, decl.data_type, reg, decl.name);
    if (decl.value) |value| try vectors.writeVectorInitialValue(g, reg, decl.data_type, value);
    try g.context.add(.{
        .name = decl.name,
        .data_type = decl.data_type,
        .reg = null,
        .vector_reg = reg,
        .function_type = decl.function_type,
        .constant = null,
        .automatic = decl.vector_reg == null,
        .first_live = g.context.firstLive(decl.name),
        .last_use = g.context.lastUse(decl.name),
    });
}

/// `$v1` and `$k1` are backend registers that only `reserved` may claim.
/// `reserved` may also hold any other register but `$zero` and the
/// backend's `$at` for a whole function, such as one its callers keep.
fn validateReservation(decl: ast.VarDecl, reg: Register) !void {
    if (decl.is_reserved) {
        if (!reservable(reg)) return error.InvalidReservedRegister;
    } else if (backendOnly(reg)) return error.RegisterReservedForBackend;
}

fn reservable(reg: Register) bool {
    return reg != .zero and reg != registers.compiler_scratch;
}

fn backendOnly(reg: Register) bool {
    return reg == registers.compiler_scratch_2 or reg == registers.command_return;
}

fn declareScalar(g: Gen, decl: ast.VarDecl) !void {
    if (decl.vector_reg != null) return error.InvalidScalarRegister;
    const reg = decl.reg orelse try g.context.allocRegister(decl.data_type, decl.name);
    try validateReservation(decl, reg);
    if (g.context.scalarLifetimeConflicts(decl.name, reg)) return error.RegisterAlreadyInUse;
    const symbol = scalarSymbol(g, decl, reg);
    if (decl.value) |value| try writeInitialScalar(g, symbol, value);
    try g.context.add(symbol);
}

/// Reserved registers stay claimed for the whole function.
fn scalarSymbol(g: Gen, decl: ast.VarDecl, reg: Register) Symbol {
    var symbol: Symbol = .{
        .name = decl.name,
        .data_type = decl.data_type,
        .reg = reg,
        .function_type = decl.function_type,
        .constant = null,
        .automatic = decl.reg == null,
        .first_live = 0,
        .last_use = std.math.maxInt(usize),
    };
    if (decl.is_reserved) return symbol;
    symbol.first_live = g.context.firstLive(decl.name);
    symbol.last_use = g.context.lastUse(decl.name);
    return symbol;
}

const Initializer = *const fn (Gen, Symbol, ast.Value) anyerror!void;

fn writeInitialScalar(g: Gen, symbol: Symbol, value: ast.Value) !void {
    return initializers.get(std.meta.activeTag(value))(g, symbol, value);
}

const initializers = blk: {
    var table = std.EnumArray(ValueTag, Initializer).initFill(&initialImmediate);
    table.set(.load, &initialLoad);
    table.set(.ident, &initialIdent);
    for ([_]ValueTag{
        .vector_control_read, .hardware_read, .scalar_comparison, .signed_less_than,
        .bit_cast,            .function_address, .code_address,   .data_address,
    }) |tag| table.set(tag, &initialSet);
    break :blk table;
};

fn initialImmediate(g: Gen, symbol: Symbol, value: ast.Value) !void {
    try operands.loadImmediateInto(g.out, symbol.reg.?, try operands.valueAsImmediate(g, value));
}

fn initialLoad(g: Gen, symbol: Symbol, value: ast.Value) !void {
    if (!common.isCompatibleScalarLoad(symbol.data_type, value.load.data_type)) return error.RegisterTypeMismatch;
    try memory.writeLoadInto(g, symbol.reg.?, value.load);
}

fn initialSet(g: Gen, symbol: Symbol, value: ast.Value) !void {
    try writeSet(g, symbol, symbol.reg.?, value);
}

/// Unlike assignment, initialization from a typed register does not
/// require a matching function type.
fn initialIdent(g: Gen, symbol: Symbol, value: ast.Value) !void {
    const source = try g.lookup(value.ident);
    if (source.reg) |source_reg| {
        try common.expectSameType(symbol, source);
        return g.out.register(.@"or", symbol.reg.?, source_reg, .zero);
    }
    try writeSymbolValue(g, symbol.reg.?, source);
}

/// A storage label's address or a constant's value.
fn writeSymbolValue(g: Gen, destination: Register, source: Symbol) !void {
    if (source.data_label) |label| return operands.loadDataAddress(g.out, destination, label);
    try operands.loadImmediateInto(g.out, destination, source.constant orelse return error.ExpectedConstant);
}

// ------------------------------------------------------------ assignments

pub fn writeAssignment(g: Gen, assignment: ast.Assignment) !void {
    const destination = try g.lookup(assignment.destination);
    if (analysis.isVectorType(destination.data_type)) return writeVectorAssignment(g, destination, assignment);
    const destination_reg = destination.reg orelse return error.CannotAssignConst;
    try writeScalarAssignment(g, destination, destination_reg, assignment);
    for (assignment.continuation) |step| {
        try writeBinary(g, destination, destination_reg, .{ .ident = assignment.destination }, step.op, step.rhs);
    }
}

/// Vector statements accept one binary operation, written either directly
/// or as a single-level expression.
fn writeVectorAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    if (assignment.lhs != .scalar_expression) {
        if (assignment.continuation.len != 0) return error.UnsupportedVectorExpressionTree;
        return vectors.writeVectorAssignment(g, destination, assignment);
    }
    const expression = assignment.lhs.scalar_expression;
    if (expression.lhs == .scalar_expression or expression.rhs == .scalar_expression) {
        return error.UnsupportedVectorExpressionTree;
    }
    var flattened = assignment;
    flattened.lhs = expression.lhs;
    flattened.op = expression.op;
    flattened.rhs = expression.rhs;
    return vectors.writeVectorAssignment(g, destination, flattened);
}

fn writeScalarAssignment(g: Gen, destination: Symbol, destination_reg: Register, assignment: ast.Assignment) !void {
    const op = assignment.op;
    const unary = op == .set or op == .bit_not or op == .negate;
    if (!unary) return writeBinary(g, destination, destination_reg, assignment.lhs, op, assignment.rhs orelse return error.InvalidAssignment);
    if (assignment.rhs != null) return error.InvalidAssignment;
    return writeUnary(g, destination, destination_reg, op, assignment.lhs);
}

fn writeUnary(g: Gen, destination: Symbol, destination_reg: Register, op: ast.AssignOp, value: ast.Value) !void {
    return switch (op) {
        .bit_not => writeBitNot(g, destination, destination_reg, value),
        .negate => writeNegate(g, destination, destination_reg, value),
        else => writeSetOrExpression(g, destination, destination_reg, value),
    };
}

fn writeSetOrExpression(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) anyerror!void {
    if (value == .scalar_expression) return writeScalarExpression(g, destination, destination_reg, value.scalar_expression);
    return writeSet(g, destination, destination_reg, value);
}

// ------------------------------------------------------------- set values

const Setter = *const fn (Gen, Symbol, Register, ast.Value) anyerror!void;

pub fn writeSet(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    return setters.get(std.meta.activeTag(value))(g, destination, destination_reg, value);
}

const setters = std.EnumArray(ValueTag, Setter).init(.{
    .ident = &setIdent,
    .vector_access = &setVectorLane,
    .vector_operation = &setTypeMismatch,
    .vector_shift = &setTypeMismatch,
    .accumulator_read = &setTypeMismatch,
    .vector_control_read = &setVectorControl,
    .hardware_read = &setHardwareRead,
    .scalar_comparison = &setComparison,
    .signed_less_than = &setSignedLessThan,
    .number = &setNumber,
    .load = &setLoad,
    .scalar_expression = &setExpression,
    .bit_cast = &setBitCast,
    .function_address = &setFunctionAddress,
    .code_address = &setCodeAddress,
    .data_address = &setDataAddress,
});

fn setTypeMismatch(_: Gen, _: Symbol, _: Register, _: ast.Value) !void {
    return error.RegisterTypeMismatch;
}

fn setExpression(_: Gen, _: Symbol, _: Register, _: ast.Value) !void {
    return error.UnsupportedScalarExpressionTree;
}

fn setNumber(g: Gen, _: Symbol, destination_reg: Register, value: ast.Value) !void {
    try operands.loadImmediateInto(g.out, destination_reg, value.number);
}

fn setIdent(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    const source = try g.lookup(value.ident);
    const source_reg = source.reg orelse return writeSymbolValue(g, destination_reg, source);
    try common.expectSameType(destination, source);
    try common.expectSameFunctionType(destination, source);
    try g.out.register(.@"or", destination_reg, source_reg, .zero);
}

/// Unsigned destinations zero-extend the sign-extended lane value.
fn setVectorLane(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    const access = value.vector_access;
    const lane = access.lane orelse return error.VectorLaneRequired;
    const source = try g.lookup(access.name);
    const source_reg = try analysis.vectorRegisterForView(source, access.view);
    try vectors.writeMfc2(g.out, destination_reg, source_reg, lane);
    if (destination.data_type == .u16 or destination.data_type == .u32) {
        try g.out.immediate(.andi, destination_reg, destination_reg, 65535);
    }
}

fn expectWord(destination: Symbol) !void {
    if (destination.data_type != .u32 and destination.data_type != .i32) return error.RegisterTypeMismatch;
}

fn setVectorControl(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    try expectWord(destination);
    try g.out.controlMove(.cfc2, destination_reg, @intFromEnum(value.vector_control_read));
}

fn setHardwareRead(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    const read = value.hardware_read;
    if (read.returns_dmem and destination.data_type != .dmem) return error.ExpectedDmemAddress;
    if (!read.returns_dmem) try expectWord(destination);
    try g.out.cop0(.mfc0, destination_reg, read.register);
}

fn setComparison(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    try writeScalarComparison(g, destination, destination_reg, value.scalar_comparison);
}

fn setSignedLessThan(g: Gen, _: Symbol, destination_reg: Register, value: ast.Value) !void {
    const comparison = value.signed_less_than;
    const lhs = try operands.valueAsAddressReg(g, comparison.lhs);
    const rhs = try operands.valueAsAddressReg(g, comparison.rhs);
    try g.out.register(.slt, destination_reg, lhs, rhs);
}

fn setLoad(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    if (!common.isCompatibleScalarLoad(destination.data_type, value.load.data_type)) return error.RegisterTypeMismatch;
    try memory.writeLoadInto(g, destination_reg, value.load);
}

/// Reinterprets a scalar; a value already in the destination needs nothing.
fn setBitCast(g: Gen, _: Symbol, destination_reg: Register, value: ast.Value) !void {
    const name = common.refName(value.bit_cast) orelse return error.RegisterTypeMismatch;
    const source = try g.lookup(name);
    if (source.vector_reg != null) return error.RegisterTypeMismatch;
    const source_reg = source.reg orelse return error.RegisterTypeMismatch;
    if (source_reg != destination_reg) try g.out.register(.@"or", destination_reg, source_reg, .zero);
}

fn setFunctionAddress(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    const target = value.function_address;
    const expected = destination.function_type orelse return error.FunctionAddressRequiresTypedRegister;
    try common.expectLocal(target.module);
    const function = try common.findFunction(g, target.name);
    if (!common.functionMatchesType(function, expected)) return error.FunctionTypeMismatch;
    try g.out.immediateSymbol(.addiu, destination_reg, .zero, target.name, 0);
}

fn setCodeAddress(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    const address = value.code_address;
    const symbol = try codeSymbol(g, destination, address.label);
    try g.out.immediateSymbol(.addiu, destination_reg, .zero, symbol, 0);
}

/// The assembly symbol of a function or a local label.
fn codeSymbol(g: Gen, destination: Symbol, label: []const u8) ![]const u8 {
    if (analysis.findFunction(g.functions, label)) |function| {
        const expected = destination.function_type orelse return label;
        if (!common.functionMatchesType(function, expected)) return error.FunctionTypeMismatch;
        return label;
    }
    const local = g.context.findLifetimeLabel(label) orelse return error.UnknownFunction;
    if (local.exported) return label;
    return g.localLabel(label, 0);
}

fn setDataAddress(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    const address = value.data_address;
    if (destination.data_type != .dmem) return error.ExpectedDmemAddress;
    const data = try g.lookup(address.label);
    const label = data.data_label orelse return error.ExpectedDataLabel;
    try g.out.immediateSymbol(.addiu, destination_reg, .zero, label, address.offset);
}

// ----------------------------------------------------------- expressions

fn needsRhsTemporary(expression: *const ast.ScalarExpression, destination: Symbol) bool {
    if (expression.rhs == .scalar_expression) return true;
    return expression.lhs == .scalar_expression and analysis.valueReadsName(expression.rhs, destination.name);
}

/// Evaluates an expression tree into the destination, using expression
/// temporaries for right operands that need their own register.
fn writeScalarExpression(g: Gen, destination: Symbol, destination_reg: Register, expression: *const ast.ScalarExpression) anyerror!void {
    if (!analysis.isPureScalarExpression(.{ .scalar_expression = @constCast(expression) })) {
        return error.SideEffectsNotAllowedInScalarExpression;
    }
    if (isNegation(expression)) return writeNegatedExpression(g, destination, destination_reg, expression.rhs);
    if (needsRhsTemporary(expression, destination)) return writeExpressionWithTemporary(g, destination, destination_reg, expression);
    const self: ast.Value = .{ .ident = destination.name };
    if (expression.lhs == .scalar_expression or expression.lhs == .number) {
        try writeSetOrExpression(g, destination, destination_reg, expression.lhs);
        return writeBinary(g, destination, destination_reg, self, expression.op, expression.rhs);
    }
    return writeBinary(g, destination, destination_reg, expression.lhs, expression.op, expression.rhs);
}

/// `-x` parses as `0 - x`.
fn isNegation(expression: *const ast.ScalarExpression) bool {
    return expression.lhs == .number and expression.lhs.number == 0 and expression.op == .sub;
}

fn writeNegatedExpression(g: Gen, destination: Symbol, destination_reg: Register, operand: ast.Value) anyerror!void {
    if (operand != .scalar_expression) return writeNegate(g, destination, destination_reg, operand);
    try writeScalarExpression(g, destination, destination_reg, operand.scalar_expression);
    return writeNegate(g, destination, destination_reg, .{ .ident = destination.name });
}

fn writeExpressionWithTemporary(g: Gen, destination: Symbol, destination_reg: Register, expression: *const ast.ScalarExpression) !void {
    const temporary = try g.context.pushExpressionTemporary(destination.data_type);
    defer g.context.popExpressionTemporary(temporary[0]);
    const symbol = temporary[1];
    try writeSetOrExpression(g, symbol, symbol.reg.?, expression.rhs);
    const rhs: ast.Value = .{ .ident = symbol.name };
    if (expression.lhs != .scalar_expression and expression.lhs != .number) {
        return writeBinary(g, destination, destination_reg, expression.lhs, expression.op, rhs);
    }
    try writeSetOrExpression(g, destination, destination_reg, expression.lhs);
    try writeBinary(g, destination, destination_reg, .{ .ident = destination.name }, expression.op, rhs);
}

// ----------------------------------------------------------- comparisons

/// The right operand of a scalar comparison, materialized if constant.
fn comparisonRhs(g: Gen, lhs: Symbol, rhs: ast.ValueRef) !Register {
    return switch (rhs) {
        .ident => |name| identComparisonRhs(g, lhs, try g.lookup(name)),
        .bit_cast => |name| bitCastComparisonRhs(try g.lookup(name)),
        .number => |number| operands.loadImmediate(g, number),
        .vector_access => error.ExpectedScalarType,
    };
}

fn identComparisonRhs(g: Gen, lhs: Symbol, rhs: Symbol) !Register {
    try common.expectSameType(lhs, rhs);
    if (rhs.reg) |reg| return reg;
    return operands.loadImmediate(g, rhs.constant orelse return error.ExpectedConstant);
}

fn bitCastComparisonRhs(rhs: Symbol) !Register {
    if (analysis.isVectorType(rhs.data_type)) return error.ExpectedScalarType;
    return rhs.reg orelse error.ComparisonRhsMustBeRegister;
}

fn comparisonLhs(g: Gen, comparison: ast.ScalarComparison) !Symbol {
    const name = common.refName(comparison.lhs) orelse return error.ComparisonLhsMustBeRegister;
    const lhs = try g.lookup(name);
    _ = lhs.reg orelse return error.ComparisonLhsMustBeRegister;
    if (analysis.isVectorType(lhs.data_type)) return error.ExpectedScalarType;
    return lhs;
}

/// Comparisons produce a normalized 0 or 1.
fn writeScalarComparison(g: Gen, destination: Symbol, destination_reg: Register, comparison: ast.ScalarComparison) !void {
    try expectWord(destination);
    const lhs = try comparisonLhs(g, comparison);
    const rhs_reg = try comparisonRhs(g, lhs, comparison.rhs);
    const operands_: [2]Register = .{ lhs.reg.?, rhs_reg };
    return switch (comparison.op) {
        .eq, .ne => writeEquality(g, destination_reg, operands_, comparison.op == .ne),
        else => writeOrdering(g, destination_reg, operands_, comparison.op, common.isSigned(lhs.data_type)),
    };
}

/// `a > b` is `b < a`; `<=` and `>=` invert the strict comparison.
fn writeOrdering(g: Gen, destination: Register, pair: [2]Register, op: ast.CompareOp, signed: bool) !void {
    const reverse = op == .gt or op == .le;
    const ordered: [2]Register = if (reverse) .{ pair[1], pair[0] } else pair;
    try g.out.register(if (signed) .slt else .sltu, destination, ordered[0], ordered[1]);
    if (op == .le or op == .ge) try g.out.immediate(.xori, destination, destination, 1);
}

fn writeEquality(g: Gen, destination: Register, pair: [2]Register, not_equal: bool) !void {
    var tested = pair[0];
    if (pair[1] != .zero) {
        try g.out.register(.xor, destination, pair[0], pair[1]);
        tested = destination;
    }
    if (not_equal) return g.out.register(.sltu, destination, .zero, tested);
    try g.out.immediate(.sltiu, destination, tested, 1);
}

// ------------------------------------------------------------- unary ops

fn writeBitNot(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    const name = common.identName(value) orelse return error.BitNotRequiresRegister;
    const source = try g.lookup(name);
    try common.expectSameType(destination, source);
    const source_reg = source.reg orelse return error.BitNotRequiresRegister;
    try g.out.register(.nor, destination_reg, source_reg, .zero);
}

/// Signed negation traps on overflow like other signed arithmetic.
fn writeNegate(g: Gen, destination: Symbol, destination_reg: Register, value: ast.Value) !void {
    if (value == .number) return writeNegatedConstant(g, destination_reg, value.number);
    const name = common.identName(value) orelse return error.NegateRequiresRegister;
    const source = try g.lookup(name);
    try common.expectSameType(destination, source);
    if (analysis.isVectorType(destination.data_type)) return error.NegateRequiresRegister;
    const source_reg = source.reg orelse return error.NegateRequiresRegister;
    try g.out.register(if (common.isSigned(destination.data_type)) .sub else .subu, destination_reg, .zero, source_reg);
}

fn writeNegatedConstant(g: Gen, destination_reg: Register, value: i64) !void {
    const negated = std.math.negate(value) catch return error.ImmediateOutOfRange;
    try operands.loadImmediateInto(g.out, destination_reg, negated);
}

// -------------------------------------------------------- binary operations

const Binary = struct {
    g: Gen,
    destination: Symbol,
    destination_reg: Register,
    lhs_reg: Register,
    op: ast.AssignOp,
};

fn binaryLhs(g: Gen, destination: Symbol, value: ast.Value) !Symbol {
    const name = common.scalarOperandName(value) orelse return error.ArithmeticLhsMustBeRegister;
    const lhs = try g.lookup(name);
    if (value != .bit_cast) try common.expectSameType(destination, lhs);
    return lhs;
}

pub fn writeBinary(g: Gen, destination: Symbol, destination_reg: Register, lhs_value: ast.Value, op: ast.AssignOp, rhs: ast.Value) !void {
    const lhs = try binaryLhs(g, destination, lhs_value);
    const binary: Binary = .{
        .g = g,
        .destination = destination,
        .destination_reg = destination_reg,
        .lhs_reg = lhs.reg orelse return error.ArithmeticLhsMustBeRegister,
        .op = op,
    };
    return switch (op) {
        .mul, .div => writePowerOfTwoMath(binary, rhs),
        .shift_left, .shift_right, .logical_shift_right => writeShift(binary, rhs),
        else => writeArithmetic(binary, rhs),
    };
}

fn writeArithmetic(binary: Binary, rhs: ast.Value) !void {
    return switch (rhs) {
        .ident => |name| writeArithmeticSymbol(binary, try binary.g.lookup(name)),
        .number => |number| writeBinaryImmediate(binary, number),
        .bit_cast => |source| writeArithmeticBitCast(binary, source),
        else => error.ArithmeticRhsMustBeRegisterOrNumber,
    };
}

/// A storage label operand adds its address as a relocated immediate.
fn writeArithmeticSymbol(binary: Binary, rhs: Symbol) !void {
    if (rhs.data_label) |label| return writeLabelAddend(binary, label);
    if (binary.destination.data_type != rhs.data_type and !common.isDmemScalarPair(binary.destination.data_type, rhs.data_type)) {
        return error.RegisterTypeMismatch;
    }
    const rhs_reg = rhs.reg orelse return writeBinaryImmediate(binary, rhs.constant orelse return error.ExpectedConstant);
    try writeRegisterBinary(binary, rhs_reg);
}

fn writeLabelAddend(binary: Binary, label: []const u8) !void {
    if (binary.op != .add and binary.op != .add_wrap) return error.UnsupportedOperator;
    const op: ir.Op = if (binary.op == .add) .addi else .addiu;
    try binary.g.out.immediateSymbol(op, binary.destination_reg, binary.lhs_reg, label, 0);
}

fn writeArithmeticBitCast(binary: Binary, source: ast.ValueRef) !void {
    const name = common.refName(source) orelse return error.ArithmeticRhsMustBeRegisterOrNumber;
    const rhs = try binary.g.lookup(name);
    if (analysis.isVectorType(rhs.data_type)) return error.ArithmeticRhsMustBeRegisterOrNumber;
    try writeRegisterBinary(binary, rhs.reg orelse return error.ArithmeticRhsMustBeRegisterOrNumber);
}

fn writeRegisterBinary(binary: Binary, rhs_reg: Register) !void {
    const op = registerOp(binary.op) orelse return error.UnsupportedOperator;
    try binary.g.out.register(op, binary.destination_reg, binary.lhs_reg, rhs_reg);
}

fn registerOp(op: ast.AssignOp) ?ir.Op {
    return register_ops.get(op);
}

const register_ops = blk: {
    var table = std.EnumArray(ast.AssignOp, ?ir.Op).initFill(null);
    table.set(.add, .add);
    table.set(.add_wrap, .addu);
    table.set(.sub, .sub);
    table.set(.sub_wrap, .subu);
    table.set(.bit_and, .@"and");
    table.set(.bit_or, .@"or");
    table.set(.bit_xor, .xor);
    table.set(.bit_nor, .nor);
    break :blk table;
};

fn logicImmediateOp(op: ast.AssignOp) ?ir.Op {
    return switch (op) {
        .bit_and => .andi,
        .bit_or => .ori,
        .bit_xor => .xori,
        else => null,
    };
}

/// Uses an immediate form when the constant fits, else materializes it in
/// `$v1`.
fn writeBinaryImmediate(binary: Binary, immediate: i64) !void {
    if (try writeFittingImmediate(binary, immediate)) return;
    const scratch = try operands.backendScratch2(binary.g.context);
    try operands.loadImmediateInto(binary.g.out, scratch, immediate);
    try writeRegisterBinary(binary, scratch);
}

fn writeFittingImmediate(binary: Binary, immediate: i64) !bool {
    return switch (binary.op) {
        .add, .sub, .add_wrap, .sub_wrap => writeAddend(binary, immediate),
        .bit_and, .bit_or, .bit_xor => writeLogicImmediate(binary, immediate),
        .bit_nor => error.NorRequiresRegister,
        else => error.UnsupportedOperator,
    };
}

/// The immediate to add; subtraction adds the negation.
fn addendFor(op: ast.AssignOp, immediate: i64) !i64 {
    if (op == .add or op == .add_wrap) return immediate;
    return std.math.negate(immediate) catch error.ImmediateOutOfRange;
}

fn writeAddend(binary: Binary, immediate: i64) !bool {
    const addend = try addendFor(binary.op, immediate);
    if (!common.fitsSigned16(addend)) return false;
    const trapping = binary.op == .add or binary.op == .sub;
    try binary.g.out.immediate(if (trapping) .addi else .addiu, binary.destination_reg, binary.lhs_reg, addend);
    return true;
}

fn writeLogicImmediate(binary: Binary, immediate: i64) !bool {
    if (!common.fitsUnsigned16(immediate)) return false;
    try binary.g.out.immediate(logicImmediateOp(binary.op).?, binary.destination_reg, binary.lhs_reg, immediate);
    return true;
}

/// The constant operand of `*` and `/`, which must be a power of two.
fn powerOfTwoOperand(binary: Binary, rhs: ast.Value) !i64 {
    if (rhs == .number) return rhs.number;
    const name = common.identName(rhs) orelse return error.PowerOfTwoConstantRequired;
    const symbol = try binary.g.lookup(name);
    try common.expectSameType(binary.destination, symbol);
    if (symbol.reg != null) return error.PowerOfTwoConstantRequired;
    return symbol.constant orelse error.ExpectedConstant;
}

/// `* 2^n` shifts left; `/ 2^n` shifts right, arithmetically if signed.
fn writePowerOfTwoMath(binary: Binary, rhs: ast.Value) !void {
    const shift = try powerOfTwoShift(try powerOfTwoOperand(binary, rhs));
    const op: ir.Op = if (binary.op == .mul) .sll else if (common.isSigned(binary.destination.data_type)) .sra else .srl;
    try binary.g.out.shift(op, binary.destination_reg, binary.lhs_reg, shift);
}

fn powerOfTwoShift(value: i64) !u5 {
    if (value <= 0 or value > std.math.maxInt(u32)) return error.PowerOfTwoConstantRequired;
    const unsigned: u32 = @intCast(value);
    if (!std.math.isPowerOfTwo(unsigned)) return error.PowerOfTwoConstantRequired;
    if (unsigned == 1) return error.NoOpPowerOfTwoMath;
    return @intCast(@ctz(unsigned));
}

fn writeShift(binary: Binary, rhs: ast.Value) !void {
    if (rhs == .number) return writeImmediateShift(binary, rhs.number);
    const name = common.identName(rhs) orelse return error.ShiftAmountMustBeRegisterOrNumber;
    const amount = try binary.g.lookup(name);
    try common.expectSameType(binary.destination, amount);
    if (amount.constant) |constant| return writeImmediateShift(binary, constant);
    const amount_reg = amount.reg orelse return error.ShiftAmountMustBeRegisterOrNumber;
    try binary.g.out.shiftVariable(shiftOp(binary, true), binary.destination_reg, binary.lhs_reg, amount_reg);
}

fn writeImmediateShift(binary: Binary, amount: i64) !void {
    if (amount < 0 or amount > 31) return error.InvalidShiftAmount;
    try binary.g.out.shift(shiftOp(binary, false), binary.destination_reg, binary.lhs_reg, amount);
}

/// `>>` is arithmetic for signed values; `>>>` is always logical.
fn shiftOp(binary: Binary, variable: bool) ir.Op {
    const arithmetic = binary.op == .shift_right and common.isSigned(binary.destination.data_type);
    const forms: [3][2]ir.Op = .{ .{ .sll, .sllv }, .{ .srl, .srlv }, .{ .sra, .srav } };
    const kind: usize = if (binary.op == .shift_left) 0 else if (arithmetic) 2 else 1;
    return forms[kind][@intFromBool(variable)];
}

test "operator tables cover the register and immediate forms" {
    try std.testing.expectEqual(@as(?ir.Op, .nor), registerOp(.bit_nor));
    try std.testing.expectEqual(@as(?ir.Op, null), registerOp(.mul));
    try std.testing.expectEqual(@as(?ir.Op, .xori), logicImmediateOp(.bit_xor));
    try std.testing.expectEqual(@as(?ir.Op, null), logicImmediateOp(.add));
    try std.testing.expectError(error.ImmediateOutOfRange, addendFor(.sub, std.math.minInt(i64)));
    try std.testing.expectEqual(@as(u5, 3), try powerOfTwoShift(8));
    try std.testing.expectError(error.PowerOfTwoConstantRequired, powerOfTwoShift(1 << 33));
}
