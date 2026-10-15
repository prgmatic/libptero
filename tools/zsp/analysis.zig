const regName = @import("registers.zig").regName;
const vectorRegName = @import("registers.zig").vectorRegName;
const nextVectorRegister = @import("registers.zig").nextVectorRegister;
const allAutomaticVectorRegisters = @import("registers.zig").allAutomaticVectorRegisters;
const allAutomaticScalarRegisters = @import("registers.zig").allAutomaticScalarRegisters;
const vectorRegisterBit = @import("registers.zig").vectorRegisterBit;
const registerBit = @import("registers.zig").registerBit;
const alloc_vector_registers = @import("registers.zig").alloc_vector_registers;
const alloc_scalar_registers = @import("registers.zig").alloc_scalar_registers;
const command_return = @import("registers.zig").command_return;
const compiler_scratch_2 = @import("registers.zig").compiler_scratch_2;
const compiler_scratch = @import("registers.zig").compiler_scratch;
const std = @import("std");
const ast = @import("ast.zig");
const rspq = @import("rspq.zig");

const Register = ast.Register;
const DataType = ast.DataType;

pub const Diagnostic = @import("explain.zig").Diagnostic;
pub const ExplainReport = @import("explain.zig").ExplainReport;

const expression_temporary_names = [_][]const u8{
    "__expression_temporary_0",
    "__expression_temporary_1",
    "__expression_temporary_2",
    "__expression_temporary_3",
    "__expression_temporary_4",
    "__expression_temporary_5",
    "__expression_temporary_6",
    "__expression_temporary_7",
};

pub fn bindParameters(context: *FunctionContext, parameters: []const ast.Parameter) !void {
    for (parameters) |parameter| {
        if (isVectorType(parameter.data_type)) {
            const vector_reg = parameter.vector_reg orelse return error.ExpectedVectorRegister;
            try validateVectorRegisterBinding(context, parameter.data_type, vector_reg, null);
        } else {
            const reg = parameter.reg orelse return error.InvalidScalarRegister;
            if (!isScalarRegister(reg)) return error.InvalidScalarRegister;
            if (reg == compiler_scratch_2 or reg == command_return) {
                return error.RegisterReservedForBackend;
            }
            if (context.isRegisterInUse(reg)) return error.RegisterAlreadyInUse;
        }
        if (std.mem.eql(u8, parameter.name, "_")) continue;
        try context.add(.{
            .name = parameter.name,
            .data_type = parameter.data_type,
            .reg = parameter.reg,
            .vector_reg = parameter.vector_reg,
            .constant = null,
            .first_live = context.firstLive(parameter.name),
            .last_use = context.lastUse(parameter.name),
        });
    }
}

pub const Symbol = struct {
    name: []const u8,
    data_type: DataType,
    reg: ?Register,
    vector_reg: ?ast.VectorRegister = null,
    function_type: ?ast.FunctionType = null,
    constant: ?i64,
    data_label: ?[]const u8 = null,
    automatic: bool = false,
    first_live: usize = 0,
    last_use: usize = std.math.maxInt(usize),
};

const FunctionClobber = struct {
    name: []const u8,
    scalar: u32 = 0,
    vector: u32 = 0,
    forbidden_scalar: u32 = 0,
    forbidden_vector: u32 = 0,
};

pub const FunctionClobberRegistry = struct {
    entries: [1024]FunctionClobber = undefined,
    len: usize = 0,

    pub fn init(functions: []const ast.Function, diagnostic: ?*Diagnostic) !FunctionClobberRegistry {
        if (functions.len > 1024) return error.TooManyFunctions;
        var result = FunctionClobberRegistry{};
        var direct: [1024]FunctionClobber = undefined;
        for (functions) |function| {
            var entry = FunctionClobber{ .name = function.name };
            scanDirectFunctionClobbers(functions, function, function.statements, &entry);
            result.entries[result.len] = entry;
            direct[result.len] = entry;
            result.len += 1;
        }
        for (functions) |function| {
            var context = FunctionContext{
                .label_prefix = function.name,
                .functions = functions,
                .diagnostic = diagnostic,
            };
            context.prepareLifetimes(functions, function.parameters, function.statements) catch |err| {
                if (diagnostic) |value| value.function_name = function.source_name;
                return err;
            };
            for (context.lifetime_calls[0..context.lifetime_call_count]) |call| {
                const target = result.findPtr(call.target) orelse continue;
                const target_function = findFunction(functions, call.target) orelse continue;
                for (context.lifetimes[0..context.lifetime_count]) |lifetime| {
                    if (lifetime.automatic or lifetime.declaration >= call.resume_position or
                        !context.valueLivesAcross(lifetime.name, call.resume_position) or
                        context.valueDefinedAt(lifetime.name, call.position)) continue;
                    if (lifetime.fixed_reg) |reg| {
                        if ((call.setup_scalar & registerBit(reg)) != 0) {
                            return error.PinnedRegisterOverwrittenByCallArgument;
                        }
                        if (target_function.external and (target.scalar & registerBit(reg)) != 0 and
                            !externalFunctionWritesScalarParameter(target_function, reg))
                        {
                            if (diagnostic) |value| {
                                value.function_name = function.source_name;
                                value.symbol_name = lifetime.name;
                            }
                            return error.PinnedRegisterClobberedByExternalCall;
                        }
                        target.forbidden_scalar |= registerBit(reg);
                    }
                    if (lifetime.fixed_vector_reg) |reg| {
                        if ((call.setup_vector & vectorRegisterBit(reg)) != 0) {
                            return error.PinnedRegisterOverwrittenByCallArgument;
                        }
                        if (target_function.external and (target.vector & vectorRegisterBit(reg)) != 0 and
                            !externalFunctionWritesVectorParameter(target_function, reg))
                        {
                            if (diagnostic) |value| {
                                value.function_name = function.source_name;
                                value.symbol_name = lifetime.name;
                            }
                            return error.PinnedRegisterClobberedByExternalCall;
                        }
                        target.forbidden_vector |= vectorRegisterBit(reg);
                        if (lifetime.data_type == .vec32) {
                            if (nextVectorRegister(reg)) |second| {
                                if ((call.setup_vector & vectorRegisterBit(second)) != 0) {
                                    return error.PinnedRegisterOverwrittenByCallArgument;
                                }
                                if (target_function.external and (target.vector & vectorRegisterBit(second)) != 0) {
                                    return error.PinnedRegisterClobberedByExternalCall;
                                }
                                target.forbidden_vector |= vectorRegisterBit(second);
                            }
                        }
                    }
                }
            }
        }
        @memcpy(direct[0..result.len], result.entries[0..result.len]);
        for (0..32) |_| {
            const previous = result;
            @memcpy(result.entries[0..result.len], direct[0..result.len]);
            for (functions, 0..) |function, index| {
                var context = FunctionContext{
                    .label_prefix = function.name,
                    .clobbers = &previous,
                    .functions = functions,
                    .diagnostic = diagnostic,
                    .function_forbidden_scalar = direct[index].forbidden_scalar,
                    .function_forbidden_vector = direct[index].forbidden_vector,
                };
                context.prepareLifetimes(functions, function.parameters, function.statements) catch |err| {
                    if (diagnostic) |value| value.function_name = function.source_name;
                    return err;
                };
                for (context.lifetime_calls[0..context.lifetime_call_count]) |call| {
                    result.entries[index].scalar |= call.setup_scalar;
                    result.entries[index].vector |= call.setup_vector;
                }
                bindParameters(&context, function.parameters) catch |err| {
                    if (diagnostic) |value| value.function_name = function.source_name;
                    return err;
                };
                simulateAutomaticRegisters(&context, function.statements, &result.entries[index]) catch |err| {
                    if (diagnostic) |value| value.function_name = function.source_name;
                    return err;
                };
            }
            var changed = true;
            while (changed) {
                changed = false;
                for (functions, 0..) |function, index| {
                    var scalar = result.entries[index].scalar;
                    var vector = result.entries[index].vector;
                    collectCalledFunctionClobbers(&result, function.statements, &scalar, &vector);
                    if (scalar != result.entries[index].scalar or vector != result.entries[index].vector) {
                        result.entries[index].scalar = scalar;
                        result.entries[index].vector = vector;
                        changed = true;
                    }
                }
            }
            for (result.entries[0..result.len], 0..) |entry, index| {
                if ((entry.scalar & entry.forbidden_scalar) != 0 or
                    (entry.vector & entry.forbidden_vector) != 0)
                {
                    if (diagnostic) |value| value.function_name = functions[index].source_name;
                    return error.PinnedRegisterClobberedByCall;
                }
            }
            var converged = true;
            for (functions, 0..) |function, index| {
                _ = function;
                if (result.entries[index].scalar != previous.entries[index].scalar or
                    result.entries[index].vector != previous.entries[index].vector)
                {
                    converged = false;
                    break;
                }
            }
            if (converged) return result;
        }
        return error.RegisterClobberAnalysisDidNotConverge;
    }

    pub fn find(self: *const FunctionClobberRegistry, name: []const u8) ?FunctionClobber {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn findPtr(self: *FunctionClobberRegistry, name: []const u8) ?*FunctionClobber {
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

fn scanDirectFunctionClobbers(
    functions: []const ast.Function,
    function: ast.Function,
    statements: []const ast.Statement,
    result: *FunctionClobber,
) void {
    if (function.external and !function.has_clobber_contract) {
        result.scalar = std.math.maxInt(u32);
        result.vector = std.math.maxInt(u32);
        return;
    }
    for (function.clobber_regs) |reg| result.scalar |= registerBit(reg);
    for (function.clobber_vector_regs) |reg| result.vector |= vectorRegisterBit(reg);
    if (!function.has_clobber_contract) {
        for (function.parameters, 0..) |parameter, parameter_index| {
            var visited: [1024]ParameterWriteVisit = undefined;
            var visited_count: usize = 0;
            if (!function.external and !functionParameterIsWritten(
                functions,
                function,
                parameter_index,
                &visited,
                &visited_count,
            )) continue;
            if (parameter.reg) |reg| result.scalar |= registerBit(reg);
            if (parameter.vector_reg) |reg| {
                result.vector |= vectorRegisterBit(reg);
                if (parameter.data_type == .vec32) {
                    if (nextVectorRegister(reg)) |second| result.vector |= vectorRegisterBit(second);
                }
            }
        }
    }
    scanDirectStatementClobbers(statements, result);
}

fn scanDirectStatementClobbers(statements: []const ast.Statement, result: *FunctionClobber) void {
    for (statements) |statement| switch (statement) {
        .var_decl => |decl| {
            if (decl.is_const or decl.value == null) continue;
            if (isVectorType(decl.data_type)) {
                if (decl.vector_reg) |reg| {
                    result.vector |= vectorRegisterBit(reg);
                    if (decl.data_type == .vec32) {
                        if (nextVectorRegister(reg)) |second| result.vector |= vectorRegisterBit(second);
                    }
                }
            } else if (decl.reg) |reg| {
                result.scalar |= registerBit(reg);
            }
        },
        .goto => |branch| if (branch.delay_slot) |delay| scanDirectStatementClobbers(delay, result),
        .conditional_goto => |branch| if (branch.delay_slot) |delay| scanDirectStatementClobbers(delay, result),
        .conditional_direct_goto => |branch| if (branch.delay_slot) |delay| scanDirectStatementClobbers(delay, result),
        .while_loop => |loop| scanDirectStatementClobbers(loop.statements, result),
        .do_while_loop => |loop| {
            scanDirectStatementClobbers(loop.statements, result);
            if (loop.delay_slot) |delay| scanDirectStatementClobbers(delay, result);
        },
        .break_loop => |transfer| if (transfer.delay_slot) |delay| scanDirectStatementClobbers(delay, result),
        .if_statement => |branch| {
            if (branch.delay_slot) |items| scanDirectStatementClobbers(items, result);
            scanDirectStatementClobbers(branch.then_statements, result);
            if (branch.else_statements) |items| scanDirectStatementClobbers(items, result);
        },
        .labeled_block => |block| {
            scanDirectStatementClobbers(block.statements, result);
            if (block.exit_delay) |delay| scanDirectStatementClobbers(delay, result);
        },
        .ordered_block => |items| scanDirectStatementClobbers(items, result),
        .builtin => |builtin| switch (builtin) {
            .hardware_read_register => |transfer| result.scalar |= registerBit(transfer.destination),
            .jump => |jump| if (jump.delay_slot) |delay| scanDirectStatementClobbers(delay, result),
            .return_from_function => |delay| if (delay) |items| scanDirectStatementClobbers(items, result),
            else => {},
        },
        .asm_line => {
            result.scalar |= allAutomaticScalarRegisters();
            result.vector |= allAutomaticVectorRegisters();
        },
        else => {},
    };
}

fn collectCalledFunctionClobbers(
    registry: *const FunctionClobberRegistry,
    statements: []const ast.Statement,
    scalar: *u32,
    vector: *u32,
) void {
    for (statements) |statement| switch (statement) {
        .call => |call| {
            addNamedClobber(registry, call.module, call.name, scalar, vector);
            if (call.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector);
        },
        .goto => |branch| if (branch.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector),
        .conditional_goto => |branch| if (branch.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector),
        .conditional_direct_goto => |branch| {
            addNamedClobber(registry, branch.target.module, branch.target.name, scalar, vector);
            if (branch.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector);
        },
        .while_loop => |loop| collectCalledFunctionClobbers(registry, loop.statements, scalar, vector),
        .do_while_loop => |loop| {
            collectCalledFunctionClobbers(registry, loop.statements, scalar, vector);
            if (loop.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector);
        },
        .break_loop => |transfer| if (transfer.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector),
        .if_statement => |branch| {
            if (branch.delay_slot) |items| collectCalledFunctionClobbers(registry, items, scalar, vector);
            collectCalledFunctionClobbers(registry, branch.then_statements, scalar, vector);
            if (branch.else_statements) |items| collectCalledFunctionClobbers(registry, items, scalar, vector);
        },
        .labeled_block => |block| {
            collectCalledFunctionClobbers(registry, block.statements, scalar, vector);
            if (block.exit_delay) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector);
        },
        .ordered_block => |items| collectCalledFunctionClobbers(registry, items, scalar, vector),
        .builtin => |builtin| switch (builtin) {
            .direct_goto => |item| addNamedClobber(registry, item.target.module, item.target.name, scalar, vector),
            .tail => |tail| {
                addNamedClobber(registry, tail.target.module, tail.target.name, scalar, vector);
                if (tail.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector);
            },
            .jump => |jump| if (jump.delay_slot) |delay| collectCalledFunctionClobbers(registry, delay, scalar, vector),
            .return_from_function => |delay| if (delay) |items| collectCalledFunctionClobbers(registry, items, scalar, vector),
            else => {},
        },
        else => {},
    };
}

fn addNamedClobber(
    registry: *const FunctionClobberRegistry,
    module: ?[]const u8,
    name: []const u8,
    scalar: *u32,
    vector: *u32,
) void {
    if (module != null) return;
    if (registry.find(name)) |entry| {
        scalar.* |= entry.scalar;
        vector.* |= entry.vector;
    }
}

fn simulateAutomaticRegisters(
    context: *FunctionContext,
    statements: []const ast.Statement,
    clobber: *FunctionClobber,
) !void {
    for (statements) |*statement_ptr| {
        const statement = statement_ptr.*;
        if (context.diagnostic) |diagnostic| diagnostic.selectStatement(context.functions, statement_ptr);
        if (context.track_statement_position) context.statement_position += 1;
        switch (statement) {
            .var_decl => |decl| {
                if (decl.is_const) {
                    try context.add(.{
                        .name = decl.name,
                        .data_type = decl.data_type,
                        .reg = null,
                        .constant = 0,
                    });
                } else if (isVectorType(decl.data_type)) {
                    const reg = decl.vector_reg orelse try context.allocVectorRegister(decl.data_type, decl.name);
                    try validateVectorRegisterBinding(context, decl.data_type, reg, decl.name);
                    if (decl.value != null) {
                        clobber.vector |= vectorRegisterBit(reg);
                        if (decl.data_type == .vec32) {
                            clobber.vector |= vectorRegisterBit(nextVectorRegister(reg) orelse
                                return error.InvalidVectorRegisterPair);
                        }
                    }
                    try context.add(.{
                        .name = decl.name,
                        .data_type = decl.data_type,
                        .reg = null,
                        .vector_reg = reg,
                        .function_type = decl.function_type,
                        .constant = null,
                        .automatic = decl.vector_reg == null,
                        .first_live = context.firstLive(decl.name),
                        .last_use = context.lastUse(decl.name),
                    });
                } else {
                    const reg = decl.reg orelse try context.allocRegister(decl.data_type, decl.name);
                    if (context.scalarLifetimeConflicts(decl.name, reg)) return error.RegisterAlreadyInUse;
                    if (decl.value != null) clobber.scalar |= registerBit(reg);
                    try context.add(.{
                        .name = decl.name,
                        .data_type = decl.data_type,
                        .reg = reg,
                        .function_type = decl.function_type,
                        .constant = null,
                        .automatic = decl.reg == null,
                        .first_live = if (decl.is_reserved) 0 else context.firstLive(decl.name),
                        .last_use = if (decl.is_reserved)
                            std.math.maxInt(usize)
                        else
                            context.lastUse(decl.name),
                    });
                }
            },
            .assignment => |assignment| {
                const destination = try context.lookup(assignment.destination);
                if (destination.reg) |reg| clobber.scalar |= registerBit(reg);
                if (destination.vector_reg) |reg| {
                    clobber.vector |= vectorRegisterBit(reg);
                    if (destination.data_type == .vec32) {
                        clobber.vector |= vectorRegisterBit(nextVectorRegister(reg) orelse
                            return error.InvalidVectorRegisterPair);
                    }
                }
                if (!isVectorType(destination.data_type)) {
                    try simulateExpressionTemporaries(
                        context,
                        assignment.lhs,
                        destination,
                        clobber,
                    );
                }
            },
            .goto => |branch| if (branch.delay_slot) |delay| try simulateAutomaticRegisters(context, delay, clobber),
            .conditional_goto => |branch| if (branch.delay_slot) |delay| try simulateAutomaticRegisters(context, delay, clobber),
            .conditional_direct_goto => |branch| if (branch.delay_slot) |delay| try simulateAutomaticRegisters(context, delay, clobber),
            .while_loop => |loop| {
                const scope = context.pushScope();
                try simulateAutomaticRegisters(context, loop.statements, clobber);
                context.popScope(scope);
            },
            .do_while_loop => |loop| {
                const scope = context.pushScope();
                try simulateAutomaticRegisters(context, loop.statements, clobber);
                if (loop.delay_slot) |delay| try simulateAutomaticRegisters(context, delay, clobber);
                context.popScope(scope);
            },
            .break_loop => |transfer| if (transfer.delay_slot) |delay| try simulateAutomaticRegisters(context, delay, clobber),
            .if_statement => |branch| {
                if (branch.delay_slot) |items| try simulateAutomaticRegisters(context, items, clobber);
                const then_scope = context.pushScope();
                try simulateAutomaticRegisters(context, branch.then_statements, clobber);
                context.popScope(then_scope);
                if (branch.else_statements) |items| {
                    const else_scope = context.pushScope();
                    try simulateAutomaticRegisters(context, items, clobber);
                    context.popScope(else_scope);
                }
            },
            .labeled_block => |block| {
                const block_scope = context.pushScope();
                try simulateAutomaticRegisters(context, block.statements, clobber);
                if (block.exit_delay) |delay| try simulateAutomaticRegisters(context, delay, clobber);
                context.popScope(block_scope);
            },
            .ordered_block => |items| try simulateAutomaticRegisters(context, items, clobber),
            .call => |call| if (call.delay_slot) |delay| try simulateAutomaticRegisters(context, delay, clobber),
            .builtin => |builtin| switch (builtin) {
                .vector_memory => |memory| switch (memory.operation) {
                    .load16, .load32, .load64, .load128, .load_quad_lane, .load_right, .load_packed_signed, .load_packed_unsigned, .load_transpose => {
                        const symbol = try context.lookup(memory.vector.name);
                        const reg = try vectorRegisterForView(symbol, memory.vector.view);
                        const mask = if (memory.operation == .load_transpose) try reserveTransposeBank(context, symbol, reg) else vectorRegisterBit(reg);
                        clobber.vector |= mask;
                    },
                    else => {},
                },
                .jump => |jump| if (jump.delay_slot) |delay| try simulateAutomaticRegisters(context, delay, clobber),
                .return_from_function => |delay| if (delay) |items| try simulateAutomaticRegisters(context, items, clobber),
                else => {},
            },
            else => {},
        }
    }
}

fn simulateExpressionTemporaries(
    context: *FunctionContext,
    value: ast.Value,
    destination: Symbol,
    clobber: *FunctionClobber,
) !void {
    const expression = switch (value) {
        .scalar_expression => |expression| expression,
        else => return,
    };
    if (!isPureScalarExpression(value)) return error.SideEffectsNotAllowedInScalarExpression;
    try simulateExpressionTemporaries(context, expression.lhs, destination, clobber);
    if (expression.rhs == .scalar_expression or
        (expression.lhs == .scalar_expression and valueReadsName(expression.rhs, destination.name)))
    {
        const temporary = try context.pushExpressionTemporary(destination.data_type);
        defer context.popExpressionTemporary(temporary[0]);
        clobber.scalar |= registerBit(temporary[1].reg.?);
        try simulateExpressionTemporaries(context, expression.rhs, temporary[1], clobber);
    }
}

pub fn isPureScalarExpression(value: ast.Value) bool {
    return switch (value) {
        .ident, .number, .bit_cast => true,
        .scalar_expression => |expression| isPureScalarExpression(expression.lhs) and
            isPureScalarExpression(expression.rhs),
        else => false,
    };
}

pub fn valueReadsName(value: ast.Value, name: []const u8) bool {
    return switch (value) {
        .ident => |identifier| std.mem.eql(u8, identifier, name),
        .bit_cast => |source| switch (source) {
            .ident => |identifier| std.mem.eql(u8, identifier, name),
            else => false,
        },
        .scalar_expression => |expression| valueReadsName(expression.lhs, name) or
            valueReadsName(expression.rhs, name),
        else => false,
    };
}

const Lifetime = struct {
    name: []const u8,
    declaration: usize,
    last_use: usize,
    automatic: bool,
    initially_defined: bool,
    first_live: usize,
    data_type: DataType,
    fixed_reg: ?Register = null,
    fixed_vector_reg: ?ast.VectorRegister = null,
    required_reg: ?Register = null,
    required_vector_reg: ?ast.VectorRegister = null,
    forbidden_scalar: u32 = 0,
    forbidden_vector: u32 = 0,
};

const LifetimeLabel = struct { name: []const u8, position: usize, exported: bool = false };
const LifetimeEdge = struct { target: []const u8, position: usize };
const LifetimeCall = struct {
    target: []const u8,
    position: usize,
    resume_position: usize,
    setup_scalar: u32 = 0,
    setup_vector: u32 = 0,
};
const LifetimeEventKind = enum { read, write, output_write };
const LifetimeEvent = struct { name: []const u8, position: usize, kind: LifetimeEventKind };
const EmissionLoop = struct {
    name: ?[]const u8,
    label: usize,
    continue_suffix: []const u8,
    break_suffix: []const u8,
};
const FlowLoop = struct { name: ?[]const u8, continue_position: usize, break_position: usize };

pub const FunctionContext = struct {
    label_prefix: []const u8,
    functions: []const ast.Function = &.{},
    diagnostic: ?*Diagnostic = null,
    explain: ?*ExplainReport = null,
    explain_function_name: ?[]const u8 = null,
    symbols: [128]Symbol = undefined,
    symbol_count: usize = 0,
    next_label: usize = 0,
    emission_loops: [32]EmissionLoop = undefined,
    emission_loop_count: usize = 0,
    flow_loops: [32]FlowLoop = undefined,
    flow_loop_count: usize = 0,
    lifetimes: [128]Lifetime = undefined,
    lifetime_count: usize = 0,
    lifetime_labels: [128]LifetimeLabel = undefined,
    lifetime_label_count: usize = 0,
    lifetime_edges: [128]LifetimeEdge = undefined,
    lifetime_edge_count: usize = 0,
    lifetime_calls: [128]LifetimeCall = undefined,
    lifetime_call_count: usize = 0,
    analysis_error: ?anyerror = null,
    lifetime_events: [2048]LifetimeEvent = undefined,
    lifetime_event_count: usize = 0,
    flow_successors: [2049][2]usize = @splat(.{ 0, 0 }),
    flow_successor_counts: [2049]u2 = @splat(0),
    flow_statement_count: usize = 0,
    statement_position: usize = 0,
    track_statement_position: bool = true,
    lifetime_reuse: bool = false,
    clobbers: ?*const FunctionClobberRegistry = null,
    function_forbidden_scalar: u32 = 0,
    function_forbidden_vector: u32 = 0,
    omitted_tail_target: ?[]const u8 = null,
    omitted_tail_position: usize = 0,
    shared_exit_label: ?usize = null,
    shared_exit_delay: ?[]const ast.Statement = null,
    shared_exit_consumed: bool = false,
    expression_temporary_depth: usize = 0,

    pub fn add(self: *FunctionContext, symbol: Symbol) !void {
        if (self.symbol_count >= self.symbols.len) return error.TooManySymbols;
        if (self.contains(symbol.name)) return error.SymbolAlreadyDefined;
        self.symbols[self.symbol_count] = symbol;
        self.symbol_count += 1;
        if (self.explain) |report| {
            if ((symbol.reg != null or symbol.vector_reg != null) and
                !std.mem.startsWith(u8, symbol.name, "__"))
            {
                try report.addAllocation(.{
                    .function_name = self.explain_function_name orelse self.label_prefix,
                    .symbol_name = symbol.name,
                    .data_type = symbol.data_type,
                    .reg = symbol.reg,
                    .vector_reg = symbol.vector_reg,
                    .automatic = symbol.automatic,
                });
            }
        }
    }

    pub fn child(self: *const FunctionContext, label_prefix: []const u8) FunctionContext {
        var result = FunctionContext{
            .label_prefix = label_prefix,
            .clobbers = self.clobbers,
            .functions = self.functions,
            .diagnostic = self.diagnostic,
            .explain = self.explain,
            .explain_function_name = self.explain_function_name,
            .function_forbidden_scalar = self.function_forbidden_scalar,
            .function_forbidden_vector = self.function_forbidden_vector,
        };
        @memcpy(result.symbols[0..self.symbol_count], self.symbols[0..self.symbol_count]);
        result.symbol_count = self.symbol_count;
        return result;
    }

    pub fn prepareLifetimes(
        self: *FunctionContext,
        functions: []const ast.Function,
        parameters: []const ast.Parameter,
        statements: []const ast.Statement,
    ) !void {
        self.analysis_error = null;
        self.lifetime_count = 0;
        self.lifetime_label_count = 0;
        self.lifetime_edge_count = 0;
        self.lifetime_call_count = 0;
        self.lifetime_event_count = 0;
        self.flow_loop_count = 0;
        self.statement_position = 0;
        self.lifetime_reuse = !statementsContainUnstructuredControlFlow(statements);
        if (!self.lifetime_reuse) {
            collectStatementLabels(self, statements);
            if (self.analysis_error) |err| return err;
            return;
        }
        for (parameters) |parameter| {
            if (std.mem.eql(u8, parameter.name, "_")) continue;
            self.declareLifetime(
                parameter.name,
                0,
                false,
                true,
                parameter.data_type,
                parameter.reg,
                parameter.vector_reg,
            );
        }
        var position: usize = 0;
        scanStatementLifetimes(self, statements, &position);
        if (self.analysis_error) |err| return err;
        if (position >= self.flow_successors.len) return error.AnalysisCapacityExceeded;
        self.extendBackwardEdgeLifetimes();
        self.flow_statement_count = position;
        @memset(self.flow_successor_counts[0 .. position + 1], 0);
        position = 0;
        buildStatementFlow(self, statements, &position, 0);
        if (self.analysis_error) |err| return err;
        position = 0;
        try applyCallRequirements(self, functions, statements, &position);
        try self.validateDefiniteAssignments();
        self.applyCallClobbers();
    }

    pub fn declareLifetime(
        self: *FunctionContext,
        name: []const u8,
        position: usize,
        automatic: bool,
        initially_defined: bool,
        data_type: DataType,
        fixed_reg: ?Register,
        fixed_vector_reg: ?ast.VectorRegister,
    ) void {
        if (self.lifetime_count >= self.lifetimes.len) {
            self.analysis_error = error.AnalysisCapacityExceeded;
            return;
        }
        self.lifetimes[self.lifetime_count] = .{
            .name = name,
            .declaration = position,
            .last_use = position,
            .automatic = automatic,
            .initially_defined = initially_defined,
            .first_live = if (initially_defined) position else std.math.maxInt(usize),
            .data_type = data_type,
            .fixed_reg = fixed_reg,
            .fixed_vector_reg = fixed_vector_reg,
        };
        self.lifetime_count += 1;
    }

    pub fn validateDefiniteAssignments(self: *const FunctionContext) !void {
        if (!self.lifetime_reuse) return;
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (lifetime.initially_defined) continue;
            var visited: [2049]bool = @splat(false);
            if (self.valueReadBeforeWrite(lifetime.name, lifetime.declaration, &visited)) {
                if (self.diagnostic) |diagnostic| diagnostic.symbol_name = lifetime.name;
                return error.RegisterReadBeforeAssignment;
            }
        }
    }

    pub fn addLifetimeLabel(self: *FunctionContext, name: []const u8, position: usize, exported: bool) void {
        if (self.lifetime_label_count >= self.lifetime_labels.len) {
            self.analysis_error = error.AnalysisCapacityExceeded;
            return;
        }
        self.lifetime_labels[self.lifetime_label_count] = .{
            .name = name,
            .position = position,
            .exported = exported,
        };
        self.lifetime_label_count += 1;
    }

    pub fn findLifetimeLabel(self: *const FunctionContext, name: []const u8) ?LifetimeLabel {
        for (self.lifetime_labels[0..self.lifetime_label_count]) |label| {
            if (std.mem.eql(u8, label.name, name)) return label;
        }
        return null;
    }

    pub fn addLifetimeEdge(self: *FunctionContext, target: []const u8, position: usize) void {
        if (self.lifetime_edge_count >= self.lifetime_edges.len) {
            self.analysis_error = error.AnalysisCapacityExceeded;
            return;
        }
        self.lifetime_edges[self.lifetime_edge_count] = .{ .target = target, .position = position };
        self.lifetime_edge_count += 1;
    }

    pub fn addLifetimeCall(
        self: *FunctionContext,
        target: []const u8,
        position: usize,
        resume_position: usize,
    ) void {
        if (self.lifetime_call_count >= self.lifetime_calls.len) {
            self.analysis_error = error.AnalysisCapacityExceeded;
            return;
        }
        self.lifetime_calls[self.lifetime_call_count] = .{
            .target = target,
            .position = position,
            .resume_position = resume_position,
        };
        self.lifetime_call_count += 1;
    }

    pub fn applyCallClobbers(self: *FunctionContext) void {
        if (!self.lifetime_reuse) return;
        const registry = self.clobbers orelse return;
        for (self.lifetime_calls[0..self.lifetime_call_count]) |call| {
            const clobber = registry.find(call.target) orelse continue;
            for (self.lifetimes[0..self.lifetime_count]) |*lifetime| {
                if (lifetime.automatic and lifetime.declaration < call.resume_position and
                    self.valueLivesAcross(lifetime.name, call.resume_position) and
                    !self.valueDefinedAt(lifetime.name, call.position))
                {
                    lifetime.forbidden_scalar |= clobber.scalar | call.setup_scalar;
                    lifetime.forbidden_vector |= clobber.vector | call.setup_vector;
                }
            }
        }
    }

    pub fn addCallSetupClobber(self: *FunctionContext, position: usize, scalar: u32, vector: u32) void {
        for (self.lifetime_calls[0..self.lifetime_call_count]) |*call| {
            if (call.position != position) continue;
            call.setup_scalar |= scalar;
            call.setup_vector |= vector;
            return;
        }
    }

    pub fn hasLifetime(self: *const FunctionContext, name: []const u8) bool {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) return true;
        }
        return false;
    }

    pub fn extendBackwardEdgeLifetimes(self: *FunctionContext) void {
        if (!self.lifetime_reuse) return;
        for (self.lifetime_edges[0..self.lifetime_edge_count]) |edge| {
            var target_position: ?usize = null;
            for (self.lifetime_labels[0..self.lifetime_label_count]) |label| {
                if (std.mem.eql(u8, label.name, edge.target)) {
                    target_position = label.position;
                    break;
                }
            }
            const target = target_position orelse continue;
            if (target >= edge.position) continue;
            for (self.lifetimes[0..self.lifetime_count]) |*lifetime| {
                if (lifetime.declaration <= edge.position and lifetime.last_use >= target) {
                    lifetime.last_use = @max(lifetime.last_use, edge.position);
                }
            }
        }
    }

    pub fn touchLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        self.addLifetimeEvent(name, position, .read);
        self.extendLifetime(name, position);
    }

    pub fn writeLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        self.addLifetimeEvent(name, position, .write);
        self.startLifetime(name, position);
        self.extendLifetime(name, position);
    }

    pub fn writeOutputLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        self.addLifetimeEvent(name, position, .output_write);
        self.startLifetime(name, position);
        self.extendLifetime(name, position);
    }

    pub fn startLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) {
                self.lifetimes[index].first_live = @min(self.lifetimes[index].first_live, position);
                return;
            }
        }
    }

    pub fn extendLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) {
                self.lifetimes[index].last_use = @max(self.lifetimes[index].last_use, position);
                return;
            }
        }
    }

    pub fn addLifetimeEvent(self: *FunctionContext, name: []const u8, position: usize, kind: LifetimeEventKind) void {
        if (self.lifetime_event_count >= self.lifetime_events.len) {
            self.analysis_error = error.AnalysisCapacityExceeded;
            return;
        }
        self.lifetime_events[self.lifetime_event_count] = .{ .name = name, .position = position, .kind = kind };
        self.lifetime_event_count += 1;
    }

    pub fn valueLivesAcross(self: *const FunctionContext, name: []const u8, position: usize) bool {
        if (position == 0 or position > self.flow_statement_count) return false;
        var visited: [2049]bool = @splat(false);
        return self.valueReadBeforeWrite(name, position, &visited);
    }

    pub fn valueReadBeforeWrite(
        self: *const FunctionContext,
        name: []const u8,
        position: usize,
        visited: *[2049]bool,
    ) bool {
        if (position == 0 or position > self.flow_statement_count or visited[position]) return false;
        visited[position] = true;
        for (self.lifetime_events[0..self.lifetime_event_count]) |event| {
            if (event.position == position and event.kind == .output_write and
                std.mem.eql(u8, event.name, name)) return false;
        }
        for (self.lifetime_events[0..self.lifetime_event_count]) |event| {
            if (event.position != position or !std.mem.eql(u8, event.name, name)) continue;
            if (event.kind == .read) return true;
            if (event.kind == .write or event.kind == .output_write) return false;
        }
        for (self.flow_successors[position][0..self.flow_successor_counts[position]]) |successor| {
            if (self.valueReadBeforeWrite(name, successor, visited)) return true;
        }
        return false;
    }

    pub fn valueDefinedAt(self: *const FunctionContext, name: []const u8, position: usize) bool {
        for (self.lifetime_events[0..self.lifetime_event_count]) |event| {
            if (event.position == position and (event.kind == .write or event.kind == .output_write) and
                std.mem.eql(u8, event.name, name)) return true;
        }
        return false;
    }

    pub fn lastUse(self: *const FunctionContext, name: []const u8) usize {
        if (!self.lifetime_reuse) return std.math.maxInt(usize);
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) return self.lifetimes[index].last_use;
        }
        return std.math.maxInt(usize);
    }

    pub fn firstLive(self: *const FunctionContext, name: []const u8) usize {
        if (!self.lifetime_reuse) return 0;
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) return self.lifetimes[index].first_live;
        }
        return 0;
    }

    pub fn requireRegister(
        self: *FunctionContext,
        name: []const u8,
        reg: ?Register,
        vector_reg: ?ast.VectorRegister,
    ) bool {
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            const lifetime = &self.lifetimes[index];
            if (!std.mem.eql(u8, lifetime.name, name)) continue;
            if (!lifetime.automatic) {
                return lifetime.fixed_reg == reg and lifetime.fixed_vector_reg == vector_reg;
            }
            if ((lifetime.required_reg != null and lifetime.required_reg != reg) or
                (lifetime.required_vector_reg != null and lifetime.required_vector_reg != vector_reg))
            {
                return false;
            }
            lifetime.required_reg = reg;
            lifetime.required_vector_reg = vector_reg;
            return true;
        }
        return false;
    }

    pub fn requiredRegister(self: *const FunctionContext, name: []const u8) ?Register {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) return lifetime.required_reg;
        }
        return null;
    }

    pub fn requiredVectorRegister(self: *const FunctionContext, name: []const u8) ?ast.VectorRegister {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) return lifetime.required_vector_reg;
        }
        return null;
    }

    pub fn registerForbidden(self: *const FunctionContext, name: []const u8, reg: Register) bool {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) {
                return (lifetime.forbidden_scalar & registerBit(reg)) != 0;
            }
        }
        return false;
    }

    pub fn vectorRegisterForbidden(self: *const FunctionContext, name: []const u8, reg: ast.VectorRegister) bool {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) {
                return (lifetime.forbidden_vector & vectorRegisterBit(reg)) != 0;
            }
        }
        return false;
    }

    pub fn lookup(self: *const FunctionContext, name: []const u8) !Symbol {
        var i = self.symbol_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.symbols[i].name, name)) return self.symbols[i];
        }
        if (self.diagnostic) |diagnostic| diagnostic.symbol_name = name;
        return error.UnknownSymbol;
    }

    pub fn contains(self: *const FunctionContext, name: []const u8) bool {
        _ = self.lookup(name) catch return false;
        return true;
    }

    pub fn allocLabel(self: *FunctionContext) usize {
        const label = self.next_label;
        self.next_label += 1;
        return label;
    }

    pub fn pushScope(self: *FunctionContext) usize {
        return self.symbol_count;
    }

    pub fn popScope(self: *FunctionContext, scope: usize) void {
        self.symbol_count = scope;
    }

    pub fn allocRegister(self: *const FunctionContext, data_type: DataType, name: []const u8) !Register {
        if (isVectorType(data_type)) return error.ExpectedScalarType;
        if (self.requiredRegister(name)) |reg| {
            if ((self.function_forbidden_scalar & registerBit(reg)) != 0) {
                return error.AutomaticRegisterClobberedByCall;
            }
            if (self.registerForbidden(name, reg)) return error.AutomaticRegisterClobberedByCall;
            if (self.scalarLifetimeConflicts(name, reg)) return error.RegisterAlreadyInUse;
            return reg;
        }
        for (alloc_scalar_registers) |reg| {
            if ((self.function_forbidden_scalar & registerBit(reg)) != 0) continue;
            if (self.registerForbidden(name, reg)) continue;
            if (!self.scalarLifetimeConflicts(name, reg)) return reg;
        }
        return error.OutOfFreeRegisters;
    }

    pub fn allocExpressionRegister(self: *const FunctionContext) !Register {
        for (alloc_scalar_registers) |reg| {
            if ((self.function_forbidden_scalar & registerBit(reg)) != 0) continue;
            if (!self.isRegisterInUse(reg)) return reg;
        }
        return error.OutOfFreeRegistersInExpression;
    }

    pub fn pushExpressionTemporary(self: *FunctionContext, data_type: DataType) !struct { usize, Symbol } {
        if (self.expression_temporary_depth >= expression_temporary_names.len) {
            return error.ExpressionNestingTooDeep;
        }
        const scope = self.pushScope();
        const name = expression_temporary_names[self.expression_temporary_depth];
        self.expression_temporary_depth += 1;
        const symbol = Symbol{
            .name = name,
            .data_type = data_type,
            .reg = try self.allocExpressionRegister(),
            .constant = null,
            .first_live = self.statement_position,
        };
        try self.add(symbol);
        return .{ scope, symbol };
    }

    pub fn popExpressionTemporary(self: *FunctionContext, scope: usize) void {
        self.popScope(scope);
        self.expression_temporary_depth -= 1;
    }

    pub fn allocVectorRegister(self: *const FunctionContext, data_type: DataType, name: []const u8) !ast.VectorRegister {
        if (!isVectorType(data_type)) return error.ExpectedVectorType;
        if (self.requiredVectorRegister(name)) |reg| {
            if ((self.function_forbidden_vector & vectorRegisterBit(reg)) != 0) {
                return error.AutomaticRegisterClobberedByCall;
            }
            if (self.vectorRegisterForbidden(name, reg)) return error.AutomaticRegisterClobberedByCall;
            try validateVectorRegisterBinding(self, data_type, reg, name);
            return reg;
        }
        for (alloc_vector_registers) |reg| {
            if ((self.function_forbidden_vector & vectorRegisterBit(reg)) != 0) continue;
            if (self.vectorRegisterForbidden(name, reg)) continue;
            if (self.vectorLifetimeConflicts(name, reg)) continue;
            if (data_type == .vec32) {
                const second = nextVectorRegister(reg) orelse continue;
                if (@intFromEnum(second) >= 29) continue;
                if (self.vectorRegisterForbidden(name, second)) continue;
                if (self.vectorLifetimeConflicts(name, second)) continue;
            }
            return reg;
        }
        return error.OutOfFreeVectorRegisters;
    }

    pub fn isRegisterInUse(self: *const FunctionContext, reg: Register) bool {
        for (self.symbols[0..self.symbol_count]) |symbol| {
            if (symbol.last_use < self.statement_position) continue;
            if (symbol.reg) |symbol_reg| {
                if (symbol_reg == reg) return true;
            }
        }
        return false;
    }

    pub fn scalarLifetimeConflicts(self: *const FunctionContext, name: []const u8, reg: Register) bool {
        const first_live = self.firstLive(name);
        const last_use = self.lastUse(name);
        for (self.symbols[0..self.symbol_count]) |symbol| {
            const symbol_reg = symbol.reg orelse continue;
            if (symbol_reg != reg) continue;
            if (first_live <= symbol.last_use and symbol.first_live <= last_use) return true;
        }
        return false;
    }

    pub fn isVectorRegisterInUse(self: *const FunctionContext, reg: ast.VectorRegister) bool {
        for (self.symbols[0..self.symbol_count]) |symbol| {
            if (symbol.last_use < self.statement_position) continue;
            const symbol_reg = symbol.vector_reg orelse continue;
            if (symbol_reg == reg) return true;
            if (symbol.data_type == .vec32 and nextVectorRegister(symbol_reg) == reg) return true;
        }
        return false;
    }

    pub fn vectorLifetimeConflicts(self: *const FunctionContext, name: []const u8, reg: ast.VectorRegister) bool {
        const first_live = self.firstLive(name);
        const last_use = self.lastUse(name);
        for (self.symbols[0..self.symbol_count]) |symbol| {
            const symbol_reg = symbol.vector_reg orelse continue;
            const occupies = symbol_reg == reg or
                (symbol.data_type == .vec32 and nextVectorRegister(symbol_reg) == reg);
            if (occupies and first_live <= symbol.last_use and symbol.first_live <= last_use) return true;
        }
        return false;
    }
};

fn collectStatementLabels(context: *FunctionContext, statements: []const ast.Statement) void {
    for (statements) |statement| switch (statement) {
        .label => |name| context.addLifetimeLabel(name, 0, false),
        .exported_label => |name| context.addLifetimeLabel(name, 0, true),
        .ordered_block => |items| collectStatementLabels(context, items),
        .while_loop => |loop| collectStatementLabels(context, loop.statements),
        .do_while_loop => |loop| {
            collectStatementLabels(context, loop.statements);
            if (loop.delay_slot) |delay| collectStatementLabels(context, delay);
        },
        .labeled_block => |block| {
            collectStatementLabels(context, block.statements);
            if (block.exit_delay) |delay| collectStatementLabels(context, delay);
        },
        .if_statement => |branch| {
            if (branch.delay_slot) |delay| collectStatementLabels(context, delay);
            collectStatementLabels(context, branch.then_statements);
            if (branch.else_statements) |items| collectStatementLabels(context, items);
        },
        else => {},
    };
}

fn statementsContainUnstructuredControlFlow(statements: []const ast.Statement) bool {
    for (statements) |statement| switch (statement) {
        .asm_line => return true,
        .conditional_direct_goto => |branch| {
            if (branch.delay_slot) |delay| if (statementsContainUnstructuredControlFlow(delay)) return true;
        },
        .break_loop => |transfer| if (transfer.delay_slot) |delay| if (statementsContainUnstructuredControlFlow(delay)) return true,
        .while_loop => |loop| if (statementsContainUnstructuredControlFlow(loop.statements)) return true,
        .do_while_loop => |loop| {
            if (statementsContainUnstructuredControlFlow(loop.statements)) return true;
            if (loop.delay_slot) |delay| if (statementsContainUnstructuredControlFlow(delay)) return true;
        },
        .if_statement => |branch| {
            if (branch.delay_slot) |items| if (statementsContainUnstructuredControlFlow(items)) return true;
            if (statementsContainUnstructuredControlFlow(branch.then_statements)) return true;
            if (branch.else_statements) |items| if (statementsContainUnstructuredControlFlow(items)) return true;
        },
        .labeled_block => |block| {
            if (statementsContainUnstructuredControlFlow(block.statements)) return true;
            if (block.exit_delay) |delay| if (statementsContainUnstructuredControlFlow(delay)) return true;
        },
        .ordered_block => |items| if (statementsContainUnstructuredControlFlow(items)) return true,
        .builtin => |builtin| switch (builtin) {
            .tail => {},
            .return_from_function => |delay| if (delay) |items| {
                if (statementsContainUnstructuredControlFlow(items)) return true;
            },
            else => {},
        },
        else => {},
    };
    return false;
}

fn scanStatementLifetimes(context: *FunctionContext, statements: []const ast.Statement, position: *usize) void {
    for (statements) |statement| {
        position.* += 1;
        const current = position.*;
        switch (statement) {
            .var_decl => |decl| {
                if (decl.is_const) {
                    if (decl.value) |value| scanValueLifetime(context, value, current);
                    continue;
                }
                context.declareLifetime(
                    decl.name,
                    current,
                    decl.reg == null and decl.vector_reg == null,
                    decl.value != null or decl.allow_undefined_read,
                    decl.data_type,
                    decl.reg,
                    decl.vector_reg,
                );
                if (decl.value) |value| scanValueLifetime(context, value, current);
                if (decl.value != null or decl.allow_undefined_read) {
                    context.writeLifetime(decl.name, current);
                }
            },
            .assignment => |assignment| {
                scanValueLifetime(context, assignment.lhs, current);
                if (assignment.rhs) |rhs| scanValueLifetime(context, rhs, current);
                for (assignment.continuation) |step| scanValueLifetime(context, step.rhs, current);
                context.writeLifetime(assignment.destination, current);
            },
            .store => |store| {
                scanValueRefLifetime(context, store.address, current);
                scanValueRefLifetime(context, store.value, current);
                if (store.label_offset) |name| context.touchLifetime(name, current);
            },
            .call => |call| {
                for (call.arguments) |argument| scanValueRefLifetime(context, argument, current);
                if (call.delay_slot) |delay| scanStatementLifetimes(context, delay, position);
                context.addLifetimeCall(call.name, current, position.* + 1);
            },
            .builtin => |builtin| scanBuiltinLifetime(context, builtin, current, position),
            .label => |name| context.addLifetimeLabel(name, current, false),
            .exported_label => |name| context.addLifetimeLabel(name, current, true),
            .conditional_goto => |branch| {
                scanConditionLifetime(context, branch.condition, current);
                context.addLifetimeEdge(branch.target, current);
                if (branch.delay_slot) |delay| scanStatementLifetimes(context, delay, position);
            },
            .conditional_direct_goto => |branch| {
                scanConditionLifetime(context, branch.condition, current);
                for (branch.arguments) |argument| scanValueRefLifetime(context, argument, current);
                if (branch.delay_slot) |delay| scanStatementLifetimes(context, delay, position);
            },
            .goto => |branch| {
                context.addLifetimeEdge(branch.target, current);
                if (branch.delay_slot) |delay| scanStatementLifetimes(context, delay, position);
            },
            .break_loop => |transfer| if (transfer.delay_slot) |delay| scanStatementLifetimes(context, delay, position),
            .while_loop => |loop| {
                scanConditionLifetime(context, loop.condition, current);
                scanStatementLifetimes(context, loop.statements, position);
            },
            .do_while_loop => |loop| {
                scanStatementLifetimes(context, loop.statements, position);
                position.* += 1;
                scanConditionLifetime(context, loop.condition, position.*);
                if (loop.delay_slot) |delay| scanStatementLifetimes(context, delay, position);
            },
            .if_statement => |branch| {
                scanConditionLifetime(context, branch.condition, current);
                if (branch.delay_slot) |items| scanStatementLifetimes(context, items, position);
                scanStatementLifetimes(context, branch.then_statements, position);
                if (branch.else_statements) |items| scanStatementLifetimes(context, items, position);
            },
            .labeled_block => |block| {
                scanStatementLifetimes(context, block.statements, position);
                if (block.exit_delay) |delay| scanStatementLifetimes(context, delay, position);
            },
            .ordered_block => |items| scanStatementLifetimes(context, items, position),
            else => {},
        }
    }
}

pub fn countFlowStatements(statements: []const ast.Statement) usize {
    var count = statements.len;
    for (statements) |statement| count += switch (statement) {
        .call => |call| if (call.delay_slot) |delay| countFlowStatements(delay) else 0,
        .goto => |branch| if (branch.delay_slot) |delay| countFlowStatements(delay) else 0,
        .conditional_goto => |branch| if (branch.delay_slot) |delay| countFlowStatements(delay) else 0,
        .conditional_direct_goto => |branch| if (branch.delay_slot) |delay| countFlowStatements(delay) else 0,
        .break_loop => |transfer| if (transfer.delay_slot) |delay| countFlowStatements(delay) else 0,
        .while_loop => |loop| countFlowStatements(loop.statements),
        .do_while_loop => |loop| countFlowStatements(loop.statements) + 1 +
            (if (loop.delay_slot) |delay| countFlowStatements(delay) else 0),
        .if_statement => |branch| (if (branch.delay_slot) |items| countFlowStatements(items) else 0) +
            countFlowStatements(branch.then_statements) +
            (if (branch.else_statements) |items| countFlowStatements(items) else 0),
        .labeled_block => |block| countFlowStatements(block.statements) +
            (if (block.exit_delay) |delay| countFlowStatements(delay) else 0),
        .ordered_block => |items| countFlowStatements(items),
        .builtin => |builtin| switch (builtin) {
            .jump => |jump| if (jump.delay_slot) |delay| countFlowStatements(delay) else 0,
            .return_from_function => |delay| if (delay) |items| countFlowStatements(items) else 0,
            else => 0,
        },
        else => 0,
    };
    return count;
}

fn flowLabelPosition(context: *const FunctionContext, name: []const u8) usize {
    for (context.lifetime_labels[0..context.lifetime_label_count]) |label| {
        if (std.mem.eql(u8, label.name, name)) return label.position;
    }
    return 0;
}

fn addFlowSuccessor(context: *FunctionContext, position: usize, successor: usize) void {
    if (position == 0 or successor == 0) return;
    const count = context.flow_successor_counts[position];
    for (context.flow_successors[position][0..count]) |existing| if (existing == successor) return;
    if (count == 2) {
        context.analysis_error = error.AnalysisCapacityExceeded;
        return;
    }
    context.flow_successors[position][count] = successor;
    context.flow_successor_counts[position] += 1;
}

fn buildStatementFlow(
    context: *FunctionContext,
    statements: []const ast.Statement,
    position: *usize,
    continuation: usize,
) void {
    for (statements, 0..) |statement, statement_index| {
        if (context.analysis_error != null) return;
        position.* += 1;
        const current = position.*;
        const nested_count: usize = switch (statement) {
            .call => |call| if (call.delay_slot) |delay| countFlowStatements(delay) else 0,
            .goto => |branch| if (branch.delay_slot) |delay| countFlowStatements(delay) else 0,
            .conditional_goto => |branch| if (branch.delay_slot) |delay| countFlowStatements(delay) else 0,
            .conditional_direct_goto => |branch| if (branch.delay_slot) |delay| countFlowStatements(delay) else 0,
            .break_loop => |transfer| if (transfer.delay_slot) |delay| countFlowStatements(delay) else 0,
            .while_loop => |loop| countFlowStatements(loop.statements),
            .do_while_loop => |loop| countFlowStatements(loop.statements) + 1 +
                (if (loop.delay_slot) |delay| countFlowStatements(delay) else 0),
            .if_statement => |branch| (if (branch.delay_slot) |items| countFlowStatements(items) else 0) +
                countFlowStatements(branch.then_statements) +
                (if (branch.else_statements) |items| countFlowStatements(items) else 0),
            .labeled_block => |block| countFlowStatements(block.statements) +
                (if (block.exit_delay) |delay| countFlowStatements(delay) else 0),
            .ordered_block => |items| countFlowStatements(items),
            .builtin => |builtin| switch (builtin) {
                .jump => |jump| if (jump.delay_slot) |delay| countFlowStatements(delay) else 0,
                .return_from_function => |delay| if (delay) |items| countFlowStatements(items) else 0,
                else => 0,
            },
            else => 0,
        };
        const next = if (statement_index + 1 < statements.len) current + nested_count + 1 else continuation;
        switch (statement) {
            .call => |call| {
                if (call.delay_slot) |delay| {
                    addFlowSuccessor(context, current, current + 1);
                    buildStatementFlow(context, delay, position, next);
                } else addFlowSuccessor(context, current, next);
            },
            .goto => |branch| {
                const target = flowLabelPosition(context, branch.target);
                if (branch.delay_slot) |delay| {
                    addFlowSuccessor(context, current, current + 1);
                    buildStatementFlow(context, delay, position, target);
                } else addFlowSuccessor(context, current, target);
            },
            .conditional_goto => |branch| {
                const target = flowLabelPosition(context, branch.target);
                if (branch.delay_slot) |delay| {
                    const delay_start = current + 1;
                    addFlowSuccessor(context, current, delay_start);
                    buildStatementFlow(context, delay, position, next);
                    const delay_end = current + nested_count;
                    addFlowSuccessor(context, delay_end, target);
                } else {
                    addFlowSuccessor(context, current, next);
                    addFlowSuccessor(context, current, target);
                }
            },
            .conditional_direct_goto => |branch| {
                if (branch.delay_slot) |delay| {
                    addFlowSuccessor(context, current, current + 1);
                    buildStatementFlow(context, delay, position, next);
                } else addFlowSuccessor(context, current, next);
            },
            .while_loop => |loop| {
                if (nested_count != 0) addFlowSuccessor(context, current, current + 1);
                addFlowSuccessor(context, current, next);
                if (context.flow_loop_count >= context.flow_loops.len) {
                    context.analysis_error = error.AnalysisCapacityExceeded;
                    return;
                }
                context.flow_loops[context.flow_loop_count] = .{
                    .name = loop.label,
                    .continue_position = current,
                    .break_position = next,
                };
                context.flow_loop_count += 1;
                buildStatementFlow(context, loop.statements, position, current);
                context.flow_loop_count -= 1;
            },
            .do_while_loop => |loop| {
                const body_start = current + 1;
                const body_count = countFlowStatements(loop.statements);
                const condition_position = current + body_count + 1;
                addFlowSuccessor(context, current, if (loop.statements.len == 0) condition_position else body_start);
                if (context.flow_loop_count >= context.flow_loops.len) {
                    context.analysis_error = error.AnalysisCapacityExceeded;
                    return;
                }
                context.flow_loops[context.flow_loop_count] = .{
                    .name = loop.label,
                    .continue_position = condition_position,
                    .break_position = next,
                };
                context.flow_loop_count += 1;
                buildStatementFlow(context, loop.statements, position, condition_position);
                context.flow_loop_count -= 1;
                position.* += 1;
                if (loop.delay_slot) |delay| {
                    const delay_start = condition_position + 1;
                    addFlowSuccessor(context, condition_position, delay_start);
                    buildStatementFlow(context, delay, position, next);
                    const delay_end = current + nested_count;
                    addFlowSuccessor(context, delay_end, body_start);
                } else {
                    addFlowSuccessor(context, condition_position, body_start);
                    addFlowSuccessor(context, condition_position, next);
                }
            },
            .break_loop => |transfer| {
                const target = findFlowLoopTarget(context, transfer.label, false);
                if (transfer.delay_slot) |delay| {
                    addFlowSuccessor(context, current, current + 1);
                    buildStatementFlow(context, delay, position, target);
                } else addFlowSuccessor(context, current, target);
            },
            .continue_loop => |name| addFlowSuccessor(context, current, findFlowLoopTarget(context, name, true)),
            .if_statement => |branch| {
                const delay_count = if (branch.delay_slot) |items| countFlowStatements(items) else 0;
                const then_count = countFlowStatements(branch.then_statements);
                const then_start = current + delay_count + 1;
                const then_target = if (then_count != 0) then_start else next;
                const branch_position = if (delay_count != 0) current + delay_count else current;
                if (branch.delay_slot) |delay| {
                    addFlowSuccessor(context, current, current + 1);
                    buildStatementFlow(context, delay, position, then_target);
                } else addFlowSuccessor(context, current, then_target);
                buildStatementFlow(context, branch.then_statements, position, next);
                if (branch.else_statements) |items| {
                    if (items.len != 0) addFlowSuccessor(context, branch_position, then_start + then_count) else addFlowSuccessor(context, branch_position, next);
                    buildStatementFlow(context, items, position, next);
                } else addFlowSuccessor(context, branch_position, next);
            },
            .labeled_block => |block| {
                const body_count = countFlowStatements(block.statements);
                const exit_count = if (block.exit_delay) |delay| countFlowStatements(delay) else 0;
                const exit_start = if (exit_count != 0) current + body_count + 1 else next;
                if (nested_count != 0) addFlowSuccessor(context, current, current + 1) else addFlowSuccessor(context, current, next);
                if (context.flow_loop_count >= context.flow_loops.len) {
                    context.analysis_error = error.AnalysisCapacityExceeded;
                    return;
                }
                context.flow_loops[context.flow_loop_count] = .{
                    .name = block.label,
                    .continue_position = 0,
                    .break_position = exit_start,
                };
                context.flow_loop_count += 1;
                buildStatementFlow(context, block.statements, position, exit_start);
                context.flow_loop_count -= 1;
                if (block.exit_delay) |delay| buildStatementFlow(context, delay, position, next);
            },
            .ordered_block => |items| {
                if (nested_count != 0) addFlowSuccessor(context, current, current + 1) else addFlowSuccessor(context, current, next);
                buildStatementFlow(context, items, position, next);
            },
            .builtin => |builtin| switch (builtin) {
                .jump => |jump| if (jump.delay_slot) |delay| {
                    addFlowSuccessor(context, current, current + 1);
                    buildStatementFlow(context, delay, position, 0);
                },
                .indirect_call => |call| {
                    addFlowSuccessor(context, current, next);
                    if (call.delay_slot) |delay| buildStatementFlow(context, delay, position, next);
                },
                .return_from_function => |delay| if (delay) |items| {
                    addFlowSuccessor(context, current, current + 1);
                    buildStatementFlow(context, items, position, 0);
                },
                .direct_goto, .tail => {},
                else => addFlowSuccessor(context, current, next),
            },
            else => addFlowSuccessor(context, current, next),
        }
    }
}

fn findFlowLoopTarget(context: *FunctionContext, name: ?[]const u8, want_continue: bool) usize {
    var index = context.flow_loop_count;
    while (index > 0) {
        index -= 1;
        const loop = context.flow_loops[index];
        if (name) |requested| {
            const actual = loop.name orelse continue;
            if (!std.mem.eql(u8, requested, actual)) continue;
        }
        return if (want_continue) loop.continue_position else loop.break_position;
    }
    context.lifetime_reuse = false;
    return 0;
}

fn scanConditionLifetime(context: *FunctionContext, condition: ast.Condition, position: usize) void {
    context.touchLifetime(condition.lhs, position);
    scanValueLifetime(context, condition.rhs, position);
}

fn scanValueRefLifetime(context: *FunctionContext, value: ast.ValueRef, position: usize) void {
    switch (value) {
        .ident, .bit_cast => |name| context.touchLifetime(name, position),
        .vector_access => |access| context.touchLifetime(access.name, position),
        .number => {},
    }
}

fn scanValueLifetime(context: *FunctionContext, value: ast.Value, position: usize) void {
    switch (value) {
        .ident => |name| context.touchLifetime(name, position),
        .vector_access => |access| context.touchLifetime(access.name, position),
        .vector_operation => |operation| {
            context.touchLifetime(operation.lhs.name, position);
            context.touchLifetime(operation.rhs.name, position);
        },
        .vector_shift => |shift| context.touchLifetime(shift.source.name, position),
        .scalar_comparison => |comparison| {
            scanValueRefLifetime(context, comparison.lhs, position);
            scanValueRefLifetime(context, comparison.rhs, position);
        },
        .signed_less_than => |comparison| {
            scanValueRefLifetime(context, comparison.lhs, position);
            scanValueRefLifetime(context, comparison.rhs, position);
        },
        .bit_cast => |source| scanValueRefLifetime(context, source, position),
        .load => |load| {
            scanValueRefLifetime(context, load.address, position);
            if (load.label_offset) |name| context.touchLifetime(name, position);
        },
        .scalar_expression => |expression| {
            scanValueLifetime(context, expression.lhs, position);
            scanValueLifetime(context, expression.rhs, position);
        },
        else => {},
    }
}

fn scanBuiltinLifetime(context: *FunctionContext, builtin: ast.Builtin, position: usize, next: *usize) void {
    switch (builtin) {
        .tail => |tail| {
            for (tail.arguments) |argument| scanValueRefLifetime(context, argument, position);
            if (tail.delay_slot) |delay| scanStatementLifetimes(context, delay, next);
        },
        .jump => |jump| {
            scanValueRefLifetime(context, jump.address, position);
            if (jump.delay_slot) |delay| scanStatementLifetimes(context, delay, next);
        },
        .direct_goto => |branch| {
            for (branch.arguments) |argument| scanValueRefLifetime(context, argument, position);
            if (branch.delay_slot) |delay| scanStatementLifetimes(context, delay, next);
        },
        .return_from_function => |delay| if (delay) |items| scanStatementLifetimes(context, items, next),
        .write_vector_control => |item| scanValueRefLifetime(context, item.value, position),
        .vector_memory => |item| {
            switch (item.operation) {
                .load16, .load32, .load64, .load128, .load_packed_signed, .load_packed_unsigned, .load_quad_lane, .load_right, .load_transpose => context.writeLifetime(item.vector.name, position),
                .store16, .store32, .store64, .store128, .store_packed_signed, .store_packed_unsigned, .store_right => context.touchLifetime(item.vector.name, position),
            }
            scanValueRefLifetime(context, item.address, position);
        },
        .hardware_write => |item| scanValueRefLifetime(context, item.value, position),
        else => {},
    }
}

fn applyCallRequirements(
    context: *FunctionContext,
    functions: []const ast.Function,
    statements: []const ast.Statement,
    position: *usize,
) !void {
    for (statements) |*statement_ptr| {
        const statement = statement_ptr.*;
        if (context.diagnostic) |diagnostic| diagnostic.selectStatement(context.functions, statement_ptr);
        position.* += 1;
        const current = position.*;
        switch (statement) {
            .call => |call| {
                if (call.module == null) {
                    if (findFunction(functions, call.name)) |function| {
                        if (call.arguments.len == function.parameters.len) {
                            for (call.arguments, function.parameters, 0..) |argument, parameter, parameter_index| {
                                switch (argument) {
                                    .ident => |name| {
                                        if (context.hasLifetime(name)) {
                                            if (!context.requireRegister(name, parameter.reg, parameter.vector_reg)) {
                                                addParameterSetupClobber(context, current, parameter);
                                            }
                                            var visited: [1024]ParameterWriteVisit = undefined;
                                            var visited_count: usize = 0;
                                            const body_writes_parameter = functionParameterIsWritten(
                                                functions,
                                                function,
                                                parameter_index,
                                                &visited,
                                                &visited_count,
                                            );
                                            const contract_writes_parameter = function.external and
                                                ((parameter.reg != null and
                                                    std.mem.indexOfScalar(ast.Register, function.clobber_regs, parameter.reg.?) != null) or
                                                    (parameter.vector_reg != null and
                                                        std.mem.indexOfScalar(ast.VectorRegister, function.clobber_vector_regs, parameter.vector_reg.?) != null));
                                            if (body_writes_parameter or contract_writes_parameter) {
                                                context.writeOutputLifetime(name, current);
                                            }
                                        } else {
                                            addParameterSetupClobber(context, current, parameter);
                                        }
                                    },
                                    .number => addParameterSetupClobber(context, current, parameter),
                                    else => {},
                                }
                            }
                        }
                    }
                }
                if (call.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position);
            },
            .goto => |branch| if (branch.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position),
            .conditional_goto => |branch| if (branch.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position),
            .conditional_direct_goto => |branch| {
                if (branch.typed and branch.target.module == null) {
                    if (findFunction(functions, branch.target.name)) |function| {
                        if (branch.arguments.len == function.parameters.len) {
                            for (branch.arguments, function.parameters) |argument, parameter| {
                                switch (argument) {
                                    .ident => |name| {
                                        if (context.hasLifetime(name)) {
                                            if (!context.requireRegister(name, parameter.reg, parameter.vector_reg)) {
                                                addParameterSetupClobber(context, current, parameter);
                                            }
                                        } else {
                                            addParameterSetupClobber(context, current, parameter);
                                        }
                                    },
                                    .number => addParameterSetupClobber(context, current, parameter),
                                    else => {},
                                }
                            }
                        }
                    }
                }
                if (branch.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position);
            },
            .break_loop => |transfer| if (transfer.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position),
            .while_loop => |loop| try applyCallRequirements(context, functions, loop.statements, position),
            .do_while_loop => |loop| {
                try applyCallRequirements(context, functions, loop.statements, position);
                position.* += 1;
                if (loop.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position);
            },
            .if_statement => |branch| {
                if (branch.delay_slot) |items| try applyCallRequirements(context, functions, items, position);
                try applyCallRequirements(context, functions, branch.then_statements, position);
                if (branch.else_statements) |items| try applyCallRequirements(context, functions, items, position);
            },
            .labeled_block => |block| {
                try applyCallRequirements(context, functions, block.statements, position);
                if (block.exit_delay) |delay| try applyCallRequirements(context, functions, delay, position);
            },
            .ordered_block => |items| try applyCallRequirements(context, functions, items, position),
            .builtin => |builtin| switch (builtin) {
                .direct_goto => |branch| {
                    if (branch.typed and branch.target.module == null) {
                        if (findFunction(functions, branch.target.name)) |function| {
                            if (branch.arguments.len == function.parameters.len) {
                                for (branch.arguments, function.parameters) |argument, parameter| switch (argument) {
                                    .ident => |name| if (context.hasLifetime(name)) {
                                        if (!context.requireRegister(name, parameter.reg, parameter.vector_reg)) {
                                            addParameterSetupClobber(context, current, parameter);
                                        }
                                    },
                                    else => {},
                                };
                            }
                        }
                    }
                    if (branch.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position);
                },
                .tail => |tail| {
                    if (tail.target.module == null) {
                        if (findFunction(functions, tail.target.name)) |function| {
                            if (tail.arguments.len == function.parameters.len) {
                                for (tail.arguments, function.parameters) |argument, parameter| switch (argument) {
                                    .ident => |name| if (context.hasLifetime(name)) {
                                        if (!context.requireRegister(name, parameter.reg, parameter.vector_reg)) {
                                            addParameterSetupClobber(context, current, parameter);
                                        }
                                    },
                                    else => {},
                                };
                            }
                        }
                    }
                    if (tail.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position);
                },
                .jump => |jump| if (jump.delay_slot) |delay| try applyCallRequirements(context, functions, delay, position),
                .return_from_function => |delay| if (delay) |items| try applyCallRequirements(context, functions, items, position),
                else => {},
            },
            else => {},
        }
    }
}

fn addParameterSetupClobber(
    context: *FunctionContext,
    position: usize,
    parameter: ast.Parameter,
) void {
    var scalar: u32 = 0;
    var vector: u32 = 0;
    if (parameter.reg) |reg| scalar |= registerBit(reg);
    if (parameter.vector_reg) |reg| {
        vector |= vectorRegisterBit(reg);
        if (parameter.data_type == .vec32) {
            if (nextVectorRegister(reg)) |second| vector |= vectorRegisterBit(second);
        }
    }
    context.addCallSetupClobber(position, scalar, vector);
}

pub const ParameterWriteVisit = struct { function: []const u8, parameter: usize };

fn externalFunctionWritesScalarParameter(function: ast.Function, reg: ast.Register) bool {
    if (std.mem.indexOfScalar(ast.Register, function.clobber_regs, reg) == null) return false;
    for (function.parameters) |parameter| {
        if (parameter.reg == reg) return true;
    }
    return false;
}

fn externalFunctionWritesVectorParameter(function: ast.Function, reg: ast.VectorRegister) bool {
    if (std.mem.indexOfScalar(ast.VectorRegister, function.clobber_vector_regs, reg) == null) return false;
    for (function.parameters) |parameter| {
        if (parameter.vector_reg == reg) return true;
    }
    return false;
}

pub fn functionParameterIsWritten(
    functions: []const ast.Function,
    function: ast.Function,
    parameter_index: usize,
    visited: *[1024]ParameterWriteVisit,
    visited_count: *usize,
) bool {
    if (parameter_index >= function.parameters.len or visited_count.* >= visited.len) return true;
    if (function.external) {
        const parameter = function.parameters[parameter_index];
        if (parameter.reg) |reg| {
            for (function.clobber_regs) |written| if (written == reg) return true;
        }
        if (parameter.vector_reg) |reg| {
            for (function.clobber_vector_regs) |written| if (written == reg) return true;
        }
    }
    for (visited[0..visited_count.*]) |item| {
        if (item.parameter == parameter_index and std.mem.eql(u8, item.function, function.name)) return false;
    }
    visited[visited_count.*] = .{ .function = function.name, .parameter = parameter_index };
    visited_count.* += 1;
    const name = function.parameters[parameter_index].name;
    return statementsWriteParameter(functions, function.statements, name, visited, visited_count);
}

fn statementsWriteParameter(
    functions: []const ast.Function,
    statements: []const ast.Statement,
    name: []const u8,
    visited: *[1024]ParameterWriteVisit,
    visited_count: *usize,
) bool {
    for (statements) |statement| switch (statement) {
        .assignment => |assignment| if (std.mem.eql(u8, assignment.destination, name)) return true,
        .call => |call| {
            if (call.module == null) if (findFunction(functions, call.name)) |callee| {
                for (call.arguments, 0..) |argument, argument_index| switch (argument) {
                    .ident => |argument_name| if (std.mem.eql(u8, argument_name, name) and
                        functionParameterIsWritten(functions, callee, argument_index, visited, visited_count)) return true,
                    else => {},
                };
            };
            if (call.delay_slot) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true;
        },
        .goto => |branch| if (branch.delay_slot) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true,
        .conditional_goto => |branch| if (branch.delay_slot) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true,
        .conditional_direct_goto => |branch| if (branch.delay_slot) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true,
        .break_loop => |transfer| if (transfer.delay_slot) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true,
        .while_loop => |loop| if (statementsWriteParameter(functions, loop.statements, name, visited, visited_count)) return true,
        .do_while_loop => |loop| {
            if (statementsWriteParameter(functions, loop.statements, name, visited, visited_count)) return true;
            if (loop.delay_slot) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true;
        },
        .if_statement => |branch| {
            if (branch.delay_slot) |items| if (statementsWriteParameter(functions, items, name, visited, visited_count)) return true;
            if (statementsWriteParameter(functions, branch.then_statements, name, visited, visited_count)) return true;
            if (branch.else_statements) |items| if (statementsWriteParameter(functions, items, name, visited, visited_count)) return true;
        },
        .labeled_block => |block| {
            if (statementsWriteParameter(functions, block.statements, name, visited, visited_count)) return true;
            if (block.exit_delay) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true;
        },
        .ordered_block => |items| if (statementsWriteParameter(functions, items, name, visited, visited_count)) return true,
        .builtin => |builtin| switch (builtin) {
            .vector_memory => |item| switch (item.operation) {
                .load16, .load32, .load64, .load128, .load_packed_signed, .load_packed_unsigned, .load_quad_lane, .load_right, .load_transpose => if (std.mem.eql(u8, item.vector.name, name)) return true,
                else => {},
            },
            .jump => |jump| if (jump.delay_slot) |delay| if (statementsWriteParameter(functions, delay, name, visited, visited_count)) return true,
            .return_from_function => |delay| if (delay) |items| if (statementsWriteParameter(functions, items, name, visited, visited_count)) return true,
            else => {},
        },
        else => {},
    };
    return false;
}

pub fn validateVectorRegisterBinding(
    context: *const FunctionContext,
    data_type: DataType,
    vector_reg: ast.VectorRegister,
    lifetime_name: ?[]const u8,
) !void {
    const first_conflicts = if (lifetime_name) |name|
        context.vectorLifetimeConflicts(name, vector_reg)
    else
        context.isVectorRegisterInUse(vector_reg);
    if (first_conflicts) return error.RegisterAlreadyInUse;
    if (data_type == .vec32) {
        const second = nextVectorRegister(vector_reg) orelse return error.InvalidVectorRegisterPair;
        const second_conflicts = if (lifetime_name) |name|
            context.vectorLifetimeConflicts(name, second)
        else
            context.isVectorRegisterInUse(second);
        if (second_conflicts) return error.RegisterAlreadyInUse;
    }
}

pub fn reserveTransposeBank(context: *FunctionContext, bank: Symbol, reg: ast.VectorRegister) !u32 {
    if (bank.automatic or @intFromEnum(reg) % 8 != 0) return error.TransposeRequiresRegisterBank;
    const mask = @as(u32, 0xff) << @as(u5, @intCast(@intFromEnum(reg)));
    for (context.symbols[0..context.symbol_count]) |symbol| {
        if (!symbol.automatic or symbol.last_use < context.statement_position) continue;
        if (symbol.vector_reg) |other| {
            var occupied = vectorRegisterBit(other);
            if (symbol.data_type == .vec32) occupied |= vectorRegisterBit(nextVectorRegister(other).?);
            if (occupied & mask != 0) return error.RegisterAlreadyInUse;
        }
    }
    // Explicit bank bindings remain usable; automatic allocation must leave
    // all eight implicitly written registers available after the transpose.
    context.function_forbidden_vector |= mask;
    return mask;
}

pub fn findFunction(functions: []const ast.Function, name: []const u8) ?ast.Function {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

pub fn isScalarRegister(reg: Register) bool {
    return switch (reg) {
        .zero,
        .at,
        .v0,
        .v1,
        .a0,
        .a1,
        .a2,
        .a3,
        .t0,
        .t1,
        .t2,
        .t3,
        .t4,
        .t5,
        .t6,
        .t7,
        .s0,
        .s1,
        .s2,
        .s3,
        .s4,
        .s5,
        .s6,
        .s7,
        .t8,
        .t9,
        .k0,
        .k1,
        .gp,
        .sp,
        .fp,
        .ra,
        => true,
    };
}

pub fn isVectorType(data_type: DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

pub fn vectorRegisterForView(symbol: Symbol, view: ?ast.VectorView) !ast.VectorRegister {
    const reg = symbol.vector_reg orelse return error.ExpectedVectorRegister;
    if (symbol.data_type == .vec16) return reg;
    if (symbol.data_type != .vec32) return error.ExpectedVectorType;
    return switch (view orelse return reg) {
        .sint, .uint => reg,
        .sfract, .ufract => nextVectorRegister(reg) orelse error.InvalidVectorRegisterPair,
    };
}

test "analysis exposes transitive write contracts without emitting assembly" {
    var diagnostic: ?@import("parser.zig").Diagnostic = null;
    var program = try @import("source.zig").Program.parse(std.testing.allocator, "fn leaf(reg($t2) value: u32) { value += 1; } fn entry(reg($t2) value: u32) { leaf(value); }", &diagnostic);
    defer program.deinit();
    const registry = try FunctionClobberRegistry.init(program.functions, null);
    const leaf = registry.find("leaf").?;
    const entry = registry.find("entry").?;
    try std.testing.expect(leaf.scalar & registerBit(.t2) != 0);
    try std.testing.expect(entry.scalar & registerBit(.t2) != 0);
    try std.testing.expectEqual(@as(u32, 0), entry.vector);
}

test "lifetime analysis rejects an unassigned value before allocation" {
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var program = try @import("source.zig").Program.parse(std.testing.allocator, "fn entry() { reg value: u32; rsp.cp0.setSpStatus(value); }", &parse_diagnostic);
    defer program.deinit();
    var diagnostic: Diagnostic = .{};
    var context = FunctionContext{ .label_prefix = "entry", .functions = program.functions, .diagnostic = &diagnostic };
    const function = program.functions[0];
    try std.testing.expectError(error.RegisterReadBeforeAssignment, context.prepareLifetimes(program.functions, function.parameters, function.statements));
    try std.testing.expectEqualStrings("value", diagnostic.symbol_name.?);
    try std.testing.expectEqual(@as(usize, 0), context.symbol_count);
}
