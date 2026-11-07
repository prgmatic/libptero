//! Function declarations: prefixes, command attributes and targets, the
//! modifiers after the parameters, and bodies. Parameters themselves are
//! parsed in parse_declarations.zig, which register declarations share.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const parser_mod = @import("parser.zig");
const declarations = @import("parse_declarations.zig");

const Parser = parser_mod.Parser;
const parseRegister = parser_mod.parseRegister;
const parseVectorRegister = parser_mod.parseVectorRegister;
const parseParameters = declarations.parseParameters;
const applyDefaultParameterRegisters = declarations.applyDefaultParameterRegisters;

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
    while (true) {
        if (atCommandTarget(self, command_indices.items.len)) return parseCommandTarget(self, &command_indices);
        if (try parseFunctionPrefix(self, &prefixes, &command_indices)) break;
    }
    return parseFunction(self, prefixes, try command_indices.toOwnedSlice(self.allocator));
}

/// `module.name` after command attributes.
fn atCommandTarget(self: *const Parser, command_count: usize) bool {
    if (command_count == 0 or self.current.tag != .ident) return false;
    const next = (self.peek(1) orelse return false)[0];
    return next.tag == .dot;
}

/// `@rspq.command(...) @rspq.commandSize(n) queue.commandLoop;` points
/// command-table entries at an imported function without declaring it again.
fn parseCommandTarget(self: *Parser, command_indices: *std.ArrayList(u8)) !ast.Function {
    const module = try self.expect(.ident);
    _ = try self.expect(.dot);
    const name = try self.expect(.ident);
    var sizes: std.ArrayList(u8) = .empty;
    errdefer sizes.deinit(self.allocator);
    if (self.current.tag == .at) try parseRspqNumberAttribute(self, "commandSize", &sizes);
    _ = try self.expect(.semicolon);
    return .{
        .name = name.text,
        .source_name = name.text,
        .export_symbol = false,
        .public = false,
        .inline_call = false,
        .external = true,
        .no_return = true,
        .command_indices = try command_indices.toOwnedSlice(self.allocator),
        .command_sizes = try sizes.toOwnedSlice(self.allocator),
        .parameters = &.{},
        .statements = &.{},
        .command_target = .{ .module = module.text, .name = name.text },
    };
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

pub fn isIdent(tok: token.Token, text: []const u8) bool {
    return tok.tag == .ident and std.mem.eql(u8, tok.text, text);
}

/// Suffixes after the parameter list: `noreturn`, `writes(...)`,
/// `align(n)`, and `@rspq.commandSize(...)`.
const Modifiers = struct {
    no_return: bool = false,
    preserves: ?ast.FunctionRef = null,
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
    var parameters = try parseParameters(self);
    errdefer self.allocator.free(parameters.items);
    const returns = @import("parse_returns.zig");
    if (try returns.parseReturnType(self, prefixes.@"inline")) |return_type| {
        const result = try returns.resultParameter(self, name.text, return_type);
        parameters.items = try self.allocator.realloc(parameters.items, parameters.items.len + 1);
        parameters.items[parameters.items.len - 1] = result;
        self.inline_result = .{ .name = result.name, .data_type = return_type.data_type, .named = return_type.name != null };
    }
    defer self.inline_result = null;
    self.returned_value = false;
    var modifiers: Modifiers = .{};
    errdefer modifiers.deinit(self.allocator);
    while (self.current.tag == .ident or self.current.tag == .at) try parseModifier(self, &modifiers);
    const internal = !prefixes.@"export" and !prefixes.@"extern" and command_indices.len == 0;
    try applyDefaultParameterRegisters(self, parameters.items, parameters.first_unpinned, internal);
    const statements = try parseFunctionBody(self, prefixes);
    try returns.checkReturned(self, name);
    return .{
        .name = name.text,
        .source_name = name.text,
        .export_symbol = prefixes.@"export",
        .public = prefixes.@"pub",
        .inline_call = prefixes.@"inline",
        .external = prefixes.@"extern",
        .no_return = modifiers.no_return,
        .alignment = modifiers.alignment,
        .preserves = modifiers.preserves,
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
    const parse = modifier_parsers.get(modifier.text) orelse return self.fail(modifier, .unsupported_function_modifier);
    return parse(self, modifiers, modifier);
}

const ModifierParser = *const fn (*Parser, *Modifiers, token.Token) anyerror!void;
const modifier_parsers = std.StaticStringMap(ModifierParser).initComptime(.{
    .{ "noreturn", parseNoReturn },
    .{ "align", parseAlignment },
    .{ "preserves", parsePreserves },
    .{ "writes", parseWrites },
});

fn parseNoReturn(_: *Parser, modifiers: *Modifiers, _: token.Token) !void {
    modifiers.no_return = true;
}

fn parseWrites(self: *Parser, modifiers: *Modifiers, modifier: token.Token) !void {
    if (modifiers.has_clobber_contract) return self.fail(modifier, .duplicate_clobber_contract);
    modifiers.has_clobber_contract = true;
    try parseClobberContract(self, modifiers);
}

/// `preserves(module.function)`.
fn parsePreserves(self: *Parser, modifiers: *Modifiers, _: token.Token) !void {
    _ = try self.expect(.l_paren);
    modifiers.preserves = try self.parseFunctionReference();
    _ = try self.expect(.r_paren);
}

/// `align(n)`: the function starts at a multiple of `n` bytes, a power of
/// two from 4 (every instruction's alignment) to 4096.
fn parseAlignment(self: *Parser, modifiers: *Modifiers, _: token.Token) !void {
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

// ------------------------------------------------------- rspq attributes

/// `rspq.<expected>` after an `@`.
pub fn expectRspqAttribute(self: *Parser, expected: []const u8) !void {
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
