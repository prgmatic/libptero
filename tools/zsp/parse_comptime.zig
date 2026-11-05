//! Compile-time source expansion: constant expressions, `inline for`
//! unrolling, and register arrays. Each expands into ordinary statements
//! before analysis, so the backend never sees them.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const StatementList = Parser.StatementList;

/// The most iterations one `inline for` may unroll.
pub const max_iterations = 256;

/// Source statements that expand to zero or several AST statements.
/// Returns false when the current statement is an ordinary one.
pub fn parseExpandingStatement(self: *Parser, list: *StatementList, location: ast.SourceLocation) !bool {
    if (self.atKeyword("inline")) {
        try parseInlineFor(self, list);
        return true;
    }
    if (isRegisterArrayStart(self)) {
        try parseRegisterArray(self, list, location);
        return true;
    }
    return @import("parse_products.zig").parseAccumulatorStatement(self, list, location);
}

// ------------------------------------------------------ constant expressions

/// An integer known while parsing: literals, `offsetOf`, `sizeOf`,
/// enum and flags members, `inline for` captures, and operators on them.
pub fn parseConstExpression(self: *Parser) anyerror!i64 {
    return parseConstBinary(self, 0);
}

fn parseConstBinary(self: *Parser, minimum_precedence: u4) anyerror!i64 {
    var lhs = try parseConstPrimary(self);
    while (parser_mod.binaryPrecedence(self.current.tag)) |precedence| {
        if (precedence < minimum_precedence) break;
        const operator = self.current;
        const op = (try self.parseBinaryAssignOp()).?;
        const rhs = try parseConstBinary(self, precedence + 1);
        lhs = fold(op, lhs, rhs) orelse return self.fail(operator, .invalid_constant_expression);
    }
    return lhs;
}

const PrimaryParser = *const fn (*Parser) anyerror!i64;
const named_primaries = std.StaticStringMap(PrimaryParser).initComptime(.{
    .{ "offsetOf", parseOffsetOf },
    .{ "sizeOf", parseSizeOf },
});

fn parseConstPrimary(self: *Parser) anyerror!i64 {
    if (try self.eat(.minus)) return negate(self, try parseConstPrimary(self));
    if (try self.eat(.l_paren)) {
        const grouped = try parseConstExpression(self);
        _ = try self.expect(.r_paren);
        return grouped;
    }
    if (self.current.tag == .number) return self.parseNumberValue(try self.expect(.number));
    if (self.current.tag != .ident) return self.fail(self.current, .expected_literal_offset);
    if (named_primaries.get(self.current.text)) |parse_primary| return parse_primary(self);
    return parseMember(self);
}

fn negate(self: *Parser, value: i64) !i64 {
    return std.math.negate(value) catch self.fail(self.current, .invalid_number);
}

/// `Enum.member` or `Flags.member`.
fn parseMember(self: *Parser) !i64 {
    const type_name = try self.expect(.ident);
    if (!try self.eat(.dot)) return self.fail(type_name, .expected_literal_offset);
    const member_name = try self.expect(.ident);
    const member = self.lookupCompileTimeMember(type_name.text, member_name.text) orelse
        return self.fail(member_name, .expected_literal_offset);
    return member.value;
}

/// `offsetOf(Struct, field)`.
fn parseOffsetOf(self: *Parser) !i64 {
    _ = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const type_name = try self.expect(.ident);
    _ = try self.expect(.comma);
    const field_name = try self.expect(.ident);
    _ = try self.expect(.r_paren);
    return self.packedStructFieldOffset(type_name, field_name);
}

/// `sizeOf(T)` for a scalar type, `vec16`/`vec32`, or a packed struct.
fn parseSizeOf(self: *Parser) !i64 {
    _ = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const type_name = try self.expect(.ident);
    _ = try self.expect(.r_paren);
    return typeSize(self, type_name);
}

pub fn typeSize(self: *Parser, type_name: token.Token) !i64 {
    if (parser_mod.parseDataTypeName(type_name.text)) |data_type| return dataTypeSize(data_type);
    const declaration = self.findPackedStruct(type_name.text) orelse return self.fail(type_name, .unknown_packed_struct);
    return packedStructSize(declaration);
}

pub fn dataTypeSize(data_type: ast.DataType) i64 {
    return switch (data_type) {
        .vec16 => 16,
        .vec32 => 32,
        else => parser_mod.scalarTypeSize(data_type),
    };
}

pub fn packedStructSize(declaration: ast.PackedStructDecl) i64 {
    var size: i64 = 0;
    for (declaration.fields) |field| size += parser_mod.scalarTypeSize(field.data_type);
    return size;
}

/// `lhs op rhs` on compile-time integers; null when undefined, such as
/// division by zero or an out-of-range shift.
pub fn fold(op: ast.AssignOp, lhs: i64, rhs: i64) ?i64 {
    const operation = folders.get(op) orelse return null;
    return operation(lhs, rhs);
}

const Folder = *const fn (i64, i64) ?i64;

const folders = blk: {
    var table = std.EnumArray(ast.AssignOp, ?Folder).initFill(null);
    table.set(.add, &add);
    table.set(.add_wrap, &add);
    table.set(.sub, &subtract);
    table.set(.sub_wrap, &subtract);
    table.set(.mul, &multiply);
    table.set(.div, &divide);
    table.set(.shift_left, &shiftLeft);
    table.set(.shift_right, &shiftRight);
    table.set(.logical_shift_right, &shiftRight);
    table.set(.bit_and, &bitAnd);
    table.set(.bit_or, &bitOr);
    table.set(.bit_xor, &bitXor);
    table.set(.bit_nor, &bitNor);
    break :blk table;
};

fn add(lhs: i64, rhs: i64) ?i64 {
    return std.math.add(i64, lhs, rhs) catch null;
}

fn subtract(lhs: i64, rhs: i64) ?i64 {
    return std.math.sub(i64, lhs, rhs) catch null;
}

fn multiply(lhs: i64, rhs: i64) ?i64 {
    return std.math.mul(i64, lhs, rhs) catch null;
}

fn divide(lhs: i64, rhs: i64) ?i64 {
    return if (rhs == 0) null else @divTrunc(lhs, rhs);
}

fn shiftLeft(value: i64, amount: i64) ?i64 {
    const bits = std.math.cast(u6, amount) orelse return null;
    return std.math.shlExact(i64, value, bits) catch null;
}

fn shiftRight(value: i64, amount: i64) ?i64 {
    const bits = std.math.cast(u6, amount) orelse return null;
    return value >> bits;
}

fn bitAnd(lhs: i64, rhs: i64) ?i64 {
    return lhs & rhs;
}

fn bitOr(lhs: i64, rhs: i64) ?i64 {
    return lhs | rhs;
}

fn bitXor(lhs: i64, rhs: i64) ?i64 {
    return lhs ^ rhs;
}

fn bitNor(lhs: i64, rhs: i64) ?i64 {
    return ~(lhs | rhs);
}

// --------------------------------------------------------------- inline for

/// `inline for (first..end) |index| { ... }`: the body once per index,
/// with `index` a compile-time integer. Names declared in the body are
/// renamed per iteration.
fn parseInlineFor(self: *Parser, list: *StatementList) !void {
    _ = try self.expect(.ident);
    const for_keyword = try self.expect(.ident);
    if (!std.mem.eql(u8, for_keyword.text, "for")) return self.fail(for_keyword, .unexpected_token);
    _ = try self.expect(.l_paren);
    const range = try parseRange(self, for_keyword);
    _ = try self.expect(.r_paren);
    _ = try self.expect(.pipe);
    const capture = try self.expect(.ident);
    _ = try self.expect(.pipe);
    if (self.current.tag != .l_brace) return self.failExpected(self.current, .l_brace);
    const body: Resume = .{ .lexer = self.lexer, .current = self.current };
    if (range.first == range.end) return skipBlock(self);
    var index = range.first;
    while (index < range.end) : (index += 1) {
        self.lexer = body.lexer;
        self.current = body.current;
        try parseIteration(self, list, capture.text, index);
    }
}

const Range = struct { first: usize, end: usize };

fn parseRange(self: *Parser, at: token.Token) !Range {
    const first = try parseConstExpression(self);
    _ = try self.expect(.dot_dot);
    const end = try parseConstExpression(self);
    if (first < 0 or end < first or end - first > max_iterations) return self.fail(at, .invalid_inline_range);
    return .{ .first = @intCast(first), .end = @intCast(end) };
}

const Resume = struct { lexer: @import("lexer.zig").Lexer, current: token.Token };

fn parseIteration(self: *Parser, list: *StatementList, capture: []const u8, index: usize) !void {
    const substitutions = self.substitutions.items.len;
    defer self.restoreSubstitutions(substitutions);
    const scope = self.type_symbols.items.len;
    defer self.type_symbols.shrinkRetainingCapacity(scope);
    try self.iterations.append(self.allocator, index);
    defer _ = self.iterations.pop();
    try self.substitute(capture, .number, try self.generatedName("{d}", .{index}));
    _ = try self.expect(.l_brace);
    try self.parseStatementsUntilBrace(list);
}

/// Skips a braced body without parsing it, for an empty range.
fn skipBlock(self: *Parser) !void {
    var depth: usize = 0;
    while (true) {
        const tag = self.current.tag;
        if (tag == .eof) return self.failExpected(self.current, .r_brace);
        try self.advance();
        depth = if (tag == .l_brace) depth + 1 else if (tag == .r_brace) depth - 1 else depth;
        if (depth == 0) return;
    }
}

// ----------------------------------------------------------- register arrays

/// `reg name: [n]T` or `reg($v01) name: [n]T`.
fn isRegisterArrayStart(self: *const Parser) bool {
    if (!self.atKeyword("reg")) return false;
    const first = self.peek(1) orelse return false;
    if (first[0].tag != .l_paren) return arrayAfterName(self.peek(3));
    const pinned = self.peek(6) orelse return false;
    return arrayAfterName(pinned[3..6].*);
}

fn arrayAfterName(tokens: ?[3]token.Token) bool {
    const after = tokens orelse return false;
    return after[0].tag == .ident and after[1].tag == .colon and after[2].tag == .l_bracket;
}

/// One register per element, named `name[index]`. A pinned vector array
/// occupies consecutive registers from the one named.
fn parseRegisterArray(self: *Parser, list: *StatementList, location: ast.SourceLocation) !void {
    _ = try self.expect(.ident);
    const pinned = try parsePinnedVector(self);
    const name = try self.declaredName(try self.expect(.ident));
    _ = try self.expect(.colon);
    _ = try self.expect(.l_bracket);
    const len_token = self.current;
    const len = try parseConstExpression(self);
    if (len <= 0 or len > 32) return self.fail(len_token, .invalid_array_length);
    _ = try self.expect(.r_bracket);
    const type_token = try self.expect(.ident);
    const data_type = try self.parseDataType(type_token);
    if (pinned != null and !parser_mod.isVectorType(data_type)) return self.fail(type_token, .expected_vector_register);
    const initializer = try parseArrayInitializer(self);
    // Known before the semicolon lexes the next token, which may index it.
    try self.type_symbols.append(self.allocator, .{ .name = name.text, .data_type = data_type, .array_len = @intCast(len) });
    _ = try self.expect(.semicolon);
    const element: Element = .{ .data_type = data_type, .first = pinned, .initializer = initializer };
    for (0..@intCast(len)) |index| {
        try list.append(self.allocator, .{ .var_decl = try element.declaration(self, name.text, index) }, location);
    }
}

fn parsePinnedVector(self: *Parser) !?ast.VectorRegister {
    if (!try self.eat(.l_paren)) return null;
    const register_token = try self.expect(.register);
    _ = try self.expect(.r_paren);
    return parser_mod.parseVectorRegister(register_token) orelse self.fail(register_token, .expected_vector_register);
}

const ArrayInitializer = union(enum) { none, undefined, value: i64 };

/// Nothing, `= undefined`, or one literal that every element starts with.
fn parseArrayInitializer(self: *Parser) !ArrayInitializer {
    if (!try self.eat(.equal)) return .none;
    if (try self.eatKeyword("undefined")) return .undefined;
    return .{ .value = try parseConstExpression(self) };
}

const Element = struct {
    data_type: ast.DataType,
    first: ?ast.VectorRegister,
    initializer: ArrayInitializer,

    fn declaration(self: Element, parser: *Parser, array: []const u8, index: usize) !ast.VarDecl {
        const name = try parser.elementName(array, index);
        try parser.addTypeSymbol(name, self.data_type);
        return .{
            .is_const = false,
            .allow_undefined_read = self.initializer == .undefined,
            .data_type = self.data_type,
            .reg = null,
            .vector_reg = try self.register(parser, index),
            .name = name,
            .value = if (self.initializer == .value) .{ .number = self.initializer.value } else null,
        };
    }

    fn register(self: Element, parser: *Parser, index: usize) !?ast.VectorRegister {
        const first = self.first orelse return null;
        const width: usize = if (self.data_type == .vec32) 2 else 1;
        const number = @intFromEnum(first) + index * width;
        if (number > 31) return parser.fail(parser.current, .expected_vector_register);
        return @enumFromInt(number);
    }
};
