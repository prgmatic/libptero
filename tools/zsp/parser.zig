const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const token = @import("token.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer_mod.Lexer,
    current: token.Token,
    diagnostic: ?Diagnostic = null,
    statement_locations: std.ArrayList(ast.StatementLocation) = .empty,
    imports: std.ArrayList(ast.Import) = .empty,
    packed_structs: std.ArrayList(ast.PackedStructDecl) = .empty,
    /// Names visible for type inference, innermost last; blocks restore
    /// the length on exit.
    type_symbols: std.ArrayList(TypeSymbol) = .empty,
    /// Whether the block just parsed opened with `@branchHint(.cold)`.
    last_block_cold: bool = false,
    compile_time_members: std.ArrayList(CompileTimeMember) = .empty,
    compile_time_types: std.ArrayList([]const u8) = .empty,
    /// Names replaced while lexing: `inline for` captures become numbers
    /// and names declared in an unrolled body get a per-iteration name.
    substitutions: std.ArrayList(Substitution) = .empty,
    /// Names the parser made up, owned by the function being parsed.
    generated_names: std.ArrayList([]const u8) = .empty,
    /// Unrolled iterations being parsed, innermost last.
    iterations: std.ArrayList(usize) = .empty,
    /// What ends an assignment: `;`, or `)` in a `while` continue expression.
    terminator: token.Tag = .semicolon,
    /// Set while parsing a store's value, where `v[first..end]` is allowed.
    allow_lane_range: bool = false,
    accumulator: @import("parse_products.zig").Chain = .{},

    pub const TypeSymbol = struct {
        name: []const u8,
        data_type: ast.DataType,
        function_type: ?ast.FunctionType = null,
        /// Register arrays: `name[i]` lexes as the element's own name.
        array_len: ?usize = null,
        pointee: ?Pointee = null,
        /// `const` declarations: the value they fold to.
        constant: ?i64 = null,
    };

    /// What a typed DMEM pointer addresses.
    pub const Pointee = union(enum) {
        scalar: ast.DataType,
        packed_struct: []const u8,
    };

    /// Formats the indices of the enclosing unrolled iterations as `0.1`.
    const IterationPath = struct {
        indices: []const usize,

        pub fn format(self: IterationPath, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (self.indices, 0..) |index, position| {
                if (position != 0) try writer.writeByte('.');
                try writer.print("{d}", .{index});
            }
        }
    };

    const Substitution = struct { name: []const u8, tag: token.Tag, text: []const u8 };

    /// Statements parsed so far in one list, with their source locations.
    pub const StatementList = struct {
        statements: std.ArrayList(ast.Statement) = .empty,
        locations: std.ArrayList(ast.SourceLocation) = .empty,

        pub fn append(self: *StatementList, allocator: std.mem.Allocator, statement: ast.Statement, location: ast.SourceLocation) !void {
            try self.statements.append(allocator, statement);
            try self.locations.append(allocator, location);
        }

        pub fn insert(self: *StatementList, allocator: std.mem.Allocator, index: usize, statement: ast.Statement, location: ast.SourceLocation) !void {
            try self.statements.insert(allocator, index, statement);
            try self.locations.insert(allocator, index, location);
        }

        pub fn remove(self: *StatementList, index: usize) void {
            _ = self.statements.orderedRemove(index);
            _ = self.locations.orderedRemove(index);
        }

        pub fn len(self: *const StatementList) usize {
            return self.statements.items.len;
        }
    };

    pub const CompileTimeMember = struct {
        type_name: []const u8,
        member_name: []const u8,
        data_type: ast.DataType,
        value: i64,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .lexer = .{ .source = source },
            .current = undefined,
            .diagnostic = null,
        };
        try parser.advance();
        return parser;
    }

    pub fn parse(self: *Parser) ![]ast.Function {
        defer self.deinitTables();
        var functions: std.ArrayList(ast.Function) = .empty;
        while (self.current.tag != .eof) {
            if (self.isCompileTimeTypeStart()) {
                try self.parseCompileTimeType();
            } else if (self.isImportStart()) {
                try self.parseImport();
            } else if (self.isFunctionDeclarationStart()) {
                try self.appendFunction(&functions, try self.parseFunctionDeclaration());
            } else {
                try self.appendFunction(&functions, try self.parseTopLevelBlock());
            }
        }

        return functions.toOwnedSlice(self.allocator);
    }

    fn deinitTables(self: *Parser) void {
        self.packed_structs.deinit(self.allocator);
        self.statement_locations.deinit(self.allocator);
        self.type_symbols.deinit(self.allocator);
        self.compile_time_members.deinit(self.allocator);
        self.compile_time_types.deinit(self.allocator);
        self.substitutions.deinit(self.allocator);
        for (self.generated_names.items) |name| self.allocator.free(name);
        self.generated_names.deinit(self.allocator);
        self.iterations.deinit(self.allocator);
    }

    pub fn appendFunction(self: *Parser, functions: *std.ArrayList(ast.Function), parsed: ast.Function) !void {
        var function = parsed;
        function.source_locations = try self.statement_locations.toOwnedSlice(self.allocator);
        function.generated_names = try self.generated_names.toOwnedSlice(self.allocator);
        try functions.append(self.allocator, function);
    }

    pub fn takeImports(self: *Parser) ![]ast.Import {
        return self.imports.toOwnedSlice(self.allocator);
    }

    pub fn parseTopLevelBlock(self: *Parser) !ast.Function {
        return .{
            .name = "top_level",
            .source_name = "top_level",
            .emit_label = false,
            .export_symbol = false,
            .public = false,
            .inline_call = false,
            .external = false,
            .no_return = true,
            .command_indices = &.{},
            .parameters = &.{},
            .statements = try self.parseTopLevelStatements(),
        };
    }

    pub fn parseTopLevelStatements(self: *Parser) anyerror![]ast.Statement {
        var list: StatementList = .{};
        defer list.locations.deinit(self.allocator);
        while (self.current.tag != .eof and !self.isFunctionDeclarationStart() and
            !self.isCompileTimeTypeStart() and !self.isImportStart())
        {
            try self.parseStatementInto(&list);
        }
        self.accumulator.closeList(&list);
        return self.finishStatements(&list);
    }

    pub fn parseBlockStatements(self: *Parser) anyerror![]ast.Statement {
        const scope = self.type_symbols.items.len;
        defer self.type_symbols.shrinkRetainingCapacity(scope);
        var list: StatementList = .{};
        defer list.locations.deinit(self.allocator);
        const cold = try self.eatColdHint();
        while (!try self.eat(.r_brace)) try self.parseStatementInto(&list);
        self.accumulator.closeList(&list);
        self.last_block_cold = cold;
        return self.finishStatements(&list);
    }

    /// `@branchHint(.cold);` opening a block.
    fn eatColdHint(self: *Parser) !bool {
        if (self.current.tag != .at) return false;
        const next = self.peek(1) orelse return false;
        if (next[0].tag != .ident or !std.mem.eql(u8, next[0].text, "branchHint")) return false;
        _ = try self.expect(.at);
        _ = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        _ = try self.expect(.dot);
        const hint = try self.expect(.ident);
        if (!std.mem.eql(u8, hint.text, "cold")) return self.fail(hint, .unsupported_builtin);
        _ = try self.expect(.r_paren);
        _ = try self.expect(.semicolon);
        return true;
    }

    /// Parses the statements up to the closing brace into `list`.
    pub fn parseStatementsUntilBrace(self: *Parser, list: *StatementList) anyerror!void {
        while (!try self.eat(.r_brace)) try self.parseStatementInto(list);
    }

    /// One source statement, which may expand to several AST statements.
    pub fn parseStatementInto(self: *Parser, list: *StatementList) anyerror!void {
        const location: ast.SourceLocation = .{ .line = self.current.line, .column = self.current.column };
        if (try @import("parse_comptime.zig").parseExpandingStatement(self, list, location)) return;
        try @import("parse_products.zig").appendStatement(self, list, try self.parseStatement(), location);
    }

    pub fn finishStatements(self: *Parser, list: *StatementList) ![]ast.Statement {
        const locations = list.locations.items;
        const result = try list.statements.toOwnedSlice(self.allocator);
        for (result, locations) |*statement, location| {
            try self.statement_locations.append(self.allocator, .{ .statement = statement, .location = location });
        }
        return result;
    }

    pub const parseStatement = @import("parse_statements.zig").parseStatement;
    pub const parseNamespaceStatement = @import("parse_statements.zig").parseNamespaceStatement;
    pub const parseLabelOrStatement = @import("parse_statements.zig").parseLabelOrStatement;
    pub const parseRspNamespaceStatement = @import("parse_statements.zig").parseRspNamespaceStatement;
    pub const parseModuleStatement = @import("parse_statements.zig").parseModuleStatement;
    pub const parsePackedKeyword = @import("parse_statements.zig").parsePackedKeyword;
    pub const parseDataKeyword = @import("parse_statements.zig").parseDataKeyword;
    pub const parseBssKeyword = @import("parse_statements.zig").parseBssKeyword;
    pub const parseStateKeyword = @import("parse_statements.zig").parseStateKeyword;
    pub const parseExactKeyword = @import("parse_statements.zig").parseExactKeyword;
    pub const parseExportKeyword = @import("parse_statements.zig").parseExportKeyword;
    pub const parseTailKeyword = @import("parse_statements.zig").parseTailKeyword;
    pub const parseReturnKeyword = @import("parse_statements.zig").parseReturnKeyword;
    pub const parseJumpKeyword = @import("parse_statements.zig").parseJumpKeyword;
    pub const parseCallKeyword = @import("parse_statements.zig").parseCallKeyword;
    pub const parseAsmKeyword = @import("parse_statements.zig").parseAsmKeyword;
    pub const parseWhileKeyword = @import("parse_statements.zig").parseWhileKeyword;
    pub const parseDoKeyword = @import("parse_statements.zig").parseDoKeyword;
    pub const parseBreakKeyword = @import("parse_statements.zig").parseBreakKeyword;
    pub const parseLabeledStatement = @import("parse_statements.zig").parseLabeledStatement;
    pub const parseIfKeyword = @import("parse_statements.zig").parseIfKeyword;
    pub const parseGotoKeyword = @import("parse_statements.zig").parseGotoKeyword;
    pub const parseStoreKeyword = @import("parse_statements.zig").parseStoreKeyword;
    pub const parseConstKeyword = @import("parse_statements.zig").parseConstKeyword;
    pub const parseVarKeyword = @import("parse_statements.zig").parseVarKeyword;
    pub const parseRegKeyword = @import("parse_statements.zig").parseRegKeyword;
    pub const parseReservedKeyword = @import("parse_statements.zig").parseReservedKeyword;
    pub const parseAssignmentOrCall = @import("parse_statements.zig").parseAssignmentOrCall;
    pub const parseDoWhileStatement = @import("parse_statements.zig").parseDoWhileStatement;
    pub const parseOptionalDelaySlot = @import("parse_statements.zig").parseOptionalDelaySlot;

    pub fn parseCallArguments(self: *Parser) ![]const ast.ValueRef {
        var arguments: std.ArrayList(ast.ValueRef) = .empty;
        errdefer arguments.deinit(self.allocator);
        if (!try self.eat(.r_paren)) while (true) {
            try arguments.append(self.allocator, try self.parseValueRef());
            if (try self.listEnds(.r_paren)) break;
        };
        return arguments.toOwnedSlice(self.allocator);
    }

    pub fn addTypeSymbol(self: *Parser, name: []const u8, data_type: ast.DataType) !void {
        return self.addTypeSymbolWithFunctionType(name, data_type, null);
    }

    pub fn addTypeSymbolWithFunctionType(
        self: *Parser,
        name: []const u8,
        data_type: ast.DataType,
        function_type: ?ast.FunctionType,
    ) !void {
        try self.type_symbols.append(self.allocator, .{ .name = name, .data_type = data_type, .function_type = function_type });
    }

    pub fn lookupTypeSymbolInfo(self: *const Parser, name: []const u8) ?TypeSymbol {
        var index = self.type_symbols.items.len;
        while (index > 0) {
            index -= 1;
            const symbol = self.type_symbols.items[index];
            if (std.mem.eql(u8, symbol.name, name)) return symbol;
        }
        return null;
    }

    /// The value of a visible `const` named `name`.
    pub fn lookupConstant(self: *const Parser, name: []const u8) ?i64 {
        const symbol = self.lookupTypeSymbolInfo(name) orelse return null;
        return symbol.constant;
    }

    pub fn lookupCompileTimeMember(self: *const Parser, type_name: []const u8, member_name: []const u8) ?CompileTimeMember {
        for (self.compile_time_members.items) |member| {
            if (std.mem.eql(u8, member.type_name, type_name) and std.mem.eql(u8, member.member_name, member_name)) return member;
        }
        return null;
    }

    pub fn findPackedStruct(self: *const Parser, name: []const u8) ?ast.PackedStructDecl {
        for (self.packed_structs.items) |declaration| {
            if (std.mem.eql(u8, declaration.name, name)) return declaration;
        }
        return null;
    }

    const declarations = @import("parse_declarations.zig");
    pub const MemoryType = declarations.MemoryType;
    pub const parseFunctionDeclaration = declarations.parseFunctionDeclaration;
    pub const isFunctionDeclarationStart = declarations.isFunctionDeclarationStart;
    pub const isCompileTimeTypeStart = declarations.isCompileTimeTypeStart;
    pub const isImportStart = declarations.isImportStart;
    pub const parseImport = declarations.parseImport;
    pub const parseCompileTimeType = declarations.parseCompileTimeType;
    pub const applyDefaultParameterRegisters = declarations.applyDefaultParameterRegisters;
    pub const parseParameters = declarations.parseParameters;
    pub const parseRegDecl = declarations.parseRegDecl;
    pub const parseConstStatement = declarations.parseConstStatement;
    pub const parsePackedStructDecl = declarations.parsePackedStructDecl;
    pub const parseMemoryType = declarations.parseMemoryType;
    pub const parseStorageBlock = declarations.parseStorageBlock;

    const builtins = @import("parse_builtins.zig");
    pub const parseBuiltinStatement = builtins.parseBuiltinStatement;
    pub const parseRspStatement = builtins.parseRspStatement;
    pub const parseCp0Statement = builtins.parseCp0Statement;
    pub const parseVectorStatement = builtins.parseVectorStatement;

    pub const parseValue = @import("parse_values.zig").parseValue;
    pub const parseNamedValue = @import("parse_values.zig").parseNamedValue;
    pub const parseVectorOrReferenceValue = @import("parse_values.zig").parseVectorOrReferenceValue;
    pub const parseHardwareRead = @import("parse_values.zig").parseHardwareRead;
    pub const parseDmemAddress = @import("parse_values.zig").parseDmemAddress;
    pub const parseCodeAddress = @import("parse_values.zig").parseCodeAddress;
    pub const parseSignedComparison = @import("parse_values.zig").parseSignedComparison;
    pub const parseBitCast = @import("parse_values.zig").parseBitCast;
    pub const parseLoadValue = @import("parse_values.zig").parseLoadValue;
    pub const parseAccumulatorValue = @import("parse_values.zig").parseAccumulatorValue;
    pub const parseVectorShiftValue = @import("parse_values.zig").parseVectorShiftValue;
    pub const parseVectorOperationValue = @import("parse_values.zig").parseVectorOperationValue;
    pub const parseFunctionReference = @import("parse_values.zig").parseFunctionReference;
    pub const parseScalarExpression = @import("parse_values.zig").parseScalarExpression;
    pub const parseValueRef = @import("parse_values.zig").parseValueRef;
    pub const isVectorDotSuffix = @import("parse_values.zig").isVectorDotSuffix;
    pub const parseVectorAccess = @import("parse_values.zig").parseVectorAccess;
    pub const parseLiteralOffset = @import("parse_values.zig").parseLiteralOffset;
    pub const packedStructFieldOffset = @import("parse_values.zig").packedStructFieldOffset;
    pub const parseCondition = @import("parse_values.zig").parseCondition;
    pub const parseComparisonOperator = @import("parse_values.zig").parseComparisonOperator;
    pub const parseCompoundAssignOp = @import("parse_values.zig").parseCompoundAssignOp;
    pub const parseBinaryAssignOp = @import("parse_values.zig").parseBinaryAssignOp;

    pub fn parseDataType(self: *Parser, tok: token.Token) !ast.DataType {
        return parseDataTypeName(tok.text) orelse self.fail(tok, .expected_data_type);
    }

    pub fn eat(self: *Parser, tag: token.Tag) !bool {
        if (self.current.tag != tag) return false;
        try self.advance();
        return true;
    }

    /// Moves to the next token, applying name substitutions and turning
    /// `array[index]` into the element's name.
    pub fn advance(self: *Parser) !void {
        const tok = self.substituted(try self.lexer.next());
        self.current = try self.arrayElement(tok);
    }

    fn substituted(self: *const Parser, tok: token.Token) token.Token {
        if (tok.tag != .ident) return tok;
        var index = self.substitutions.items.len;
        while (index > 0) {
            index -= 1;
            const substitution = self.substitutions.items[index];
            if (!std.mem.eql(u8, substitution.name, tok.text)) continue;
            var replaced = tok;
            replaced.tag = substitution.tag;
            replaced.text = substitution.text;
            return replaced;
        }
        return tok;
    }

    /// `name[index]` for a register array, with a literal or substituted index.
    fn arrayElement(self: *Parser, tok: token.Token) !token.Token {
        const len = self.arrayLength(tok) orelse return tok;
        var lexer = self.lexer;
        if ((try lexer.next()).tag != .l_bracket) return tok;
        const index = try self.arrayIndex(&lexer, len);
        self.lexer = lexer;
        var element = tok;
        element.text = try self.elementName(tok.text, index);
        return element;
    }

    fn arrayLength(self: *const Parser, tok: token.Token) ?usize {
        if (tok.tag != .ident) return null;
        const symbol = self.lookupTypeSymbolInfo(tok.text) orelse return null;
        return symbol.array_len;
    }

    /// `index]` after an array's `[`, checked against its length.
    fn arrayIndex(self: *Parser, lexer: *lexer_mod.Lexer, len: usize) !usize {
        const index_token = self.substituted(try lexer.next());
        if (index_token.tag != .number) return self.fail(index_token, .expected_array_index);
        if ((try lexer.next()).tag != .r_bracket) return self.fail(index_token, .expected_array_index);
        const index = try self.parseNumberValue(index_token);
        const valid = std.math.cast(usize, index) orelse return self.fail(index_token, .array_index_out_of_range);
        return if (valid < len) valid else self.fail(index_token, .array_index_out_of_range);
    }

    /// The generated name of `array[index]`.
    pub fn elementName(self: *Parser, array: []const u8, index: usize) ![]const u8 {
        return self.generatedName("{s}[{d}]", .{ array, index });
    }

    /// A parser-made name, shared by every use of the same text.
    pub fn generatedName(self: *Parser, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, fmt, args);
        for (self.generated_names.items) |existing| {
            if (!std.mem.eql(u8, existing, name)) continue;
            self.allocator.free(name);
            return existing;
        }
        errdefer self.allocator.free(name);
        try self.generated_names.append(self.allocator, name);
        return name;
    }

    /// Replaces `name` while lexing until `restoreSubstitutions`.
    pub fn substitute(self: *Parser, name: []const u8, tag: token.Tag, text: []const u8) !void {
        try self.substitutions.append(self.allocator, .{ .name = name, .tag = tag, .text = text });
    }

    pub fn restoreSubstitutions(self: *Parser, len: usize) void {
        self.substitutions.shrinkRetainingCapacity(len);
    }

    /// A name declared inside an unrolled body, made unique per iteration.
    pub fn declaredName(self: *Parser, name: token.Token) !token.Token {
        if (self.iterations.items.len == 0) return name;
        var renamed = name;
        renamed.text = try self.generatedName("{s}#{f}", .{ name.text, IterationPath{ .indices = self.iterations.items } });
        try self.substitute(name.text, .ident, renamed.text);
        return renamed;
    }

    /// Whether the current token is the identifier `word`.
    pub fn atKeyword(self: *const Parser, word: []const u8) bool {
        return self.current.tag == .ident and std.mem.eql(u8, self.current.text, word);
    }

    /// Consumes the identifier `word` if it is current.
    pub fn eatKeyword(self: *Parser, word: []const u8) !bool {
        if (!self.atKeyword(word)) return false;
        _ = try self.expect(.ident);
        return true;
    }

    /// The `count` tokens after the current one, without consuming them.
    pub fn peek(self: *const Parser, comptime count: usize) ?[count]token.Token {
        var lexer = self.lexer;
        var tokens: [count]token.Token = undefined;
        for (&tokens) |*tok| tok.* = self.substituted(lexer.next() catch return null);
        return tokens;
    }

    /// After a list item: consumes `close` or a comma, allowing a trailing
    /// comma before `close`. True when the list has ended.
    pub fn listEnds(self: *Parser, close: token.Tag) !bool {
        if (try self.eat(close)) return true;
        _ = try self.expect(.comma);
        return self.eat(close);
    }

    pub fn expect(self: *Parser, tag: token.Tag) !token.Token {
        const tok = self.current;
        if (tok.tag != tag) return self.failExpected(tok, tag);
        try self.advance();
        return tok;
    }

    pub fn parseNumberValue(self: *Parser, tok: token.Token) !i64 {
        return parseNumber(tok) catch return self.fail(tok, .invalid_number);
    }

    pub fn failExpected(self: *Parser, tok: token.Token, expected: token.Tag) error{ParseError} {
        self.setDiagnostic(tok, .unexpected_token, expected);
        return error.ParseError;
    }

    pub fn fail(self: *Parser, tok: token.Token, code: ErrorType) error{ParseError} {
        self.setDiagnostic(tok, code, null);
        return error.ParseError;
    }

    pub fn setDiagnostic(self: *Parser, tok: token.Token, code: ErrorType, expected_token: ?token.Tag) void {
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

pub fn valueFromRef(value_ref: ast.ValueRef) ast.Value {
    return switch (value_ref) {
        .ident => |name| .{ .ident = name },
        .bit_cast => |name| .{ .bit_cast = .{ .ident = name } },
        .vector_access => |access| .{ .vector_access = access },
        .number => |number| .{ .number = number },
    };
}

/// Binding strength of a binary scalar operator; higher binds tighter.
pub fn binaryPrecedence(tag: token.Tag) ?u4 {
    return binary_precedence.get(tag);
}

const binary_precedence = blk: {
    var table = std.EnumArray(token.Tag, ?u4).initFill(null);
    const levels = .{
        .{ 1, .{ .pipe, .nor } },
        .{ 2, .{.caret} },
        .{ 3, .{.ampersand} },
        .{ 4, .{ .shift_left, .shift_right, .logical_shift_right } },
        .{ 5, .{ .plus, .plus_percent, .minus, .minus_percent } },
        .{ 6, .{ .star, .slash } },
    };
    for (levels) |level| {
        for (level[1]) |tag| table.set(tag, level[0]);
    }
    break :blk table;
};

pub fn valueRefFromValue(value: ast.Value) !ast.ValueRef {
    return switch (value) {
        .ident => |name| .{ .ident = name },
        .vector_access => |access| .{ .vector_access = access },
        .number => |number| .{ .number = number },
        else => error.InvalidComparisonExpression,
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
    expected_register,
    expected_vector_register,
    invalid_vector_lane,
    invalid_vector_swizzle,
    unsupported_destination_swizzle,
    expected_vector_operand,
    unsupported_vector_shift,
    invalid_accumulator_part,
    expected_fixed_register_parameter,
    expected_import,
    expected_value,
    expected_comparison_operator,
    expected_literal_offset,
    expected_scalar_data_type,
    expected_data_literal,
    undefined_data_initializer,
    external_data_initializer,
    expected_struct_declaration,
    invalid_array_length,
    invalid_command_index,
    invalid_hardware_register,
    duplicate_clobber_contract,
    duplicate_compile_time_type,
    duplicate_compile_time_member,
    expected_unsigned_scalar_type,
    unknown_packed_struct,
    unknown_packed_struct_field,
    incorrect_array_initializer_count,
    unexpected_token,
    invalid_number,
    invalid_constant_expression,
    invalid_inline_range,
    expected_array_index,
    array_index_out_of_range,
    invalid_lane_range,
    invalid_lane_range_transfer,
    invalid_vector_product,
    accumulator_not_started,
    accumulator_read_not_adjacent,
    accumulator_read_requires_fraction,
    expected_pointer_field,
    pointer_type_mismatch,
};

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    token_tag: token.Tag,
    token_text: []const u8,
    expected_token: ?token.Tag = null,
    err: ErrorType,
};

const error_strings = std.EnumArray(ErrorType, []const u8).init(.{
    .expected_function_declaration = "expected function declaration",
    .unsupported_function_modifier = "unsupported function modifier",
    .unsupported_statement = "unsupported statement",
    .unsupported_builtin = "unsupported builtin",
    .var_keyword_removed = "'var' has been replaced by 'reg' for register variables",
    .expected_data_type = "expected data type",
    .expected_scalar_register = "expected scalar register",
    .expected_register = "expected scalar or vector register",
    .expected_vector_register = "expected vector register ($v00 through $v31)",
    .invalid_vector_lane = "vector lane must be between 0 and 7",
    .invalid_vector_swizzle = "unsupported vector swizzle",
    .unsupported_destination_swizzle = "only a single lane or typed view is allowed on an assignment destination",
    .expected_vector_operand = "expected vector operand",
    .unsupported_vector_shift = "unsupported vector shift amount",
    .invalid_accumulator_part = "expected accumulator part .high, .middle, or .low",
    .expected_fixed_register_parameter = "expected fixed-register parameter",
    .expected_import = "expected import",
    .expected_value = "expected value",
    .expected_comparison_operator = "expected comparison operator",
    .expected_literal_offset = "expected literal memory offset",
    .expected_scalar_data_type = "expected scalar data type",
    .expected_data_literal = "expected data initializer literal",
    .undefined_data_initializer = "data declarations must contain initialized bytes; reserve storage in a bss block",
    .external_data_initializer = "external storage declarations cannot have initializers",
    .expected_struct_declaration = "expected packed struct declaration",
    .invalid_array_length = "invalid array length",
    .invalid_command_index = "command index must be between 0 and 239",
    .invalid_hardware_register = "hardware register index must be between 0 and 15",
    .duplicate_clobber_contract = "function has more than one clobber contract",
    .duplicate_compile_time_type = "duplicate compile-time type",
    .duplicate_compile_time_member = "duplicate compile-time member",
    .expected_unsigned_scalar_type = "expected unsigned scalar type",
    .unknown_packed_struct = "unknown packed struct",
    .unknown_packed_struct_field = "unknown packed struct field",
    .incorrect_array_initializer_count = "array initializer must contain exactly the declared element count",
    .unexpected_token = "unexpected token",
    .invalid_number = "invalid number",
    .invalid_constant_expression = "constant expression overflows or divides by zero",
    .invalid_inline_range = "inline for needs a range first..end with first <= end and at most 256 iterations",
    .expected_array_index = "register array index must be a compile-time integer",
    .array_index_out_of_range = "register array index is out of range",
    .invalid_lane_range = "a lane range must select 2, 4, or 8 lanes within the vector; 8 lanes start at lane 0",
    .invalid_lane_range_transfer = "lane ranges are only allowed as a load destination or a stored value, and their type must match",
    .invalid_vector_product = "unsupported vector product; multiply vec32 pairs, or vec16 operands viewed as .sint, .ufract, or .sfract",
    .accumulator_not_started = "`acc +=` needs an `acc = a * b;` earlier in the same block",
    .accumulator_read_not_adjacent = "`r = acc;` must directly follow the product it reads; use accumulator(.high/.middle/.low) for raw slices",
    .accumulator_read_requires_fraction = "reading a vec32 needs a final product with a vec32 left operand, which leaves the fraction readable",
    .expected_pointer_field = "expected a field of the pointed-to packed struct, or `.*`",
    .pointer_type_mismatch = "pointer types differ",
});

pub fn errorString(code: ErrorType) []const u8 {
    return error_strings.get(code);
}

pub fn parseRegister(tok: token.Token) ?ast.Register {
    inline for (std.meta.fields(ast.Register)) |field| {
        if (std.mem.eql(u8, tok.text[1..], field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

pub fn parseVectorRegister(tok: token.Token) ?ast.VectorRegister {
    if (tok.text.len != 4 or tok.text[1] != 'v') return null;
    const index = std.fmt.parseInt(u5, tok.text[2..], 10) catch return null;
    return @enumFromInt(index);
}

pub fn isVectorType(data_type: ast.DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

pub fn isSignedType(data_type: ast.DataType) bool {
    return data_type == .i8 or data_type == .i16 or data_type == .i32;
}

pub fn scalarTypeSize(data_type: ast.DataType) i64 {
    return switch (data_type) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .dmem => 4,
        .vec16, .vec32 => unreachable,
    };
}

pub fn literalFitsType(value: i64, data_type: ast.DataType) bool {
    const range = literal_ranges.get(data_type) orelse return false;
    return value >= range[0] and value <= range[1];
}

/// Inclusive literal bounds per type; DMEM addresses may name its end.
const literal_ranges = std.EnumArray(ast.DataType, ?[2]i64).init(.{
    .u8 = .{ 0, std.math.maxInt(u8) },
    .u16 = .{ 0, std.math.maxInt(u16) },
    .u32 = .{ 0, std.math.maxInt(u32) },
    .dmem = .{ 0, 4096 },
    .i8 = .{ std.math.minInt(i8), std.math.maxInt(i8) },
    .i16 = .{ std.math.minInt(i16), std.math.maxInt(i16) },
    .i32 = .{ std.math.minInt(i32), std.math.maxInt(i32) },
    .vec16 = null,
    .vec32 = null,
});

pub fn parseVectorView(text: []const u8) ?ast.VectorView {
    inline for (std.meta.fields(ast.VectorView)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn parseVectorOp(text: []const u8) ?ast.VectorOp {
    const aliases = .{
        .{ "vectorAdd", ast.VectorOp.vadd },
        .{ "vectorSubtract", ast.VectorOp.vsub },
        .{ "vectorAddCarry", ast.VectorOp.vaddc },
        .{ "vectorSubtractCarry", ast.VectorOp.vsubc },
        .{ "vectorCompareLessThan", ast.VectorOp.vlt },
        .{ "vectorCompareEqual", ast.VectorOp.veq },
        .{ "vectorCompareNotEqual", ast.VectorOp.vne },
        .{ "vectorCompareGreaterOrEqual", ast.VectorOp.vge },
        .{ "vectorClipHigh", ast.VectorOp.vch },
        .{ "vectorClipLow", ast.VectorOp.vcl },
        .{ "vectorSelectByCompareCode", ast.VectorOp.vmrg },
        .{ "vectorReciprocal", ast.VectorOp.vrcp },
        .{ "vectorReciprocalLow", ast.VectorOp.vrcpl },
        .{ "vectorReciprocalHigh", ast.VectorOp.vrcph },
        .{ "vectorReciprocalSquareRoot", ast.VectorOp.vrsq },
        .{ "vectorReciprocalSquareRootLow", ast.VectorOp.vrsql },
        .{ "vectorReciprocalSquareRootHigh", ast.VectorOp.vrsqh },
        .{ "vectorMove", ast.VectorOp.vmov },
    };
    inline for (aliases) |alias| if (std.mem.eql(u8, text, alias[0])) return alias[1];
    inline for (std.meta.fields(ast.VectorOp)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn explicitAccumulatorPart(text: []const u8) ?ast.AccumulatorPart {
    if (std.mem.eql(u8, text, "readVectorAccumulatorHigh")) return .high;
    if (std.mem.eql(u8, text, "readVectorAccumulatorMiddle")) return .middle;
    if (std.mem.eql(u8, text, "readVectorAccumulatorLow")) return .low;
    return null;
}

pub fn isUnaryVectorOp(op: ast.VectorOp) bool {
    return switch (op) {
        .vrcp, .vrcpl, .vrcph, .vrsq, .vrsql, .vrsqh, .vmov => true,
        else => false,
    };
}

pub fn parseAccumulatorPart(text: []const u8) ?ast.AccumulatorPart {
    inline for (std.meta.fields(ast.AccumulatorPart)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn vectorControlRegisterForOperation(name: []const u8, comptime prefix: []const u8) ?ast.VectorControlRegister {
    if (std.mem.eql(u8, name, prefix ++ "CarryOut")) return .carry_out;
    if (std.mem.eql(u8, name, prefix ++ "CompareCode")) return .compare_code;
    if (std.mem.eql(u8, name, prefix ++ "CompareExtension")) return .compare_extension;
    return null;
}

pub fn vectorMemoryOperationForBuiltin(name: []const u8) ?ast.VectorMemoryOperation {
    const names = .{
        .{ "loadQuad", ast.VectorMemoryOperation.load_quad_lane },
        .{ "loadRight", ast.VectorMemoryOperation.load_right },
        .{ "storeRight", ast.VectorMemoryOperation.store_right },
        .{ "loadTranspose", ast.VectorMemoryOperation.load_transpose },
        .{ "loadPackedSigned", ast.VectorMemoryOperation.load_packed_signed },
        .{ "loadPackedUnsigned", ast.VectorMemoryOperation.load_packed_unsigned },
        .{ "storePackedSigned", ast.VectorMemoryOperation.store_packed_signed },
        .{ "storePackedUnsigned", ast.VectorMemoryOperation.store_packed_unsigned },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub fn vectorMemoryOperationHasLane(operation: ast.VectorMemoryOperation) bool {
    return switch (operation) {
        .load32, .store32, .load64, .store64, .store_packed_signed, .store_packed_unsigned, .load_quad_lane, .load_transpose => true,
        .load128, .store128, .load_packed_signed, .load_packed_unsigned, .load_right, .store_right => false,
    };
}

pub fn cp0NamedReadRegister(name: []const u8) ?u4 {
    const names = [_]struct { []const u8, u4 }{
        .{ "dmaMemoryAddress", 0 },
        .{ "dmaRdramAddress", 1 },
        .{ "spStatus", 4 },
        .{ "dmaFull", 5 },
        .{ "dmaBusy", 6 },
        .{ "rdpCommandStart", 8 },
        .{ "rdpCommandEnd", 9 },
        .{ "rdpStatus", 11 },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub fn cp0NamedWriteRegister(name: []const u8) ?u4 {
    const names = [_]struct { []const u8, u4 }{
        .{ "setDmaMemoryAddress", 0 },
        .{ "setDmaRdramAddress", 1 },
        .{ "startDmaRead", 2 },
        .{ "startDmaWrite", 3 },
        .{ "setSpStatus", 4 },
        .{ "setRdpCommandStart", 8 },
        .{ "setRdpCommandEnd", 9 },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub fn vectorAccessFromRef(value: ast.ValueRef) !?ast.VectorAccess {
    return switch (value) {
        .ident => |name| .{ .name = name },
        .bit_cast => null,
        .vector_access => |access| access,
        .number => null,
    };
}

const ParsedSwizzle = struct { element: u4, lane: ?u3 = null };

pub fn parseSwizzle(text: []const u8) ?ParsedSwizzle {
    for (swizzles) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
}

/// Element selectors: one lane (`.x`, which also names the lane), one lane
/// broadcast (`.xxxxxxxx`), or a pattern within each half.
const swizzles = [_]struct { []const u8, ParsedSwizzle }{
    .{ "x", .{ .element = 8, .lane = 0 } },         .{ "y", .{ .element = 9, .lane = 1 } },
    .{ "z", .{ .element = 10, .lane = 2 } },        .{ "w", .{ .element = 11, .lane = 3 } },
    .{ "X", .{ .element = 12, .lane = 4 } },        .{ "Y", .{ .element = 13, .lane = 5 } },
    .{ "Z", .{ .element = 14, .lane = 6 } },        .{ "W", .{ .element = 15, .lane = 7 } },
    .{ "xxxxxxxx", .{ .element = 8 } },             .{ "yyyyyyyy", .{ .element = 9 } },
    .{ "zzzzzzzz", .{ .element = 10 } },            .{ "wwwwwwww", .{ .element = 11 } },
    .{ "XXXXXXXX", .{ .element = 12 } },            .{ "YYYYYYYY", .{ .element = 13 } },
    .{ "ZZZZZZZZ", .{ .element = 14 } },            .{ "WWWWWWWW", .{ .element = 15 } },
    .{ "xyzwXYZW", .{ .element = 0 } },             .{ "xxzzXXZZ", .{ .element = 2 } },
    .{ "yywwYYWW", .{ .element = 3 } },             .{ "xxxxXXXX", .{ .element = 4 } },
    .{ "yyyyYYYY", .{ .element = 5 } },             .{ "zzzzZZZZ", .{ .element = 6 } },
    .{ "wwwwWWWW", .{ .element = 7 } },
};

pub fn parseDataTypeName(text: []const u8) ?ast.DataType {
    inline for (std.meta.fields(ast.DataType)) |field| {
        if (std.mem.eql(u8, text, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

/// Decimal or `0x` hexadecimal, with `_` or `'` digit separators.
pub fn parseNumber(tok: token.Token) !i64 {
    var buffer: [64]u8 = undefined;
    const digits = try withoutSeparators(tok.text, &buffer);
    if (std.ascii.startsWithIgnoreCase(digits, "0x")) return std.fmt.parseInt(i64, digits[2..], 16);
    return std.fmt.parseInt(i64, digits, 10);
}

fn withoutSeparators(text: []const u8, buffer: *[64]u8) ![]const u8 {
    if (text.len > buffer.len) return error.NumberTooLong;
    var len: usize = 0;
    for (text) |c| {
        if (c == '\'' or c == '_') continue;
        buffer[len] = c;
        len += 1;
    }
    return buffer[0..len];
}
