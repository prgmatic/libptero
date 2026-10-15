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
    return .{ .data_block = try self.parseStorageBlock(false, true) };
}

pub fn parseBssKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .bss_block = try self.parseStorageBlock(false, false) };
}

pub fn parseStateKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    return .{ .state_block = try self.parseStorageBlock(false, true) };
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
        .typed = false,
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
    _ = try self.expect(.l_paren);
    const condition = try self.parseCondition();
    _ = try self.expect(.r_paren);
    _ = try self.expect(.l_brace);
    return .{ .while_loop = .{
        .condition = condition,
        .statements = try self.parseBlockStatements(),
    } };
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

pub fn parseLabeledStatement(self: *Parser, first: token.Token) anyerror!ast.Statement {
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "block")) {
        _ = try self.expect(.ident);
        _ = try self.expect(.l_brace);
        const statements = try self.parseBlockStatements();
        var exit_delay: ?[]ast.Statement = null;
        if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "exit")) {
            _ = try self.expect(.ident);
            const slot = try self.expect(.ident);
            if (!std.mem.eql(u8, slot.text, "slot")) return self.fail(slot, .unexpected_token);
            _ = try self.expect(.l_brace);
            exit_delay = try self.parseBlockStatements();
        }
        return .{ .labeled_block = .{
            .label = first.text,
            .statements = statements,
            .exit_delay = exit_delay,
        } };
    }
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "while")) {
        _ = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        const condition = try self.parseCondition();
        _ = try self.expect(.r_paren);
        _ = try self.expect(.l_brace);
        return .{ .while_loop = .{
            .label = first.text,
            .condition = condition,
            .statements = try self.parseBlockStatements(),
        } };
    }
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "do")) {
        _ = try self.expect(.ident);
        return self.parseDoWhileStatement(first.text);
    }
    return .{ .label = first.text };
}

pub fn parseIfKeyword(self: *Parser, _: token.Token) anyerror!ast.Statement {
    _ = try self.expect(.l_paren);
    const condition = try self.parseCondition();
    _ = try self.expect(.r_paren);
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "tail")) {
        _ = try self.expect(.ident);
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
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "jump")) {
        _ = try self.expect(.ident);
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
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "goto")) {
        _ = try self.expect(.ident);
        const target = try self.expect(.ident);
        return .{ .conditional_goto = .{
            .condition = condition,
            .target = target.text,
            .delay_slot = try self.parseOptionalDelaySlot(),
        } };
    }
    var delay_slot: ?[]ast.Statement = null;
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "slot")) {
        _ = try self.expect(.ident);
        _ = try self.expect(.l_brace);
        delay_slot = try self.parseBlockStatements();
    }
    _ = try self.expect(.l_brace);
    const then_statements = try self.parseBlockStatements();

    var else_statements: ?[]ast.Statement = null;
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "else")) {
        _ = try self.expect(.ident);
        _ = try self.expect(.l_brace);
        else_statements = try self.parseBlockStatements();
    }

    return .{ .if_statement = .{
        .condition = condition,
        .delay_slot = delay_slot,
        .then_statements = then_statements,
        .else_statements = else_statements,
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
    const value = try self.parseValueRef();
    try operand.parseOffset(self);
    _ = try self.expect(.r_paren);
    _ = try self.expect(.semicolon);
    return .{ .store = .{
        .data_type = memory_type.data_type,
        .half_vector = memory_type.half_vector,
        .quarter_vector = memory_type.quarter_vector,
        .address = operand.address,
        .value = value,
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

pub fn parseAssignmentOrCall(self: *Parser, first: token.Token) anyerror!ast.Statement {
    var destination_lane: ?u3 = null;
    var destination_view: ?ast.VectorView = null;
    if (self.current.tag == .l_bracket or self.isVectorDotSuffix()) {
        const access = try self.parseVectorAccess(first.text);
        destination_lane = access.lane;
        destination_view = access.view;
        if (access.lane == null and access.view == null) {
            return self.fail(first, .unsupported_destination_swizzle);
        }
    }

    if (try self.parseCompoundAssignOp()) |op| {
        const value = valueFromRef(try self.parseValueRef());
        _ = try self.expect(.semicolon);
        return .{ .assignment = .{
            .destination = first.text,
            .destination_lane = destination_lane,
            .destination_view = destination_view,
            .lhs = .{ .ident = first.text },
            .op = op,
            .rhs = value,
        } };
    }

    if (try self.eat(.equal)) {
        if (try self.eat(.minus)) {
            const value = valueFromRef(try self.parseValueRef());
            _ = try self.expect(.semicolon);
            return .{ .assignment = .{
                .destination = first.text,
                .destination_lane = destination_lane,
                .destination_view = destination_view,
                .lhs = value,
                .op = .negate,
                .rhs = null,
            } };
        }
        if (try self.eat(.tilde)) {
            const value = valueFromRef(try self.parseValueRef());
            _ = try self.expect(.semicolon);
            return .{ .assignment = .{
                .destination = first.text,
                .destination_lane = destination_lane,
                .destination_view = destination_view,
                .lhs = value,
                .op = .bit_not,
                .rhs = null,
            } };
        }

        const lhs = try self.parseScalarExpression(0);
        const comparison = try self.parseComparisonOperator();
        const assignment_lhs: ast.Value = if (comparison) |comparison_op| .{ .scalar_comparison = .{
            .lhs = try valueRefFromValue(lhs),
            .op = comparison_op,
            .rhs = try self.parseValueRef(),
        } } else lhs;
        _ = try self.expect(.semicolon);
        return .{ .assignment = .{
            .destination = first.text,
            .destination_lane = destination_lane,
            .destination_view = destination_view,
            .lhs = assignment_lhs,
            .op = .set,
            .rhs = null,
        } };
    }

    if (try self.eat(.l_paren)) {
        const arguments = try self.parseCallArguments();
        const delay_slot = try self.parseOptionalDelaySlot();
        return .{ .call = .{
            .module = null,
            .name = first.text,
            .arguments = arguments,
            .delay_slot = delay_slot,
        } };
    }

    if (try self.eat(.dot)) {
        const member = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        const arguments = try self.parseCallArguments();
        const delay_slot = try self.parseOptionalDelaySlot();
        return .{ .call = .{
            .module = first.text,
            .name = member.text,
            .arguments = arguments,
            .delay_slot = delay_slot,
        } };
    }

    return self.fail(first, .unsupported_statement);
}

pub fn parseDoWhileStatement(self: *Parser, label: ?[]const u8) !ast.Statement {
    _ = try self.expect(.l_brace);
    const statements = try self.parseBlockStatements();
    const while_token = try self.expect(.ident);
    if (!std.mem.eql(u8, while_token.text, "while")) return self.fail(while_token, .unexpected_token);
    _ = try self.expect(.l_paren);
    const condition = try self.parseCondition();
    _ = try self.expect(.r_paren);
    const delay_slot = try self.parseOptionalDelaySlot();
    return .{ .do_while_loop = .{
        .label = label,
        .condition = condition,
        .statements = statements,
        .delay_slot = delay_slot,
    } };
}

pub fn parseOptionalDelaySlot(self: *Parser) !?[]ast.Statement {
    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "slot")) {
        _ = try self.expect(.ident);
        _ = try self.expect(.l_brace);
        return try self.parseBlockStatements();
    }
    _ = try self.expect(.semicolon);
    return null;
}
