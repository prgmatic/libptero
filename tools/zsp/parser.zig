const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const token = @import("token.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer_mod.Lexer,
    current: token.Token,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .lexer = .{ .source = source },
            .current = undefined,
        };
        parser.current = try parser.lexer.next();
        return parser;
    }

    pub fn parse(self: *Parser) ![]ast.Function {
        var functions: std.ArrayList(ast.Function) = .empty;
        while (self.current.tag != .eof) {
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
                    return self.fail(prefix, "expected function declaration");
                }
                break;
            }

            const func = try self.parseFunction(export_symbol, inline_call);
            try functions.append(self.allocator, func);
        }

        return functions.toOwnedSlice(self.allocator);
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
                return self.fail(modifier, "unsupported function modifier");
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

    fn parseBlockStatements(self: *Parser) anyerror![]const ast.Statement {
        var statements: std.ArrayList(ast.Statement) = .empty;
        while (!try self.eat(.r_brace)) {
            try statements.append(self.allocator, try self.parseStatement());
        }
        return statements.toOwnedSlice(self.allocator);
    }

    fn parseStatement(self: *Parser) anyerror!ast.Statement {
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
                .value = try parseNumber(value),
            } };
        }

        if (try self.eat(.l_paren)) {
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .call = first.text };
        }

        return self.fail(first, "unsupported statement");
    }

    fn parseVarDecl(self: *Parser, is_const: bool) !ast.VarDecl {
        const name = try self.expect(.ident);
        _ = try self.expect(.colon);
        const data_type = try self.expect(.ident);
        if (!isDataType(data_type.text)) return self.fail(data_type, "expected data type");

        var reg: ?[]const u8 = null;
        if (try self.eat(.less)) {
            const reg_token = try self.expect(.register);
            _ = try self.expect(.type_end);
            reg = reg_token.text;
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
                return .{ .number = try parseNumber(tok) };
            },
            else => return self.fail(self.current, "expected value"),
        }
    }

    fn eat(self: *Parser, tag: token.Tag) !bool {
        if (self.current.tag != tag) return false;
        self.current = try self.lexer.next();
        return true;
    }

    fn expect(self: *Parser, tag: token.Tag) !token.Token {
        const tok = self.current;
        if (tok.tag != tag) return self.fail(tok, "unexpected token");
        self.current = try self.lexer.next();
        return tok;
    }

    fn fail(self: *Parser, tok: token.Token, message: []const u8) error{ParseError} {
        _ = self;
        std.debug.print("zsp:{d}:{d}: {s}: '{s}'\n", .{ tok.line, tok.column, message, tok.text });
        return error.ParseError;
    }
};

fn isDataType(text: []const u8) bool {
    return std.mem.eql(u8, text, "u16");
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
