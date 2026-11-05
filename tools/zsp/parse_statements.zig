const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const Parser = @import("parser.zig").Parser;
const valueFromRef = @import("parser.zig").valueFromRef;
const valueRefFromValue = @import("parser.zig").valueRefFromValue;

pub fn parseStatement(self: *Parser) anyerror!ast.Statement {
    if (try self.eat(.at)) return self.parseBuiltinStatement();
    const first = try self.expect(.ident);
    if (self.current.tag == .dot) {
        if (try self.parseNamespaceStatement(first)) |statement| return statement;
    }
    if (early_statement_parsers.get(first.text)) |parse_statement| return parse_statement(self, first);
    return self.parseLabelOrStatement(first);
}

pub fn parseNamespaceStatement(self: *Parser, first: token.Token) !?ast.Statement {
    if (std.mem.eql(u8, first.text, "rsp")) return try self.parseRspNamespaceStatement(first);
    if (std.mem.eql(u8, first.text, "dma")) return try self.parseModuleStatement(first);
    if (std.mem.eql(u8, first.text, "rdp")) return try self.parseModuleStatement(first);
    return null;
}

pub fn parseLabelOrStatement(self: *Parser, first: token.Token) anyerror!ast.Statement {
    if (try self.eat(.colon)) return self.parseLabeledStatement(first);
    if (late_statement_parsers.get(first.text)) |parse_statement| return parse_statement(self, first);
    return self.parseAssignmentOrCall(first);
}

const StatementParser = *const fn (*Parser, token.Token) anyerror!ast.Statement;
const early_statement_parsers = std.StaticStringMap(StatementParser).initComptime(.{
    .{ "packed", parsePackedKeyword },
    .{ "data", parseDataKeyword },
    .{ "bss", parseBssKeyword },
    .{ "state", parseStateKeyword },
    .{ "exact", parseExactKeyword },
    .{ "export", parseExportKeyword },
    .{ "tail", parseTailKeyword },
    .{ "return", parseReturnKeyword },
    .{ "jump", parseJumpKeyword },
    .{ "call", parseCallKeyword },
    .{ "asm", parseAsmKeyword },
    .{ "while", parseWhileKeyword },
    .{ "do", parseDoKeyword },
    .{ "break", parseBreakKeyword },
    .{ "continue", parseBreakKeyword },
});

const late_statement_parsers = std.StaticStringMap(StatementParser).initComptime(.{
    .{ "if", parseIfKeyword },
    .{ "goto", parseGotoKeyword },
    .{ "store", parseStoreKeyword },
    .{ "const", parseConstKeyword },
    .{ "var", parseVarKeyword },
    .{ "reg", parseRegKeyword },
    .{ "reserved", parseReservedKeyword },
});

pub fn parseRspNamespaceStatement(self: *Parser, _: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.dot);
    const facility = try self.expect(.ident);
    if (std.mem.eql(u8, facility.text, "cp0")) {
        _ = try self.expect(.dot);
        return self.parseCp0Statement(try self.expect(.ident));
    }
    if (std.mem.eql(u8, facility.text, "vector")) {
        _ = try self.expect(.dot);
        return self.parseVectorStatement(try self.expect(.ident));
    }
    return self.parseRspStatement(facility);
}

pub fn parseModuleStatement(self: *Parser, first: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.dot);
    const operation_name = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    const arguments = try self.parseCallArguments();
    const delay_slot = try self.parseOptionalDelaySlot();
    return .{ .call = .{
        .module = first.text,
        .name = operation_name.text,
        .arguments = arguments,
        .delay_slot = delay_slot,
    } };
}

pub fn parsePackedKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .packed_struct_decl = try self.parsePackedStructDecl() };
}

pub fn parseDataKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .data_block = try self.parseStorageBlock(true) };
}

pub fn parseBssKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .bss_block = try self.parseStorageBlock(false) };
}

pub fn parseStateKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .state_block = try self.parseStorageBlock(true) };
}

pub fn parseExactKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.l_brace);
    return .{ .ordered_block = try self.parseBlockStatements() };
}

pub fn parseExportKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    const label = try self.expect(.ident);
    _ = try self.expect(.colon);
    return .{ .exported_label = label.text };
}

pub fn parseTailKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    const target_first = try self.expect(.ident);
    var target = ast.FunctionRef{ .name = target_first.text };
    if (try self.eat(.dot)) {
        target = .{ .module = target_first.text, .name = (try self.expect(.ident)).text };
    }
    _ = try self.expect(.l_paren);
    const arguments = try self.parseCallArguments();
    return .{ .builtin = .{ .tail = .{
        .target = target,
        .arguments = arguments,
        .delay_slot = try self.parseOptionalDelaySlot(),
    } } };
}

pub fn parseReturnKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .builtin = .{ .return_from_function = try self.parseOptionalDelaySlot() } };
}

pub fn parseJumpKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    if (self.current.tag == .ident) {
        const target = try self.parseFunctionReference();
        _ = try self.expect(.l_paren);
        const arguments = try self.parseCallArguments();
        return .{ .builtin = .{ .direct_goto = .{
            .target = target,
            .arguments = arguments,
            .typed = true,
            .delay_slot = try self.parseOptionalDelaySlot(),
        } } };
    }
    _ = try self.expect(.l_paren);
    const address = try self.parseValueRef();
    _ = try self.expect(.r_paren);
    return .{ .builtin = .{ .jump = .{
        .address = address,
        .delay_slot = try self.parseOptionalDelaySlot(),
    } } };
}

pub fn parseCallKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.l_paren);
    const address = try self.parseValueRef();
    _ = try self.expect(.r_paren);
    return .{ .builtin = .{ .indirect_call = .{
        .address = address,
        .delay_slot = try self.parseOptionalDelaySlot(),
    } } };
}

pub fn parseAsmKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.l_paren);
    const asm_text = try self.expect(.string);
    _ = try self.expect(.r_paren);
    _ = try self.expect(.semicolon);
    return .{ .asm_line = asm_text.text };
}

pub fn parseWhileKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return parseWhile(self, null);
}

/// `while (condition) { ... }` after the keyword, optionally with a
/// continue expression: `while (condition) : (step) { ... }`. A loop with a
/// condition is rotated into `if (condition) do { ... } while (condition)`
/// so each iteration takes one branch; `while (true)` has no condition
/// unless its body ends in `if (c) { break; }`.
fn parseWhile(self: *Parser, label: ?[]const u8) !ast.Statement {
    _ = try self.expect(.l_paren);
    const condition: ?ast.Condition = if (try self.eatKeyword("true")) null else try self.parseCondition();
    _ = try self.expect(.r_paren);
    const step = try parseContinueExpression(self);
    var body = try parseBraced(self);
    const cold = self.last_block_cold;
    const loops = @import("parse_loops.zig");
    if (step) |statements| body = try loops.appendStep(self, label, body, statements);
    const guard = condition orelse return loops.exitAtEnd(self, label, body);
    const loop: ast.Statement = .{ .do_while_loop = .{ .label = label, .condition = condition, .statements = body, .delay_slot = null } };
    const then_statements = try self.allocator.alloc(ast.Statement, 1);
    then_statements[0] = loop;
    return .{ .if_statement = .{ .condition = guard, .delay_slot = null, .then_statements = then_statements, .else_statements = null, .cold = cold } };
}

/// `: (statement)`, ended by the parenthesis instead of a semicolon.
fn parseContinueExpression(self: *Parser) !?[]ast.Statement {
    if (!try self.eat(.colon)) return null;
    _ = try self.expect(.l_paren);
    const terminator = self.terminator;
    self.terminator = .r_paren;
    defer self.terminator = terminator;
    var list: Parser.StatementList = .{};
    defer list.locations.deinit(self.allocator);
    try self.parseStatementInto(&list);
    return try list.statements.toOwnedSlice(self.allocator);
}

/// `{ ... }`
fn parseBraced(self: *Parser) ![]ast.Statement {
    _ = try self.expect(.l_brace);
    return self.parseBlockStatements();
}

pub fn parseDoKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return self.parseDoWhileStatement(null);
}

pub fn parseBreakKeyword(self: *Parser, first: token.Token) anyerror!ast.Statement {
    const label: ?[]const u8 = if (self.current.tag == .ident) (try self.expect(.ident)).text else null;
    if (std.mem.eql(u8, first.text, "break")) {
        return .{ .break_loop = .{
            .label = label,
            .delay_slot = try self.parseOptionalDelaySlot(),
        } };
    }
    _ = try self.expect(.semicolon);
    return .{ .continue_loop = label };
}

/// `label:` alone, or naming the block or loop that follows.
pub fn parseLabeledStatement(self: *Parser, first: token.Token) anyerror!ast.Statement {
    const label = (try self.declaredName(first)).text;
    if (try self.eatKeyword("block")) return parseLabeledBlock(self, label);
    if (try self.eatKeyword("while")) return parseWhile(self, label);
    if (try self.eatKeyword("do")) return self.parseDoWhileStatement(label);
    return .{ .label = label };
}

/// `block { ... }`, optionally followed by `exit slot { ... }`.
fn parseLabeledBlock(self: *Parser, label: []const u8) !ast.Statement {
    const statements = try parseBraced(self);
    return .{ .labeled_block = .{ .label = label, .statements = statements, .exit_delay = try parseExitSlot(self) } };
}

fn parseExitSlot(self: *Parser) !?[]ast.Statement {
    if (!try self.eatKeyword("exit")) return null;
    const slot = try self.expect(.ident);
    if (!std.mem.eql(u8, slot.text, "slot")) return self.fail(slot, .unexpected_token);
    return try parseBraced(self);
}

/// `if (condition)` followed by `tail`/`jump f(...)`, `goto label`, or a
/// block with an optional leading `slot { ... }` and trailing `else`.
pub fn parseIfKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.l_paren);
    const condition = try self.parseCondition();
    _ = try self.expect(.r_paren);
    if (try self.eatKeyword("tail") or try self.eatKeyword("jump")) return parseConditionalDirectGoto(self, condition);
    if (try self.eatKeyword("goto")) return parseConditionalGoto(self, condition);
    return parseIfStatement(self, condition);
}

fn parseConditionalDirectGoto(self: *Parser, condition: ast.Condition) !ast.Statement {
    const target = try self.parseFunctionReference();
    _ = try self.expect(.l_paren);
    const arguments = try self.parseCallArguments();
    return .{ .conditional_direct_goto = .{
        .condition = condition,
        .target = target,
        .arguments = arguments,
        .typed = true,
        .delay_slot = try self.parseOptionalDelaySlot(),
    } };
}

fn parseConditionalGoto(self: *Parser, condition: ast.Condition) !ast.Statement {
    const target = try self.expect(.ident);
    return .{ .conditional_goto = .{ .condition = condition, .target = target.text, .delay_slot = try self.parseOptionalDelaySlot() } };
}

fn parseIfStatement(self: *Parser, condition: ast.Condition) !ast.Statement {
    const delay_slot = if (try self.eatKeyword("slot")) try parseBraced(self) else null;
    const then_statements = try parseBraced(self);
    const cold = self.last_block_cold;
    const else_statements = if (try self.eatKeyword("else")) try parseBraced(self) else null;
    return .{ .if_statement = .{
        .condition = condition,
        .delay_slot = delay_slot,
        .then_statements = then_statements,
        .else_statements = else_statements,
        .cold = cold,
    } };
}

pub fn parseGotoKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    const target = try self.expect(.ident);
    var encoding: ast.DirectGotoEncoding = .jump;
    if (try self.eat(.comma)) {
        _ = try self.expect(.dot);
        const encoding_name = try self.expect(.ident);
        if (std.mem.eql(u8, encoding_name.text, "jump")) {
            encoding = .jump;
        } else if (std.mem.eql(u8, encoding_name.text, "branch")) {
            encoding = .branch;
        } else return self.fail(encoding_name, .unsupported_builtin);
    }
    return .{ .goto = .{
        .target = target.text,
        .encoding = encoding,
        .delay_slot = try self.parseOptionalDelaySlot(),
    } };
}

pub fn parseStoreKeyword(self: *Parser, first: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.l_paren);
    const memory_type = try self.parseMemoryType();
    _ = try self.expect(.comma);
    var operand = try @import("parse_memory.zig").Operand.parseBase(self, memory_type.offset, first);
    _ = try self.expect(.comma);
    self.allow_lane_range = true;
    const value = self.parseValueRef();
    self.allow_lane_range = false;
    try operand.parseOffset(self);
    _ = try self.expect(.r_paren);
    _ = try self.expect(.semicolon);
    return .{ .store = .{
        .data_type = memory_type.data_type,
        .address = operand.address,
        .value = try value,
        .offset = operand.offset,
        .label_offset = operand.label,
    } };
}

pub fn parseConstKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return self.parseConstStatement();
}

pub fn parseVarKeyword(self: *Parser, first: token.Token) anyerror!ast.Statement {
    return self.fail(first, .var_keyword_removed);
}

pub fn parseRegKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .var_decl = try self.parseRegDecl() };
}

pub fn parseReservedKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    const reg_keyword = try self.expect(.ident);
    if (!std.mem.eql(u8, reg_keyword.text, "reg")) return self.fail(reg_keyword, .unexpected_token);
    var declaration = try self.parseRegDecl();
    declaration.is_reserved = true;
    return .{ .var_decl = declaration };
}

/// A statement starting with a name: an assignment to it, a call of it,
/// or a call into the module it names.
pub fn parseAssignmentOrCall(self: *Parser, first: token.Token) anyerror!ast.Statement {
    const pointers = @import("parse_pointers.zig");
    if (pointers.isDereference(self, first)) return pointers.parseStore(self, first);
    const destination = try parseDestination(self, first);
    if (try self.parseCompoundAssignOp()) |op| {
        return finishAssignment(self, destination, .{ .ident = first.text }, op, valueFromRef(try self.parseValueRef()));
    }
    if (try self.eat(.equal)) return parseAssignedValue(self, destination);
    if (try self.eat(.l_paren)) return parseCall(self, null, first.text);
    if (!try self.eat(.dot)) return self.fail(first, .unsupported_statement);
    const member = try self.expect(.ident);
    _ = try self.expect(.l_paren);
    return parseCall(self, first.text, member.text);
}

const Destination = struct { name: []const u8, lane: ?u3 = null, lane_count: u4 = 1, view: ?ast.VectorView = null };

/// A name, or a vector name with one lane or a typed view selected.
fn parseDestination(self: *Parser, first: token.Token) !Destination {
    if (self.current.tag != .l_bracket and !self.isVectorDotSuffix()) return .{ .name = first.text };
    const access = try self.parseVectorAccess(first.text);
    if (access.lane == null and access.view == null) return self.fail(first, .unsupported_destination_swizzle);
    return .{ .name = first.text, .lane = access.lane, .lane_count = access.lane_count, .view = access.view };
}

/// `= -x;`, `= ~x;`, `= expression;`, or `= a < b;`.
fn parseAssignedValue(self: *Parser, destination: Destination) !ast.Statement {
    if (try self.eat(.minus)) return finishAssignment(self, destination, valueFromRef(try self.parseValueRef()), .negate, null);
    if (try self.eat(.tilde)) return finishAssignment(self, destination, valueFromRef(try self.parseValueRef()), .bit_not, null);
    const lhs = try self.parseScalarExpression(0);
    const comparison = try self.parseComparisonOperator() orelse return finishAssignment(self, destination, lhs, .set, null);
    const value: ast.Value = .{ .scalar_comparison = .{
        .lhs = try valueRefFromValue(lhs),
        .op = comparison,
        .rhs = try self.parseValueRef(),
    } };
    return finishAssignment(self, destination, value, .set, null);
}

fn finishAssignment(self: *Parser, destination: Destination, lhs: ast.Value, op: ast.AssignOp, rhs: ?ast.Value) !ast.Statement {
    _ = try self.expect(self.terminator);
    return .{ .assignment = .{
        .destination = destination.name,
        .destination_lane = destination.lane,
        .destination_lane_count = destination.lane_count,
        .destination_view = destination.view,
        .lhs = lhs,
        .op = op,
        .rhs = rhs,
    } };
}

fn parseCall(self: *Parser, module: ?[]const u8, name: []const u8) !ast.Statement {
    const arguments = try self.parseCallArguments();
    return .{ .call = .{ .module = module, .name = name, .arguments = arguments, .delay_slot = try self.parseOptionalDelaySlot() } };
}

pub fn parseDoWhileStatement(self: *Parser, label: ?[]const u8) !ast.Statement {
    _ = try self.expect(.l_brace);
    const statements = try self.parseBlockStatements();
    const while_token = try self.expect(.ident);
    if (!std.mem.eql(u8, while_token.text, "while")) return self.fail(while_token, .unexpected_token);
    _ = try self.expect(.l_paren);
    const condition: ?ast.Condition = if (try self.eatKeyword("true")) null else try self.parseCondition();
    _ = try self.expect(.r_paren);
    const delay_slot = try self.parseOptionalDelaySlot();
    return .{ .do_while_loop = .{
        .label = label,
        .condition = condition,
        .statements = statements,
        .delay_slot = delay_slot,
    } };
}

/// `slot { ... }` after a transfer, or the terminating `;`.
pub fn parseOptionalDelaySlot(self: *Parser) !?[]ast.Statement {
    if (try self.eatKeyword("slot")) return try parseBraced(self);
    _ = try self.expect(self.terminator);
    return null;
}
