//! State and type rules shared by the instruction-selection modules.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const Emitter = @import("Emitter.zig");

const DataType = ast.DataType;
const Symbol = analysis.Symbol;

/// What every emitter function needs: the IR sink, the linked program, and
/// the allocation state of the function being lowered.
pub const Gen = struct {
    out: *Emitter,
    functions: []const ast.Function,
    context: *analysis.FunctionContext,

    pub fn with(self: Gen, context: *analysis.FunctionContext) Gen {
        return .{ .out = self.out, .functions = self.functions, .context = context };
    }

    pub fn lookup(self: Gen, name: []const u8) !Symbol {
        return self.context.lookup(name);
    }

    /// `LABEL_<function>_<suffix>_<index>`, the spelling of local labels.
    pub fn localLabel(self: Gen, suffix: []const u8, index: usize) ![]const u8 {
        return self.out.name("LABEL_{s}_{s}_{d}", .{ self.context.label_prefix, suffix, index });
    }

    pub fn advance(self: Gen, count: usize) void {
        if (self.context.track_statement_position) self.context.statement_position += count;
    }
};

pub fn isSigned(data_type: DataType) bool {
    return switch (data_type) {
        .i8, .i16, .i32 => true,
        else => false,
    };
}

pub fn scalarDataSize(data_type: DataType) !usize {
    return switch (data_type) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .dmem => 4,
        .vec16, .vec32 => error.ExpectedScalarType,
    };
}

fn isWord(data_type: DataType) bool {
    return data_type == .u32 or data_type == .i32;
}

pub fn isDmemScalarPair(lhs: DataType, rhs: DataType) bool {
    return (lhs == .dmem and isWord(rhs)) or (rhs == .dmem and isWord(lhs));
}

pub fn expectSameType(lhs: Symbol, rhs: Symbol) !void {
    if (lhs.data_type != rhs.data_type and !isDmemScalarPair(lhs.data_type, rhs.data_type)) {
        return error.RegisterTypeMismatch;
    }
}

/// Word destinations, including DMEM addresses, accept narrower loads.
pub fn isCompatibleScalarLoad(destination: DataType, source: DataType) bool {
    if (destination == source) return true;
    const word_destination = isWord(destination) or destination == .dmem;
    if (!word_destination) return false;
    const size = scalarDataSize(source) catch return false;
    return size < 4 or destination == .dmem;
}

/// Signed and unsigned scalars of the same width share a representation.
pub fn scalarAbiTypesCompatible(lhs: DataType, rhs: DataType) bool {
    const lhs_size = scalarDataSize(lhs) catch return false;
    const rhs_size = scalarDataSize(rhs) catch return false;
    return lhs_size == rhs_size;
}

pub fn expectSameFunctionType(left: Symbol, right: Symbol) !void {
    const left_type = left.function_type orelse return expectNoFunctionType(right);
    const right_type = right.function_type orelse return error.FunctionTypeMismatch;
    if (!std.meta.eql(left_type, right_type)) return error.FunctionTypeMismatch;
}

fn expectNoFunctionType(symbol: Symbol) !void {
    if (symbol.function_type != null) return error.FunctionTypeMismatch;
}

fn parameterMatches(actual: ast.Parameter, wanted: ast.FunctionParameterType) bool {
    return scalarAbiTypesCompatible(actual.data_type, wanted.data_type) and
        actual.reg == wanted.reg and actual.vector_reg == wanted.vector_reg;
}

pub fn functionMatchesType(function: ast.Function, expected: ast.FunctionType) bool {
    if (function.parameters.len > expected.parameter_count) return false;
    for (function.parameters, expected.parameterSlice()[0..function.parameters.len]) |actual, wanted| {
        if (!parameterMatches(actual, wanted)) return false;
    }
    return true;
}

pub fn validateMemoryOffset(offset: i64) !void {
    if (!fitsSigned16(offset)) return error.MemoryOffsetOutOfRange;
}

pub fn fitsSigned16(value: i64) bool {
    return value >= std.math.minInt(i16) and value <= std.math.maxInt(i16);
}

pub fn fitsUnsigned16(value: i64) bool {
    return value >= 0 and value <= std.math.maxInt(u16);
}

pub fn invertComparison(op: ast.CompareOp) ast.CompareOp {
    return inverse_comparisons.get(op);
}

const inverse_comparisons = std.EnumArray(ast.CompareOp, ast.CompareOp).init(.{
    .eq = .ne,
    .ne = .eq,
    .lt = .ge,
    .le = .gt,
    .gt = .le,
    .ge = .lt,
});

/// The register a `fn`-free identifier names, used by operand helpers.
pub fn identName(value: ast.Value) ?[]const u8 {
    return if (value == .ident) value.ident else null;
}

/// The identifier behind `name` or `@bitCast(name)`.
pub fn scalarOperandName(value: ast.Value) ?[]const u8 {
    if (value == .bit_cast and value.bit_cast == .ident) return value.bit_cast.ident;
    return identName(value);
}

pub fn refName(value: ast.ValueRef) ?[]const u8 {
    return if (value == .ident) value.ident else null;
}

pub fn findFunction(g: Gen, name: []const u8) !ast.Function {
    return analysis.findFunction(g.functions, name) orelse error.UnknownFunction;
}

/// Calls must have been resolved to local names by module linking.
pub fn expectLocal(module: ?[]const u8) !void {
    if (module != null) return error.UnresolvedModuleCall;
}

const testing = std.testing;

test "scalar type rules accept representation-compatible pairs" {
    try testing.expect(isSigned(.i16) and !isSigned(.dmem));
    try testing.expect(isDmemScalarPair(.dmem, .u32) and isDmemScalarPair(.i32, .dmem));
    try testing.expect(!isDmemScalarPair(.dmem, .u16));
    try testing.expect(isCompatibleScalarLoad(.u32, .u8) and isCompatibleScalarLoad(.dmem, .i32));
    try testing.expect(isCompatibleScalarLoad(.dmem, .u16) and !isCompatibleScalarLoad(.u16, .u8));
    try testing.expect(!isCompatibleScalarLoad(.vec16, .u8));
    try testing.expect(scalarAbiTypesCompatible(.u16, .i16) and !scalarAbiTypesCompatible(.u16, .u32));
    try testing.expect(!scalarAbiTypesCompatible(.vec16, .u32));
    try testing.expectError(error.ExpectedScalarType, scalarDataSize(.vec32));
    try testing.expectEqual(ast.CompareOp.le, invertComparison(.gt));
    try testing.expectError(error.MemoryOffsetOutOfRange, validateMemoryOffset(40000));
    try testing.expect(fitsUnsigned16(65535) and !fitsUnsigned16(-1));
}

test "function types compare parameter registers and widths" {
    var expected: ast.FunctionType = .{ .parameter_count = 1 };
    expected.parameters[0] = .{ .data_type = .u32, .reg = .a0 };
    const function: ast.Function = .{
        .name = "f",
        .source_name = "f",
        .export_symbol = false,
        .public = false,
        .inline_call = false,
        .no_return = false,
        .parameters = &.{.{ .name = "x", .data_type = .i32, .reg = .a0 }},
        .statements = &.{},
    };
    try testing.expect(functionMatchesType(function, expected));
    expected.parameters[0].reg = .a1;
    try testing.expect(!functionMatchesType(function, expected));
    expected.parameter_count = 0;
    try testing.expect(!functionMatchesType(function, expected));
    const plain: Symbol = .{ .name = "a", .data_type = .u32, .reg = .t0, .constant = null };
    var typed = plain;
    typed.function_type = expected;
    try expectSameFunctionType(plain, plain);
    try testing.expectError(error.FunctionTypeMismatch, expectSameFunctionType(plain, typed));
    try testing.expectError(error.FunctionTypeMismatch, expectSameFunctionType(typed, plain));
    try expectSameFunctionType(typed, typed);
    try testing.expectEqualStrings("y", scalarOperandName(.{ .bit_cast = .{ .ident = "y" } }).?);
    try testing.expectEqual(@as(?[]const u8, null), scalarOperandName(.{ .number = 1 }));
}
