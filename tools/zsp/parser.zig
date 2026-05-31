const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const token = @import("token.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer_mod.Lexer,
    current: token.Token,
    diagnostic: ?Diagnostic = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .lexer = .{ .source = source },
            .current = undefined,
            .diagnostic = null,
        };
        parser.current = try parser.lexer.next();
        return parser;
    }

    pub fn parse(self: *Parser) ![]ast.Function {
        var functions: std.ArrayList(ast.Function) = .empty;
        while (self.current.tag != .eof) {
            if (self.isFunctionDeclarationStart()) {
                try functions.append(self.allocator, try self.parseFunctionDeclaration());
            } else {
                try functions.append(self.allocator, try self.parseTopLevelBlock());
            }
        }

        return functions.toOwnedSlice(self.allocator);
    }

    fn parseFunctionDeclaration(self: *Parser) !ast.Function {
        var inline_call = false;
        var export_symbol = false;
        while (true) {
            const prefix = try self.expect(.ident);
            if (std.mem.eql(u8, prefix.text, "export")) {
                export_symbol = true;
                continue;
            }
            if (std.mem.eql(u8, prefix.text, "inline")) {
                inline_call = true;
                continue;
            }
            if (!std.mem.eql(u8, prefix.text, "fn")) {
                return self.fail(prefix, .expected_function_declaration);
            }
            break;
        }

        return self.parseFunction(export_symbol, inline_call);
    }

    fn parseTopLevelBlock(self: *Parser) !ast.Function {
        return .{
            .name = "top_level",
            .emit_label = false,
            .export_symbol = false,
            .inline_call = false,
            .no_return = true,
            .statements = try self.parseTopLevelStatements(),
        };
    }

    fn parseFunction(self: *Parser, export_symbol: bool, inline_call: bool) !ast.Function {
        const name = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        _ = try self.expect(.r_paren);
        var no_return = false;
        while (self.current.tag == .ident) {
            const modifier = try self.expect(.ident);
            if (std.mem.eql(u8, modifier.text, "noreturn")) {
                no_return = true;
            } else {
                return self.fail(modifier, .unsupported_function_modifier);
            }
        }
        _ = try self.expect(.l_brace);

        const statements = try self.parseBlockStatements();

        return .{
            .name = name.text,
            .export_symbol = export_symbol,
            .inline_call = inline_call,
            .no_return = no_return,
            .statements = statements,
        };
    }

    fn parseTopLevelStatements(self: *Parser) anyerror![]const ast.Statement {
        var statements: std.ArrayList(ast.Statement) = .empty;
        while (self.current.tag != .eof and !self.isFunctionDeclarationStart()) {
            try statements.append(self.allocator, try self.parseStatement());
        }
        return statements.toOwnedSlice(self.allocator);
    }

    fn parseBlockStatements(self: *Parser) anyerror![]const ast.Statement {
        var statements: std.ArrayList(ast.Statement) = .empty;
        while (!try self.eat(.r_brace)) {
            try statements.append(self.allocator, try self.parseStatement());
        }
        return statements.toOwnedSlice(self.allocator);
    }

    fn parseStatement(self: *Parser) anyerror!ast.Statement {
        if (try self.eat(.at)) {
            return self.parseBuiltinStatement();
        }

        const first = try self.expect(.ident);

        if (std.mem.eql(u8, first.text, "asm")) {
            _ = try self.expect(.l_paren);
            const asm_text = try self.expect(.string);
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .asm_line = asm_text.text };
        }

        if (std.mem.eql(u8, first.text, "while")) {
            _ = try self.expect(.l_paren);
            const lhs = try self.expect(.ident);
            _ = try self.expect(.less);
            const rhs = try self.parseValue();
            _ = try self.expect(.r_paren);
            _ = try self.expect(.l_brace);
            return .{ .while_loop = .{
                .condition = .{ .lhs = lhs.text, .op = .lt, .rhs = rhs },
                .statements = try self.parseBlockStatements(),
            } };
        }

        if (std.mem.eql(u8, first.text, "store")) {
            _ = try self.expect(.l_paren);
            const data_type = try self.expect(.ident);
            _ = try self.expect(.comma);
            const address = try self.parseValue();
            _ = try self.expect(.comma);
            const value = try self.parseValue();
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .store = .{
                .data_type = data_type.text,
                .address = address,
                .value = value,
            } };
        }

        if (std.mem.eql(u8, first.text, "const")) {
            return .{ .var_decl = try self.parseVarDecl(true) };
        }

        if (std.mem.eql(u8, first.text, "var")) {
            return .{ .var_decl = try self.parseVarDecl(false) };
        }

        if (try self.eat(.plus_equal)) {
            const value = try self.expect(.number);
            _ = try self.expect(.semicolon);
            return .{ .add_assign = .{
                .name = first.text,
                .value = try self.parseNumberValue(value),
            } };
        }

        if (try self.eat(.l_paren)) {
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .call = first.text };
        }

        return self.fail(first, .unsupported_statement);
    }

    fn parseBuiltinStatement(self: *Parser) !ast.Statement {
        const name = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        _ = try self.expect(.r_paren);
        _ = try self.expect(.semicolon);

        if (std.mem.eql(u8, name.text, "nop")) return .{ .builtin = .nop };
        if (std.mem.eql(u8, name.text, "break")) return .{ .builtin = .breakpoint };
        return self.fail(name, .unsupported_builtin);
    }

    fn parseVarDecl(self: *Parser, is_const: bool) !ast.VarDecl {
        const name = try self.expect(.ident);
        _ = try self.expect(.colon);
        const data_type = try self.expect(.ident);
        if (!isDataType(data_type.text)) return self.fail(data_type, .expected_data_type);

        var reg: ?ast.Register = null;
        if (try self.eat(.less)) {
            const reg_token = try self.expect(.register);
            _ = try self.expect(.type_end);
            reg = parseRegister(reg_token) orelse return self.fail(reg_token, .expected_scalar_register);
        }

        _ = try self.expect(.equal);
        const value = try self.parseValue();
        _ = try self.expect(.semicolon);

        return .{
            .is_const = is_const,
            .data_type = data_type.text,
            .reg = reg,
            .name = name.text,
            .value = value,
        };
    }

    fn parseValue(self: *Parser) !ast.Value {
        switch (self.current.tag) {
            .ident => {
                const tok = try self.expect(.ident);
                return .{ .ident = tok.text };
            },
            .number => {
                const tok = try self.expect(.number);
                return .{ .number = try self.parseNumberValue(tok) };
            },
            else => return self.fail(self.current, .expected_value),
        }
    }

    fn eat(self: *Parser, tag: token.Tag) !bool {
        if (self.current.tag != tag) return false;
        self.current = try self.lexer.next();
        return true;
    }

    fn isFunctionDeclarationStart(self: *const Parser) bool {
        if (self.current.tag != .ident) return false;
        return std.mem.eql(u8, self.current.text, "export") or
            std.mem.eql(u8, self.current.text, "inline") or
            std.mem.eql(u8, self.current.text, "fn");
    }

    fn expect(self: *Parser, tag: token.Tag) !token.Token {
        const tok = self.current;
        if (tok.tag != tag) return self.failExpected(tok, tag);
        self.current = try self.lexer.next();
        return tok;
    }

    fn parseNumberValue(self: *Parser, tok: token.Token) !i64 {
        return parseNumber(tok) catch return self.fail(tok, .invalid_number);
    }

    fn failExpected(self: *Parser, tok: token.Token, expected: token.Tag) error{ParseError} {
        self.setDiagnostic(tok, .unexpected_token, expected);
        return error.ParseError;
    }

    fn fail(self: *Parser, tok: token.Token, code: ErrorType) error{ParseError} {
        self.setDiagnostic(tok, code, null);
        return error.ParseError;
    }

    fn setDiagnostic(self: *Parser, tok: token.Token, code: ErrorType, expected_token: ?token.Tag) void {
        self.diagnostic = .{
            .err = code,
            .line = tok.line,
            .column = tok.column,
            .token_tag = tok.tag,
            .token_text = tok.text,
            .expected_token = expected_token,
        };
    }
};

pub const ErrorType = enum {
    expected_function_declaration,
    unsupported_function_modifier,
    unsupported_statement,
    unsupported_builtin,
    expected_data_type,
    expected_scalar_register,
    expected_value,
    unexpected_token,
    invalid_number,
};

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    token_tag: token.Tag,
    token_text: []const u8,
    expected_token: ?token.Tag = null,
    err: ErrorType,
};

pub fn errorString(code: ErrorType) []const u8 {
    return switch (code) {
        .expected_function_declaration => "expected function declaration",
        .unsupported_function_modifier => "unsupported function modifier",
        .unsupported_statement => "unsupported statement",
        .unsupported_builtin => "unsupported builtin",
        .expected_data_type => "expected data type",
        .expected_scalar_register => "expected scalar register",
        .expected_value => "expected value",
        .unexpected_token => "unexpected token",
        .invalid_number => "invalid number",
    };
}

fn isDataType(text: []const u8) bool {
    return std.mem.eql(u8, text, "u16");
}

fn parseRegister(tok: token.Token) ?ast.Register {
    inline for (std.meta.fields(ast.Register)) |field| {
        if (std.mem.eql(u8, tok.text[1..], field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseNumber(tok: token.Token) !i64 {
    var cleaned_buf: [64]u8 = undefined;
    if (tok.text.len > cleaned_buf.len) return error.NumberTooLong;

    var len: usize = 0;
    for (tok.text) |c| {
        if (c == '\'' or c == '_') continue;
        cleaned_buf[len] = c;
        len += 1;
    }
    const cleaned = cleaned_buf[0..len];
    if (std.mem.startsWith(u8, cleaned, "0x") or std.mem.startsWith(u8, cleaned, "0X")) {
        return std.fmt.parseInt(i64, cleaned[2..], 16);
    }
    return std.fmt.parseInt(i64, cleaned, 10);
}
