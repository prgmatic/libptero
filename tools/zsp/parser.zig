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
        var functions: std.ArrayList(ast.Function) = .empty;
        while (self.current.tag != .eof) {
            if (self.isCompileTimeTypeStart()) {
                try self.parseCompileTimeType();
            } else if (self.isImportStart()) {
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

    fn parseTopLevelBlock(self: *Parser) !ast.Function {
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

    fn parseFunction(
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

    fn parseImport(self: *Parser) !void {
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

    fn parseCompileTimeType(self: *Parser) !void {
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

    fn lookupCompileTimeMember(
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

    fn applyDefaultParameterRegisters(
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

    fn parseParameters(self: *Parser, allow_unpinned: bool) !ParsedParameters {
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

    fn parseTopLevelStatements(self: *Parser) anyerror![]ast.Statement {
        var statements: std.ArrayList(ast.Statement) = .empty;
        while (self.current.tag != .eof and !self.isFunctionDeclarationStart() and
            !self.isCompileTimeTypeStart() and !self.isImportStart())
        {
            try statements.append(self.allocator, try self.parseStatement());
        }
        return statements.toOwnedSlice(self.allocator);
    }

    fn parseBlockStatements(self: *Parser) anyerror![]ast.Statement {
        const scope = self.type_symbol_count;
        defer self.type_symbol_count = scope;
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

        if (std.mem.eql(u8, first.text, "rsp") and self.current.tag == .dot) {
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

        if ((std.mem.eql(u8, first.text, "dma") or std.mem.eql(u8, first.text, "rdp")) and
            self.current.tag == .dot)
        {
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

        if (std.mem.eql(u8, first.text, "packed")) {
            return .{ .packed_struct_decl = try self.parsePackedStructDecl() };
        }

        if (std.mem.eql(u8, first.text, "data")) {
            return .{ .data_block = try self.parseStorageBlock(true) };
        }

        if (std.mem.eql(u8, first.text, "bss")) {
            return .{ .bss_block = try self.parseStorageBlock(false) };
        }

        if (std.mem.eql(u8, first.text, "state")) {
            return .{ .state_block = try self.parseStorageBlock(false) };
        }

        if (std.mem.eql(u8, first.text, "exact")) {
            _ = try self.expect(.l_brace);
            return .{ .ordered_block = try self.parseBlockStatements() };
        }

        if (std.mem.eql(u8, first.text, "tail")) {
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

        if (std.mem.eql(u8, first.text, "return")) {
            return .{ .builtin = .{ .return_from_function = try self.parseOptionalDelaySlot() } };
        }

        if (std.mem.eql(u8, first.text, "jump")) {
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

        if (std.mem.eql(u8, first.text, "do")) return self.parseDoWhileStatement(null);

        if (std.mem.eql(u8, first.text, "break") or std.mem.eql(u8, first.text, "continue")) {
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

        if (try self.eat(.colon)) {
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

        if (std.mem.eql(u8, first.text, "if")) {
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

        if (std.mem.eql(u8, first.text, "goto")) {
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

        if (std.mem.eql(u8, first.text, "store")) {
            _ = try self.expect(.l_paren);
            const memory_type = try self.parseMemoryType();
            _ = try self.expect(.comma);
            var address = try self.parseValueRef();
            var label_offset: ?[]const u8 = null;
            if (try self.eat(.plus)) {
                label_offset = switch (address) {
                    .ident => |name| name,
                    else => return self.fail(first, .unexpected_token),
                };
                address = try self.parseValueRef();
            }
            _ = try self.expect(.comma);
            const value = try self.parseValueRef();
            var offset: i64 = memory_type.offset;
            if (try self.eat(.comma)) {
                if (self.current.tag == .ident and !std.mem.eql(u8, self.current.text, "offsetOf")) {
                    if (label_offset != null) return self.fail(self.current, .unexpected_token);
                    label_offset = (try self.expect(.ident)).text;
                    if (try self.eat(.comma)) offset += try self.parseLiteralOffset();
                } else {
                    offset += try self.parseLiteralOffset();
                }
            }
            _ = try self.expect(.r_paren);
            _ = try self.expect(.semicolon);
            return .{ .store = .{
                .data_type = memory_type.data_type,
                .half_vector = memory_type.half_vector,
                .quarter_vector = memory_type.quarter_vector,
                .address = address,
                .value = value,
                .offset = offset,
                .label_offset = label_offset,
            } };
        }

        if (std.mem.eql(u8, first.text, "const")) {
            return self.parseConstStatement();
        }

        if (std.mem.eql(u8, first.text, "var")) {
            return self.fail(first, .var_keyword_removed);
        }

        if (std.mem.eql(u8, first.text, "reg")) {
            return .{ .var_decl = try self.parseRegDecl() };
        }

        if (std.mem.eql(u8, first.text, "reserved")) {
            const reg_keyword = try self.expect(.ident);
            if (!std.mem.eql(u8, reg_keyword.text, "reg")) return self.fail(reg_keyword, .unexpected_token);
            var declaration = try self.parseRegDecl();
            declaration.is_reserved = true;
            return .{ .var_decl = declaration };
        }

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

    fn parseDoWhileStatement(self: *Parser, label: ?[]const u8) !ast.Statement {
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

    fn parseOptionalDelaySlot(self: *Parser) !?[]ast.Statement {
        if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "slot")) {
            _ = try self.expect(.ident);
            _ = try self.expect(.l_brace);
            return try self.parseBlockStatements();
        }
        _ = try self.expect(.semicolon);
        return null;
    }

    fn parsePackedStructDecl(self: *Parser) !ast.PackedStructDecl {
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

    fn parseMemoryType(self: *Parser) !MemoryType {
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

    fn parseStorageBlock(self: *Parser, initialized: bool) ![]const ast.DataDecl {
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

        return self.fail(name, .unsupported_builtin);
    }

    fn parseRspStatement(self: *Parser, operation: token.Token) !ast.Statement {
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

    fn parseCp0Statement(self: *Parser, operation_name: token.Token) !ast.Statement {
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

    fn parseVectorStatement(self: *Parser, operation_name: token.Token) !ast.Statement {
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

    fn parseConstStatement(self: *Parser) !ast.Statement {
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

    fn parseRegDecl(self: *Parser) !ast.VarDecl {
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

    fn addTypeSymbol(self: *Parser, name: []const u8, data_type: ast.DataType) !void {
        return self.addTypeSymbolWithFunctionType(name, data_type, null);
    }

    fn addTypeSymbolWithFunctionType(
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

    fn lookupTypeSymbol(self: *const Parser, name: []const u8) ?ast.DataType {
        return if (self.lookupTypeSymbolInfo(name)) |symbol| symbol.data_type else null;
    }

    fn lookupTypeSymbolInfo(self: *const Parser, name: []const u8) ?TypeSymbol {
        var index = self.type_symbol_count;
        while (index > 0) {
            index -= 1;
            const symbol = self.type_symbols[index];
            if (std.mem.eql(u8, symbol.name, name)) return symbol;
        }
        return null;
    }

    fn parseValue(self: *Parser) !ast.Value {
        if (try self.eat(.ampersand)) {
            return .{ .function_address = try self.parseFunctionReference() };
        }
        var value_lookahead = self.lexer;
        const value_next = try value_lookahead.next();
        if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "rsp") and value_next.tag == .dot) {
            _ = try self.expect(.ident);
            _ = try self.expect(.dot);
            const facility = try self.expect(.ident);
            _ = try self.expect(.dot);
            const operation = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            if (std.mem.eql(u8, facility.text, "vector")) {
                const register = vectorControlRegisterForOperation(operation.text, "get") orelse
                    return self.fail(operation, .unsupported_builtin);
                _ = try self.expect(.r_paren);
                return .{ .vector_control_read = register };
            }
            if (std.mem.eql(u8, facility.text, "cp0")) {
                if (cp0NamedReadRegister(operation.text)) |register| {
                    _ = try self.expect(.r_paren);
                    return .{ .hardware_read = .{
                        .register = register,
                        .returns_dmem = register == 0,
                    } };
                }
                if (!std.mem.eql(u8, operation.text, "read")) return self.fail(operation, .unsupported_builtin);
                const register_token = try self.expect(.number);
                const register = try self.parseNumberValue(register_token);
                if (register < 0 or register > 15) return self.fail(register_token, .invalid_hardware_register);
                _ = try self.expect(.r_paren);
                return .{ .hardware_read = .{ .register = @intCast(register) } };
            }
            return self.fail(facility, .unsupported_builtin);
        }
        if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "dmem") and value_next.tag == .dot) {
            _ = try self.expect(.ident);
            _ = try self.expect(.dot);
            const operation = try self.expect(.ident);
            if (!std.mem.eql(u8, operation.text, "addressOf")) return self.fail(operation, .unsupported_builtin);
            _ = try self.expect(.l_paren);
            const label = try self.expect(.ident);
            var offset: i64 = 0;
            if (try self.eat(.comma)) offset = try self.parseNumberValue(try self.expect(.number));
            _ = try self.expect(.r_paren);
            return .{ .data_address = .{ .label = label.text, .offset = offset } };
        }
        if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "signedLessThan")) {
            _ = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            const lhs = try self.parseValueRef();
            _ = try self.expect(.comma);
            const rhs = try self.parseValueRef();
            _ = try self.expect(.r_paren);
            return .{ .signed_less_than = .{ .lhs = lhs, .rhs = rhs } };
        }

        if (self.current.tag == .ident and
            (std.mem.eql(u8, self.current.text, "load") or
                std.mem.eql(u8, self.current.text, "loadUnaligned") or
                std.mem.eql(u8, self.current.text, "loadVectorBytes") or
                std.mem.eql(u8, self.current.text, "loadVectorBytesUnsigned") or
                std.mem.eql(u8, self.current.text, "loadVectorWords")))
        {
            const packed_u8 = std.mem.eql(u8, self.current.text, "loadVectorBytes");
            const packed_unsigned_u8 = std.mem.eql(u8, self.current.text, "loadVectorBytesUnsigned");
            const partial_u32 = std.mem.eql(u8, self.current.text, "loadVectorWords");
            const unaligned = std.mem.eql(u8, self.current.text, "loadUnaligned");
            _ = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            var field_offset: i64 = 0;
            const data_type: ast.DataType = if (packed_u8 or packed_unsigned_u8 or partial_u32) .vec16 else blk: {
                const memory_type = try self.parseMemoryType();
                if (memory_type.half_vector or memory_type.quarter_vector) {
                    return self.fail(self.current, .expected_data_type);
                }
                field_offset = memory_type.offset;
                _ = try self.expect(.comma);
                break :blk memory_type.data_type;
            };
            var address = try self.parseValueRef();
            var offset: i64 = field_offset;
            var label_offset: ?[]const u8 = null;
            if (try self.eat(.plus)) {
                label_offset = switch (address) {
                    .ident => |name| name,
                    else => return self.fail(self.current, .unexpected_token),
                };
                address = try self.parseValueRef();
            }
            var partial_u32_lane: ?u3 = null;
            if (try self.eat(.comma)) {
                if (self.current.tag == .ident and !std.mem.eql(u8, self.current.text, "offsetOf")) {
                    if (label_offset != null) return self.fail(self.current, .unexpected_token);
                    label_offset = (try self.expect(.ident)).text;
                    if (try self.eat(.comma)) offset += try self.parseLiteralOffset();
                } else {
                    offset += try self.parseLiteralOffset();
                }
            }
            if (partial_u32 and try self.eat(.comma)) {
                const lane_token = self.current;
                const lane = try self.parseLiteralOffset();
                if (lane < 0 or lane > 7) return self.fail(lane_token, .invalid_vector_lane);
                partial_u32_lane = @intCast(lane);
            }
            _ = try self.expect(.r_paren);
            return .{ .load = .{
                .data_type = data_type,
                .address = address,
                .offset = offset,
                .label_offset = label_offset,
                .packed_u8 = packed_u8,
                .packed_unsigned_u8 = packed_unsigned_u8,
                .partial_u32_lane = if (partial_u32) partial_u32_lane orelse 0 else null,
                .unaligned = unaligned,
            } };
        }

        if (self.current.tag == .ident and
            (std.mem.eql(u8, self.current.text, "accumulator") or
                explicitAccumulatorPart(self.current.text) != null))
        {
            const operation = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            const part = explicitAccumulatorPart(operation.text) orelse blk: {
                _ = try self.expect(.dot);
                const part_token = try self.expect(.ident);
                break :blk parseAccumulatorPart(part_token.text) orelse
                    return self.fail(part_token, .invalid_accumulator_part);
            };
            _ = try self.expect(.r_paren);
            return .{ .accumulator_read = part };
        }

        if (self.current.tag == .ident and
            (std.mem.eql(u8, self.current.text, "vectorShiftLeft8") or
                std.mem.eql(u8, self.current.text, "vectorShiftRightArithmetic") or
                std.mem.eql(u8, self.current.text, "vectorShiftRightLogical")))
        {
            const operation = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            const source_token = self.current;
            const source = try vectorAccessFromRef(try self.parseValueRef()) orelse
                return self.fail(source_token, .expected_vector_operand);
            _ = try self.expect(.comma);
            const amount_value = try self.parseNumberValue(try self.expect(.number));
            const left = std.mem.eql(u8, operation.text, "vectorShiftLeft8");
            if ((left and (amount_value < 8 or amount_value > 15)) or
                (!left and (amount_value < 1 or amount_value > 8)))
            {
                return self.fail(operation, .unsupported_vector_shift);
            }
            _ = try self.expect(.r_paren);
            const kind: @FieldType(ast.VectorShift, "kind") = if (left)
                .left_8
            else if (std.mem.eql(u8, operation.text, "vectorShiftRightLogical"))
                .right_logical
            else
                .right_arithmetic;
            return .{ .vector_shift = .{
                .kind = kind,
                .source = source,
                .amount = @intCast(amount_value),
            } };
        }

        if (self.current.tag == .ident and parseVectorOp(self.current.text) != null) {
            const op_token = try self.expect(.ident);
            const op = parseVectorOp(op_token.text).?;
            _ = try self.expect(.l_paren);
            const lhs_token = self.current;
            const lhs = try vectorAccessFromRef(try self.parseValueRef()) orelse
                return self.fail(lhs_token, .expected_vector_operand);
            const rhs = if (isUnaryVectorOp(op)) lhs else blk: {
                _ = try self.expect(.comma);
                const rhs_token = self.current;
                break :blk try vectorAccessFromRef(try self.parseValueRef()) orelse
                    return self.fail(rhs_token, .expected_vector_operand);
            };
            _ = try self.expect(.r_paren);
            return .{ .vector_operation = .{
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
                .explicit_lane_encoding = std.mem.startsWith(u8, op_token.text, "vectorReciprocal") or
                    std.mem.eql(u8, op_token.text, "vectorMove"),
            } };
        }

        const value_ref = try self.parseValueRef();
        return switch (value_ref) {
            .ident => |name| .{ .ident = name },
            .vector_access => |access| .{ .vector_access = access },
            .number => |number| .{ .number = number },
        };
    }

    fn parseFunctionReference(self: *Parser) !ast.FunctionRef {
        const first = try self.expect(.ident);
        if (try self.eat(.dot)) {
            return .{
                .module = first.text,
                .name = (try self.expect(.ident)).text,
            };
        }
        return .{ .name = first.text };
    }

    fn parseScalarExpression(self: *Parser, minimum_precedence: u4) !ast.Value {
        var lhs = if (try self.eat(.l_paren)) blk: {
            const grouped = try self.parseScalarExpression(0);
            _ = try self.expect(.r_paren);
            break :blk grouped;
        } else try self.parseValue();

        while (binaryPrecedence(self.current.tag)) |precedence| {
            if (precedence < minimum_precedence) break;
            const op = (try self.parseBinaryAssignOp()).?;
            const rhs = try self.parseScalarExpression(precedence + 1);
            const expression = try self.allocator.create(ast.ScalarExpression);
            expression.* = .{ .lhs = lhs, .op = op, .rhs = rhs };
            lhs = .{ .scalar_expression = expression };
        }
        return lhs;
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
                if (self.current.tag == .dot) {
                    var lookahead = self.lexer;
                    const member_token = try lookahead.next();
                    if (member_token.tag == .ident) {
                        if (self.lookupCompileTimeMember(tok.text, member_token.text)) |member| {
                            _ = try self.expect(.dot);
                            _ = try self.expect(.ident);
                            return .{ .number = member.value };
                        }
                    }
                }
                if (self.current.tag == .l_bracket or self.isVectorDotSuffix()) {
                    return .{ .vector_access = try self.parseVectorAccess(tok.text) };
                }
                return .{ .ident = tok.text };
            },
            .number => {
                const tok = try self.expect(.number);
                return .{ .number = try self.parseNumberValue(tok) };
            },
            else => return self.fail(self.current, .expected_value),
        }
    }

    fn isVectorDotSuffix(self: *const Parser) bool {
        if (self.current.tag != .dot) return false;
        var lexer = self.lexer;
        const suffix = lexer.next() catch return false;
        return suffix.tag == .ident and
            (parseVectorView(suffix.text) != null or parseSwizzle(suffix.text) != null);
    }

    fn parseVectorAccess(self: *Parser, name: []const u8) !ast.VectorAccess {
        if (try self.eat(.l_bracket)) {
            const lane_token = try self.expect(.number);
            const lane = try self.parseNumberValue(lane_token);
            if (lane < 0 or lane > 7) return self.fail(lane_token, .invalid_vector_lane);
            _ = try self.expect(.r_bracket);
            return .{ .name = name, .element = @intCast(lane + 8), .lane = @intCast(lane) };
        }

        _ = try self.expect(.dot);
        const suffix = try self.expect(.ident);
        if (parseVectorView(suffix.text)) |view| {
            if (try self.eat(.l_bracket)) {
                const lane_token = try self.expect(.number);
                const lane = try self.parseNumberValue(lane_token);
                if (lane < 0 or lane > 7) return self.fail(lane_token, .invalid_vector_lane);
                _ = try self.expect(.r_bracket);
                return .{ .name = name, .view = view, .element = @intCast(lane + 8), .lane = @intCast(lane) };
            }
            if (try self.eat(.dot)) {
                const swizzle_token = try self.expect(.ident);
                const swizzle = parseSwizzle(swizzle_token.text) orelse
                    return self.fail(swizzle_token, .invalid_vector_swizzle);
                return .{
                    .name = name,
                    .view = view,
                    .element = swizzle.element,
                    .lane = swizzle.lane,
                };
            }
            return .{ .name = name, .view = view };
        }
        const swizzle = parseSwizzle(suffix.text) orelse
            return self.fail(suffix, .invalid_vector_swizzle);
        return .{
            .name = name,
            .element = swizzle.element,
            .lane = swizzle.lane,
        };
    }

    fn parseLiteralOffset(self: *Parser) !i64 {
        if (self.current.tag == .ident and std.mem.eql(u8, self.current.text, "offsetOf")) {
            _ = try self.expect(.ident);
            _ = try self.expect(.l_paren);
            const type_name = try self.expect(.ident);
            _ = try self.expect(.comma);
            const field_name = try self.expect(.ident);
            _ = try self.expect(.r_paren);
            return self.packedStructFieldOffset(type_name, field_name);
        }
        const tok = self.current;
        return switch (try self.parseValueRef()) {
            .number => |number| number,
            .ident, .vector_access => self.fail(tok, .expected_literal_offset),
        };
    }

    fn packedStructFieldOffset(self: *Parser, type_name: token.Token, field_name: token.Token) !i64 {
        for (self.packed_structs.items) |declaration| {
            if (!std.mem.eql(u8, declaration.name, type_name.text)) continue;
            var offset: i64 = 0;
            for (declaration.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name.text)) return offset;
                offset += switch (field.data_type) {
                    .u8, .i8 => 1,
                    .u16, .i16 => 2,
                    .u32, .i32, .dmem => 4,
                    .vec16, .vec32 => unreachable,
                };
            }
            return self.fail(field_name, .expected_literal_offset);
        }
        return self.fail(type_name, .expected_literal_offset);
    }

    fn parseCondition(self: *Parser) !ast.Condition {
        const lhs = try self.expect(.ident);
        const op = (try self.parseComparisonOperator()) orelse
            return self.fail(self.current, .expected_comparison_operator);
        return .{
            .lhs = lhs.text,
            .op = op,
            .rhs = valueFromRef(try self.parseValueRef()),
        };
    }

    fn parseComparisonOperator(self: *Parser) !?ast.CompareOp {
        const op: ast.CompareOp = switch (self.current.tag) {
            .equal_equal => ast.CompareOp.eq,
            .not_equal => ast.CompareOp.ne,
            .less => ast.CompareOp.lt,
            .less_equal => ast.CompareOp.le,
            .greater => ast.CompareOp.gt,
            .greater_equal => ast.CompareOp.ge,
            else => return null,
        };
        self.current = try self.lexer.next();
        return op;
    }

    fn parseCompoundAssignOp(self: *Parser) !?ast.AssignOp {
        const op: ast.AssignOp = switch (self.current.tag) {
            .plus_equal => .add,
            .plus_percent_equal => .add_wrap,
            .minus_equal => .sub,
            .minus_percent_equal => .sub_wrap,
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
            .plus_percent => .add_wrap,
            .minus => .sub,
            .minus_percent => .sub_wrap,
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

    fn parseRspqNumberAttribute(
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

    fn isCompileTimeTypeStart(self: *const Parser) bool {
        return self.current.tag == .ident and
            (std.mem.eql(u8, self.current.text, "enum") or
                std.mem.eql(u8, self.current.text, "flags"));
    }

    fn isImportStart(self: *const Parser) bool {
        if (self.current.tag != .ident or !std.mem.eql(u8, self.current.text, "const")) return false;
        var lexer = self.lexer;
        _ = lexer.next() catch return false;
        const separator = lexer.next() catch return false;
        const import_name = lexer.next() catch return false;
        return separator.tag == .equal and import_name.tag == .ident and
            std.mem.eql(u8, import_name.text, "import");
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
        .vector_access => |access| .{ .vector_access = access },
        .number => |number| .{ .number = number },
    };
}

fn binaryPrecedence(tag: token.Tag) ?u4 {
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

fn valueRefFromValue(value: ast.Value) !ast.ValueRef {
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

pub fn errorString(code: ErrorType) []const u8 {
    return switch (code) {
        .expected_function_declaration => "expected function declaration",
        .unsupported_function_modifier => "unsupported function modifier",
        .unsupported_statement => "unsupported statement",
        .unsupported_builtin => "unsupported builtin",
        .var_keyword_removed => "'var' has been replaced by 'reg' for register variables",
        .expected_data_type => "expected data type",
        .expected_scalar_register => "expected scalar register",
        .expected_register => "expected scalar or vector register",
        .expected_vector_register => "expected vector register ($v00 through $v31)",
        .invalid_vector_lane => "vector lane must be between 0 and 7",
        .invalid_vector_swizzle => "unsupported vector swizzle",
        .unsupported_destination_swizzle => "only a single lane or typed view is allowed on an assignment destination",
        .expected_vector_operand => "expected vector operand",
        .unsupported_vector_shift => "unsupported vector shift amount",
        .invalid_accumulator_part => "expected accumulator part .high, .middle, or .low",
        .expected_fixed_register_parameter => "expected fixed-register parameter",
        .expected_import => "expected import",
        .expected_value => "expected value",
        .expected_comparison_operator => "expected comparison operator",
        .expected_literal_offset => "expected literal memory offset",
        .expected_scalar_data_type => "expected scalar data type",
        .expected_data_literal => "expected data initializer literal",
        .undefined_data_initializer => "data declarations must contain initialized bytes; reserve storage in a bss block",
        .external_data_initializer => "external storage declarations cannot have initializers",
        .expected_struct_declaration => "expected packed struct declaration",
        .invalid_array_length => "invalid array length",
        .invalid_command_index => "command index must be between 0 and 239",
        .invalid_hardware_register => "hardware register index must be between 0 and 15",
        .duplicate_clobber_contract => "function has more than one clobber contract",
        .duplicate_compile_time_type => "duplicate compile-time type",
        .duplicate_compile_time_member => "duplicate compile-time member",
        .expected_unsigned_scalar_type => "expected unsigned scalar type",
        .unknown_packed_struct => "unknown packed struct",
        .unknown_packed_struct_field => "unknown packed struct field",
        .incorrect_array_initializer_count => "array initializer must contain exactly the declared element count",
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

fn parseVectorRegister(tok: token.Token) ?ast.VectorRegister {
    if (tok.text.len != 4 or tok.text[1] != 'v') return null;
    const index = std.fmt.parseInt(u5, tok.text[2..], 10) catch return null;
    return @enumFromInt(index);
}

fn isVectorType(data_type: ast.DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

fn isSignedType(data_type: ast.DataType) bool {
    return data_type == .i8 or data_type == .i16 or data_type == .i32;
}

fn scalarTypeSize(data_type: ast.DataType) i64 {
    return switch (data_type) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .dmem => 4,
        .vec16, .vec32 => unreachable,
    };
}

fn literalFitsType(value: i64, data_type: ast.DataType) bool {
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

fn abiTypesCompatible(left: ast.DataType, right: ast.DataType) bool {
    if (left == right) return true;
    return switch (left) {
        .u8, .i8 => right == .u8 or right == .i8,
        .u16, .i16 => right == .u16 or right == .i16,
        .u32, .i32 => right == .u32 or right == .i32,
        .dmem => false,
        .vec16, .vec32 => false,
    };
}

fn parseVectorView(text: []const u8) ?ast.VectorView {
    inline for (std.meta.fields(ast.VectorView)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseVectorOp(text: []const u8) ?ast.VectorOp {
    const aliases = .{
        .{ "vectorAdd", ast.VectorOp.vadd },
        .{ "vectorSubtract", ast.VectorOp.vsub },
        .{ "vectorAddCarry", ast.VectorOp.vaddc },
        .{ "vectorSubtractCarry", ast.VectorOp.vsubc },
        .{ "vectorCompareLessThan", ast.VectorOp.vlt },
        .{ "vectorCompareEqual", ast.VectorOp.veq },
        .{ "vectorCompareNotEqual", ast.VectorOp.vne },
        .{ "vectorCompareGreaterOrEqual", ast.VectorOp.vge },
        .{ "vectorSelectByCompareCode", ast.VectorOp.vmrg },
        .{ "vectorReciprocal", ast.VectorOp.vrcp },
        .{ "vectorReciprocalLow", ast.VectorOp.vrcpl },
        .{ "vectorReciprocalHigh", ast.VectorOp.vrcph },
        .{ "vectorMove", ast.VectorOp.vmov },
    };
    inline for (aliases) |alias| if (std.mem.eql(u8, text, alias[0])) return alias[1];
    inline for (std.meta.fields(ast.VectorOp)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn explicitAccumulatorPart(text: []const u8) ?ast.AccumulatorPart {
    if (std.mem.eql(u8, text, "readVectorAccumulatorHigh")) return .high;
    if (std.mem.eql(u8, text, "readVectorAccumulatorMiddle")) return .middle;
    if (std.mem.eql(u8, text, "readVectorAccumulatorLow")) return .low;
    return null;
}

fn isUnaryVectorOp(op: ast.VectorOp) bool {
    return op == .vrcp or op == .vrcpl or op == .vrcph or op == .vmov;
}

fn parseAccumulatorPart(text: []const u8) ?ast.AccumulatorPart {
    inline for (std.meta.fields(ast.AccumulatorPart)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn vectorControlRegisterForOperation(name: []const u8, comptime prefix: []const u8) ?ast.VectorControlRegister {
    if (std.mem.eql(u8, name, prefix ++ "CarryOut")) return .carry_out;
    if (std.mem.eql(u8, name, prefix ++ "CompareCode")) return .compare_code;
    if (std.mem.eql(u8, name, prefix ++ "CompareExtension")) return .compare_extension;
    return null;
}

fn vectorMemoryOperationForBuiltin(name: []const u8) ?ast.VectorMemoryOperation {
    const names = .{
        .{ "load16", ast.VectorMemoryOperation.load16 },
        .{ "store16", ast.VectorMemoryOperation.store16 },
        .{ "load32", ast.VectorMemoryOperation.load32 },
        .{ "store32", ast.VectorMemoryOperation.store32 },
        .{ "load64", ast.VectorMemoryOperation.load64 },
        .{ "store64", ast.VectorMemoryOperation.store64 },
        .{ "load128", ast.VectorMemoryOperation.load128 },
        .{ "store128", ast.VectorMemoryOperation.store128 },
        .{ "loadPackedSigned", ast.VectorMemoryOperation.load_packed_signed },
        .{ "loadPackedUnsigned", ast.VectorMemoryOperation.load_packed_unsigned },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

fn vectorMemoryOperationHasLane(operation: ast.VectorMemoryOperation) bool {
    return switch (operation) {
        .load16, .store16, .load32, .store32, .load64, .store64 => true,
        .load128, .store128, .load_packed_signed, .load_packed_unsigned => false,
    };
}

fn cp0NamedReadRegister(name: []const u8) ?u4 {
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

fn cp0NamedWriteRegister(name: []const u8) ?u4 {
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

fn vectorAccessFromRef(value: ast.ValueRef) !?ast.VectorAccess {
    return switch (value) {
        .ident => |name| .{ .name = name },
        .vector_access => |access| access,
        .number => null,
    };
}

const ParsedSwizzle = struct { element: u4, lane: ?u3 = null };

fn parseSwizzle(text: []const u8) ?ParsedSwizzle {
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
