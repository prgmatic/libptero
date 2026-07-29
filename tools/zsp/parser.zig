const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const token = @import("token.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer_mod.Lexer,
    current: token.Token,
    diagnostic: ?Diagnostic = null,
    imports: std.ArrayList(ast.Import) = .empty,

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
            if (self.isImportStart()) {
                try self.parseImport();
            } else if (self.isFunctionDeclarationStart()) {
                try functions.append(self.allocator, try self.parseFunctionDeclaration());
            } else {
                try functions.append(self.allocator, try self.parseTopLevelBlock());
            }
        }

        return functions.toOwnedSlice(self.allocator);
    }

    pub fn takeImports(self: *Parser) ![]ast.Import {
        return self.imports.toOwnedSlice(self.allocator);
    }

    fn parseFunctionDeclaration(self: *Parser) !ast.Function {
        var inline_call = false;
        var export_symbol = false;
        var public = false;
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
            if (std.mem.eql(u8, prefix.text, "pub")) {
                public = true;
                continue;
            }
            if (!std.mem.eql(u8, prefix.text, "fn")) {
                return self.fail(prefix, .expected_function_declaration);
            }
            break;
        }

        return self.parseFunction(export_symbol, inline_call, public);
    }

    fn parseTopLevelBlock(self: *Parser) !ast.Function {
        return .{
            .name = "top_level",
            .source_name = "top_level",
            .emit_label = false,
            .export_symbol = false,
            .public = false,
            .inline_call = false,
            .no_return = true,
            .parameters = &.{},
            .statements = try self.parseTopLevelStatements(),
        };
    }

    fn parseFunction(self: *Parser, export_symbol: bool, inline_call: bool, public: bool) !ast.Function {
        const name = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        const parameters = try self.parseParameters();
        errdefer self.allocator.free(parameters);
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
            .source_name = name.text,
            .export_symbol = export_symbol,
            .public = public,
            .inline_call = inline_call,
            .no_return = no_return,
            .parameters = parameters,
            .statements = statements,
        };
    }

    fn parseImport(self: *Parser) !void {
        _ = try self.expect(.ident);
        const name = try self.expect(.ident);
        _ = try self.expect(.equal);
        _ = try self.expect(.at);
        const import_name = try self.expect(.ident);
        if (!std.mem.eql(u8, import_name.text, "import")) {
            return self.fail(import_name, .expected_import);
        }
        _ = try self.expect(.l_paren);
        const path = try self.expect(.string);
        _ = try self.expect(.r_paren);
        _ = try self.expect(.semicolon);
        try self.imports.append(self.allocator, .{
            .name = name.text,
            .path = path.text,
        });
    }

    fn parseParameters(self: *Parser) ![]const ast.Parameter {
        var parameters: std.ArrayList(ast.Parameter) = .empty;
        errdefer parameters.deinit(self.allocator);
        if (try self.eat(.r_paren)) return parameters.toOwnedSlice(self.allocator);

        while (true) {
            const reg_keyword = try self.expect(.ident);
            if (!std.mem.eql(u8, reg_keyword.text, "reg")) {
                return self.fail(reg_keyword, .expected_fixed_register_parameter);
            }
            _ = try self.expect(.l_paren);
            const reg_token = try self.expect(.register);
            _ = try self.expect(.r_paren);
            const reg = parseRegister(reg_token) orelse
                return self.fail(reg_token, .expected_scalar_register);
            const name = try self.expect(.ident);
            _ = try self.expect(.colon);
            const data_type = try self.parseDataType(try self.expect(.ident));
            try parameters.append(self.allocator, .{
                .name = name.text,
                .data_type = data_type,
                .reg = reg,
            });

            if (try self.eat(.r_paren)) break;
            _ = try self.expect(.comma);
            if (try self.eat(.r_paren)) break;
        }
        return parameters.toOwnedSlice(self.allocator);
    }

    fn parseTopLevelStatements(self: *Parser) anyerror![]ast.Statement {
        var statements: std.ArrayList(ast.Statement) = .empty;
        while (self.current.tag != .eof and !self.isFunctionDeclarationStart()) {
            try statements.append(self.allocator, try self.parseStatement());
        }
        return statements.toOwnedSlice(self.allocator);
    }

    fn parseBlockStatements(self: *Parser) anyerror![]ast.Statement {
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
            const condition = try self.parseCondition();
            _ = try self.expect(.r_paren);
            _ = try self.expect(.l_brace);
            return .{ .while_loop = .{
                .condition = condition,
                .statements = try self.parseBlockStatements(),
            } };
        }

        if (std.mem.eql(u8, first.text, "if")) {
            _ = try self.expect(.l_paren);
            const condition = try self.parseCondition();
            _ = try self.expect(.r_paren);
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
                .then_statements = then_statements,
                .else_statements = else_statements,
            } };
        }

        if (std.mem.eql(u8, first.text, "store")) {
            _ = try self.expect(.l_paren);
            const data_type = try self.expect(.ident);
            _ = try self.expect(.comma);
            const address = try self.parseValueRef();
            _ = try self.expect(.comma);
            const value = try self.parseValueRef();
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .store = .{
                .data_type = try self.parseDataType(data_type),
                .address = address,
                .value = value,
            } };
        }

        if (std.mem.eql(u8, first.text, "const")) {
            return .{ .var_decl = try self.parseConstDecl() };
        }

        if (std.mem.eql(u8, first.text, "var")) {
            return self.fail(first, .var_keyword_removed);
        }

        if (std.mem.eql(u8, first.text, "reg")) {
            return .{ .var_decl = try self.parseRegDecl() };
        }

        if (try self.parseCompoundAssignOp()) |op| {
            const value = valueFromRef(try self.parseValueRef());
            _ = try self.expect(.semicolon);
            return .{ .assignment = .{
                .destination = first.text,
                .lhs = .{ .ident = first.text },
                .op = op,
                .rhs = value,
            } };
        }

        if (try self.eat(.equal)) {
            if (try self.eat(.tilde)) {
                const value = valueFromRef(try self.parseValueRef());
                _ = try self.expect(.semicolon);
                return .{ .assignment = .{
                    .destination = first.text,
                    .lhs = value,
                    .op = .bit_not,
                    .rhs = null,
                } };
            }

            const lhs = try self.parseValue();
            var op: ast.AssignOp = .set;
            var rhs: ?ast.Value = null;
            if (try self.parseBinaryAssignOp()) |binary_op| {
                op = binary_op;
                rhs = valueFromRef(try self.parseValueRef());
            }
            _ = try self.expect(.semicolon);
            return .{ .assignment = .{
                .destination = first.text,
                .lhs = lhs,
                .op = op,
                .rhs = rhs,
            } };
        }

        if (try self.eat(.l_paren)) {
            const arguments = try self.parseCallArguments();
            _ = try self.expect(.semicolon);
            return .{ .call = .{
                .module = null,
                .name = first.text,
                .arguments = arguments,
            } };
        }

        if (try self.eat(.dot)) {
            const member = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            const arguments = try self.parseCallArguments();
            _ = try self.expect(.semicolon);
            return .{ .call = .{
                .module = first.text,
                .name = member.text,
                .arguments = arguments,
            } };
        }

        return self.fail(first, .unsupported_statement);
    }

    fn parseCallArguments(self: *Parser) ![]const ast.ValueRef {
        var arguments: std.ArrayList(ast.ValueRef) = .empty;
        errdefer arguments.deinit(self.allocator);
        if (try self.eat(.r_paren)) return arguments.toOwnedSlice(self.allocator);

        while (true) {
            try arguments.append(self.allocator, try self.parseValueRef());
            if (try self.eat(.r_paren)) break;
            _ = try self.expect(.comma);
            if (try self.eat(.r_paren)) break;
        }
        return arguments.toOwnedSlice(self.allocator);
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

    fn parseConstDecl(self: *Parser) !ast.VarDecl {
        const name = try self.expect(.ident);
        _ = try self.expect(.colon);
        const data_type_token = try self.expect(.ident);
        const data_type = try self.parseDataType(data_type_token);

        _ = try self.expect(.equal);
        const value = valueFromRef(try self.parseValueRef());
        _ = try self.expect(.semicolon);

        return .{
            .is_const = true,
            .data_type = data_type,
            .reg = null,
            .name = name.text,
            .value = value,
        };
    }

    fn parseRegDecl(self: *Parser) !ast.VarDecl {
        var reg: ?ast.Register = null;
        if (try self.eat(.l_paren)) {
            const reg_token = try self.expect(.register);
            _ = try self.expect(.r_paren);
            reg = parseRegister(reg_token) orelse return self.fail(reg_token, .expected_scalar_register);
        }

        const name = try self.expect(.ident);
        var explicit_data_type: ?ast.DataType = null;
        if (try self.eat(.colon)) {
            explicit_data_type = try self.parseDataType(try self.expect(.ident));
        }
        _ = try self.expect(.equal);
        const value = try self.parseValue();
        _ = try self.expect(.semicolon);
        const data_type = explicit_data_type orelse switch (value) {
            .load => |load| load.data_type,
            else => return self.fail(name, .expected_data_type),
        };

        return .{
            .is_const = false,
            .data_type = data_type,
            .reg = reg,
            .name = name.text,
            .value = value,
        };
    }

    fn parseValue(self: *Parser) !ast.Value {
        if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "load")) {
            _ = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            const data_type = try self.parseDataType(try self.expect(.ident));
            _ = try self.expect(.comma);
            const address = try self.parseValueRef();
            _ = try self.expect(.r_paren);
            return .{ .load = .{ .data_type = data_type, .address = address } };
        }

        const value_ref = try self.parseValueRef();
        return switch (value_ref) {
            .ident => |name| .{ .ident = name },
            .number => |number| .{ .number = number },
        };
    }

    fn parseValueRef(self: *Parser) !ast.ValueRef {
        if (try self.eat(.minus)) {
            const tok = try self.expect(.number);
            const value = try self.parseNumberValue(tok);
            return .{ .number = std.math.negate(value) catch return self.fail(tok, .invalid_number) };
        }

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

    fn parseCondition(self: *Parser) !ast.Condition {
        const lhs = try self.expect(.ident);
        const op = switch (self.current.tag) {
            .equal_equal => ast.CompareOp.eq,
            .not_equal => ast.CompareOp.ne,
            .less => ast.CompareOp.lt,
            .less_equal => ast.CompareOp.le,
            .greater => ast.CompareOp.gt,
            .greater_equal => ast.CompareOp.ge,
            else => return self.fail(self.current, .expected_comparison_operator),
        };
        self.current = try self.lexer.next();
        return .{
            .lhs = lhs.text,
            .op = op,
            .rhs = valueFromRef(try self.parseValueRef()),
        };
    }

    fn parseCompoundAssignOp(self: *Parser) !?ast.AssignOp {
        const op: ast.AssignOp = switch (self.current.tag) {
            .plus_equal => .add,
            .minus_equal => .sub,
            .star_equal => .mul,
            .slash_equal => .div,
            .shift_left_equal => .shift_left,
            .shift_right_equal => .shift_right,
            .logical_shift_right_equal => .logical_shift_right,
            .ampersand_equal => .bit_and,
            .pipe_equal => .bit_or,
            .caret_equal => .bit_xor,
            .nor_equal => .bit_nor,
            else => return null,
        };
        self.current = try self.lexer.next();
        return op;
    }

    fn parseBinaryAssignOp(self: *Parser) !?ast.AssignOp {
        const op: ast.AssignOp = switch (self.current.tag) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .shift_left => .shift_left,
            .shift_right => .shift_right,
            .logical_shift_right => .logical_shift_right,
            .ampersand => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .nor => .bit_nor,
            else => return null,
        };
        self.current = try self.lexer.next();
        return op;
    }

    fn parseDataType(self: *Parser, tok: token.Token) !ast.DataType {
        return parseDataTypeName(tok.text) orelse self.fail(tok, .expected_data_type);
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
            std.mem.eql(u8, self.current.text, "pub") or
            std.mem.eql(u8, self.current.text, "fn");
    }

    fn isImportStart(self: *const Parser) bool {
        if (self.current.tag != .ident or !std.mem.eql(u8, self.current.text, "const")) return false;
        var lexer = self.lexer;
        _ = lexer.next() catch return false;
        const separator = lexer.next() catch return false;
        return separator.tag == .equal;
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

fn valueFromRef(value_ref: ast.ValueRef) ast.Value {
    return switch (value_ref) {
        .ident => |name| .{ .ident = name },
        .number => |number| .{ .number = number },
    };
}

pub const ErrorType = enum {
    expected_function_declaration,
    unsupported_function_modifier,
    unsupported_statement,
    unsupported_builtin,
    var_keyword_removed,
    expected_data_type,
    expected_scalar_register,
    expected_fixed_register_parameter,
    expected_import,
    expected_value,
    expected_comparison_operator,
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
        .var_keyword_removed => "'var' has been replaced by 'reg' for register variables",
        .expected_data_type => "expected data type",
        .expected_scalar_register => "expected scalar register",
        .expected_fixed_register_parameter => "expected fixed-register parameter",
        .expected_import => "expected import",
        .expected_value => "expected value",
        .expected_comparison_operator => "expected comparison operator",
        .unexpected_token => "unexpected token",
        .invalid_number => "invalid number",
    };
}

fn parseRegister(tok: token.Token) ?ast.Register {
    inline for (std.meta.fields(ast.Register)) |field| {
        if (std.mem.eql(u8, tok.text[1..], field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseDataTypeName(text: []const u8) ?ast.DataType {
    inline for (std.meta.fields(ast.DataType)) |field| {
        if (std.mem.eql(u8, text, field.name)) {
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
