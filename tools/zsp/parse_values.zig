const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const Parser = @import("parser.zig").Parser;
const binaryPrecedence = @import("parser.zig").binaryPrecedence;
const cp0NamedReadRegister = @import("parser.zig").cp0NamedReadRegister;
const explicitAccumulatorPart = @import("parser.zig").explicitAccumulatorPart;
const isUnaryVectorOp = @import("parser.zig").isUnaryVectorOp;
const parseAccumulatorPart = @import("parser.zig").parseAccumulatorPart;
const parseSwizzle = @import("parser.zig").parseSwizzle;
const parseVectorOp = @import("parser.zig").parseVectorOp;
const parseVectorView = @import("parser.zig").parseVectorView;
const valueFromRef = @import("parser.zig").valueFromRef;
const vectorAccessFromRef = @import("parser.zig").vectorAccessFromRef;
const vectorControlRegisterForOperation = @import("parser.zig").vectorControlRegisterForOperation;

pub fn parseValue(self: *Parser) anyerror!ast.Value {
    if (try self.eat(.ampersand)) return .{ .function_address = try self.parseFunctionReference() };
    if (self.current.tag == .ident) return self.parseNamedValue();
    return valueFromRef(try self.parseValueRef());
}

const ValueParser = *const fn (*Parser) anyerror!ast.Value;
const namespace_value_parsers = std.StaticStringMap(ValueParser).initComptime(.{
    .{ "scalar", parseScalarMaterialization },
    .{ "rsp", parseHardwareRead },
    .{ "dmem", parseDmemAddress },
    .{ "code", parseCodeAddress },
});
const builtin_value_parsers = std.StaticStringMap(ValueParser).initComptime(.{
    .{ "signedLessThan", parseSignedComparison },
    .{ "bitCast", parseBitCast },
    .{ "load", parseLoadValue },
    .{ "loadUnaligned", parseLoadValue },
    .{ "loadVectorBytes", parseLoadValue },
    .{ "loadVectorBytesUnsigned", parseLoadValue },
    .{ "loadVectorWords", parseLoadValue },
    .{ "accumulator", parseAccumulatorValue },
    .{ "vectorShiftLeft8", parseVectorShiftValue },
    .{ "vectorShiftRightArithmetic", parseVectorShiftValue },
    .{ "vectorShiftRightLogical", parseVectorShiftValue },
});

pub fn parseNamedValue(self: *Parser) anyerror!ast.Value {
    var lookahead = self.lexer;
    if ((try lookahead.next()).tag == .dot) {
        if (namespace_value_parsers.get(self.current.text)) |parse_value| return parse_value(self);
    }
    if (builtin_value_parsers.get(self.current.text)) |parse_value| return parse_value(self);
    return self.parseVectorOrReferenceValue();
}

pub fn parseVectorOrReferenceValue(self: *Parser) anyerror!ast.Value {
    if (explicitAccumulatorPart(self.current.text) != null) return self.parseAccumulatorValue();
    if (parseVectorOp(self.current.text) != null) return self.parseVectorOperationValue();
    return valueFromRef(try self.parseValueRef());
}

pub fn parseScalarMaterialization(self: *Parser) anyerror!ast.Value {
    _ = try self.expect(.ident);
    _ = try self.expect(.dot);
    const operation = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    if (std.mem.eql(u8, operation.text, "unsigned")) {
        const value = try self.parseNumberValue(try self.expect(.number));
        _ = try self.expect(.r_paren);
        return .{ .scalar_materialize = .{ .value = value, .encoding = .unsigned } };
    }
    if (std.mem.eql(u8, operation.text, "zero")) {
        _ = try self.expect(.r_paren);
        return .{ .scalar_materialize = .{ .value = 0, .encoding = .zero } };
    }
    return self.fail(operation, .unsupported_builtin);
}

pub fn parseHardwareRead(self: *Parser) anyerror!ast.Value {
    _ = try self.expect(.ident);
    _ = try self.expect(.dot);
    const facility = try self.expect(.ident);
    _ = try self.expect(.dot);
    const operation = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    if (std.mem.eql(u8, facility.text, "vector")) {
        const register = vectorControlRegisterForOperation(operation.text, "get") orelse
            return self.fail(operation, .unsupported_builtin);
        _ = try self.expect(.r_paren);
        return .{ .vector_control_read = register };
    }
    if (std.mem.eql(u8, facility.text, "cp0")) return parseCp0Read(self, operation);
    return self.fail(facility, .unsupported_builtin);
}

fn parseCp0Read(self: *Parser, operation: token.Token) !ast.Value {
    if (cp0NamedReadRegister(operation.text)) |register| {
        _ = try self.expect(.r_paren);
        return .{ .hardware_read = .{
            .register = register,
            .returns_dmem = register == 0,
        } };
    }
    if (!std.mem.eql(u8, operation.text, "read")) return self.fail(operation, .unsupported_builtin);
    const register_token = try self.expect(.number);
    const register = try self.parseNumberValue(register_token);
    if (register < 0 or register > 15) return self.fail(register_token, .invalid_hardware_register);
    _ = try self.expect(.r_paren);
    return .{ .hardware_read = .{ .register = @intCast(register) } };
}

pub fn parseDmemAddress(self: *Parser) anyerror!ast.Value {
    _ = try self.expect(.ident);
    _ = try self.expect(.dot);
    const operation = try self.expect(.ident);
    const unsigned = std.mem.eql(u8, operation.text, "addressOfUnsigned");
    if (!unsigned and !std.mem.eql(u8, operation.text, "addressOf"))
        return self.fail(operation, .unsupported_builtin);
    _ = try self.expect(.l_paren);
    const label = try self.expect(.ident);
    var offset: i64 = 0;
    if (try self.eat(.comma)) offset = try self.parseNumberValue(try self.expect(.number));
    _ = try self.expect(.r_paren);
    return .{ .data_address = .{ .label = label.text, .offset = offset, .unsigned = unsigned } };
}

pub fn parseCodeAddress(self: *Parser) anyerror!ast.Value {
    _ = try self.expect(.ident);
    _ = try self.expect(.dot);
    const operation = try self.expect(.ident);
    const unsigned = std.mem.eql(u8, operation.text, "addressOfUnsigned");
    if (!unsigned and !std.mem.eql(u8, operation.text, "addressOf"))
        return self.fail(operation, .unsupported_builtin);
    _ = try self.expect(.l_paren);
    const label = try self.expect(.ident);
    _ = try self.expect(.r_paren);
    return .{ .code_address = .{ .label = label.text, .unsigned = unsigned } };
}

pub fn parseSignedComparison(self: *Parser) anyerror!ast.Value {
    _ = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const lhs = try self.parseValueRef();
    _ = try self.expect(.comma);
    const rhs = try self.parseValueRef();
    _ = try self.expect(.r_paren);
    return .{ .signed_less_than = .{ .lhs = lhs, .rhs = rhs } };
}

pub fn parseBitCast(self: *Parser) anyerror!ast.Value {
    _ = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const source = try self.parseValueRef();
    _ = try self.expect(.r_paren);
    return .{ .bit_cast = source };
}

pub fn parseLoadValue(self: *Parser) anyerror!ast.Value {
    const packed_u8 = std.mem.eql(u8, self.current.text, "loadVectorBytes");
    const packed_unsigned_u8 = std.mem.eql(u8, self.current.text, "loadVectorBytesUnsigned");
    const partial_u32 = std.mem.eql(u8, self.current.text, "loadVectorWords");
    const unaligned = std.mem.eql(u8, self.current.text, "loadUnaligned");
    _ = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const memory = @import("parse_memory.zig");
    const load_type = try memory.parseLoadType(self, packed_u8 or packed_unsigned_u8 or partial_u32);
    var operand = try memory.Operand.parseBase(self, load_type.offset, null);
    try operand.parseOffset(self);
    const partial_u32_lane = try memory.parseWordLane(self, partial_u32);
    _ = try self.expect(.r_paren);
    return .{ .load = .{
        .data_type = load_type.data_type,
        .address = operand.address,
        .offset = operand.offset,
        .label_offset = operand.label,
        .packed_u8 = packed_u8,
        .packed_unsigned_u8 = packed_unsigned_u8,
        .partial_u32_lane = partial_u32_lane,
        .unaligned = unaligned,
    } };
}

pub fn parseAccumulatorValue(self: *Parser) anyerror!ast.Value {
    const operation = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const part = explicitAccumulatorPart(operation.text) orelse blk: {
        _ = try self.expect(.dot);
        const part_token = try self.expect(.ident);
        break :blk parseAccumulatorPart(part_token.text) orelse
            return self.fail(part_token, .invalid_accumulator_part);
    };
    _ = try self.expect(.r_paren);
    return .{ .accumulator_read = part };
}

const ShiftSpec = struct { kind: @FieldType(ast.VectorShift, "kind"), min: i64, max: i64 };
const vector_shifts = std.StaticStringMap(ShiftSpec).initComptime(.{
    .{ "vectorShiftLeft8", ShiftSpec{ .kind = .left_8, .min = 8, .max = 15 } },
    .{ "vectorShiftRightArithmetic", ShiftSpec{ .kind = .right_arithmetic, .min = 1, .max = 8 } },
    .{ "vectorShiftRightLogical", ShiftSpec{ .kind = .right_logical, .min = 1, .max = 8 } },
});

pub fn parseVectorShiftValue(self: *Parser) anyerror!ast.Value {
    const operation = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const source_token = self.current;
    const source = try vectorAccessFromRef(try self.parseValueRef()) orelse
        return self.fail(source_token, .expected_vector_operand);
    _ = try self.expect(.comma);
    const amount_value = try self.parseNumberValue(try self.expect(.number));
    const specification = vector_shifts.get(operation.text) orelse return self.fail(operation, .unsupported_builtin);
    if (amount_value < specification.min or amount_value > specification.max) return self.fail(operation, .unsupported_vector_shift);
    _ = try self.expect(.r_paren);
    return .{ .vector_shift = .{
        .kind = specification.kind,
        .source = source,
        .amount = @intCast(amount_value),
    } };
}

pub fn parseVectorOperationValue(self: *Parser) anyerror!ast.Value {
    const op_token = try self.expect(.ident);
    const op = parseVectorOp(op_token.text).?;
    _ = try self.expect(.l_paren);
    const lhs_token = self.current;
    const lhs = try vectorAccessFromRef(try self.parseValueRef()) orelse
        return self.fail(lhs_token, .expected_vector_operand);
    const rhs = if (isUnaryVectorOp(op)) lhs else blk: {
        _ = try self.expect(.comma);
        const rhs_token = self.current;
        break :blk try vectorAccessFromRef(try self.parseValueRef()) orelse
            return self.fail(rhs_token, .expected_vector_operand);
    };
    _ = try self.expect(.r_paren);
    return .{ .vector_operation = .{
        .op = op,
        .lhs = lhs,
        .rhs = rhs,
        .explicit_lane_encoding = std.mem.startsWith(u8, op_token.text, "vectorReciprocal") or
            std.mem.eql(u8, op_token.text, "vectorMove"),
    } };
}

pub fn parseFunctionReference(self: *Parser) !ast.FunctionRef {
    const first = try self.expect(.ident);
    if (try self.eat(.dot)) {
        return .{
            .module = first.text,
            .name = (try self.expect(.ident)).text,
        };
    }
    return .{ .name = first.text };
}

pub fn parseScalarExpression(self: *Parser, minimum_precedence: u4) !ast.Value {
    var lhs = if (try self.eat(.l_paren)) blk: {
        const grouped = try self.parseScalarExpression(0);
        _ = try self.expect(.r_paren);
        break :blk grouped;
    } else try self.parseValue();

    while (binaryPrecedence(self.current.tag)) |precedence| {
        if (precedence < minimum_precedence) break;
        const op = (try self.parseBinaryAssignOp()).?;
        const rhs = try self.parseScalarExpression(precedence + 1);
        const expression = try self.allocator.create(ast.ScalarExpression);
        expression.* = .{ .lhs = lhs, .op = op, .rhs = rhs };
        lhs = .{ .scalar_expression = expression };
    }
    return lhs;
}

/// A literal, a name, `bitCast(name)`, a compile-time member such as
/// `Mode.fast`, or a vector access.
pub fn parseValueRef(self: *Parser) !ast.ValueRef {
    if (try self.eat(.minus)) return parseNegativeNumber(self);
    return switch (self.current.tag) {
        .ident => parseNamedRef(self, try self.expect(.ident)),
        .number => .{ .number = try self.parseNumberValue(try self.expect(.number)) },
        else => self.fail(self.current, .expected_value),
    };
}

fn parseNegativeNumber(self: *Parser) !ast.ValueRef {
    const tok = try self.expect(.number);
    const value = try self.parseNumberValue(tok);
    return .{ .number = std.math.negate(value) catch return self.fail(tok, .invalid_number) };
}

fn parseNamedRef(self: *Parser, tok: token.Token) !ast.ValueRef {
    if (std.mem.eql(u8, tok.text, "bitCast") and self.current.tag == .l_paren) return parseBitCastRef(self);
    if (compileTimeMemberAhead(self, tok.text)) |member| {
        _ = try self.expect(.dot);
        _ = try self.expect(.ident);
        return .{ .number = member.value };
    }
    if (self.current.tag == .l_bracket or self.isVectorDotSuffix()) return .{ .vector_access = try self.parseVectorAccess(tok.text) };
    return .{ .ident = tok.text };
}

fn parseBitCastRef(self: *Parser) !ast.ValueRef {
    _ = try self.expect(.l_paren);
    const source = try self.expect(.ident);
    _ = try self.expect(.r_paren);
    return .{ .bit_cast = source.text };
}

/// The member a following `.name` selects when `type_name` is an enum or
/// flags type.
fn compileTimeMemberAhead(self: *const Parser, type_name: []const u8) ?Parser.CompileTimeMember {
    if (self.current.tag != .dot) return null;
    const next = self.peek(1) orelse return null;
    if (next[0].tag != .ident) return null;
    return self.lookupCompileTimeMember(type_name, next[0].text);
}

pub fn isVectorDotSuffix(self: *const Parser) bool {
    if (self.current.tag != .dot) return false;
    var lexer = self.lexer;
    const suffix = lexer.next() catch return false;
    return suffix.tag == .ident and
        (parseVectorView(suffix.text) != null or parseSwizzle(suffix.text) != null);
}

pub fn parseVectorAccess(self: *Parser, name: []const u8) !ast.VectorAccess {
    var access = ast.VectorAccess{ .name = name };
    if (try self.eat(.l_bracket)) return parseVectorLane(self, access);
    _ = try self.expect(.dot);
    const suffix = try self.expect(.ident);
    access.view = parseVectorView(suffix.text);
    if (access.view == null) return applySwizzle(self, access, suffix);
    if (try self.eat(.l_bracket)) return parseVectorLane(self, access);
    if (try self.eat(.dot)) return applySwizzle(self, access, try self.expect(.ident));
    return access;
}

fn parseVectorLane(self: *Parser, original: ast.VectorAccess) !ast.VectorAccess {
    const lane_token = try self.expect(.number);
    const number = try self.parseNumberValue(lane_token);
    const lane = std.math.cast(u3, number) orelse return self.fail(lane_token, .invalid_vector_lane);
    _ = try self.expect(.r_bracket);
    var access = original;
    access.element = @as(u4, lane) + 8;
    access.lane = lane;
    return access;
}

fn applySwizzle(self: *Parser, original: ast.VectorAccess, suffix: token.Token) !ast.VectorAccess {
    const swizzle = parseSwizzle(suffix.text) orelse return self.fail(suffix, .invalid_vector_swizzle);
    var access = original;
    access.element = swizzle.element;
    access.lane = swizzle.lane;
    return access;
}

pub fn parseLiteralOffset(self: *Parser) !i64 {
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "offsetOf")) {
        _ = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        const type_name = try self.expect(.ident);
        _ = try self.expect(.comma);
        const field_name = try self.expect(.ident);
        _ = try self.expect(.r_paren);
        return self.packedStructFieldOffset(type_name, field_name);
    }
    const tok = self.current;
    return switch (try self.parseValueRef()) {
        .number => |number| number,
        .ident, .bit_cast, .vector_access => self.fail(tok, .expected_literal_offset),
    };
}

pub fn packedStructFieldOffset(self: *Parser, type_name: token.Token, field_name: token.Token) !i64 {
    const declaration = self.findPackedStruct(type_name.text) orelse return self.fail(type_name, .expected_literal_offset);
    const field = @import("parse_declarations.zig").packedField(declaration, field_name.text) orelse
        return self.fail(field_name, .expected_literal_offset);
    return field.offset;
}

pub fn parseCondition(self: *Parser) !ast.Condition {
    const lhs = try self.expect(.ident);
    const op = (try self.parseComparisonOperator()) orelse
        return self.fail(self.current, .expected_comparison_operator);
    return .{
        .lhs = lhs.text,
        .op = op,
        .rhs = valueFromRef(try self.parseValueRef()),
    };
}

const comparison_operators = std.EnumArray(token.Tag, ?ast.CompareOp).initDefault(@as(?ast.CompareOp, null), .{
    .equal_equal = .eq,
    .not_equal = .ne,
    .less = .lt,
    .less_equal = .le,
    .greater = .gt,
    .greater_equal = .ge,
});

pub fn parseComparisonOperator(self: *Parser) !?ast.CompareOp {
    const op = comparison_operators.get(self.current.tag) orelse return null;
    self.current = try self.lexer.next();
    return op;
}

const compound_operators = std.EnumArray(token.Tag, ?ast.AssignOp).initDefault(@as(?ast.AssignOp, null), .{
    .plus_equal = .add,
    .plus_percent_equal = .add_wrap,
    .minus_equal = .sub,
    .minus_percent_equal = .sub_wrap,
    .star_equal = .mul,
    .slash_equal = .div,
    .shift_left_equal = .shift_left,
    .shift_right_equal = .shift_right,
    .logical_shift_right_equal = .logical_shift_right,
    .ampersand_equal = .bit_and,
    .pipe_equal = .bit_or,
    .caret_equal = .bit_xor,
    .nor_equal = .bit_nor,
});

pub fn parseCompoundAssignOp(self: *Parser) !?ast.AssignOp {
    const op = compound_operators.get(self.current.tag) orelse return null;
    self.current = try self.lexer.next();
    return op;
}

const binary_operators = std.EnumArray(token.Tag, ?ast.AssignOp).initDefault(@as(?ast.AssignOp, null), .{
    .plus = .add,
    .plus_percent = .add_wrap,
    .minus = .sub,
    .minus_percent = .sub_wrap,
    .star = .mul,
    .slash = .div,
    .shift_left = .shift_left,
    .shift_right = .shift_right,
    .logical_shift_right = .logical_shift_right,
    .ampersand = .bit_and,
    .pipe = .bit_or,
    .caret = .bit_xor,
    .nor = .bit_nor,
});

pub fn parseBinaryAssignOp(self: *Parser) !?ast.AssignOp {
    const op = binary_operators.get(self.current.tag) orelse return null;
    self.current = try self.lexer.next();
    return op;
}
