//! Declarations: functions and their parameters, register and constant
//! variables, compile-time enums and flags, imports, packed structs, and
//! storage blocks.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const isVectorType = parser_mod.isVectorType;
const parseRegister = parser_mod.parseRegister;
const parseVectorRegister = parser_mod.parseVectorRegister;
const pointers = @import("parse_pointers.zig");

// ------------------------------------------------------------- functions

/// Keywords written before `fn`; the field names are the keywords.
const Prefixes = struct {
    @"export": bool = false,
    @"extern": bool = false,
    @"inline": bool = false,
    @"pub": bool = false,
};

pub fn parseFunctionDeclaration(self: *Parser) !ast.Function {
    var prefixes: Prefixes = .{};
    var command_indices: std.ArrayList(u8) = .empty;
    errdefer command_indices.deinit(self.allocator);
    while (!try parseFunctionPrefix(self, &prefixes, &command_indices)) {}
    return parseFunction(self, prefixes, try command_indices.toOwnedSlice(self.allocator));
}

/// Consumes one prefix or attribute; true once `fn` is consumed.
fn parseFunctionPrefix(self: *Parser, prefixes: *Prefixes, command_indices: *std.ArrayList(u8)) !bool {
    if (self.current.tag == .at) {
        try parseRspqNumberAttribute(self, "command", command_indices);
        return false;
    }
    const prefix = try self.expect(.ident);
    if (std.mem.eql(u8, prefix.text, "fn")) return true;
    const flag = prefixFlag(prefixes, prefix.text) orelse return self.fail(prefix, .expected_function_declaration);
    flag.* = true;
    return false;
}

fn prefixFlag(prefixes: *Prefixes, text: []const u8) ?*bool {
    inline for (std.meta.fields(Prefixes)) |field| {
        if (std.mem.eql(u8, text, field.name)) return &@field(prefixes, field.name);
    }
    return null;
}

pub fn isFunctionDeclarationStart(self: *const Parser) bool {
    if (self.current.tag == .at) return startsCommandAttribute(self);
    if (self.current.tag != .ident) return false;
    return std.mem.eql(u8, self.current.text, "fn") or isPrefixKeyword(self.current.text);
}

fn isPrefixKeyword(text: []const u8) bool {
    var prefixes: Prefixes = .{};
    return prefixFlag(&prefixes, text) != null;
}

fn startsCommandAttribute(self: *const Parser) bool {
    const next = self.peek(3) orelse return false;
    return isIdent(next[0], "rspq") and next[1].tag == .dot and isIdent(next[2], "command");
}

fn isIdent(tok: token.Token, text: []const u8) bool {
    return tok.tag == .ident and std.mem.eql(u8, tok.text, text);
}

/// Suffixes after the parameter list: `noreturn`, `writes(...)`,
/// `align(n)`, and `@rspq.commandSize(...)`.
const Modifiers = struct {
    no_return: bool = false,
    alignment: u16 = 4,
    has_clobber_contract: bool = false,
    command_sizes: std.ArrayList(u8) = .empty,
    clobber_regs: std.ArrayList(ast.Register) = .empty,
    clobber_vector_regs: std.ArrayList(ast.VectorRegister) = .empty,

    fn deinit(self: *Modifiers, allocator: std.mem.Allocator) void {
        self.command_sizes.deinit(allocator);
        self.clobber_regs.deinit(allocator);
        self.clobber_vector_regs.deinit(allocator);
    }
};

fn parseFunction(self: *Parser, prefixes: Prefixes, command_indices: []const u8) !ast.Function {
    self.function_names.clearRetainingCapacity();
    const function_scope = self.type_symbols.items.len;
    defer self.type_symbols.shrinkRetainingCapacity(function_scope);
    const name = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const parameters = try parseParameters(self);
    errdefer self.allocator.free(parameters.items);
    var modifiers: Modifiers = .{};
    errdefer modifiers.deinit(self.allocator);
    while (self.current.tag == .ident or self.current.tag == .at) try parseModifier(self, &modifiers);
    const internal = !prefixes.@"export" and !prefixes.@"extern" and command_indices.len == 0;
    try applyDefaultParameterRegisters(self, parameters.items, parameters.first_unpinned, internal);
    const statements = try parseFunctionBody(self, prefixes);
    return .{
        .name = name.text,
        .source_name = name.text,
        .export_symbol = prefixes.@"export",
        .public = prefixes.@"pub",
        .inline_call = prefixes.@"inline",
        .external = prefixes.@"extern",
        .no_return = modifiers.no_return,
        .alignment = modifiers.alignment,
        .command_indices = command_indices,
        .command_sizes = try modifiers.command_sizes.toOwnedSlice(self.allocator),
        .has_clobber_contract = modifiers.has_clobber_contract,
        .clobber_regs = try modifiers.clobber_regs.toOwnedSlice(self.allocator),
        .clobber_vector_regs = try modifiers.clobber_vector_regs.toOwnedSlice(self.allocator),
        .parameters = parameters.items,
        .statements = statements,
    };
}

/// A block, or `;` for an external declaration.
fn parseFunctionBody(self: *Parser, prefixes: Prefixes) ![]ast.Statement {
    if (!prefixes.@"extern") {
        _ = try self.expect(.l_brace);
        return self.parseBlockStatements();
    }
    if (prefixes.@"inline" or prefixes.@"export") return error.InvalidExternalFunction;
    _ = try self.expect(.semicolon);
    return &.{};
}

fn parseModifier(self: *Parser, modifiers: *Modifiers) !void {
    if (self.current.tag == .at) return parseRspqNumberAttribute(self, "commandSize", &modifiers.command_sizes);
    const modifier = try self.expect(.ident);
    if (std.mem.eql(u8, modifier.text, "noreturn")) {
        modifiers.no_return = true;
        return;
    }
    if (std.mem.eql(u8, modifier.text, "align")) return parseAlignment(self, modifiers);
    if (!std.mem.eql(u8, modifier.text, "writes")) return self.fail(modifier, .unsupported_function_modifier);
    if (modifiers.has_clobber_contract) return self.fail(modifier, .duplicate_clobber_contract);
    modifiers.has_clobber_contract = true;
    try parseClobberContract(self, modifiers);
}

/// `align(n)`: the function starts at a multiple of `n` bytes, a power of
/// two from 4 (every instruction's alignment) to 4096.
fn parseAlignment(self: *Parser, modifiers: *Modifiers) !void {
    _ = try self.expect(.l_paren);
    const value_token = try self.expect(.number);
    const value = try self.parseNumberValue(value_token);
    if (value < 4 or value > 4096 or !std.math.isPowerOfTwo(value)) return self.fail(value_token, .invalid_function_alignment);
    modifiers.alignment = @intCast(value);
    _ = try self.expect(.r_paren);
}

/// `writes($t0, $v01, ...)`: every register the function may change.
fn parseClobberContract(self: *Parser, modifiers: *Modifiers) !void {
    _ = try self.expect(.l_paren);
    if (try self.eat(.r_paren)) return;
    while (true) {
        try parseClobberRegister(self, modifiers);
        if (try self.eat(.r_paren)) return;
        _ = try self.expect(.comma);
    }
}

fn parseClobberRegister(self: *Parser, modifiers: *Modifiers) !void {
    const register_token = try self.expect(.register);
    if (parseRegister(register_token)) |reg| return modifiers.clobber_regs.append(self.allocator, reg);
    const reg = parseVectorRegister(register_token) orelse return self.fail(register_token, .expected_register);
    try modifiers.clobber_vector_regs.append(self.allocator, reg);
}

// ------------------------------------------------------------ parameters

pub const ParsedParameters = struct {
    items: []ast.Parameter,
    first_unpinned: ?token.Token,
};

/// Parameters up to the closing parenthesis; a trailing comma is allowed.
pub fn parseParameters(self: *Parser) !ParsedParameters {
    var parameters: std.ArrayList(ast.Parameter) = .empty;
    errdefer parameters.deinit(self.allocator);
    var first_unpinned: ?token.Token = null;
    if (!try self.eat(.r_paren)) while (true) {
        try parameters.append(self.allocator, try parseParameter(self, &first_unpinned));
        if (try self.listEnds(.r_paren)) break;
    };
    return .{ .items = try parameters.toOwnedSlice(self.allocator), .first_unpinned = first_unpinned };
}

fn parseParameter(self: *Parser, first_unpinned: *?token.Token) !ast.Parameter {
    const register_token = try parseRegisterAttribute(self);
    const name = try self.expect(.ident);
    if (register_token == null and first_unpinned.* == null) first_unpinned.* = name;
    _ = try self.expect(.colon);
    const declared = try parseValueType(self);
    const data_type = declared.data_type.?;
    const binding = try optionalBinding(self, register_token, data_type);
    try self.type_symbols.append(self.allocator, .{ .name = name.text, .data_type = data_type, .pointee = declared.pointee });
    return .{ .name = name.text, .data_type = data_type, .reg = binding.reg, .vector_reg = binding.vector_reg };
}

/// `reg($t0)` before a parameter or a function type's parameter.
fn parseRegisterAttribute(self: *Parser) !?token.Token {
    if (!self.atKeyword("reg")) return null;
    _ = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const register_token = try self.expect(.register);
    _ = try self.expect(.r_paren);
    return register_token;
}

const Binding = struct { reg: ?ast.Register = null, vector_reg: ?ast.VectorRegister = null };

/// The register a token names, checked against the value's type.
fn parseBinding(self: *Parser, register_token: token.Token, data_type: ast.DataType) !Binding {
    if (!isVectorType(data_type)) {
        return .{ .reg = parseRegister(register_token) orelse return self.fail(register_token, .expected_scalar_register) };
    }
    return .{ .vector_reg = parseVectorRegister(register_token) orelse return self.fail(register_token, .expected_vector_register) };
}

fn optionalBinding(self: *Parser, register_token: ?token.Token, data_type: ast.DataType) !Binding {
    const fixed = register_token orelse return .{};
    return parseBinding(self, fixed, data_type);
}

const argument_registers = [_]ast.Register{ .a0, .a1, .a2, .a3 };

/// The structural convention: the first four scalars in `$a0`-`$a3`.
fn defaultArgumentRegister(data_type: ast.DataType, index: usize) ?ast.Register {
    if (isVectorType(data_type) or index >= argument_registers.len) return null;
    return argument_registers[index];
}

/// Unpinned scalar parameters default to `$a0`-`$a3`. Internal functions
/// may leave any parameter unpinned; the compiler then chooses.
pub fn applyDefaultParameterRegisters(
    self: *Parser,
    parameters: []ast.Parameter,
    first_unpinned: ?token.Token,
    internal: bool,
) !void {
    for (parameters, 0..) |*parameter, index| {
        if (parameter.reg != null or parameter.vector_reg != null) continue;
        parameter.automatic = true;
        parameter.reg = defaultArgumentRegister(parameter.data_type, index);
        if (parameter.reg == null and !internal) return self.fail(first_unpinned.?, .expected_fixed_register_parameter);
    }
}

// ------------------------------------------------------ register variables

const DeclaredType = struct {
    data_type: ?ast.DataType = null,
    function_type: ?ast.FunctionType = null,
    pointee: ?Parser.Pointee = null,
};
const ResolvedType = struct {
    data_type: ast.DataType,
    function_type: ?ast.FunctionType = null,
    pointee: ?Parser.Pointee = null,
};
const Initializer = struct { value: ?ast.Value = null, undefined: bool = false };

/// `reg($t0) name: type = value;` after the `reg` keyword. The type may
/// be omitted when the initializer determines it.
pub fn parseRegDecl(self: *Parser) !ast.VarDecl {
    const register_token = try parseParenthesizedRegister(self);
    const name = try self.declaredName(try self.expect(.ident));
    const declared: DeclaredType = if (try self.eat(.colon)) try parseDeclaredType(self) else .{};
    const initializer = try parseInitializer(self);
    _ = try self.expect(.semicolon);
    const resolved = try resolveType(self, name, declared, initializer.value);
    try checkPointee(self, name, resolved.pointee, initializer.value);
    const binding = try optionalBinding(self, register_token, resolved.data_type);
    try self.type_symbols.append(self.allocator, .{
        .name = name.text,
        .data_type = resolved.data_type,
        .function_type = resolved.function_type,
        .pointee = resolved.pointee,
    });
    return .{
        .is_const = false,
        .allow_undefined_read = initializer.undefined,
        .data_type = resolved.data_type,
        .reg = binding.reg,
        .vector_reg = binding.vector_reg,
        .function_type = resolved.function_type,
        .name = name.text,
        .value = initializer.value,
    };
}

fn parseParenthesizedRegister(self: *Parser) !?token.Token {
    if (!try self.eat(.l_paren)) return null;
    const register_token = try self.expect(.register);
    _ = try self.expect(.r_paren);
    return register_token;
}

/// Initializing a typed pointer from another needs the same pointee.
fn checkPointee(self: *Parser, name: token.Token, pointee: ?Parser.Pointee, value: ?ast.Value) !void {
    const expected = pointee orelse return;
    const actual = sourcePointee(self, value) orelse return;
    if (!pointers.samePointee(expected, actual)) return self.fail(name, .pointer_type_mismatch);
}

/// The pointee of a typed pointer an initializer copies.
fn sourcePointee(self: *const Parser, value: ?ast.Value) ?Parser.Pointee {
    const initial = value orelse return null;
    if (initial != .ident) return null;
    const source = self.lookupTypeSymbolInfo(initial.ident) orelse return null;
    return source.pointee;
}

/// A data type or `*T`.
fn parseValueType(self: *Parser) !DeclaredType {
    if (try self.eat(.star)) return .{ .data_type = .dmem, .pointee = try pointers.parsePointee(self) };
    return .{ .data_type = try self.parseDataType(try self.expect(.ident)) };
}

/// A data type, `*T`, or `fn(...)` for a function pointer held in a scalar.
fn parseDeclaredType(self: *Parser) !DeclaredType {
    if (self.current.tag == .star) return parseValueType(self);
    const type_name = try self.expect(.ident);
    if (!std.mem.eql(u8, type_name.text, "fn")) return .{ .data_type = try self.parseDataType(type_name) };
    return .{ .data_type = .u32, .function_type = try parseFunctionType(self, type_name) };
}

fn parseFunctionType(self: *Parser, type_name: token.Token) !ast.FunctionType {
    _ = try self.expect(.l_paren);
    var parsed: ast.FunctionType = .{};
    if (try self.eat(.r_paren)) return parsed;
    while (true) {
        if (parsed.parameter_count >= parsed.parameters.len) return error.TooManyParameters;
        parsed.parameters[parsed.parameter_count] = try parseFunctionTypeParameter(self, type_name, parsed.parameter_count);
        parsed.parameter_count += 1;
        if (try self.eat(.r_paren)) return parsed;
        _ = try self.expect(.comma);
    }
}

fn parseFunctionTypeParameter(self: *Parser, type_name: token.Token, index: usize) !ast.FunctionParameterType {
    const register_token = try parseRegisterAttribute(self);
    const data_type = try self.parseDataType(try self.expect(.ident));
    if (register_token) |fixed| {
        const binding = try parseBinding(self, fixed, data_type);
        return .{ .data_type = data_type, .reg = binding.reg, .vector_reg = binding.vector_reg };
    }
    const reg = defaultArgumentRegister(data_type, index) orelse return self.fail(type_name, .expected_fixed_register_parameter);
    return .{ .data_type = data_type, .reg = reg };
}

/// `= value`, `= undefined`, or nothing.
fn parseInitializer(self: *Parser) !Initializer {
    if (!try self.eat(.equal)) return .{};
    if (!self.atKeyword("undefined")) return .{ .value = try self.parseScalarExpression(0) };
    _ = try self.expect(.ident);
    return .{ .undefined = true };
}

/// The declared type, else one implied by the initializer.
fn resolveType(self: *Parser, name: token.Token, declared: DeclaredType, value: ?ast.Value) !ResolvedType {
    if (declared.data_type) |data_type| return .{ .data_type = data_type, .function_type = declared.function_type, .pointee = declared.pointee };
    const initial = value orelse return self.fail(name, .expected_data_type);
    if (initial == .ident) return copiedType(self, name, initial.ident);
    return .{ .data_type = inferredType(initial) orelse return self.fail(name, .expected_data_type) };
}

fn copiedType(self: *Parser, name: token.Token, source_name: []const u8) !ResolvedType {
    const source = self.lookupTypeSymbolInfo(source_name) orelse return self.fail(name, .expected_data_type);
    return .{ .data_type = source.data_type, .function_type = source.function_type, .pointee = source.pointee };
}

fn inferredType(value: ast.Value) ?ast.DataType {
    return switch (value) {
        .load => |load| load.data_type,
        .number => |number| literalType(number),
        .hardware_read => |read| if (read.returns_dmem) .dmem else .u32,
        else => fixed_value_types.get(std.meta.activeTag(value)),
    };
}

/// Untyped literals are unsigned unless negative.
fn literalType(number: i64) ast.DataType {
    return if (number < 0) .i32 else .u32;
}

const fixed_value_types = blk: {
    var table = std.EnumArray(std.meta.Tag(ast.Value), ?ast.DataType).initFill(null);
    table.set(.accumulator_read, .vec16);
    table.set(.vector_control_read, .u32);
    table.set(.scalar_comparison, .u32);
    table.set(.signed_less_than, .u32);
    break :blk table;
};

/// `const name: type = value;` or `const name = @rspq.commandTable();`.
pub fn parseConstStatement(self: *Parser) !ast.Statement {
    const name = try self.expect(.ident);
    if (try self.eat(.equal)) return parseCommandTable(self, name);
    _ = try self.expect(.colon);
    const data_type = try self.parseDataType(try self.expect(.ident));
    _ = try self.expect(.equal);
    const value = try @import("parse_comptime.zig").parseConstExpression(self);
    _ = try self.expect(.semicolon);
    try self.type_symbols.append(self.allocator, .{ .name = name.text, .data_type = data_type, .constant = value });
    return .{ .var_decl = .{ .is_const = true, .data_type = data_type, .reg = null, .name = name.text, .value = .{ .number = value } } };
}

fn parseCommandTable(self: *Parser, name: token.Token) !ast.Statement {
    _ = try self.expect(.at);
    try expectRspqAttribute(self, "commandTable");
    _ = try self.expect(.l_paren);
    _ = try self.expect(.r_paren);
    _ = try self.expect(.semicolon);
    return .{ .command_table_decl = name.text };
}

// ------------------------------------------------------- rspq attributes

/// `rspq.<expected>` after an `@`.
fn expectRspqAttribute(self: *Parser, expected: []const u8) !void {
    const namespace = try self.expect(.ident);
    if (!std.mem.eql(u8, namespace.text, "rspq")) return self.fail(namespace, .unsupported_builtin);
    _ = try self.expect(.dot);
    const attribute = try self.expect(.ident);
    if (!std.mem.eql(u8, attribute.text, expected)) return self.fail(attribute, .unsupported_builtin);
}

/// `@rspq.command(n, ...)` or `@rspq.commandSize(n, ...)`.
pub fn parseRspqNumberAttribute(self: *Parser, expected_name: []const u8, values: *std.ArrayList(u8)) !void {
    _ = try self.expect(.at);
    try expectRspqAttribute(self, expected_name);
    _ = try self.expect(.l_paren);
    while (true) {
        try values.append(self.allocator, try parseRspqNumber(self, std.mem.eql(u8, expected_name, "command")));
        if (!try self.eat(.comma)) break;
    }
    _ = try self.expect(.r_paren);
}

/// Command indices stop below the 240 reserved by the queue; sizes fit a byte.
fn parseRspqNumber(self: *Parser, is_command: bool) !u8 {
    const value_token = try self.expect(.number);
    const value = try self.parseNumberValue(value_token);
    const maximum: i64 = if (is_command) 239 else 255;
    if (value >= 0 and value <= maximum) return @intCast(value);
    if (is_command) return self.fail(value_token, .invalid_command_index);
    return error.InvalidCommandSize;
}

// ------------------------------------------------------ compile-time types

pub fn isCompileTimeTypeStart(self: *const Parser) bool {
    return self.atKeyword("enum") or self.atKeyword("flags");
}

/// Members of one `enum` or `flags` declaration, numbered in order.
const MemberSequence = struct {
    type_name: []const u8,
    data_type: ast.DataType,
    is_flags: bool,
    next: i64,

    /// Enums count up by one; flags take the next bit.
    fn advance(self: *MemberSequence, value: i64) bool {
        self.next = (if (self.is_flags) std.math.mul(i64, value, 2) else std.math.add(i64, value, 1)) catch return false;
        return true;
    }
};

pub fn parseCompileTimeType(self: *Parser) !void {
    const kind = try self.expect(.ident);
    const is_flags = std.mem.eql(u8, kind.text, "flags");
    const type_name = try self.expect(.ident);
    try declareCompileTimeType(self, type_name);
    _ = try self.expect(.colon);
    const data_type = try self.parseDataType(try self.expect(.ident));
    if (!compileTimeTypeAllowed(data_type, is_flags)) return self.fail(type_name, .expected_unsigned_scalar_type);
    _ = try self.expect(.l_brace);
    var sequence: MemberSequence = .{ .type_name = type_name.text, .data_type = data_type, .is_flags = is_flags, .next = @intFromBool(is_flags) };
    while (!try self.eat(.r_brace)) try parseCompileTimeMember(self, &sequence);
}

fn declareCompileTimeType(self: *Parser, type_name: token.Token) !void {
    for (self.compile_time_types.items) |existing| {
        if (std.mem.eql(u8, existing, type_name.text)) return self.fail(type_name, .duplicate_compile_time_type);
    }
    try self.compile_time_types.append(self.allocator, type_name.text);
}

fn compileTimeTypeAllowed(data_type: ast.DataType, is_flags: bool) bool {
    if (isVectorType(data_type)) return false;
    return !is_flags or !parser_mod.isSignedType(data_type);
}

fn parseCompileTimeMember(self: *Parser, sequence: *MemberSequence) !void {
    const member = try self.expect(.ident);
    const value = if (try self.eat(.equal)) try parseMemberValue(self, member) else sequence.next;
    if (!parser_mod.literalFitsType(value, sequence.data_type)) return self.fail(member, .invalid_number);
    _ = try self.expect(.semicolon);
    if (self.lookupCompileTimeMember(sequence.type_name, member.text) != null) return self.fail(member, .duplicate_compile_time_member);
    try self.compile_time_members.append(self.allocator, .{
        .type_name = sequence.type_name,
        .member_name = member.text,
        .data_type = sequence.data_type,
        .value = value,
    });
    if (!sequence.advance(value)) return self.fail(member, .invalid_number);
}

fn parseMemberValue(self: *Parser, member: token.Token) !i64 {
    const parsed = try self.parseValueRef();
    if (parsed != .number) return self.fail(member, .expected_data_literal);
    return parsed.number;
}

// ---------------------------------------------------------------- imports

pub fn isImportStart(self: *const Parser) bool {
    if (!self.atKeyword("const")) return false;
    const next = self.peek(3) orelse return false;
    return next[1].tag == .equal and isIdent(next[2], "import");
}

/// `const name = import("path");`
pub fn parseImport(self: *Parser) !void {
    _ = try self.expect(.ident);
    const name = try self.expect(.ident);
    _ = try self.expect(.equal);
    const import_name = try self.expect(.ident);
    if (!std.mem.eql(u8, import_name.text, "import")) return self.fail(import_name, .expected_import);
    _ = try self.expect(.l_paren);
    const path = try self.expect(.string);
    _ = try self.expect(.r_paren);
    _ = try self.expect(.semicolon);
    try self.imports.append(self.allocator, .{ .name = name.text, .path = path.text });
}

// -------------------------------------------------------- packed structs

pub fn parsePackedStructDecl(self: *Parser) !ast.PackedStructDecl {
    const struct_keyword = try self.expect(.ident);
    if (!std.mem.eql(u8, struct_keyword.text, "struct")) return self.fail(struct_keyword, .expected_struct_declaration);
    const name = try self.expect(.ident);
    _ = try self.expect(.l_brace);
    var fields: std.ArrayList(ast.PackedStructField) = .empty;
    errdefer fields.deinit(self.allocator);
    while (!try self.eat(.r_brace)) try fields.append(self.allocator, try parsePackedField(self));
    const declaration: ast.PackedStructDecl = .{ .name = name.text, .fields = try fields.toOwnedSlice(self.allocator) };
    errdefer self.allocator.free(declaration.fields);
    try self.packed_structs.append(self.allocator, declaration);
    return declaration;
}

fn parsePackedField(self: *Parser) !ast.PackedStructField {
    const field_name = try self.expect(.ident);
    _ = try self.expect(.colon);
    const data_type = try self.parseDataType(try self.expect(.ident));
    if (isVectorType(data_type)) return self.fail(field_name, .expected_scalar_data_type);
    _ = try self.expect(.semicolon);
    return .{ .name = field_name.text, .data_type = data_type };
}

pub const MemoryType = struct {
    data_type: ast.DataType,
    offset: i64 = 0,
};

/// A load or store type: a data type, or a packed struct field written
/// `Struct.field`.
pub fn parseMemoryType(self: *Parser) !MemoryType {
    const type_name = try self.expect(.ident);
    if (try self.eat(.dot)) return parsePackedFieldType(self, type_name);
    return .{ .data_type = try self.parseDataType(type_name) };
}

fn parsePackedFieldType(self: *Parser, type_name: token.Token) !MemoryType {
    const field_name = try self.expect(.ident);
    const declaration = self.findPackedStruct(type_name.text) orelse return self.fail(type_name, .unknown_packed_struct);
    const field = packedField(declaration, field_name.text) orelse return self.fail(field_name, .unknown_packed_struct_field);
    return .{ .data_type = field.data_type, .offset = field.offset };
}

pub const PackedField = struct { data_type: ast.DataType, offset: i64 };

/// A field's type and byte offset within its packed struct.
pub fn packedField(declaration: ast.PackedStructDecl, name: []const u8) ?PackedField {
    var offset: i64 = 0;
    for (declaration.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return .{ .data_type = field.data_type, .offset = offset };
        offset += parser_mod.scalarTypeSize(field.data_type);
    }
    return null;
}

// --------------------------------------------------------- storage blocks

const Visibility = enum { private, public, external };

/// What an initializer must supply: one literal, or a braced list for
/// arrays and packed structs.
const StorageShape = struct {
    array_len: ?usize,
    storage_type: ast.DataStorageType,

    fn isAggregate(self: StorageShape) bool {
        return self.array_len != null or self.storage_type == .packed_struct;
    }

    /// Scalar arrays must be initialized completely.
    fn countMismatch(self: StorageShape, count: usize) bool {
        const len = self.array_len orelse return false;
        return self.storage_type == .scalar and count != len;
    }
};

/// The declarations of a `data`, `bss`, or `state` block.
pub fn parseStorageBlock(self: *Parser, allow_initialized: bool) ![]const ast.DataDecl {
    _ = try self.expect(.l_brace);
    var declarations: std.ArrayList(ast.DataDecl) = .empty;
    errdefer {
        for (declarations.items) |declaration| self.allocator.free(declaration.values);
        declarations.deinit(self.allocator);
    }
    while (!try self.eat(.r_brace)) {
        const declaration = try parseStorageDeclaration(self, allow_initialized);
        errdefer self.allocator.free(declaration.values);
        try declarations.append(self.allocator, declaration);
    }
    return declarations.toOwnedSlice(self.allocator);
}

fn parseStorageDeclaration(self: *Parser, allow_initialized: bool) !ast.DataDecl {
    const visibility = try parseVisibility(self);
    const name = try self.expect(.ident);
    _ = try self.expect(.colon);
    const shape: StorageShape = .{ .array_len = try parseArrayLength(self), .storage_type = try parseStorageType(self, name) };
    const initialized = allow_initialized and self.current.tag == .equal;
    const values: []const i64 = if (initialized) try parseStorageInitializer(self, name, visibility, shape) else &.{};
    errdefer self.allocator.free(values);
    _ = try self.expect(.semicolon);
    try self.type_symbols.append(self.allocator, .{ .name = name.text, .data_type = .dmem, .pointee = pointers.storagePointee(shape.storage_type) });
    return .{
        .name = name.text,
        .storage_type = shape.storage_type,
        .array_len = shape.array_len orelse 1,
        .is_array = shape.array_len != null,
        .values = values,
        .initialized = initialized,
        .public = visibility == .public,
        .external = visibility == .external,
    };
}

fn parseVisibility(self: *Parser) !Visibility {
    const visibility: Visibility = if (self.atKeyword("pub")) .public else if (self.atKeyword("extern")) .external else return .private;
    _ = try self.expect(.ident);
    return visibility;
}

fn parseArrayLength(self: *Parser) !?usize {
    if (!try self.eat(.l_bracket)) return null;
    const length_token = try self.expect(.number);
    const length = try self.parseNumberValue(length_token);
    if (length <= 0) return self.fail(length_token, .invalid_array_length);
    _ = try self.expect(.r_bracket);
    return @intCast(length);
}

fn parseStorageType(self: *Parser, name: token.Token) !ast.DataStorageType {
    const type_token = try self.expect(.ident);
    const data_type = parser_mod.parseDataTypeName(type_token.text) orelse return .{ .packed_struct = type_token.text };
    if (isVectorType(data_type)) return self.fail(name, .expected_scalar_data_type);
    return .{ .scalar = data_type };
}

fn parseStorageInitializer(self: *Parser, name: token.Token, visibility: Visibility, shape: StorageShape) ![]const i64 {
    if (visibility == .external) return self.fail(name, .external_data_initializer);
    _ = try self.expect(.equal);
    if (self.atKeyword("undefined")) return self.fail(self.current, .undefined_data_initializer);
    var values: std.ArrayList(i64) = .empty;
    errdefer values.deinit(self.allocator);
    if (shape.isAggregate()) try parseAggregateValues(self, &values) else try values.append(self.allocator, try parseDataLiteral(self));
    if (shape.countMismatch(values.items.len)) return self.fail(name, .incorrect_array_initializer_count);
    return values.toOwnedSlice(self.allocator);
}

/// `.{ 1, 2, 3 }`; the leading dot is optional.
fn parseAggregateValues(self: *Parser, values: *std.ArrayList(i64)) !void {
    _ = try self.eat(.dot);
    _ = try self.expect(.l_brace);
    if (try self.eat(.r_brace)) return;
    while (true) {
        try values.append(self.allocator, try parseDataLiteral(self));
        if (try self.listEnds(.r_brace)) return;
    }
}

fn parseDataLiteral(self: *Parser) !i64 {
    const value = try self.parseValueRef();
    if (value != .number) return self.fail(self.current, .expected_data_literal);
    return value.number;
}
