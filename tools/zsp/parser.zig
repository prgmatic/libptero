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
    type_symbols: [256]TypeSymbol = undefined,
    type_symbol_count: usize = 0,
    compile_time_members: [256]CompileTimeMember = undefined,
    compile_time_member_count: usize = 0,
    compile_time_types: [64][]const u8 = undefined,
    compile_time_type_count: usize = 0,

    const TypeSymbol = struct {
        name: []const u8,
        data_type: ast.DataType,
        function_type: ?ast.FunctionType = null,
    };

    const ParsedParameters = struct {
        items: []ast.Parameter,
        first_unpinned: ?token.Token,
    };

    const CompileTimeMember = struct {
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
        parser.current = try parser.lexer.next();
        return parser;
    }

    pub fn parse(self: *Parser) ![]ast.Function {
        defer self.packed_structs.deinit(self.allocator);
        defer self.statement_locations.deinit(self.allocator);
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

    pub fn appendFunction(self: *Parser, functions: *std.ArrayList(ast.Function), parsed: ast.Function) !void {
        var function = parsed;
        function.source_locations = try self.statement_locations.toOwnedSlice(self.allocator);
        try functions.append(self.allocator, function);
    }

    pub fn takeImports(self: *Parser) ![]ast.Import {
        return self.imports.toOwnedSlice(self.allocator);
    }

    pub fn parseFunctionDeclaration(self: *Parser) !ast.Function {
        var inline_call = false;
        var export_symbol = false;
        var public = false;
        var external = false;
        var command_indices: std.ArrayList(u8) = .empty;
        errdefer command_indices.deinit(self.allocator);
        while (true) {
            if (self.current.tag == .at) {
                try self.parseRspqNumberAttribute("command", &command_indices);
                continue;
            }
            const prefix = try self.expect(.ident);
            if (std.mem.eql(u8, prefix.text, "export")) {
                export_symbol = true;
                continue;
            }
            if (std.mem.eql(u8, prefix.text, "extern")) {
                external = true;
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

        return self.parseFunction(export_symbol, inline_call, public, external, try command_indices.toOwnedSlice(self.allocator));
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

    pub fn parseFunction(
        self: *Parser,
        export_symbol: bool,
        inline_call: bool,
        public: bool,
        external: bool,
        command_indices: []const u8,
    ) !ast.Function {
        const function_scope = self.type_symbol_count;
        defer self.type_symbol_count = function_scope;
        const name = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        const parsed_parameters = try self.parseParameters(true);
        const parameters = parsed_parameters.items;
        errdefer self.allocator.free(parameters);
        var no_return = false;
        var command_sizes: std.ArrayList(u8) = .empty;
        errdefer command_sizes.deinit(self.allocator);
        var clobber_regs: std.ArrayList(ast.Register) = .empty;
        errdefer clobber_regs.deinit(self.allocator);
        var clobber_vector_regs: std.ArrayList(ast.VectorRegister) = .empty;
        errdefer clobber_vector_regs.deinit(self.allocator);
        var has_clobber_contract = false;
        while (self.current.tag == .ident or self.current.tag == .at) {
            if (self.current.tag == .at) {
                try self.parseRspqNumberAttribute("commandSize", &command_sizes);
                continue;
            }
            const modifier = try self.expect(.ident);
            if (std.mem.eql(u8, modifier.text, "noreturn")) {
                no_return = true;
            } else if (std.mem.eql(u8, modifier.text, "writes")) {
                if (has_clobber_contract) return self.fail(modifier, .duplicate_clobber_contract);
                has_clobber_contract = true;
                _ = try self.expect(.l_paren);
                if (!try self.eat(.r_paren)) while (true) {
                    const register_token = try self.expect(.register);
                    if (parseRegister(register_token)) |reg| {
                        try clobber_regs.append(self.allocator, reg);
                    } else if (parseVectorRegister(register_token)) |reg| {
                        try clobber_vector_regs.append(self.allocator, reg);
                    } else {
                        return self.fail(register_token, .expected_register);
                    }
                    if (try self.eat(.r_paren)) break;
                    _ = try self.expect(.comma);
                };
            } else {
                return self.fail(modifier, .unsupported_function_modifier);
            }
        }
        try self.applyDefaultParameterRegisters(parameters, parsed_parameters.first_unpinned);
        if (external) {
            if (inline_call or export_symbol) return error.InvalidExternalFunction;
            _ = try self.expect(.semicolon);
            return .{
                .name = name.text,
                .source_name = name.text,
                .export_symbol = false,
                .public = public,
                .inline_call = false,
                .external = true,
                .no_return = no_return,
                .command_indices = command_indices,
                .command_sizes = try command_sizes.toOwnedSlice(self.allocator),
                .has_clobber_contract = has_clobber_contract,
                .clobber_regs = try clobber_regs.toOwnedSlice(self.allocator),
                .clobber_vector_regs = try clobber_vector_regs.toOwnedSlice(self.allocator),
                .parameters = parameters,
                .statements = &.{},
            };
        }
        _ = try self.expect(.l_brace);

        const statements = try self.parseBlockStatements();

        return .{
            .name = name.text,
            .source_name = name.text,
            .export_symbol = export_symbol,
            .public = public,
            .inline_call = inline_call,
            .external = false,
            .no_return = no_return,
            .command_indices = command_indices,
            .command_sizes = try command_sizes.toOwnedSlice(self.allocator),
            .has_clobber_contract = has_clobber_contract,
            .clobber_regs = try clobber_regs.toOwnedSlice(self.allocator),
            .clobber_vector_regs = try clobber_vector_regs.toOwnedSlice(self.allocator),
            .parameters = parameters,
            .statements = statements,
        };
    }

    pub fn parseImport(self: *Parser) !void {
        _ = try self.expect(.ident);
        const name = try self.expect(.ident);
        _ = try self.expect(.equal);
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

    pub fn parseCompileTimeType(self: *Parser) !void {
        const kind = try self.expect(.ident);
        const is_flags = std.mem.eql(u8, kind.text, "flags");
        const type_name = try self.expect(.ident);
        for (self.compile_time_types[0..self.compile_time_type_count]) |existing| {
            if (std.mem.eql(u8, existing, type_name.text)) {
                return self.fail(type_name, .duplicate_compile_time_type);
            }
        }
        if (self.compile_time_type_count >= self.compile_time_types.len) return error.TooManyCompileTimeTypes;
        self.compile_time_types[self.compile_time_type_count] = type_name.text;
        self.compile_time_type_count += 1;
        _ = try self.expect(.colon);
        const data_type = try self.parseDataType(try self.expect(.ident));
        if (isVectorType(data_type) or (is_flags and isSignedType(data_type))) {
            return self.fail(type_name, .expected_unsigned_scalar_type);
        }
        _ = try self.expect(.l_brace);
        var next_value: i64 = if (is_flags) 1 else 0;
        while (!try self.eat(.r_brace)) {
            const member = try self.expect(.ident);
            var value = next_value;
            if (try self.eat(.equal)) {
                const parsed = try self.parseValueRef();
                value = switch (parsed) {
                    .number => |number| number,
                    else => return self.fail(member, .expected_data_literal),
                };
            }
            if (!literalFitsType(value, data_type)) return self.fail(member, .invalid_number);
            _ = try self.expect(.semicolon);
            for (self.compile_time_members[0..self.compile_time_member_count]) |existing| {
                if (std.mem.eql(u8, existing.type_name, type_name.text) and
                    std.mem.eql(u8, existing.member_name, member.text))
                {
                    return self.fail(member, .duplicate_compile_time_member);
                }
            }
            if (self.compile_time_member_count >= self.compile_time_members.len) {
                return error.TooManyCompileTimeMembers;
            }
            self.compile_time_members[self.compile_time_member_count] = .{
                .type_name = type_name.text,
                .member_name = member.text,
                .data_type = data_type,
                .value = value,
            };
            self.compile_time_member_count += 1;
            next_value = if (is_flags)
                std.math.mul(i64, value, 2) catch return self.fail(member, .invalid_number)
            else
                std.math.add(i64, value, 1) catch return self.fail(member, .invalid_number);
        }
    }

    pub fn lookupCompileTimeMember(
        self: *const Parser,
        type_name: []const u8,
        member_name: []const u8,
    ) ?CompileTimeMember {
        for (self.compile_time_members[0..self.compile_time_member_count]) |member| {
            if (std.mem.eql(u8, member.type_name, type_name) and
                std.mem.eql(u8, member.member_name, member_name)) return member;
        }
        return null;
    }

    pub fn applyDefaultParameterRegisters(
        self: *Parser,
        parameters: []ast.Parameter,
        first_unpinned: ?token.Token,
    ) !void {
        const argument_registers = [_]ast.Register{ .a0, .a1, .a2, .a3 };
        for (parameters, 0..) |*parameter, index| {
            if (parameter.reg != null or parameter.vector_reg != null) continue;
            if (isVectorType(parameter.data_type) or index >= argument_registers.len) {
                return self.fail(first_unpinned.?, .expected_fixed_register_parameter);
            }
            parameter.reg = argument_registers[index];
        }
    }

    pub fn parseParameters(self: *Parser, allow_unpinned: bool) !ParsedParameters {
        var parameters: std.ArrayList(ast.Parameter) = .empty;
        errdefer parameters.deinit(self.allocator);
        var first_unpinned: ?token.Token = null;
        if (try self.eat(.r_paren)) return .{
            .items = try parameters.toOwnedSlice(self.allocator),
            .first_unpinned = null,
        };

        while (true) {
            var register_token: ?token.Token = null;
            const name = if (self.current.tag == .ident and
                std.mem.eql(u8, self.current.text, "reg"))
            blk: {
                _ = try self.expect(.ident);
                _ = try self.expect(.l_paren);
                register_token = try self.expect(.register);
                _ = try self.expect(.r_paren);
                break :blk try self.expect(.ident);
            } else blk: {
                const unpinned = try self.expect(.ident);
                if (!allow_unpinned) return self.fail(unpinned, .expected_fixed_register_parameter);
                if (first_unpinned == null) first_unpinned = unpinned;
                break :blk unpinned;
            };
            _ = try self.expect(.colon);
            const data_type = try self.parseDataType(try self.expect(.ident));
            const reg = if (register_token) |fixed|
                if (!isVectorType(data_type))
                    parseRegister(fixed) orelse return self.fail(fixed, .expected_scalar_register)
                else
                    null
            else
                null;
            const vector_reg = if (register_token) |fixed|
                if (isVectorType(data_type))
                    parseVectorRegister(fixed) orelse return self.fail(fixed, .expected_vector_register)
                else
                    null
            else
                null;
            try parameters.append(self.allocator, .{
                .name = name.text,
                .data_type = data_type,
                .reg = reg,
                .vector_reg = vector_reg,
            });
            try self.addTypeSymbol(name.text, data_type);

            if (try self.eat(.r_paren)) break;
            _ = try self.expect(.comma);
            if (try self.eat(.r_paren)) break;
        }
        return .{
            .items = try parameters.toOwnedSlice(self.allocator),
            .first_unpinned = first_unpinned,
        };
    }

    pub fn parseTopLevelStatements(self: *Parser) anyerror![]ast.Statement {
        var statements: std.ArrayList(ast.Statement) = .empty;
        var locations: std.ArrayList(ast.SourceLocation) = .empty;
        defer locations.deinit(self.allocator);
        while (self.current.tag != .eof and !self.isFunctionDeclarationStart() and
            !self.isCompileTimeTypeStart() and !self.isImportStart())
        {
            try locations.append(self.allocator, .{ .line = self.current.line, .column = self.current.column });
            try statements.append(self.allocator, try self.parseStatement());
        }
        return self.finishStatements(&statements, locations.items);
    }

    pub fn parseBlockStatements(self: *Parser) anyerror![]ast.Statement {
        const scope = self.type_symbol_count;
        defer self.type_symbol_count = scope;
        var statements: std.ArrayList(ast.Statement) = .empty;
        var locations: std.ArrayList(ast.SourceLocation) = .empty;
        defer locations.deinit(self.allocator);
        while (!try self.eat(.r_brace)) {
            try locations.append(self.allocator, .{ .line = self.current.line, .column = self.current.column });
            try statements.append(self.allocator, try self.parseStatement());
        }
        return self.finishStatements(&statements, locations.items);
    }

    pub fn finishStatements(self: *Parser, statements: *std.ArrayList(ast.Statement), locations: []const ast.SourceLocation) ![]ast.Statement {
        const result = try statements.toOwnedSlice(self.allocator);
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

    pub fn parsePackedStructDecl(self: *Parser) !ast.PackedStructDecl {
        const struct_keyword = try self.expect(.ident);
        if (!std.mem.eql(u8, struct_keyword.text, "struct")) {
            return self.fail(struct_keyword, .expected_struct_declaration);
        }
        const name = try self.expect(.ident);
        _ = try self.expect(.l_brace);
        var fields: std.ArrayList(ast.PackedStructField) = .empty;
        errdefer fields.deinit(self.allocator);
        while (!try self.eat(.r_brace)) {
            const field_name = try self.expect(.ident);
            _ = try self.expect(.colon);
            const data_type = try self.parseDataType(try self.expect(.ident));
            if (isVectorType(data_type)) return self.fail(field_name, .expected_scalar_data_type);
            _ = try self.expect(.semicolon);
            try fields.append(self.allocator, .{
                .name = field_name.text,
                .data_type = data_type,
            });
        }
        const declaration: ast.PackedStructDecl = .{
            .name = name.text,
            .fields = try fields.toOwnedSlice(self.allocator),
        };
        errdefer self.allocator.free(declaration.fields);
        try self.packed_structs.append(self.allocator, declaration);
        return declaration;
    }

    const MemoryType = struct {
        data_type: ast.DataType,
        offset: i64 = 0,
        half_vector: bool = false,
        quarter_vector: bool = false,
    };

    pub fn parseMemoryType(self: *Parser) !MemoryType {
        const type_name = try self.expect(.ident);
        if (try self.eat(.dot)) {
            const field_name = try self.expect(.ident);
            var offset: i64 = 0;
            for (self.packed_structs.items) |declaration| {
                if (!std.mem.eql(u8, declaration.name, type_name.text)) continue;
                for (declaration.fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name.text)) {
                        return .{ .data_type = field.data_type, .offset = offset };
                    }
                    offset += scalarTypeSize(field.data_type);
                }
                return self.fail(field_name, .unknown_packed_struct_field);
            }
            return self.fail(type_name, .unknown_packed_struct);
        }
        const half_vector = std.mem.eql(u8, type_name.text, "vec64");
        const quarter_vector = std.mem.eql(u8, type_name.text, "vec32lane");
        return .{
            .data_type = if (half_vector or quarter_vector)
                .vec16
            else
                try self.parseDataType(type_name),
            .half_vector = half_vector,
            .quarter_vector = quarter_vector,
        };
    }

    pub fn parseStorageBlock(self: *Parser, require_initialized: bool, allow_initialized: bool) ![]const ast.DataDecl {
        _ = try self.expect(.l_brace);
        var declarations: std.ArrayList(ast.DataDecl) = .empty;
        errdefer {
            for (declarations.items) |declaration| self.allocator.free(declaration.values);
            declarations.deinit(self.allocator);
        }

        while (!try self.eat(.r_brace)) {
            var public = false;
            var external = false;
            if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "pub")) {
                public = true;
                _ = try self.expect(.ident);
            } else if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "extern")) {
                external = true;
                _ = try self.expect(.ident);
            }
            const name = try self.expect(.ident);
            _ = try self.expect(.colon);
            const is_array = try self.eat(.l_bracket);
            const array_len_value: i64 = if (is_array) blk: {
                const array_len_token = try self.expect(.number);
                const value = try self.parseNumberValue(array_len_token);
                if (value <= 0 or value > std.math.maxInt(usize)) {
                    return self.fail(array_len_token, .invalid_array_length);
                }
                _ = try self.expect(.r_bracket);
                break :blk value;
            } else 1;
            const type_token = try self.expect(.ident);
            const storage_type: ast.DataStorageType = if (parseDataTypeName(type_token.text)) |data_type| blk: {
                if (isVectorType(data_type)) return self.fail(name, .expected_scalar_data_type);
                break :blk .{ .scalar = data_type };
            } else .{ .packed_struct = type_token.text };
            var values: std.ArrayList(i64) = .empty;
            errdefer values.deinit(self.allocator);
            const initialized = allow_initialized and self.current.tag == .equal;
            if (require_initialized and !initialized) _ = try self.expect(.equal);
            if (initialized) {
                if (external) return self.fail(name, .external_data_initializer);
                _ = try self.expect(.equal);
                if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "undefined")) {
                    return self.fail(self.current, .undefined_data_initializer);
                }
                const aggregate_initializer = is_array or storage_type == .packed_struct;
                if (!aggregate_initializer) {
                    const value = try self.parseValueRef();
                    switch (value) {
                        .number => |number| try values.append(self.allocator, number),
                        else => return self.fail(self.current, .expected_data_literal),
                    }
                } else {
                    _ = try self.eat(.dot);
                    _ = try self.expect(.l_brace);
                    if (!try self.eat(.r_brace)) {
                        while (true) {
                            const value = try self.parseValueRef();
                            switch (value) {
                                .number => |number| try values.append(self.allocator, number),
                                else => return self.fail(self.current, .expected_data_literal),
                            }
                            if (try self.eat(.r_brace)) break;
                            _ = try self.expect(.comma);
                            if (try self.eat(.r_brace)) break;
                        }
                    }
                }
            }
            if (initialized and is_array and storage_type == .scalar and values.items.len != array_len_value) {
                return self.fail(name, .incorrect_array_initializer_count);
            }
            _ = try self.expect(.semicolon);
            try declarations.append(self.allocator, .{
                .name = name.text,
                .storage_type = storage_type,
                .array_len = @intCast(array_len_value),
                .is_array = is_array,
                .values = try values.toOwnedSlice(self.allocator),
                .initialized = initialized,
                .public = public,
                .external = external,
            });
        }
        return declarations.toOwnedSlice(self.allocator);
    }

    pub fn parseCallArguments(self: *Parser) ![]const ast.ValueRef {
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

    pub fn parseBuiltinStatement(self: *Parser) !ast.Statement {
        const name = try self.expect(.ident);
        _ = try self.expect(.l_paren);

        return self.fail(name, .unsupported_builtin);
    }

    pub fn parseRspStatement(self: *Parser, operation: token.Token) !ast.Statement {
        _ = try self.expect(.l_paren);
        if (std.mem.eql(u8, operation.text, "halt")) {
            var code: i64 = 0;
            if (self.current.tag != .r_paren) code = try self.parseNumberValue(try self.expect(.number));
            if (code < 0 or code > 0xfffff) return error.InvalidBreakCode;
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .builtin = .{ .breakpoint = @intCast(code) } };
        }
        if (std.mem.eql(u8, operation.text, "nop")) {
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .builtin = .nop };
        }
        return self.fail(operation, .unsupported_builtin);
    }

    pub fn parseCp0Statement(self: *Parser, operation_name: token.Token) !ast.Statement {
        _ = try self.expect(.l_paren);
        if (std.mem.eql(u8, operation_name.text, "readRegister") or
            std.mem.eql(u8, operation_name.text, "writeRegister"))
        {
            const register_token = try self.expect(.number);
            const register = try self.parseNumberValue(register_token);
            if (register < 0 or register > 15) return self.fail(register_token, .invalid_hardware_register);
            _ = try self.expect(.comma);
            const scalar_token = try self.expect(.register);
            const scalar_register = parseRegister(scalar_token) orelse
                return self.fail(scalar_token, .expected_scalar_register);
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            if (std.mem.eql(u8, operation_name.text, "readRegister")) {
                return .{ .builtin = .{ .hardware_read_register = .{
                    .hardware_register = @intCast(register),
                    .destination = scalar_register,
                } } };
            }
            return .{ .builtin = .{ .hardware_write_register = .{
                .hardware_register = @intCast(register),
                .source = scalar_register,
            } } };
        }
        if (std.mem.eql(u8, operation_name.text, "write")) {
            const register_token = try self.expect(.number);
            const register = try self.parseNumberValue(register_token);
            if (register < 0 or register > 15) return self.fail(register_token, .invalid_hardware_register);
            _ = try self.expect(.comma);
            const value = try self.parseValueRef();
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .builtin = .{ .hardware_write = .{
                .operation = .{ .cp0 = @intCast(register) },
                .value = value,
            } } };
        }
        if (cp0NamedWriteRegister(operation_name.text)) |register| {
            const value = try self.parseValueRef();
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .builtin = .{ .hardware_write = .{
                .operation = .{ .cp0 = register },
                .value = value,
                .requires_dmem = register == 0,
            } } };
        }
        return self.fail(operation_name, .unsupported_builtin);
    }

    pub fn parseVectorStatement(self: *Parser, operation_name: token.Token) !ast.Statement {
        _ = try self.expect(.l_paren);
        if (vectorControlRegisterForOperation(operation_name.text, "set")) |register| {
            const value = try self.parseValueRef();
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .builtin = .{ .write_vector_control = .{
                .register = register,
                .value = value,
            } } };
        }
        const operation = vectorMemoryOperationForBuiltin(operation_name.text) orelse
            return self.fail(operation_name, .unsupported_builtin);
        const vector_token = self.current;
        const vector = try vectorAccessFromRef(try self.parseValueRef()) orelse
            return self.fail(vector_token, .expected_vector_operand);
        _ = try self.expect(.comma);
        var lane: u3 = 0;
        if (vectorMemoryOperationHasLane(operation)) {
            const lane_token = try self.expect(.number);
            const lane_value = try self.parseNumberValue(lane_token);
            if (lane_value < 0 or lane_value > 7) return self.fail(lane_token, .invalid_vector_lane);
            lane = @intCast(lane_value);
            _ = try self.expect(.comma);
        }
        const address = try self.parseValueRef();
        var offset: i64 = 0;
        if (try self.eat(.comma)) offset = try self.parseLiteralOffset();
        _ = try self.expect(.r_paren);
        _ = try self.expect(.semicolon);
        return .{ .builtin = .{ .vector_memory = .{
            .operation = operation,
            .vector = vector,
            .lane = lane,
            .address = address,
            .offset = offset,
        } } };
    }

    pub fn parseConstStatement(self: *Parser) !ast.Statement {
        const name = try self.expect(.ident);
        if (try self.eat(.equal)) {
            _ = try self.expect(.at);
            const namespace = try self.expect(.ident);
            if (!std.mem.eql(u8, namespace.text, "rspq")) return self.fail(namespace, .unsupported_builtin);
            _ = try self.expect(.dot);
            const builtin = try self.expect(.ident);
            if (!std.mem.eql(u8, builtin.text, "commandTable")) return self.fail(builtin, .unsupported_builtin);
            _ = try self.expect(.l_paren);
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .command_table_decl = name.text };
        }
        _ = try self.expect(.colon);
        const data_type_token = try self.expect(.ident);
        const data_type = try self.parseDataType(data_type_token);

        _ = try self.expect(.equal);
        const value = valueFromRef(try self.parseValueRef());
        _ = try self.expect(.semicolon);
        try self.addTypeSymbol(name.text, data_type);

        return .{ .var_decl = .{
            .is_const = true,
            .data_type = data_type,
            .reg = null,
            .name = name.text,
            .value = value,
        } };
    }

    pub fn parseRegDecl(self: *Parser) !ast.VarDecl {
        var register_token: ?token.Token = null;
        if (try self.eat(.l_paren)) {
            register_token = try self.expect(.register);
            _ = try self.expect(.r_paren);
        }

        const name = try self.expect(.ident);
        var explicit_data_type: ?ast.DataType = null;
        var function_type: ?ast.FunctionType = null;
        if (try self.eat(.colon)) {
            const type_name = try self.expect(.ident);
            if (std.mem.eql(u8, type_name.text, "fn")) {
                _ = try self.expect(.l_paren);
                var parsed_type = ast.FunctionType{};
                if (!try self.eat(.r_paren)) while (true) {
                    if (parsed_type.parameter_count >= parsed_type.parameters.len) {
                        return error.TooManyParameters;
                    }
                    var parameter_register_token: ?token.Token = null;
                    if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "reg")) {
                        _ = try self.expect(.ident);
                        _ = try self.expect(.l_paren);
                        parameter_register_token = try self.expect(.register);
                        _ = try self.expect(.r_paren);
                    }
                    const parameter_type = try self.parseDataType(try self.expect(.ident));
                    var parameter = ast.FunctionParameterType{ .data_type = parameter_type };
                    if (parameter_register_token) |reg_token| {
                        if (isVectorType(parameter_type)) {
                            parameter.vector_reg = parseVectorRegister(reg_token) orelse
                                return self.fail(reg_token, .expected_vector_register);
                        } else {
                            parameter.reg = parseRegister(reg_token) orelse
                                return self.fail(reg_token, .expected_scalar_register);
                        }
                    } else if (!isVectorType(parameter_type) and
                        parsed_type.parameter_count < 4)
                    {
                        parameter.reg = ([_]ast.Register{ .a0, .a1, .a2, .a3 })[parsed_type.parameter_count];
                    } else {
                        return self.fail(type_name, .expected_fixed_register_parameter);
                    }
                    parsed_type.parameters[parsed_type.parameter_count] = parameter;
                    parsed_type.parameter_count += 1;
                    if (try self.eat(.r_paren)) break;
                    _ = try self.expect(.comma);
                };
                function_type = parsed_type;
                explicit_data_type = .u32;
            } else {
                explicit_data_type = try self.parseDataType(type_name);
            }
        }
        var value: ?ast.Value = null;
        var allow_undefined_read = false;
        if (try self.eat(.equal)) {
            if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "undefined")) {
                _ = try self.expect(.ident);
                allow_undefined_read = true;
            } else {
                value = try self.parseValue();
            }
        }
        _ = try self.expect(.semicolon);
        const data_type = explicit_data_type orelse if (value) |initial_value| switch (initial_value) {
            .ident => |source_name| blk: {
                const source = self.lookupTypeSymbolInfo(source_name) orelse
                    return self.fail(name, .expected_data_type);
                function_type = source.function_type;
                break :blk source.data_type;
            },
            .load => |load| load.data_type,
            .number => |number| if (number < 0)
                @as(ast.DataType, .i32)
            else
                @as(ast.DataType, .u32),
            .accumulator_read => .vec16,
            .hardware_read => |read| if (read.returns_dmem)
                @as(ast.DataType, .dmem)
            else
                @as(ast.DataType, .u32),
            .vector_control_read, .scalar_comparison, .signed_less_than => .u32,
            else => return self.fail(name, .expected_data_type),
        } else return self.fail(name, .expected_data_type);
        var reg: ?ast.Register = null;
        var vector_reg: ?ast.VectorRegister = null;
        if (register_token) |reg_token| {
            if (isVectorType(data_type)) {
                vector_reg = parseVectorRegister(reg_token) orelse
                    return self.fail(reg_token, .expected_vector_register);
            } else {
                reg = parseRegister(reg_token) orelse
                    return self.fail(reg_token, .expected_scalar_register);
            }
        }

        try self.addTypeSymbolWithFunctionType(name.text, data_type, function_type);
        return .{
            .is_const = false,
            .allow_undefined_read = allow_undefined_read,
            .data_type = data_type,
            .reg = reg,
            .vector_reg = vector_reg,
            .function_type = function_type,
            .name = name.text,
            .value = value,
        };
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
        if (self.type_symbol_count >= self.type_symbols.len) return error.TooManySymbols;
        self.type_symbols[self.type_symbol_count] = .{
            .name = name,
            .data_type = data_type,
            .function_type = function_type,
        };
        self.type_symbol_count += 1;
    }

    pub fn lookupTypeSymbolInfo(self: *const Parser, name: []const u8) ?TypeSymbol {
        var index = self.type_symbol_count;
        while (index > 0) {
            index -= 1;
            const symbol = self.type_symbols[index];
            if (std.mem.eql(u8, symbol.name, name)) return symbol;
        }
        return null;
    }

    pub const parseValue = @import("parse_values.zig").parseValue;
    pub const parseNamedValue = @import("parse_values.zig").parseNamedValue;
    pub const parseVectorOrReferenceValue = @import("parse_values.zig").parseVectorOrReferenceValue;
    pub const parseScalarMaterialization = @import("parse_values.zig").parseScalarMaterialization;
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
        self.current = try self.lexer.next();
        return true;
    }

    pub fn isFunctionDeclarationStart(self: *const Parser) bool {
        if (self.current.tag == .at) {
            var lexer = self.lexer;
            const namespace = lexer.next() catch return false;
            const dot = lexer.next() catch return false;
            const attribute = lexer.next() catch return false;
            return namespace.tag == .ident and std.mem.eql(u8, namespace.text, "rspq") and
                dot.tag == .dot and attribute.tag == .ident and
                std.mem.eql(u8, attribute.text, "command");
        }
        if (self.current.tag != .ident) return false;
        return std.mem.eql(u8, self.current.text, "export") or
            std.mem.eql(u8, self.current.text, "extern") or
            std.mem.eql(u8, self.current.text, "inline") or
            std.mem.eql(u8, self.current.text, "pub") or
            std.mem.eql(u8, self.current.text, "fn");
    }

    pub fn parseRspqNumberAttribute(
        self: *Parser,
        expected_name: []const u8,
        values: *std.ArrayList(u8),
    ) !void {
        _ = try self.expect(.at);
        const namespace = try self.expect(.ident);
        if (!std.mem.eql(u8, namespace.text, "rspq")) return self.fail(namespace, .unsupported_builtin);
        _ = try self.expect(.dot);
        const attribute = try self.expect(.ident);
        if (!std.mem.eql(u8, attribute.text, expected_name)) return self.fail(attribute, .unsupported_builtin);
        _ = try self.expect(.l_paren);
        while (true) {
            const value_token = try self.expect(.number);
            const value = try self.parseNumberValue(value_token);
            const maximum: i64 = if (std.mem.eql(u8, expected_name, "command")) 239 else 255;
            if (value < 0 or value > maximum) {
                if (maximum == 239) return self.fail(value_token, .invalid_command_index);
                return error.InvalidCommandSize;
            }
            try values.append(self.allocator, @intCast(value));
            if (!try self.eat(.comma)) break;
        }
        _ = try self.expect(.r_paren);
    }

    pub fn isCompileTimeTypeStart(self: *const Parser) bool {
        return self.current.tag == .ident and
            (std.mem.eql(u8, self.current.text, "enum") or
                std.mem.eql(u8, self.current.text, "flags"));
    }

    pub fn isImportStart(self: *const Parser) bool {
        if (self.current.tag != .ident or !std.mem.eql(u8, self.current.text, "const")) return false;
        var lexer = self.lexer;
        _ = lexer.next() catch return false;
        const separator = lexer.next() catch return false;
        const import_name = lexer.next() catch return false;
        return separator.tag == .equal and import_name.tag == .ident and
            std.mem.eql(u8, import_name.text, "import");
    }

    pub fn expect(self: *Parser, tag: token.Tag) !token.Token {
        const tok = self.current;
        if (tok.tag != tag) return self.failExpected(tok, tag);
        self.current = try self.lexer.next();
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

pub fn binaryPrecedence(tag: token.Tag) ?u4 {
    return switch (tag) {
        .pipe, .nor => 1,
        .caret => 2,
        .ampersand => 3,
        .shift_left, .shift_right, .logical_shift_right => 4,
        .plus, .plus_percent, .minus, .minus_percent => 5,
        .star, .slash => 6,
        else => null,
    };
}

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
    return switch (data_type) {
        .u8 => value >= 0 and value <= std.math.maxInt(u8),
        .u16 => value >= 0 and value <= std.math.maxInt(u16),
        .u32 => value >= 0 and value <= std.math.maxInt(u32),
        .dmem => value >= 0 and value <= 4096,
        .i8 => value >= std.math.minInt(i8) and value <= std.math.maxInt(i8),
        .i16 => value >= std.math.minInt(i16) and value <= std.math.maxInt(i16),
        .i32 => value >= std.math.minInt(i32) and value <= std.math.maxInt(i32),
        .vec16, .vec32 => false,
    };
}

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
    return op == .vrcp or op == .vrcpl or op == .vrcph or
        op == .vrsq or op == .vrsql or op == .vrsqh or op == .vmov;
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
        .{ "load16", ast.VectorMemoryOperation.load16 },
        .{ "store16", ast.VectorMemoryOperation.store16 },
        .{ "load32", ast.VectorMemoryOperation.load32 },
        .{ "store32", ast.VectorMemoryOperation.store32 },
        .{ "load64", ast.VectorMemoryOperation.load64 },
        .{ "store64", ast.VectorMemoryOperation.store64 },
        .{ "load128", ast.VectorMemoryOperation.load128 },
        .{ "store128", ast.VectorMemoryOperation.store128 },
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
        .load16, .store16, .load32, .store32, .load64, .store64, .store_packed_signed, .store_packed_unsigned, .load_quad_lane, .load_transpose => true,
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
    const names = [_][]const u8{
        "x",        "y",        "z",        "w",        "X",        "Y",        "Z",        "W",
        "xxxxxxxx", "yyyyyyyy", "zzzzzzzz", "wwwwwwww", "XXXXXXXX", "YYYYYYYY", "ZZZZZZZZ", "WWWWWWWW",
    };
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, text, name)) {
            const lane: u3 = @intCast(index % 8);
            return .{ .element = @as(u4, lane) + 8, .lane = if (text.len == 1) lane else null };
        }
    }
    if (std.mem.eql(u8, text, "xyzwXYZW")) return .{ .element = 0 };
    if (std.mem.eql(u8, text, "xxzzXXZZ")) return .{ .element = 2 };
    if (std.mem.eql(u8, text, "yywwYYWW")) return .{ .element = 3 };
    if (std.mem.eql(u8, text, "xxxxXXXX")) return .{ .element = 4 };
    if (std.mem.eql(u8, text, "yyyyYYYY")) return .{ .element = 5 };
    if (std.mem.eql(u8, text, "zzzzZZZZ")) return .{ .element = 6 };
    if (std.mem.eql(u8, text, "wwwwWWWW")) return .{ .element = 7 };
    return null;
}

pub fn parseDataTypeName(text: []const u8) ?ast.DataType {
    inline for (std.meta.fields(ast.DataType)) |field| {
        if (std.mem.eql(u8, text, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

pub fn parseNumber(tok: token.Token) !i64 {
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
