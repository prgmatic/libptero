const std = @import("std");
const ast = @import("ast.zig");
const rspq = @import("rspq.zig");

const Register = ast.Register;
const DataType = ast.DataType;

const compiler_scratch: Register = .at;
const compiler_scratch_2: Register = .v1;
const command_return: Register = .k1;
const alloc_scalar_registers = [_]Register{
    .t0, .t1, .t2, .t3, .t4, .t5, .t6, .t7, .t8, .t9,
    .k0, .sp, .fp, .s0, .s1, .s2, .s3, .s4, .s5, .s6,
    .s7,
};
const alloc_vector_registers = [_]ast.VectorRegister{
    .v01, .v02, .v03, .v04, .v05, .v06, .v07,
    .v08, .v09, .v10, .v11, .v12, .v13, .v14,
    .v15, .v16, .v17, .v18, .v19, .v20, .v21,
    .v22, .v23, .v24, .v25, .v26, .v27, .v28,
};

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

pub const Diagnostic = struct {
    function_name: ?[]const u8 = null,
    symbol_name: ?[]const u8 = null,
};

pub const ExplainAllocation = struct {
    function_name: []const u8,
    symbol_name: []const u8,
    data_type: DataType,
    reg: ?Register,
    vector_reg: ?ast.VectorRegister,
    automatic: bool,
};

pub const ExplainWrites = struct {
    function_name: []const u8,
    scalar: u32,
    vector: u32,
};

pub const ExplainReport = struct {
    allocations: [2048]ExplainAllocation = undefined,
    allocation_count: usize = 0,
    writes: [1024]ExplainWrites = undefined,
    writes_count: usize = 0,

    fn addAllocation(self: *ExplainReport, allocation: ExplainAllocation) !void {
        if (self.allocation_count >= self.allocations.len) return error.TooManyExplainAllocations;
        self.allocations[self.allocation_count] = allocation;
        self.allocation_count += 1;
    }

    pub fn write(self: *const ExplainReport, writer: *std.Io.Writer) !void {
        try writer.writeAll("registers:\n");
        var current_function: ?[]const u8 = null;
        for (self.allocations[0..self.allocation_count]) |allocation| {
            if (current_function == null or !std.mem.eql(u8, current_function.?, allocation.function_name)) {
                current_function = allocation.function_name;
                try writer.print("  {s}:\n", .{allocation.function_name});
            }
            try writer.print("    {s}: {s} -> ", .{ allocation.symbol_name, @tagName(allocation.data_type) });
            if (allocation.reg) |reg| {
                try writer.writeAll(regName(reg));
            } else if (allocation.vector_reg) |reg| {
                try writer.print("${s}", .{vectorRegName(reg)});
                if (allocation.data_type == .vec32) {
                    try writer.print("/${s}", .{vectorRegName(nextVectorRegister(reg).?)});
                }
            }
            try writer.print(" ({s})\n", .{if (allocation.automatic) "automatic" else "fixed"});
        }
        if (self.allocation_count == 0) try writer.writeAll("  none\n");

        try writer.writeAll("writes:\n");
        for (self.writes[0..self.writes_count]) |entry| {
            try writer.print("  {s}:", .{entry.function_name});
            var any = false;
            for (std.enums.values(Register)) |reg| {
                if ((entry.scalar & registerBit(reg)) == 0) continue;
                try writer.print(" {s}", .{regName(reg)});
                any = true;
            }
            for (std.enums.values(ast.VectorRegister)) |reg| {
                if ((entry.vector & vectorRegisterBit(reg)) == 0) continue;
                try writer.print(" ${s}", .{vectorRegName(reg)});
                any = true;
            }
            if (!any) try writer.writeAll(" none");
            try writer.writeByte('\n');
        }
    }
};

pub fn write(writer: *std.Io.Writer, functions: []const ast.Function) !void {
    return writeWithDiagnostic(writer, functions, null);
}

pub fn writeWithDiagnostic(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    diagnostic: ?*Diagnostic,
) !void {
    return writeInternal(writer, functions, diagnostic, null);
}

pub fn writeWithExplain(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    diagnostic: ?*Diagnostic,
    explain: *ExplainReport,
) !void {
    return writeInternal(writer, functions, diagnostic, explain);
}

fn writeInternal(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    diagnostic: ?*Diagnostic,
    explain: ?*ExplainReport,
) !void {
    try writer.writeAll(".set noreorder\n");
    try writer.writeAll(".set noat\n");

    var clobbers = try FunctionClobberRegistry.init(functions, diagnostic);
    if (explain) |report| {
        for (functions) |function| {
            if (report.writes_count >= report.writes.len) return error.TooManyFunctions;
            const contract = clobbers.find(function.name) orelse return error.UnknownFunction;
            report.writes[report.writes_count] = .{
                .function_name = function.source_name,
                .scalar = contract.scalar,
                .vector = contract.vector,
            };
            report.writes_count += 1;
        }
    }
    const command_analysis = try rspq.analyzeCommands(functions);
    var top_level_context = FunctionContext{
        .label_prefix = "top_level",
        .clobbers = &clobbers,
        .functions = functions,
        .diagnostic = diagnostic,
        .explain = explain,
    };
    try writeStorageBlocks(writer, functions, &top_level_context);
    try writeCommandTable(writer, &command_analysis, &top_level_context);
    try writer.writeAll(".text\n\n");
    var emitted = [_]bool{false} ** 1024;
    if (functions.len > emitted.len) return error.TooManyFunctions;
    var tail_target = [_]bool{false} ** 1024;
    for (functions) |function| {
        if (function.statements.len == 0) continue;
        const builtin = switch (function.statements[function.statements.len - 1]) {
            .builtin => |builtin| builtin,
            else => continue,
        };
        const target = switch (builtin) {
            .tail => |tail| tail.target,
            else => continue,
        };
        if (target.module != null) return error.UnresolvedModuleCall;
        for (functions, 0..) |candidate, target_index| {
            if (!std.mem.eql(u8, candidate.name, target.name)) continue;
            tail_target[target_index] = true;
            break;
        } else return error.UnknownFunction;
    }
    for (functions, 0..) |_, function_index| {
        if (tail_target[function_index]) continue;
        writeFunction(writer, functions, &top_level_context, &emitted, function_index) catch |err| {
            if (diagnostic) |value| value.function_name = functions[function_index].source_name;
            return err;
        };
    }
    for (functions, 0..) |_, function_index| {
        writeFunction(writer, functions, &top_level_context, &emitted, function_index) catch |err| {
            if (diagnostic) |value| value.function_name = functions[function_index].source_name;
            return err;
        };
    }
    try writeCommandManifest(writer, functions, &command_analysis);
}

pub fn writeInterface(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    diagnostic: ?*Diagnostic,
) !void {
    const contracts = try FunctionClobberRegistry.init(functions, diagnostic);
    for (functions) |function| {
        if (!function.public or !function.export_symbol or function.external or function.inline_call) continue;
        const interface_name = function.source_name;
        const contract = contracts.find(function.name) orelse return error.UnknownFunction;
        try writer.print("// @zsp-symbol {s} {s}\n", .{ interface_name, function.name });
        try writer.print("pub extern fn {s}(", .{interface_name});
        for (function.parameters, 0..) |parameter, index| {
            if (index != 0) try writer.writeAll(", ");
            if (parameter.reg) |reg| {
                try writer.print("reg({s}) ", .{regName(reg)});
            } else if (parameter.vector_reg) |reg| {
                try writer.print("reg(${s}) ", .{vectorRegName(reg)});
            }
            try writer.print("{s}: {s}", .{ parameter.name, @tagName(parameter.data_type) });
        }
        try writer.writeAll(") writes(");
        var wrote_register = false;
        for (std.enums.values(Register)) |reg| {
            if ((contract.scalar & registerBit(reg)) == 0) continue;
            if (wrote_register) try writer.writeAll(", ");
            try writer.writeAll(regName(reg));
            wrote_register = true;
        }
        for (std.enums.values(ast.VectorRegister)) |reg| {
            if ((contract.vector & vectorRegisterBit(reg)) == 0) continue;
            if (wrote_register) try writer.writeAll(", ");
            try writer.print("${s}", .{vectorRegName(reg)});
            wrote_register = true;
        }
        try writer.writeByte(')');
        if (function.no_return) try writer.writeAll(" noreturn");
        try writer.writeAll(";\n\n");
    }
}

fn writeFunction(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    top_level_context: *FunctionContext,
    emitted: []bool,
    function_index: usize,
) !void {
    if (emitted[function_index]) return;
    emitted[function_index] = true;
    const function = functions[function_index];
    if (function.external) return;
    if (!function.inline_call) {
        const terminal_jump = function.statements.len != 0 and switch (function.statements[function.statements.len - 1]) {
            .builtin => |builtin| switch (builtin) {
                .direct_goto, .tail, .jump, .return_from_function => true,
                else => false,
            },
            else => false,
        };
        const saves_command_return = function.command_indices.len != 0 and
            statementsContainEmittedCall(functions, function.statements);
        if ((function.export_symbol or function.command_indices.len != 0) and function.emit_label) {
            try writer.print(".globl {s}\n", .{function.name});
        }
        if (function.emit_label) {
            try writer.print("{s}:\n", .{function.name});
        }
        if (saves_command_return and !function.no_return and !terminal_jump) {
            try writer.print("  or {s}, {s}, {s}\n", .{
                regName(command_return), regName(.ra), regName(.zero),
            });
        }
        var function_context = top_level_context.child(function.name);
        function_context.explain_function_name = function.source_name;
        const context = if (function.emit_label) &function_context else top_level_context;
        if (function.emit_label) {
            if (top_level_context.clobbers.?.find(function.name)) |function_clobber| {
                context.function_forbidden_scalar = function_clobber.forbidden_scalar;
                context.function_forbidden_vector = function_clobber.forbidden_vector;
            }
            try context.prepareLifetimes(functions, function.parameters, function.statements);
        }
        if (function.statements.len != 0) switch (function.statements[function.statements.len - 1]) {
            .builtin => |terminal| switch (terminal) {
                .tail => |tail| {
                    if (tail.target.module != null) return error.UnresolvedModuleCall;
                    const target_index = findFunctionIndex(functions, tail.target.name) orelse return error.UnknownFunction;
                    if (!functions[target_index].external and !functions[target_index].inline_call and !emitted[target_index]) {
                        context.omitted_tail_target = tail.target.name;
                        context.omitted_tail_position = countFlowStatements(function.statements);
                    }
                },
                else => {},
            },
            else => {},
        };
        try bindParameters(context, function.parameters);
        try writeStatements(writer, functions, context, function.statements);
        if (!function.no_return and !terminal_jump) {
            if (function.command_indices.len != 0) {
                try writer.print("  jr {s}\n", .{regName(if (saves_command_return) command_return else .ra)});
            } else {
                try writer.writeAll("  jr $ra\n");
            }
            try writer.writeAll("  nop\n");
        }
        try writer.writeByte('\n');
    }
    if (function.statements.len == 0) return;
    const builtin = switch (function.statements[function.statements.len - 1]) {
        .builtin => |builtin| builtin,
        else => return,
    };
    const target = switch (builtin) {
        .tail => |tail| tail.target,
        else => return,
    };
    if (target.module != null) return error.UnresolvedModuleCall;
    const target_index = findFunctionIndex(functions, target.name) orelse return error.UnknownFunction;
    if (functions[target_index].external or functions[target_index].inline_call) return;
    return writeFunction(writer, functions, top_level_context, emitted, target_index);
}

fn findFunctionIndex(functions: []const ast.Function, name: []const u8) ?usize {
    for (functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, name)) return index;
    }
    return null;
}

fn isContinuationPairAt(statements: []const ast.Statement, index: usize) bool {
    if (index + 1 >= statements.len or statements[index] != .call or
        statements[index + 1] != .builtin) return false;
    const call = statements[index].call;
    const following = statements[index + 1].builtin;
    return following == .tail and call.delay_slot == null and
        following.tail.delay_slot == null and following.tail.arguments.len == 0;
}

fn statementsContainEmittedCall(functions: []const ast.Function, statements: []const ast.Statement) bool {
    for (statements) |statement| switch (statement) {
        .call => |call| {
            if (call.module != null) return true;
            const callee = findFunction(functions, call.name) orelse return true;
            if (!callee.inline_call) return true;
            if (statementsContainEmittedCall(functions, callee.statements)) return true;
            if (call.delay_slot) |delay_slot| {
                if (statementsContainEmittedCall(functions, delay_slot)) return true;
            }
        },
        .if_statement => |branch| {
            if (branch.delay_slot) |delay_slot| if (statementsContainEmittedCall(functions, delay_slot)) return true;
            if (statementsContainEmittedCall(functions, branch.then_statements)) return true;
            if (branch.else_statements) |else_statements| {
                if (statementsContainEmittedCall(functions, else_statements)) return true;
            }
        },
        .while_loop => |loop| if (statementsContainEmittedCall(functions, loop.statements)) return true,
        .do_while_loop => |loop| {
            if (statementsContainEmittedCall(functions, loop.statements)) return true;
            if (loop.delay_slot) |delay| if (statementsContainEmittedCall(functions, delay)) return true;
        },
        .labeled_block => |block| {
            if (statementsContainEmittedCall(functions, block.statements)) return true;
            if (block.exit_delay) |delay| if (statementsContainEmittedCall(functions, delay)) return true;
        },
        .ordered_block => |ordered| if (statementsContainEmittedCall(functions, ordered)) return true,
        .goto => |branch| if (branch.delay_slot) |delay_slot| {
            if (statementsContainEmittedCall(functions, delay_slot)) return true;
        },
        .conditional_goto => |branch| if (branch.delay_slot) |delay_slot| {
            if (statementsContainEmittedCall(functions, delay_slot)) return true;
        },
        .conditional_direct_goto => |branch| if (branch.delay_slot) |delay_slot| {
            if (statementsContainEmittedCall(functions, delay_slot)) return true;
        },
        .break_loop => |transfer| if (transfer.delay_slot) |delay| {
            if (statementsContainEmittedCall(functions, delay)) return true;
        },
        .builtin => |builtin| switch (builtin) {
            .jump => |jump| if (jump.delay_slot) |delay_slot| {
                if (statementsContainEmittedCall(functions, delay_slot)) return true;
            },
            .direct_goto => |jump| if (jump.delay_slot) |delay_slot| {
                if (statementsContainEmittedCall(functions, delay_slot)) return true;
            },
            .return_from_function => |delay_slot| if (delay_slot) |return_statements| {
                if (statementsContainEmittedCall(functions, return_statements)) return true;
            },
            else => {},
        },
        else => {},
    };
    return false;
}

fn writeCommandManifest(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    analysis: *const rspq.CommandAnalysis,
) !void {
    var wrote_section = false;
    for (functions) |function| {
        if (function.command_indices.len == 0) continue;
        for (function.command_indices) |index| {
            const command = analysis.find(index).?;
            if (!wrote_section) {
                try writer.writeAll(".section .zsp_commands,\"\",@progbits\n");
                wrote_section = true;
            }
            try writer.print("  .word {s}\n  .byte {d}\n  .byte {d}\n  .short 0\n", .{
                function.name,
                index,
                command.size,
            });
        }
    }
    if (wrote_section) try writer.writeByte('\n');
}

fn writeCommandTable(
    writer: *std.Io.Writer,
    analysis: *const rspq.CommandAnalysis,
    context: *FunctionContext,
) !void {
    const name = analysis.table_name orelse return;

    try writer.writeAll(".data\n.balign 2\n");
    try writer.print("{s}:\n", .{name});
    for (analysis.entries[0..analysis.table_len]) |_| try writer.writeAll("  .short 0\n");
    try writer.writeAll(".section .zsp_command_table,\"\",@progbits\n");
    try writer.print("  .word {s}\n  .word {d}\n", .{ name, analysis.table_len });
    try writer.writeAll(".data\n");
    try writer.writeByte('\n');
    try context.add(.{
        .name = name,
        .data_type = .dmem,
        .reg = null,
        .constant = null,
        .data_label = name,
    });
}

fn bindParameters(context: *FunctionContext, parameters: []const ast.Parameter) !void {
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

const Symbol = struct {
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

const FunctionClobberRegistry = struct {
    entries: [1024]FunctionClobber = undefined,
    len: usize = 0,

    fn init(functions: []const ast.Function, diagnostic: ?*Diagnostic) !FunctionClobberRegistry {
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
                        if (target_function.external and (target.scalar & registerBit(reg)) != 0) {
                            return error.PinnedRegisterClobberedByExternalCall;
                        }
                        target.forbidden_scalar |= registerBit(reg);
                    }
                    if (lifetime.fixed_vector_reg) |reg| {
                        if ((call.setup_vector & vectorRegisterBit(reg)) != 0) {
                            return error.PinnedRegisterOverwrittenByCallArgument;
                        }
                        if (target_function.external and (target.vector & vectorRegisterBit(reg)) != 0) {
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
            for (result.entries[0..result.len]) |entry| {
                if ((entry.scalar & entry.forbidden_scalar) != 0 or
                    (entry.vector & entry.forbidden_vector) != 0)
                {
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

    fn find(self: *const FunctionClobberRegistry, name: []const u8) ?FunctionClobber {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    fn findPtr(self: *FunctionClobberRegistry, name: []const u8) ?*FunctionClobber {
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

fn registerBit(reg: Register) u32 {
    return @as(u32, 1) << @intFromEnum(reg);
}

fn vectorRegisterBit(reg: ast.VectorRegister) u32 {
    return @as(u32, 1) << @intFromEnum(reg);
}

fn allAutomaticScalarRegisters() u32 {
    var result: u32 = 0;
    for (alloc_scalar_registers) |reg| result |= registerBit(reg);
    return result;
}

fn allAutomaticVectorRegisters() u32 {
    var result: u32 = 0;
    for (alloc_vector_registers) |reg| result |= vectorRegisterBit(reg);
    return result;
}

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
            if (decl.is_const) continue;
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
    for (statements) |statement| {
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
                    clobber.vector |= vectorRegisterBit(reg);
                    if (decl.data_type == .vec32) {
                        clobber.vector |= vectorRegisterBit(nextVectorRegister(reg) orelse
                            return error.InvalidVectorRegisterPair);
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
                    clobber.scalar |= registerBit(reg);
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

fn isPureScalarExpression(value: ast.Value) bool {
    return switch (value) {
        .ident, .number => true,
        .scalar_expression => |expression| isPureScalarExpression(expression.lhs) and
            isPureScalarExpression(expression.rhs),
        else => false,
    };
}

fn valueReadsName(value: ast.Value, name: []const u8) bool {
    return switch (value) {
        .ident => |identifier| std.mem.eql(u8, identifier, name),
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

const LifetimeLabel = struct { name: []const u8, position: usize };
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

const FunctionContext = struct {
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

    fn add(self: *FunctionContext, symbol: Symbol) !void {
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

    fn child(self: *const FunctionContext, label_prefix: []const u8) FunctionContext {
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

    fn prepareLifetimes(
        self: *FunctionContext,
        functions: []const ast.Function,
        parameters: []const ast.Parameter,
        statements: []const ast.Statement,
    ) !void {
        self.lifetime_count = 0;
        self.lifetime_label_count = 0;
        self.lifetime_edge_count = 0;
        self.lifetime_call_count = 0;
        self.lifetime_event_count = 0;
        self.flow_loop_count = 0;
        self.statement_position = 0;
        self.lifetime_reuse = !statementsContainUnstructuredControlFlow(statements);
        if (!self.lifetime_reuse) return;
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
        if (!self.lifetime_reuse or position >= self.flow_successors.len) {
            self.lifetime_reuse = false;
            return;
        }
        self.extendBackwardEdgeLifetimes();
        self.flow_statement_count = position;
        @memset(self.flow_successor_counts[0 .. position + 1], 0);
        position = 0;
        buildStatementFlow(self, statements, &position, 0);
        position = 0;
        try applyCallRequirements(self, functions, statements, &position);
        try self.validateDefiniteAssignments();
        self.applyCallClobbers();
    }

    fn declareLifetime(
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
            self.lifetime_reuse = false;
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

    fn validateDefiniteAssignments(self: *const FunctionContext) !void {
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

    fn addLifetimeLabel(self: *FunctionContext, name: []const u8, position: usize) void {
        if (self.lifetime_label_count >= self.lifetime_labels.len) {
            self.lifetime_reuse = false;
            return;
        }
        self.lifetime_labels[self.lifetime_label_count] = .{ .name = name, .position = position };
        self.lifetime_label_count += 1;
    }

    fn addLifetimeEdge(self: *FunctionContext, target: []const u8, position: usize) void {
        if (self.lifetime_edge_count >= self.lifetime_edges.len) {
            self.lifetime_reuse = false;
            return;
        }
        self.lifetime_edges[self.lifetime_edge_count] = .{ .target = target, .position = position };
        self.lifetime_edge_count += 1;
    }

    fn addLifetimeCall(
        self: *FunctionContext,
        target: []const u8,
        position: usize,
        resume_position: usize,
    ) void {
        if (self.lifetime_call_count >= self.lifetime_calls.len) {
            self.lifetime_reuse = false;
            return;
        }
        self.lifetime_calls[self.lifetime_call_count] = .{
            .target = target,
            .position = position,
            .resume_position = resume_position,
        };
        self.lifetime_call_count += 1;
    }

    fn applyCallClobbers(self: *FunctionContext) void {
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

    fn addCallSetupClobber(self: *FunctionContext, position: usize, scalar: u32, vector: u32) void {
        for (self.lifetime_calls[0..self.lifetime_call_count]) |*call| {
            if (call.position != position) continue;
            call.setup_scalar |= scalar;
            call.setup_vector |= vector;
            return;
        }
    }

    fn hasLifetime(self: *const FunctionContext, name: []const u8) bool {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) return true;
        }
        return false;
    }

    fn extendBackwardEdgeLifetimes(self: *FunctionContext) void {
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

    fn touchLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        self.addLifetimeEvent(name, position, .read);
        self.extendLifetime(name, position);
    }

    fn writeLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        self.addLifetimeEvent(name, position, .write);
        self.startLifetime(name, position);
        self.extendLifetime(name, position);
    }

    fn writeOutputLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        self.addLifetimeEvent(name, position, .output_write);
        self.startLifetime(name, position);
        self.extendLifetime(name, position);
    }

    fn startLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) {
                self.lifetimes[index].first_live = @min(self.lifetimes[index].first_live, position);
                return;
            }
        }
    }

    fn extendLifetime(self: *FunctionContext, name: []const u8, position: usize) void {
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) {
                self.lifetimes[index].last_use = @max(self.lifetimes[index].last_use, position);
                return;
            }
        }
    }

    fn addLifetimeEvent(self: *FunctionContext, name: []const u8, position: usize, kind: LifetimeEventKind) void {
        if (self.lifetime_event_count >= self.lifetime_events.len) {
            self.lifetime_reuse = false;
            return;
        }
        self.lifetime_events[self.lifetime_event_count] = .{ .name = name, .position = position, .kind = kind };
        self.lifetime_event_count += 1;
    }

    fn valueLivesAcross(self: *const FunctionContext, name: []const u8, position: usize) bool {
        if (position == 0 or position > self.flow_statement_count) return false;
        var visited: [2049]bool = @splat(false);
        return self.valueReadBeforeWrite(name, position, &visited);
    }

    fn valueReadBeforeWrite(
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

    fn valueDefinedAt(self: *const FunctionContext, name: []const u8, position: usize) bool {
        for (self.lifetime_events[0..self.lifetime_event_count]) |event| {
            if (event.position == position and (event.kind == .write or event.kind == .output_write) and
                std.mem.eql(u8, event.name, name)) return true;
        }
        return false;
    }

    fn lastUse(self: *const FunctionContext, name: []const u8) usize {
        if (!self.lifetime_reuse) return std.math.maxInt(usize);
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) return self.lifetimes[index].last_use;
        }
        return std.math.maxInt(usize);
    }

    fn firstLive(self: *const FunctionContext, name: []const u8) usize {
        if (!self.lifetime_reuse) return 0;
        var index = self.lifetime_count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes[index].name, name)) return self.lifetimes[index].first_live;
        }
        return 0;
    }

    fn requireRegister(
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

    fn requiredRegister(self: *const FunctionContext, name: []const u8) ?Register {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) return lifetime.required_reg;
        }
        return null;
    }

    fn requiredVectorRegister(self: *const FunctionContext, name: []const u8) ?ast.VectorRegister {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) return lifetime.required_vector_reg;
        }
        return null;
    }

    fn registerForbidden(self: *const FunctionContext, name: []const u8, reg: Register) bool {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) {
                return (lifetime.forbidden_scalar & registerBit(reg)) != 0;
            }
        }
        return false;
    }

    fn vectorRegisterForbidden(self: *const FunctionContext, name: []const u8, reg: ast.VectorRegister) bool {
        for (self.lifetimes[0..self.lifetime_count]) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) {
                return (lifetime.forbidden_vector & vectorRegisterBit(reg)) != 0;
            }
        }
        return false;
    }

    fn lookup(self: *const FunctionContext, name: []const u8) !Symbol {
        var i = self.symbol_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.symbols[i].name, name)) return self.symbols[i];
        }
        return error.UnknownSymbol;
    }

    fn contains(self: *const FunctionContext, name: []const u8) bool {
        _ = self.lookup(name) catch return false;
        return true;
    }

    fn allocLabel(self: *FunctionContext) usize {
        const label = self.next_label;
        self.next_label += 1;
        return label;
    }

    fn pushScope(self: *FunctionContext) usize {
        return self.symbol_count;
    }

    fn popScope(self: *FunctionContext, scope: usize) void {
        self.symbol_count = scope;
    }

    fn allocRegister(self: *const FunctionContext, data_type: DataType, name: []const u8) !Register {
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

    fn allocExpressionRegister(self: *const FunctionContext) !Register {
        for (alloc_scalar_registers) |reg| {
            if ((self.function_forbidden_scalar & registerBit(reg)) != 0) continue;
            if (!self.isRegisterInUse(reg)) return reg;
        }
        return error.OutOfFreeRegistersInExpression;
    }

    fn pushExpressionTemporary(self: *FunctionContext, data_type: DataType) !struct { usize, Symbol } {
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

    fn popExpressionTemporary(self: *FunctionContext, scope: usize) void {
        self.popScope(scope);
        self.expression_temporary_depth -= 1;
    }

    fn allocVectorRegister(self: *const FunctionContext, data_type: DataType, name: []const u8) !ast.VectorRegister {
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

    fn isRegisterInUse(self: *const FunctionContext, reg: Register) bool {
        for (self.symbols[0..self.symbol_count]) |symbol| {
            if (symbol.last_use < self.statement_position) continue;
            if (symbol.reg) |symbol_reg| {
                if (symbol_reg == reg) return true;
            }
        }
        return false;
    }

    fn scalarLifetimeConflicts(self: *const FunctionContext, name: []const u8, reg: Register) bool {
        const first_live = self.firstLive(name);
        const last_use = self.lastUse(name);
        for (self.symbols[0..self.symbol_count]) |symbol| {
            const symbol_reg = symbol.reg orelse continue;
            if (symbol_reg != reg) continue;
            if (first_live <= symbol.last_use and symbol.first_live <= last_use) return true;
        }
        return false;
    }

    fn isVectorRegisterInUse(self: *const FunctionContext, reg: ast.VectorRegister) bool {
        for (self.symbols[0..self.symbol_count]) |symbol| {
            if (symbol.last_use < self.statement_position) continue;
            const symbol_reg = symbol.vector_reg orelse continue;
            if (symbol_reg == reg) return true;
            if (symbol.data_type == .vec32 and nextVectorRegister(symbol_reg) == reg) return true;
        }
        return false;
    }

    fn vectorLifetimeConflicts(self: *const FunctionContext, name: []const u8, reg: ast.VectorRegister) bool {
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
            .label => |name| context.addLifetimeLabel(name, current),
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

fn countFlowStatements(statements: []const ast.Statement) usize {
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
        context.lifetime_reuse = false;
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
                    context.lifetime_reuse = false;
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
                    context.lifetime_reuse = false;
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
                    context.lifetime_reuse = false;
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
        .ident => |name| context.touchLifetime(name, position),
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
                .load16, .load32, .load64, .load128, .load_packed_signed, .load_packed_unsigned => context.writeLifetime(item.vector.name, position),
                .store16, .store32, .store64, .store128 => context.touchLifetime(item.vector.name, position),
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
    for (statements) |statement| {
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
                                            if (functionParameterIsWritten(
                                                functions,
                                                function,
                                                parameter_index,
                                                &visited,
                                                &visited_count,
                                            )) context.writeOutputLifetime(name, current);
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

const ParameterWriteVisit = struct { function: []const u8, parameter: usize };

fn functionParameterIsWritten(
    functions: []const ast.Function,
    function: ast.Function,
    parameter_index: usize,
    visited: *[1024]ParameterWriteVisit,
    visited_count: *usize,
) bool {
    if (parameter_index >= function.parameters.len or visited_count.* >= visited.len) return true;
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
                .load16, .load32, .load64, .load128, .load_packed_signed, .load_packed_unsigned => if (std.mem.eql(u8, item.vector.name, name)) return true,
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

fn writeStatements(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    statements: []const ast.Statement,
) anyerror!void {
    var statement_index: usize = 0;
    while (statement_index < statements.len) : (statement_index += 1) {
        const statement = statements[statement_index];
        if (isContinuationPairAt(statements, statement_index)) {
            const call = statement.call;
            const following = statements[statement_index + 1].builtin.tail;
            if (call.module != null or following.target.module != null) {
                return error.UnresolvedModuleCall;
            }
            const callee = findFunction(functions, call.name) orelse return error.UnknownFunction;
            const continuation = findFunction(functions, following.target.name) orelse return error.UnknownFunction;
            if (callee.inline_call or continuation.parameters.len != 0) {
                return error.InvalidContinuationCall;
            }
            if (context.track_statement_position) context.statement_position += 2;
            if (context.omitted_tail_target != null and
                std.mem.eql(u8, context.omitted_tail_target.?, following.target.name) and
                context.omitted_tail_position == context.statement_position)
            {
                try writeCall(writer, functions, context, call);
            } else {
                try writeFunctionArguments(writer, functions, context, callee, call.arguments, true);
                try writer.print("  j {s}\n", .{call.name});
                try writer.print("  addiu $ra, $zero, %lo({s})\n", .{following.target.name});
            }
            statement_index += 1;
            continue;
        }
        if (context.track_statement_position) context.statement_position += 1;
        switch (statement) {
            .packed_struct_decl => {},
            .command_table_decl => {},
            .data_block => {},
            .bss_block => {},
            .state_block => {},
            .var_decl => |decl| try writeVarDecl(writer, context, decl),
            .assignment => |assignment| try writeAssignment(writer, context, assignment),
            .store => |store| try writeStore(writer, context, store),
            .call => |call| try writeCall(writer, functions, context, call),
            .builtin => |builtin| try writeBuiltin(writer, functions, context, builtin),
            .label => |name| try writer.print("LABEL_{s}_{s}_0:\n", .{ context.label_prefix, name }),
            .goto => |branch| {
                try writer.print("  {s} LABEL_{s}_{s}_0\n", .{
                    if (branch.encoding == .jump) "j" else "b",
                    context.label_prefix,
                    branch.target,
                });
                try writeConditionalDirectDelaySlot(writer, functions, context, branch.delay_slot);
            },
            .conditional_goto => |branch| {
                var inverse = branch.condition;
                inverse.op = switch (inverse.op) {
                    .eq => .ne,
                    .ne => .eq,
                    .lt => .ge,
                    .le => .gt,
                    .gt => .le,
                    .ge => .lt,
                };
                try writeConditionBranchFalse(writer, context, inverse, branch.target, 0, branch.delay_slot == null);
                if (branch.delay_slot) |delay_slot| {
                    try validateDelaySlot(delay_slot);
                    try writeStatements(writer, functions, context, delay_slot);
                }
            },
            .conditional_direct_goto => |branch| {
                if (branch.target.module != null) return error.UnresolvedModuleCall;
                if (branch.typed) {
                    const target = findFunction(functions, branch.target.name) orelse return error.UnknownFunction;
                    try writeFunctionArguments(writer, functions, context, target, branch.arguments, true);
                }
                const lhs = try context.lookup(branch.condition.lhs);
                const lhs_reg = lhs.reg orelse return error.ConditionLhsMustBeRegister;
                if (branch.condition.op != .eq and branch.condition.op != .ne) {
                    if (branch.condition.rhs == .number and branch.condition.rhs.number == 0 and
                        isSigned(lhs.data_type))
                    {
                        try writer.print("  {s} {s}, {s}\n", .{
                            switch (branch.condition.op) {
                                .lt => "bltz",
                                .le => "blez",
                                .gt => "bgtz",
                                .ge => "bgez",
                                else => unreachable,
                            },
                            regName(lhs_reg),
                            branch.target.name,
                        });
                        try writeConditionalDirectDelaySlot(writer, functions, context, branch.delay_slot);
                        continue;
                    }
                    if (branch.condition.rhs == .number) {
                        const immediate = branch.condition.rhs.number;
                        const adjusted = if (branch.condition.op == .gt or branch.condition.op == .le)
                            std.math.add(i64, immediate, 1) catch null
                        else
                            immediate;
                        if (adjusted) |value| {
                            if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
                                try writer.print("  {s} {s}, {s}, {d}\n", .{
                                    if (isSigned(lhs.data_type)) "slti" else "sltiu",
                                    regName(compiler_scratch),
                                    regName(lhs_reg),
                                    value,
                                });
                                try writer.print("  {s} {s}, {s}\n", .{
                                    switch (branch.condition.op) {
                                        .lt, .le => "bnez",
                                        .gt, .ge => "beqz",
                                        else => unreachable,
                                    },
                                    regName(compiler_scratch),
                                    branch.target.name,
                                });
                                try writeConditionalDirectDelaySlot(writer, functions, context, branch.delay_slot);
                                continue;
                            }
                        }
                    }
                    const rhs_name = switch (branch.condition.rhs) {
                        .ident => |name| name,
                        else => return error.ConditionalDirectGotoRequiresRegisterOperands,
                    };
                    const rhs = try context.lookup(rhs_name);
                    try expectSameType(lhs, rhs);
                    const rhs_reg = rhs.reg orelse return error.ConditionRhsMustBeRegisterOrNumber;
                    const reverse = branch.condition.op == .gt or branch.condition.op == .le;
                    try writer.print("  {s} {s}, {s}, {s}\n", .{
                        if (isSigned(lhs.data_type)) "slt" else "sltu",
                        regName(compiler_scratch),
                        regName(if (reverse) rhs_reg else lhs_reg),
                        regName(if (reverse) lhs_reg else rhs_reg),
                    });
                    try writer.print("  {s} {s}, {s}\n", .{
                        switch (branch.condition.op) {
                            .lt, .gt => "bnez",
                            .le, .ge => "beqz",
                            else => unreachable,
                        },
                        regName(compiler_scratch),
                        branch.target.name,
                    });
                    try writeConditionalDirectDelaySlot(writer, functions, context, branch.delay_slot);
                    continue;
                }
                var rhs_reg: ?Register = null;
                var rhs_immediate: ?i64 = null;
                switch (branch.condition.rhs) {
                    .number => |number| rhs_immediate = number,
                    .ident => |name| {
                        const rhs = try context.lookup(name);
                        try expectSameType(lhs, rhs);
                        rhs_reg = rhs.reg orelse return error.ConditionRhsMustBeRegisterOrNumber;
                    },
                    else => return error.ConditionRhsMustBeRegisterOrNumber,
                }
                if (rhs_immediate != null and rhs_immediate.? == 0) {
                    try writer.print("  {s} {s}, {s}\n", .{
                        if (branch.condition.op == .eq) "beqz" else "bnez",
                        regName(lhs_reg),
                        branch.target.name,
                    });
                } else {
                    if (rhs_reg == null) {
                        try loadImmediateInto(writer, compiler_scratch, rhs_immediate.?);
                        rhs_reg = compiler_scratch;
                    }
                    try writer.print("  {s} {s}, {s}, {s}\n", .{
                        if (branch.condition.op == .eq) "beq" else "bne",
                        regName(lhs_reg),
                        regName(rhs_reg.?),
                        branch.target.name,
                    });
                }
                try writeConditionalDirectDelaySlot(writer, functions, context, branch.delay_slot);
            },
            .break_loop => |transfer| try writeBreakTransfer(writer, functions, context, transfer),
            .continue_loop => |name| try writeLoopTransfer(writer, context, name, true),
            .while_loop => |loop| try writeWhile(writer, functions, context, loop),
            .do_while_loop => |loop| try writeDoWhile(writer, functions, context, loop),
            .labeled_block => |block| try writeLabeledBlock(writer, functions, context, block),
            .if_statement => |if_statement| try writeIf(writer, functions, context, if_statement),
            .ordered_block => |ordered| {
                try writer.writeAll("# zsp exact block begin\n");
                try writeStatements(writer, functions, context, ordered);
                try writer.writeAll("# zsp exact block end\n");
            },
            .asm_line => |asm_line| try writer.print("  {s}\n", .{asm_line}),
        }
    }
}

fn writeStorageBlocks(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
) !void {
    var packed_structs = PackedStructRegistry{};
    for (functions) |function| {
        for (function.statements) |statement| switch (statement) {
            .packed_struct_decl => |declaration| try packed_structs.add(declaration),
            else => {},
        };
    }
    inline for (.{ .data_block, .bss_block, .state_block }) |block_tag| {
        var offset: usize = 0;
        var wrote_section = false;
        for (functions) |function| for (function.statements) |statement| {
            if (std.meta.activeTag(statement) != block_tag) continue;
            const declarations = switch (statement) {
                .data_block => |items| items,
                .bss_block => |items| items,
                .state_block => |items| items,
                else => unreachable,
            };
            if (!wrote_section) {
                try writer.writeAll(switch (block_tag) {
                    .data_block => ".data\n",
                    .bss_block => ".bss\n",
                    .state_block => ".section .state,\"aw\",@nobits\n",
                    else => unreachable,
                });
                wrote_section = true;
            }
            for (declarations) |declaration| {
                const element_size = switch (declaration.storage_type) {
                    .scalar => |data_type| try scalarDataSize(data_type),
                    .packed_struct => |name| blk: {
                        break :blk try packed_structs.sizeOf(name);
                    },
                };
                const alignment: usize = switch (declaration.storage_type) {
                    .scalar => element_size,
                    .packed_struct => 1,
                };
                if (!declaration.external) {
                    offset = std.mem.alignForward(usize, offset, alignment);
                    if (alignment > 1) try writer.print(".balign {d}\n", .{alignment});
                    if (declaration.public) try writer.print(".globl {s}\n", .{declaration.name});
                    try writer.print("{s}:\n", .{declaration.name});
                }
                if (!declaration.external and !declaration.initialized) {
                    try writer.print("  .space {d}\n", .{declaration.array_len * element_size});
                } else if (!declaration.external) switch (declaration.storage_type) {
                    .scalar => |data_type| for (declaration.values) |value| {
                        try validateDataValue(data_type, value);
                        try writer.print("  {s} {d}\n", .{ dataDirective(data_type), value });
                    },
                    .packed_struct => |name| {
                        const layout = try packed_structs.lookup(name);
                        if (declaration.is_array) return error.PackedStructArraysUnsupported;
                        if (declaration.values.len != layout.fields.len) {
                            return error.IncorrectPackedStructInitializerCount;
                        }
                        for (declaration.values, layout.fields) |value, field| {
                            try validateDataValue(field.data_type, value);
                            try writer.print("  {s} {d}\n", .{ dataDirective(field.data_type), value });
                        }
                    },
                };
                if (!declaration.external and declaration.initialized) switch (declaration.storage_type) {
                    .scalar => {
                        const remaining = declaration.array_len - declaration.values.len;
                        if (remaining > 0) {
                            try writer.print("  .space {d}, 0\n", .{remaining * element_size});
                        }
                    },
                    .packed_struct => {},
                };
                try context.add(.{
                    .name = declaration.name,
                    .data_type = .dmem,
                    .reg = null,
                    .constant = null,
                    .data_label = declaration.name,
                });
                if (!declaration.external) offset += declaration.array_len * element_size;
            }
        };
        if (wrote_section) {
            if (block_tag == .state_block) try writer.writeAll(".balign 8\n");
            try writer.writeByte('\n');
        }
    }
}

const PackedStructRegistry = struct {
    declarations: [32]ast.PackedStructDecl = undefined,
    len: usize = 0,

    fn add(self: *PackedStructRegistry, declaration: ast.PackedStructDecl) !void {
        if (self.len >= self.declarations.len) return error.TooManyPackedStructs;
        if (self.find(declaration.name) != null) return error.SymbolAlreadyDefined;
        for (declaration.fields, 0..) |field, index| {
            for (declaration.fields[0..index]) |previous| {
                if (std.mem.eql(u8, field.name, previous.name)) return error.SymbolAlreadyDefined;
            }
        }
        self.declarations[self.len] = declaration;
        self.len += 1;
    }

    fn lookup(self: *const PackedStructRegistry, name: []const u8) !ast.PackedStructDecl {
        return self.find(name) orelse error.UnknownPackedStruct;
    }

    fn find(self: *const PackedStructRegistry, name: []const u8) ?ast.PackedStructDecl {
        for (self.declarations[0..self.len]) |declaration| {
            if (std.mem.eql(u8, declaration.name, name)) return declaration;
        }
        return null;
    }

    fn sizeOf(self: *const PackedStructRegistry, name: []const u8) !usize {
        const declaration = try self.lookup(name);
        var size: usize = 0;
        for (declaration.fields) |field| size += try scalarDataSize(field.data_type);
        return size;
    }
};

fn scalarDataSize(data_type: DataType) !usize {
    return switch (data_type) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .dmem => 4,
        .vec16, .vec32 => error.ExpectedScalarType,
    };
}

fn dataDirective(data_type: DataType) []const u8 {
    return switch (data_type) {
        .u8, .i8 => ".byte",
        .u16, .i16 => ".short",
        .u32, .i32, .dmem => ".word",
        .vec16, .vec32 => unreachable,
    };
}

fn validateDataValue(data_type: DataType, value: i64) !void {
    const valid = switch (data_type) {
        .u8 => value >= 0 and value <= std.math.maxInt(u8),
        .u16 => value >= 0 and value <= std.math.maxInt(u16),
        .u32 => value >= 0 and value <= std.math.maxInt(u32),
        .dmem => value >= 0 and value <= 4096,
        .i8 => value >= std.math.minInt(i8) and value <= std.math.maxInt(i8),
        .i16 => value >= std.math.minInt(i16) and value <= std.math.maxInt(i16),
        .i32 => value >= std.math.minInt(i32) and value <= std.math.maxInt(i32),
        .vec16, .vec32 => false,
    };
    if (!valid) return error.DataInitializerOutOfRange;
}

fn writeVarDecl(writer: *std.Io.Writer, context: *FunctionContext, decl: ast.VarDecl) !void {
    if (decl.is_const) {
        if (isVectorType(decl.data_type)) return error.VectorConstUnsupported;
        try context.add(.{
            .name = decl.name,
            .data_type = decl.data_type,
            .reg = null,
            .constant = try valueAsImmediate(context, decl.value orelse return error.ExpectedConstant),
        });
        return;
    }

    if (isVectorType(decl.data_type)) {
        if (decl.reg != null) return error.InvalidVectorRegister;
        const vector_reg = decl.vector_reg orelse try context.allocVectorRegister(decl.data_type, decl.name);
        try validateVectorRegisterBinding(context, decl.data_type, vector_reg, decl.name);
        if (decl.value) |value| {
            try writeVectorInitialValue(writer, context, vector_reg, decl.data_type, value);
        }
        try context.add(.{
            .name = decl.name,
            .data_type = decl.data_type,
            .reg = null,
            .vector_reg = vector_reg,
            .function_type = decl.function_type,
            .constant = null,
            .automatic = decl.vector_reg == null,
            .first_live = context.firstLive(decl.name),
            .last_use = context.lastUse(decl.name),
        });
        return;
    }

    if (decl.vector_reg != null) return error.InvalidScalarRegister;
    const reg = decl.reg orelse try context.allocRegister(decl.data_type, decl.name);
    if (!isScalarRegister(reg)) return error.InvalidScalarRegister;
    if (decl.is_reserved and reg != compiler_scratch_2) return error.InvalidReservedRegister;
    if ((!decl.is_reserved and reg == compiler_scratch_2) or reg == command_return) {
        return error.RegisterReservedForBackend;
    }
    if (context.scalarLifetimeConflicts(decl.name, reg)) return error.RegisterAlreadyInUse;
    if (decl.value) |value| switch (value) {
        .load => |load| {
            if (!isCompatibleScalarLoad(decl.data_type, load.data_type)) return error.RegisterTypeMismatch;
            try writeLoadInto(writer, context, reg, load);
        },
        .ident => |name| {
            const source = try context.lookup(name);
            if (source.reg) |source_reg| {
                try expectSameType(.{ .name = decl.name, .data_type = decl.data_type, .reg = reg, .constant = null }, source);
                try writer.print("  or {s}, {s}, {s}\n", .{
                    regName(reg), regName(source_reg), regName(.zero),
                });
            } else if (source.data_label) |label| {
                try loadDataAddress(writer, reg, label);
            } else {
                try loadImmediateInto(writer, reg, source.constant orelse return error.ExpectedConstant);
            }
        },
        .vector_control_read, .hardware_read, .scalar_comparison, .signed_less_than, .function_address, .data_address => try writeSet(
            writer,
            context,
            .{
                .name = decl.name,
                .data_type = decl.data_type,
                .reg = reg,
                .function_type = decl.function_type,
                .constant = null,
            },
            reg,
            value,
        ),
        else => try loadImmediateInto(writer, reg, try valueAsImmediate(context, value)),
    };
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

fn validateVectorRegisterBinding(
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

fn writeVectorInitialValue(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: ast.VectorRegister,
    data_type: DataType,
    value: ast.Value,
) !void {
    switch (value) {
        .load => |load| {
            if (load.data_type != data_type) return error.RegisterTypeMismatch;
            try writeVectorLoad(writer, context, destination, load);
        },
        .ident => |name| {
            const source = try context.lookup(name);
            if (source.data_type != data_type) return error.RegisterTypeMismatch;
            const source_reg = source.vector_reg orelse return error.ExpectedVectorRegister;
            try writeVectorOp(writer, .vor, destination, source_reg, source_reg, 0);
            if (data_type == .vec32) {
                try writeVectorOp(
                    writer,
                    .vor,
                    nextVectorRegister(destination).?,
                    nextVectorRegister(source_reg).?,
                    nextVectorRegister(source_reg).?,
                    0,
                );
            }
        },
        .vector_access => |access| {
            if (access.lane != null) return error.VectorLaneInitializationUnsupported;
            const source = try context.lookup(access.name);
            const source_reg = try vectorRegisterForView(source, access.view);
            if (data_type != .vec16 or source.data_type != .vec16) {
                return error.RegisterTypeMismatch;
            }
            try writeVectorOp(writer, .vor, destination, .v00, source_reg, access.element);
        },
        .vector_operation => |operation| {
            if (data_type != .vec16) return error.Vec32ViewRequired;
            const lhs = try vectorOperand(context, operation.lhs);
            const rhs = try vectorOperand(context, operation.rhs);
            if (lhs.data_type != .vec16 or rhs.data_type != .vec16) {
                return error.VectorMultiplyRequiresVec16Operands;
            }
            if (lhs.element != 0) return error.VectorSwizzleOnlyAllowedOnRhs;
            try writeEncodedVectorOp(
                writer,
                @tagName(operation.op),
                @intFromEnum(operation.op),
                destination,
                lhs.reg,
                rhs.reg,
                rhs.element,
            );
        },
        .vector_shift => |shift| {
            if (data_type != .vec16) return error.UnsupportedVectorShift;
            try writeNamedVectorShift(writer, context, destination, shift);
        },
        .accumulator_read => |part| {
            if (data_type != .vec16) return error.AccumulatorReadRequiresVec16;
            try writeEncodedVectorOp(
                writer,
                "vsar",
                0b011101,
                destination,
                .v00,
                .v00,
                @intFromEnum(part),
            );
        },
        .vector_control_read => return error.RegisterTypeMismatch,
        .hardware_read => return error.RegisterTypeMismatch,
        .scalar_comparison => return error.RegisterTypeMismatch,
        .signed_less_than => return error.RegisterTypeMismatch,
        .number => |number| {
            if (number != 0) return error.VectorImmediateUnsupported;
            try writeVectorOp(writer, .vxor, destination, destination, destination, 0);
            if (data_type == .vec32) {
                const fraction = nextVectorRegister(destination).?;
                try writeVectorOp(writer, .vxor, fraction, fraction, fraction, 0);
            }
        },
        .scalar_expression => return error.UnsupportedScalarExpressionTree,
        .function_address, .data_address => return error.RegisterTypeMismatch,
    }
}

fn writeAssignment(writer: *std.Io.Writer, context: *FunctionContext, assignment: ast.Assignment) !void {
    const destination = try context.lookup(assignment.destination);
    if (isVectorType(destination.data_type)) {
        if (assignment.lhs == .scalar_expression) {
            const expression = assignment.lhs.scalar_expression;
            if (expression.lhs == .scalar_expression or expression.rhs == .scalar_expression) {
                return error.UnsupportedVectorExpressionTree;
            }
            var flattened = assignment;
            flattened.lhs = expression.lhs;
            flattened.op = expression.op;
            flattened.rhs = expression.rhs;
            return writeVectorAssignment(writer, context, destination, flattened);
        }
        if (assignment.continuation.len != 0) return error.UnsupportedVectorExpressionTree;
        return writeVectorAssignment(writer, context, destination, assignment);
    }
    const destination_reg = destination.reg orelse return error.CannotAssignConst;

    switch (assignment.op) {
        .set => {
            if (assignment.rhs != null) return error.InvalidAssignment;
            if (assignment.lhs == .scalar_expression) {
                try writeScalarExpression(writer, context, destination, destination_reg, assignment.lhs.scalar_expression);
            } else {
                try writeSet(writer, context, destination, destination_reg, assignment.lhs);
            }
        },
        .bit_not => {
            if (assignment.rhs != null) return error.InvalidAssignment;
            try writeBitNot(writer, context, destination, destination_reg, assignment.lhs);
        },
        .negate => {
            if (assignment.rhs != null) return error.InvalidAssignment;
            try writeNegate(writer, context, destination, destination_reg, assignment.lhs);
        },
        else => {
            const rhs = assignment.rhs orelse return error.InvalidAssignment;
            try writeBinary(writer, context, destination, destination_reg, assignment.lhs, assignment.op, rhs);
        },
    }
    for (assignment.continuation) |step| {
        try writeBinary(
            writer,
            context,
            destination,
            destination_reg,
            .{ .ident = assignment.destination },
            step.op,
            step.rhs,
        );
    }
}

const VectorAluOp = enum(u6) {
    vadd = 0b010000,
    vsub = 0b010001,
    vaddc = 0b010100,
    vsubc = 0b010101,
    vand = 0b101000,
    vnor = 0b101011,
    vor = 0b101010,
    vxor = 0b101100,
};

fn writeVectorAssignment(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    assignment: ast.Assignment,
) !void {
    const destination_reg = destination.vector_reg orelse return error.ExpectedVectorRegister;
    if (assignment.lhs == .accumulator_read) {
        if (assignment.op != .set or assignment.rhs != null) return error.InvalidAssignment;
        if (assignment.destination_lane != null) return error.InvalidVectorLaneAssignment;
        const result_reg = try vectorRegisterForView(destination, assignment.destination_view);
        if (destination.data_type == .vec32 and assignment.destination_view == null) {
            return error.AccumulatorReadRequiresVec16;
        }
        return writeEncodedVectorOp(
            writer,
            "vsar",
            0b011101,
            result_reg,
            .v00,
            .v00,
            @intFromEnum(assignment.lhs.accumulator_read),
        );
    }
    if (assignment.lhs == .vector_operation) {
        if (assignment.op != .set or assignment.rhs != null) return error.InvalidAssignment;
        const operation = assignment.lhs.vector_operation;
        if (operation.op == .vrcp or operation.op == .vrcpl or operation.op == .vrcph or operation.op == .vmov) {
            const destination_lane = assignment.destination_lane orelse return error.VectorLaneOperationRequiresLane;
            const result_reg = try vectorRegisterForView(destination, assignment.destination_view);
            if (destination.data_type == .vec32 and assignment.destination_view == null) {
                return error.Vec32ViewRequired;
            }
            const source = try vectorOperand(context, operation.lhs);
            if (source.data_type != .vec16 or source.element < 8 or operation.lhs.lane == null) {
                return error.VectorLaneOperationRequiresLane;
            }
            return writeVectorLaneOp(
                writer,
                operation.op,
                result_reg,
                destination_lane + @as(u4, if (operation.explicit_lane_encoding) 8 else 0),
                source.reg,
                source.element,
            );
        }
        if (assignment.destination_lane != null) return error.InvalidVectorLaneAssignment;
        const lhs = try vectorOperand(context, operation.lhs);
        const rhs = try vectorOperand(context, operation.rhs);
        if (lhs.data_type != .vec16 or rhs.data_type != .vec16) {
            return error.VectorMultiplyRequiresVec16Operands;
        }
        if (lhs.element != 0) return error.VectorSwizzleOnlyAllowedOnRhs;
        const result_reg = try vectorRegisterForView(destination, assignment.destination_view);
        if (destination.data_type == .vec32 and assignment.destination_view == null) {
            return error.Vec32ViewRequired;
        }
        return writeEncodedVectorOp(
            writer,
            @tagName(operation.op),
            @intFromEnum(operation.op),
            result_reg,
            lhs.reg,
            rhs.reg,
            rhs.element,
        );
    }
    if (assignment.lhs == .vector_shift) {
        if (assignment.op != .set or assignment.rhs != null or assignment.destination_lane != null or
            (destination.data_type != .vec16 and assignment.destination_view == null))
        {
            return error.UnsupportedVectorShift;
        }
        return writeNamedVectorShift(
            writer,
            context,
            try vectorRegisterForView(destination, assignment.destination_view),
            assignment.lhs.vector_shift,
        );
    }
    if (assignment.destination_lane) |lane| {
        if (assignment.op != .set or assignment.rhs != null) return error.InvalidVectorLaneAssignment;
        const result_reg = try vectorRegisterForView(destination, assignment.destination_view);
        if (destination.data_type == .vec32 and assignment.destination_view == null) {
            return error.Vec32ViewRequired;
        }
        if (assignment.lhs == .load) {
            const load = assignment.lhs.load;
            if (load.data_type != .vec16) return error.PartialVectorMemoryRequiresVec16;
            const address_reg = try valueAsDmemReg(writer, context, load.address);
            return writeVectorLaneMemory(
                writer,
                true,
                result_reg,
                lane,
                address_reg,
                load.offset,
            );
        }
        const source_reg = switch (assignment.lhs) {
            .ident => |name| (try context.lookup(name)).reg orelse
                return error.VectorLaneSourceMustBeScalarRegister,
            .vector_access => |access| {
                const source = try vectorOperand(context, access);
                if (source.data_type != .vec16 or source.element < 8 or access.lane == null) {
                    return error.VectorLaneOperationRequiresLane;
                }
                return writeVectorLaneOp(
                    writer,
                    .vmov,
                    result_reg,
                    lane,
                    source.reg,
                    source.element,
                );
            },
            else => return error.VectorLaneSourceMustBeScalarRegister,
        };
        return writeMtc2(writer, source_reg, result_reg, lane);
    }
    if (assignment.op == .set and assignment.lhs == .number) {
        if (assignment.lhs.number != 0 or assignment.rhs != null) return error.VectorImmediateUnsupported;
        return writeVectorOp(writer, .vxor, destination_reg, destination_reg, destination_reg, 0);
    }
    const lhs_operand = switch (assignment.lhs) {
        .ident => |name| try vectorOperand(context, .{ .name = name }),
        .vector_access => |access| try vectorOperand(context, access),
        .vector_operation => return error.InvalidAssignment,
        .vector_shift => return error.InvalidAssignment,
        .accumulator_read => return error.InvalidAssignment,
        .vector_control_read => return error.InvalidAssignment,
        .hardware_read => return error.InvalidAssignment,
        .scalar_comparison => return error.InvalidAssignment,
        .signed_less_than => return error.InvalidAssignment,
        .scalar_expression => return error.UnsupportedVectorExpressionTree,
        .function_address, .data_address => return error.RegisterTypeMismatch,
        .number => return error.VectorImmediateUnsupported,
        .load => |load| {
            if (assignment.op != .set or assignment.rhs != null) return error.InvalidAssignment;
            if (load.data_type != destination.data_type) return error.RegisterTypeMismatch;
            return writeVectorLoad(writer, context, destination_reg, load);
        },
    };
    const destination_type: DataType = if (assignment.destination_view != null) .vec16 else destination.data_type;
    if (lhs_operand.data_type != destination_type) return error.RegisterTypeMismatch;
    const destination_view_reg = try vectorRegisterForView(destination, assignment.destination_view);
    const lhs_reg = lhs_operand.reg;

    if (assignment.op == .set) {
        if (assignment.rhs != null) return error.InvalidAssignment;
        try writeVectorOp(
            writer,
            .vor,
            destination_view_reg,
            if (lhs_operand.element == 0) lhs_reg else .v00,
            lhs_reg,
            lhs_operand.element,
        );
        if (destination_type == .vec32) {
            try writeVectorOp(
                writer,
                .vor,
                nextVectorRegister(destination_reg).?,
                nextVectorRegister(lhs_reg).?,
                nextVectorRegister(lhs_reg).?,
                0,
            );
        }
        return;
    }

    if (assignment.op == .bit_not) {
        if (assignment.rhs != null) return error.InvalidAssignment;
        try writeVectorOp(writer, .vnor, destination_view_reg, lhs_reg, lhs_reg, lhs_operand.element);
        if (destination_type == .vec32) {
            try writeVectorOp(
                writer,
                .vnor,
                nextVectorRegister(destination_reg).?,
                nextVectorRegister(lhs_reg).?,
                nextVectorRegister(lhs_reg).?,
                0,
            );
        }
        return;
    }

    if (assignment.op == .logical_shift_right or assignment.op == .shift_right or assignment.op == .shift_left) {
        const amount = switch (assignment.rhs orelse return error.InvalidAssignment) {
            .number => |number| number,
            else => return error.UnsupportedVectorShift,
        };
        if (destination_type != .vec16) return error.UnsupportedVectorShift;
        const shift_reg: ast.VectorRegister = .v31;
        if ((assignment.op == .logical_shift_right or assignment.op == .shift_right) and amount >= 1 and amount <= 8) {
            const op: ast.VectorOp = if (assignment.op == .shift_right) .vmudm else .vmudl;
            return writeEncodedVectorOp(
                writer,
                if (assignment.op == .shift_right) "vsra" else "vsrl",
                @intFromEnum(op),
                destination_view_reg,
                lhs_reg,
                shift_reg,
                @intCast(7 + amount),
            );
        }
        if (assignment.op == .shift_left and amount >= 8 and amount <= 15) {
            return writeEncodedVectorOp(
                writer,
                "vsll8",
                @intFromEnum(ast.VectorOp.vmudn),
                destination_view_reg,
                lhs_reg,
                shift_reg,
                @intCast(23 - amount),
            );
        }
        return error.UnsupportedVectorShift;
    }

    const rhs_value = assignment.rhs orelse return error.InvalidAssignment;
    const rhs_operand = switch (rhs_value) {
        .ident => |name| try vectorOperand(context, .{ .name = name }),
        .vector_access => |access| try vectorOperand(context, access),
        else => return error.VectorImmediateUnsupported,
    };
    if (rhs_operand.data_type != destination_type) return error.RegisterTypeMismatch;
    if (lhs_operand.element != 0) return error.VectorSwizzleOnlyAllowedOnRhs;
    const rhs_reg = rhs_operand.reg;
    const element = rhs_operand.element;

    if (destination_type == .vec32) {
        const destination_fraction = nextVectorRegister(destination_reg).?;
        const lhs_fraction = nextVectorRegister(lhs_reg).?;
        const rhs_fraction = nextVectorRegister(rhs_reg).?;
        switch (assignment.op) {
            .add => {
                try writeVectorOp(writer, .vaddc, destination_fraction, lhs_fraction, rhs_fraction, element);
                try writeVectorOp(writer, .vadd, destination_reg, lhs_reg, rhs_reg, element);
            },
            .sub => {
                try writeVectorOp(writer, .vsubc, destination_fraction, lhs_fraction, rhs_fraction, element);
                try writeVectorOp(writer, .vsub, destination_reg, lhs_reg, rhs_reg, element);
            },
            .bit_and, .bit_or, .bit_xor, .bit_nor => {
                const op = vectorLogicOp(assignment.op);
                try writeVectorOp(writer, op, destination_reg, lhs_reg, rhs_reg, element);
                try writeVectorOp(writer, op, destination_fraction, lhs_fraction, rhs_fraction, element);
            },
            else => return error.UnsupportedVectorOperator,
        }
        return;
    }

    const op: VectorAluOp = switch (assignment.op) {
        .add => .vaddc,
        .sub => .vsubc,
        .bit_and, .bit_or, .bit_xor, .bit_nor => vectorLogicOp(assignment.op),
        else => return error.UnsupportedVectorOperator,
    };
    try writeVectorOp(writer, op, destination_view_reg, lhs_reg, rhs_reg, element);
}

fn writeVectorLaneOp(
    writer: *std.Io.Writer,
    op: ast.VectorOp,
    destination: ast.VectorRegister,
    destination_element: u4,
    source: ast.VectorRegister,
    source_element: u4,
) !void {
    const word: u32 = 0x4a000000 |
        (@as(u32, source_element) << 21) |
        (@as(u32, @intFromEnum(source)) << 16) |
        (@as(u32, destination_element) << 11) |
        (@as(u32, @intFromEnum(destination)) << 6) |
        @as(u32, @intFromEnum(op));
    try writer.print("  .word 0x{x:0>8} # {s} ${s}[{d}], ${s}[{d}]\n", .{
        word,
        @tagName(op),
        vectorRegName(destination),
        if (destination_element >= 8) destination_element - 8 else destination_element,
        vectorRegName(source),
        source_element - 8,
    });
}

const VectorOperand = struct {
    data_type: DataType,
    reg: ast.VectorRegister,
    element: u4,
};

fn vectorOperand(context: *FunctionContext, access: ast.VectorAccess) !VectorOperand {
    const symbol = try context.lookup(access.name);
    if (!isVectorType(symbol.data_type)) return error.ExpectedVectorType;
    return .{
        .data_type = if (access.view != null) .vec16 else symbol.data_type,
        .reg = try vectorRegisterForView(symbol, access.view),
        .element = access.element,
    };
}

fn vectorLogicOp(op: ast.AssignOp) VectorAluOp {
    return switch (op) {
        .bit_and => .vand,
        .bit_or => .vor,
        .bit_xor => .vxor,
        .bit_nor => .vnor,
        else => unreachable,
    };
}

fn writeNamedVectorShift(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: ast.VectorRegister,
    shift: ast.VectorShift,
) !void {
    const source = try vectorOperand(context, shift.source);
    if (source.data_type != .vec16 or source.element != 0) return error.UnsupportedVectorShift;
    const op: ast.VectorOp = switch (shift.kind) {
        .left_8 => .vmudn,
        .right_arithmetic => .vmudm,
        .right_logical => .vmudl,
    };
    const element: u4 = switch (shift.kind) {
        .left_8 => @intCast(23 - @as(u8, shift.amount)),
        .right_arithmetic, .right_logical => @intCast(7 + @as(u8, shift.amount)),
    };
    try writeEncodedVectorOp(
        writer,
        switch (shift.kind) {
            .left_8 => "vsll8",
            .right_arithmetic => "vsra",
            .right_logical => "vsrl",
        },
        @intFromEnum(op),
        destination,
        source.reg,
        .v31,
        element,
    );
}

fn writeVectorOp(
    writer: *std.Io.Writer,
    op: VectorAluOp,
    destination: ast.VectorRegister,
    lhs: ast.VectorRegister,
    rhs: ast.VectorRegister,
    element: u4,
) !void {
    return writeEncodedVectorOp(
        writer,
        @tagName(op),
        @intFromEnum(op),
        destination,
        lhs,
        rhs,
        element,
    );
}

fn writeEncodedVectorOp(
    writer: *std.Io.Writer,
    name: []const u8,
    opcode: u6,
    destination: ast.VectorRegister,
    lhs: ast.VectorRegister,
    rhs: ast.VectorRegister,
    element: u4,
) !void {
    const word: u32 = 0x4a000000 |
        (@as(u32, element) << 21) |
        (@as(u32, @intFromEnum(rhs)) << 16) |
        (@as(u32, @intFromEnum(lhs)) << 11) |
        (@as(u32, @intFromEnum(destination)) << 6) |
        @as(u32, opcode);
    try writer.print("  .word 0x{x:0>8} # {s} ${s}, ${s}, ${s}\n", .{
        word,
        name,
        vectorRegName(destination),
        vectorRegName(lhs),
        vectorRegName(rhs),
    });
}

fn writeMtc2(
    writer: *std.Io.Writer,
    source: Register,
    destination: ast.VectorRegister,
    lane: u3,
) !void {
    const word: u32 = 0x48800000 |
        (@as(u32, @intFromEnum(source)) << 16) |
        (@as(u32, @intFromEnum(destination)) << 11) |
        (@as(u32, lane) << 8);
    try writer.print("  .word 0x{x:0>8} # mtc2 {s}, ${s}[{d}]\n", .{
        word, regName(source), vectorRegName(destination), lane,
    });
}

fn writeMfc2(
    writer: *std.Io.Writer,
    destination: Register,
    source: ast.VectorRegister,
    lane: u3,
) !void {
    const word: u32 = 0x48000000 |
        (@as(u32, @intFromEnum(destination)) << 16) |
        (@as(u32, @intFromEnum(source)) << 11) |
        (@as(u32, lane) << 8);
    try writer.print("  .word 0x{x:0>8} # mfc2 {s}, ${s}[{d}]\n", .{
        word, regName(destination), vectorRegName(source), lane,
    });
}

fn writeSet(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    value: ast.Value,
) !void {
    switch (value) {
        .number => |number| try loadImmediateInto(writer, destination_reg, number),
        .ident => |name| {
            const source = try context.lookup(name);
            if (source.reg) |source_reg| {
                try expectSameType(destination, source);
                try expectSameFunctionType(destination, source);
                try writer.print("  or {s}, {s}, {s}\n", .{
                    regName(destination_reg),
                    regName(source_reg),
                    regName(.zero),
                });
            } else if (source.data_label) |label| {
                try loadDataAddress(writer, destination_reg, label);
            } else {
                try loadImmediateInto(writer, destination_reg, source.constant orelse return error.ExpectedConstant);
            }
        },
        .vector_access => |access| {
            const lane = access.lane orelse return error.VectorLaneRequired;
            const source = try context.lookup(access.name);
            const source_reg = try vectorRegisterForView(source, access.view);
            try writeMfc2(writer, destination_reg, source_reg, lane);
            if (destination.data_type == .u16 or destination.data_type == .u32) {
                try writer.print("  andi {s}, {s}, 65535\n", .{
                    regName(destination_reg), regName(destination_reg),
                });
            }
        },
        .vector_operation => return error.RegisterTypeMismatch,
        .vector_shift => return error.RegisterTypeMismatch,
        .accumulator_read => return error.RegisterTypeMismatch,
        .vector_control_read => |control_register| {
            if (destination.data_type != .u32 and destination.data_type != .i32) {
                return error.RegisterTypeMismatch;
            }
            const word = @as(u32, 0x48400000) |
                (@as(u32, @intFromEnum(destination_reg)) << 16) |
                (@as(u32, @intFromEnum(control_register)) << 11);
            try writer.print("  .word 0x{x:0>8} # cfc2 {s}, ${d}\n", .{
                word, regName(destination_reg), @intFromEnum(control_register),
            });
        },
        .hardware_read => |read| {
            if (read.returns_dmem) {
                if (destination.data_type != .dmem) return error.ExpectedDmemAddress;
            } else if (destination.data_type != .u32 and destination.data_type != .i32) {
                return error.RegisterTypeMismatch;
            }
            try writer.print("  mfc0 {s}, ${d}\n", .{ regName(destination_reg), read.register });
        },
        .scalar_comparison => |comparison| try writeScalarComparison(
            writer,
            context,
            destination,
            destination_reg,
            comparison,
        ),
        .signed_less_than => |comparison| {
            const lhs = try valueAsAddressReg(writer, context, comparison.lhs);
            const rhs = try valueAsAddressReg(writer, context, comparison.rhs);
            try writer.print("  slt {s}, {s}, {s}\n", .{
                regName(destination_reg), regName(lhs), regName(rhs),
            });
        },
        .load => |load| {
            if (!isCompatibleScalarLoad(destination.data_type, load.data_type)) return error.RegisterTypeMismatch;
            try writeLoadInto(writer, context, destination_reg, load);
        },
        .scalar_expression => return error.UnsupportedScalarExpressionTree,
        .function_address => |target| {
            const expected_type = destination.function_type orelse
                return error.FunctionAddressRequiresTypedRegister;
            if (target.module != null) return error.UnresolvedModuleCall;
            const function = findFunction(context.functions, target.name) orelse
                return error.UnknownFunction;
            if (!functionMatchesType(function, expected_type)) return error.FunctionTypeMismatch;
            try writer.print("  addiu {s}, $zero, %lo({s})\n", .{
                regName(destination_reg), target.name,
            });
        },
        .data_address => |address| {
            if (destination.data_type != .dmem) return error.ExpectedDmemAddress;
            const data = try context.lookup(address.label);
            const label = data.data_label orelse return error.ExpectedDataLabel;
            if (address.offset == 0) {
                try writer.print("  addiu {s}, $zero, %lo({s})\n", .{ regName(destination_reg), label });
            } else {
                try writer.print("  addiu {s}, $zero, %lo({s} + {d})\n", .{
                    regName(destination_reg), label, address.offset,
                });
            }
        },
    }
}

fn expectSameFunctionType(left: Symbol, right: Symbol) !void {
    if (left.function_type == null and right.function_type == null) return;
    if (left.function_type == null or right.function_type == null or
        !std.meta.eql(left.function_type.?, right.function_type.?))
    {
        return error.FunctionTypeMismatch;
    }
}

fn functionMatchesType(function: ast.Function, expected: ast.FunctionType) bool {
    if (function.parameters.len > expected.parameter_count) return false;
    for (function.parameters, expected.parameterSlice()[0..function.parameters.len]) |actual, wanted| {
        if (!scalarAbiTypesCompatible(actual.data_type, wanted.data_type) or
            actual.reg != wanted.reg or actual.vector_reg != wanted.vector_reg) return false;
    }
    return true;
}

fn writeScalarExpression(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    expression: *const ast.ScalarExpression,
) anyerror!void {
    if (!isPureScalarExpression(.{ .scalar_expression = @constCast(expression) })) {
        return error.SideEffectsNotAllowedInScalarExpression;
    }

    const needs_rhs_temporary = expression.rhs == .scalar_expression or
        (expression.lhs == .scalar_expression and valueReadsName(expression.rhs, destination.name));
    if (needs_rhs_temporary) {
        const temporary = try context.pushExpressionTemporary(destination.data_type);
        defer context.popExpressionTemporary(temporary[0]);
        const temporary_symbol = temporary[1];
        const temporary_reg = temporary_symbol.reg.?;
        if (expression.rhs == .scalar_expression) {
            try writeScalarExpression(
                writer,
                context,
                temporary_symbol,
                temporary_reg,
                expression.rhs.scalar_expression,
            );
        } else {
            try writeSet(writer, context, temporary_symbol, temporary_reg, expression.rhs);
        }
        if (expression.lhs != .scalar_expression and expression.lhs != .number) {
            return writeBinary(
                writer,
                context,
                destination,
                destination_reg,
                expression.lhs,
                expression.op,
                .{ .ident = temporary_symbol.name },
            );
        }
        try writeScalarExpressionLhs(writer, context, destination, destination_reg, expression.lhs);
        return writeBinary(
            writer,
            context,
            destination,
            destination_reg,
            .{ .ident = destination.name },
            expression.op,
            .{ .ident = temporary_symbol.name },
        );
    }

    if (expression.lhs == .scalar_expression) {
        try writeScalarExpression(
            writer,
            context,
            destination,
            destination_reg,
            expression.lhs.scalar_expression,
        );
        return writeBinary(
            writer,
            context,
            destination,
            destination_reg,
            .{ .ident = destination.name },
            expression.op,
            expression.rhs,
        );
    }

    if (expression.lhs == .number) {
        try writeSet(writer, context, destination, destination_reg, expression.lhs);
        return writeBinary(
            writer,
            context,
            destination,
            destination_reg,
            .{ .ident = destination.name },
            expression.op,
            expression.rhs,
        );
    }
    return writeBinary(
        writer,
        context,
        destination,
        destination_reg,
        expression.lhs,
        expression.op,
        expression.rhs,
    );
}

fn writeScalarExpressionLhs(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    lhs: ast.Value,
) anyerror!void {
    if (lhs == .scalar_expression) {
        return writeScalarExpression(writer, context, destination, destination_reg, lhs.scalar_expression);
    }
    return writeSet(writer, context, destination, destination_reg, lhs);
}

fn isCompatibleScalarLoad(destination: DataType, source: DataType) bool {
    return destination == source or
        (destination == .dmem and (source == .u32 or source == .i32)) or
        ((destination == .u32 or destination == .i32 or destination == .dmem) and
            (source == .u8 or source == .u16 or source == .i8 or source == .i16));
}

fn writeScalarComparison(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    comparison: ast.ScalarComparison,
) !void {
    if (destination.data_type != .u32 and destination.data_type != .i32) return error.RegisterTypeMismatch;
    const lhs_name = switch (comparison.lhs) {
        .ident => |name| name,
        else => return error.ComparisonLhsMustBeRegister,
    };
    const lhs = try context.lookup(lhs_name);
    const lhs_reg = lhs.reg orelse return error.ComparisonLhsMustBeRegister;
    if (isVectorType(lhs.data_type)) return error.ExpectedScalarType;

    var rhs_reg: Register = undefined;
    switch (comparison.rhs) {
        .ident => |name| {
            const rhs = try context.lookup(name);
            try expectSameType(lhs, rhs);
            rhs_reg = rhs.reg orelse blk: {
                const immediate = rhs.constant orelse return error.ExpectedConstant;
                if (immediate == 0) break :blk .zero;
                const scratch = try backendScratch2(context);
                try loadImmediateInto(writer, scratch, immediate);
                break :blk scratch;
            };
        },
        .number => |number| {
            if (number == 0) {
                rhs_reg = .zero;
            } else {
                const scratch = try backendScratch2(context);
                try loadImmediateInto(writer, scratch, number);
                rhs_reg = scratch;
            }
        },
        .vector_access => return error.ExpectedScalarType,
    }

    const instruction = if (isSigned(lhs.data_type)) "slt" else "sltu";
    switch (comparison.op) {
        .lt, .gt, .le, .ge => {
            const reverse = comparison.op == .gt or comparison.op == .le;
            try writer.print("  {s} {s}, {s}, {s}\n", .{
                instruction,
                regName(destination_reg),
                regName(if (reverse) rhs_reg else lhs_reg),
                regName(if (reverse) lhs_reg else rhs_reg),
            });
            if (comparison.op == .le or comparison.op == .ge) {
                try writer.print("  xori {s}, {s}, 1\n", .{ regName(destination_reg), regName(destination_reg) });
            }
        },
        .eq, .ne => {
            if (rhs_reg == .zero) {
                if (comparison.op == .ne) {
                    try writer.print("  sltu {s}, $zero, {s}\n", .{ regName(destination_reg), regName(lhs_reg) });
                } else {
                    try writer.print("  sltiu {s}, {s}, 1\n", .{ regName(destination_reg), regName(lhs_reg) });
                }
                return;
            }
            try writer.print("  xor {s}, {s}, {s}\n", .{
                regName(destination_reg), regName(lhs_reg), regName(rhs_reg),
            });
            if (comparison.op == .ne) {
                try writer.print("  sltu {s}, $zero, {s}\n", .{ regName(destination_reg), regName(destination_reg) });
            } else {
                try writer.print("  sltiu {s}, {s}, 1\n", .{ regName(destination_reg), regName(destination_reg) });
            }
        },
    }
}

fn writeBitNot(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    value: ast.Value,
) !void {
    const source = switch (value) {
        .ident => |name| try context.lookup(name),
        .vector_access => return error.BitNotRequiresRegister,
        .vector_operation => return error.BitNotRequiresRegister,
        .vector_shift => return error.BitNotRequiresRegister,
        .accumulator_read => return error.BitNotRequiresRegister,
        .vector_control_read => return error.BitNotRequiresRegister,
        .hardware_read => return error.BitNotRequiresRegister,
        .scalar_comparison => return error.BitNotRequiresRegister,
        .signed_less_than => return error.BitNotRequiresRegister,
        .number => return error.BitNotRequiresRegister,
        .load => return error.BitNotRequiresRegister,
        .scalar_expression => return error.BitNotRequiresRegister,
        .function_address, .data_address => return error.BitNotRequiresRegister,
    };
    try expectSameType(destination, source);
    const source_reg = source.reg orelse return error.BitNotRequiresRegister;
    try writer.print("  nor {s}, {s}, {s}\n", .{
        regName(destination_reg),
        regName(source_reg),
        regName(.zero),
    });
}

fn writeNegate(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    value: ast.Value,
) !void {
    const name = switch (value) {
        .number => |number| return loadImmediateInto(
            writer,
            destination_reg,
            std.math.negate(number) catch return error.ImmediateOutOfRange,
        ),
        .ident => |name| name,
        else => return error.NegateRequiresRegister,
    };
    const source = try context.lookup(name);
    try expectSameType(destination, source);
    if (isVectorType(destination.data_type)) return error.NegateRequiresRegister;
    const source_reg = source.reg orelse return error.NegateRequiresRegister;
    try writer.print("  {s} {s}, $zero, {s}\n", .{
        if (isSigned(destination.data_type)) "sub" else "subu",
        regName(destination_reg),
        regName(source_reg),
    });
}

fn writeBinary(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    lhs_value: ast.Value,
    op: ast.AssignOp,
    rhs_value: ast.Value,
) !void {
    const lhs = switch (lhs_value) {
        .ident => |name| try context.lookup(name),
        .vector_access => return error.ArithmeticLhsMustBeRegister,
        .vector_operation => return error.ArithmeticLhsMustBeRegister,
        .vector_shift => return error.ArithmeticLhsMustBeRegister,
        .accumulator_read => return error.ArithmeticLhsMustBeRegister,
        .vector_control_read => return error.ArithmeticLhsMustBeRegister,
        .hardware_read => return error.ArithmeticLhsMustBeRegister,
        .scalar_comparison => return error.ArithmeticLhsMustBeRegister,
        .signed_less_than => return error.ArithmeticLhsMustBeRegister,
        .number => return error.ArithmeticLhsMustBeRegister,
        .load => return error.ArithmeticLhsMustBeRegister,
        .scalar_expression => return error.ArithmeticLhsMustBeRegister,
        .function_address, .data_address => return error.ArithmeticLhsMustBeRegister,
    };
    try expectSameType(destination, lhs);
    const lhs_reg = lhs.reg orelse return error.ArithmeticLhsMustBeRegister;

    if (op == .mul or op == .div) {
        return writePowerOfTwoMath(writer, context, destination, destination_reg, lhs_reg, op, rhs_value);
    }

    if (op == .shift_left or op == .shift_right or op == .logical_shift_right) {
        return writeShift(writer, context, destination, destination_reg, lhs_reg, op, rhs_value);
    }

    switch (rhs_value) {
        .ident => |name| {
            const rhs = try context.lookup(name);
            if (destination.data_type != rhs.data_type and
                !isDmemScalarPair(destination.data_type, rhs.data_type))
            {
                return error.RegisterTypeMismatch;
            }
            if (rhs.reg) |rhs_reg| {
                const instruction = registerBinaryInstruction(op) orelse return error.UnsupportedOperator;
                try writer.print("  {s} {s}, {s}, {s}\n", .{
                    instruction,
                    regName(destination_reg),
                    regName(lhs_reg),
                    regName(rhs_reg),
                });
            } else {
                try writeBinaryImmediate(
                    writer,
                    context,
                    destination_reg,
                    lhs_reg,
                    op,
                    rhs.constant orelse return error.ExpectedConstant,
                );
            }
        },
        .number => |number| try writeBinaryImmediate(writer, context, destination_reg, lhs_reg, op, number),
        .vector_access => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .vector_operation => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .vector_shift => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .accumulator_read => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .vector_control_read => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .hardware_read => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .scalar_comparison => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .signed_less_than => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .load => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .scalar_expression => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .function_address, .data_address => return error.ArithmeticRhsMustBeRegisterOrNumber,
    }
}

fn writeBinaryImmediate(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Register,
    lhs: Register,
    op: ast.AssignOp,
    immediate: i64,
) !void {
    switch (op) {
        .add, .sub, .add_wrap, .sub_wrap => {
            const addend = if (op == .add or op == .add_wrap) immediate else std.math.negate(immediate) catch
                return error.ImmediateOutOfRange;
            if (addend >= std.math.minInt(i16) and addend <= std.math.maxInt(i16)) {
                try writer.print("  {s} {s}, {s}, {d}\n", .{
                    if (op == .add or op == .sub) "addi" else "addiu",
                    regName(destination),
                    regName(lhs),
                    addend,
                });
                return;
            }
        },
        .bit_and, .bit_or, .bit_xor => {
            if (immediate >= 0 and immediate <= std.math.maxInt(u16)) {
                const instruction = immediateBinaryInstruction(op).?;
                try writer.print("  {s} {s}, {s}, {d}\n", .{
                    instruction,
                    regName(destination),
                    regName(lhs),
                    immediate,
                });
                return;
            }
        },
        .bit_nor => return error.NorRequiresRegister,
        else => return error.UnsupportedOperator,
    }

    const scratch = try backendScratch2(context);
    try loadImmediateInto(writer, scratch, immediate);
    const instruction = registerBinaryInstruction(op) orelse return error.UnsupportedOperator;
    try writer.print("  {s} {s}, {s}, {s}\n", .{
        instruction,
        regName(destination),
        regName(lhs),
        regName(scratch),
    });
}

fn registerBinaryInstruction(op: ast.AssignOp) ?[]const u8 {
    return switch (op) {
        .add => "add",
        .add_wrap => "addu",
        .sub => "sub",
        .sub_wrap => "subu",
        .bit_and => "and",
        .bit_or => "or",
        .bit_xor => "xor",
        .bit_nor => "nor",
        else => null,
    };
}

fn immediateBinaryInstruction(op: ast.AssignOp) ?[]const u8 {
    return switch (op) {
        .add, .sub => "addi",
        .add_wrap, .sub_wrap => "addiu",
        .bit_and => "andi",
        .bit_or => "ori",
        .bit_xor => "xori",
        else => null,
    };
}

fn writePowerOfTwoMath(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    lhs_reg: Register,
    op: ast.AssignOp,
    rhs_value: ast.Value,
) !void {
    const value = switch (rhs_value) {
        .number => |number| number,
        .ident => |name| blk: {
            const rhs = try context.lookup(name);
            try expectSameType(destination, rhs);
            if (rhs.reg != null) return error.PowerOfTwoConstantRequired;
            break :blk rhs.constant orelse return error.ExpectedConstant;
        },
        .vector_access => return error.PowerOfTwoConstantRequired,
        .vector_operation => return error.PowerOfTwoConstantRequired,
        .vector_shift => return error.PowerOfTwoConstantRequired,
        .accumulator_read => return error.PowerOfTwoConstantRequired,
        .vector_control_read => return error.PowerOfTwoConstantRequired,
        .hardware_read => return error.PowerOfTwoConstantRequired,
        .scalar_comparison => return error.PowerOfTwoConstantRequired,
        .signed_less_than => return error.PowerOfTwoConstantRequired,
        .load => return error.PowerOfTwoConstantRequired,
        .scalar_expression => return error.PowerOfTwoConstantRequired,
        .function_address, .data_address => return error.PowerOfTwoConstantRequired,
    };
    if (value <= 0 or value > std.math.maxInt(u32)) return error.PowerOfTwoConstantRequired;
    const unsigned: u32 = @intCast(value);
    if (!std.math.isPowerOfTwo(unsigned)) return error.PowerOfTwoConstantRequired;
    if (unsigned == 1) return error.NoOpPowerOfTwoMath;
    const shift: u5 = @intCast(@ctz(unsigned));

    const instruction = if (op == .mul)
        "sll"
    else if (isSigned(destination.data_type))
        "sra"
    else
        "srl";
    try writer.print("  {s} {s}, {s}, {d}\n", .{
        instruction,
        regName(destination_reg),
        regName(lhs_reg),
        shift,
    });
}

fn writeShift(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: Symbol,
    destination_reg: Register,
    lhs_reg: Register,
    op: ast.AssignOp,
    rhs_value: ast.Value,
) !void {
    switch (rhs_value) {
        .number => |amount| try writeImmediateShift(
            writer,
            destination,
            destination_reg,
            lhs_reg,
            op,
            amount,
        ),
        .ident => |name| {
            const rhs = try context.lookup(name);
            try expectSameType(destination, rhs);
            if (rhs.constant) |amount| {
                return writeImmediateShift(
                    writer,
                    destination,
                    destination_reg,
                    lhs_reg,
                    op,
                    amount,
                );
            }
            const rhs_reg = rhs.reg orelse return error.ShiftAmountMustBeRegisterOrNumber;
            const instruction = shiftInstruction(op, isSigned(destination.data_type), true);
            try writer.print("  {s} {s}, {s}, {s}\n", .{
                instruction,
                regName(destination_reg),
                regName(lhs_reg),
                regName(rhs_reg),
            });
        },
        .vector_access => return error.ShiftAmountMustBeRegisterOrNumber,
        .vector_operation => return error.ShiftAmountMustBeRegisterOrNumber,
        .vector_shift => return error.ShiftAmountMustBeRegisterOrNumber,
        .accumulator_read => return error.ShiftAmountMustBeRegisterOrNumber,
        .vector_control_read => return error.ShiftAmountMustBeRegisterOrNumber,
        .hardware_read => return error.ShiftAmountMustBeRegisterOrNumber,
        .scalar_comparison => return error.ShiftAmountMustBeRegisterOrNumber,
        .signed_less_than => return error.ShiftAmountMustBeRegisterOrNumber,
        .load => return error.ShiftAmountMustBeRegisterOrNumber,
        .scalar_expression => return error.ShiftAmountMustBeRegisterOrNumber,
        .function_address, .data_address => return error.ShiftAmountMustBeRegisterOrNumber,
    }
}

fn writeImmediateShift(
    writer: *std.Io.Writer,
    destination: Symbol,
    destination_reg: Register,
    lhs_reg: Register,
    op: ast.AssignOp,
    amount: i64,
) !void {
    if (amount < 0 or amount > 31) return error.InvalidShiftAmount;
    const instruction = shiftInstruction(op, isSigned(destination.data_type), false);
    try writer.print("  {s} {s}, {s}, {d}\n", .{
        instruction,
        regName(destination_reg),
        regName(lhs_reg),
        amount,
    });
}

fn shiftInstruction(op: ast.AssignOp, signed: bool, variable: bool) []const u8 {
    return switch (op) {
        .shift_left => if (variable) "sllv" else "sll",
        .logical_shift_right => if (variable) "srlv" else "srl",
        .shift_right => if (signed)
            (if (variable) "srav" else "sra")
        else
            (if (variable) "srlv" else "srl"),
        else => unreachable,
    };
}

fn expectSameType(lhs: Symbol, rhs: Symbol) !void {
    if (lhs.data_type != rhs.data_type and
        !isDmemScalarPair(lhs.data_type, rhs.data_type))
    {
        return error.RegisterTypeMismatch;
    }
}

fn isDmemScalarPair(lhs: DataType, rhs: DataType) bool {
    return (lhs == .dmem and (rhs == .u32 or rhs == .i32)) or
        (rhs == .dmem and (lhs == .u32 or lhs == .i32));
}

fn writeStore(writer: *std.Io.Writer, context: *FunctionContext, store: anytype) !void {
    if (isVectorType(store.data_type)) {
        if (store.label_offset != null) return error.VectorMemorySymbolicOffsetUnsupported;
        const value_access: ast.VectorAccess = switch (store.value) {
            .ident => |name| .{ .name = name },
            .vector_access => |access| access,
            .number => return error.ExpectedVectorRegister,
        };
        const value = try context.lookup(value_access.name);
        const value_type: DataType = if (value_access.view != null) .vec16 else value.data_type;
        if (value_type != store.data_type) return error.RegisterTypeMismatch;
        const vector_reg = try vectorRegisterForView(value, value_access.view);
        const address_reg = try valueAsDmemReg(writer, context, store.address);
        if (store.quarter_vector) {
            if (store.data_type != .vec16 or value_access.view != null) {
                return error.PartialVectorMemoryRequiresVec16;
            }
            return writeQuarterVectorMemory(
                writer,
                false,
                vector_reg,
                value_access.lane orelse 0,
                address_reg,
                store.offset,
            );
        }
        if (store.half_vector) {
            if (store.data_type != .vec16 or value_access.view != null) {
                return error.PartialVectorMemoryRequiresVec16;
            }
            return writeHalfVectorMemory(
                writer,
                false,
                vector_reg,
                value_access.lane orelse 0,
                address_reg,
                store.offset,
            );
        }
        if (value_access.lane) |lane| {
            if (store.data_type != .vec16) return error.PartialVectorMemoryRequiresVec16;
            return writeVectorLaneMemory(
                writer,
                false,
                vector_reg,
                lane,
                address_reg,
                store.offset,
            );
        }
        try writeVectorMemory(writer, false, vector_reg, address_reg, store.offset);
        if (store.data_type == .vec32) {
            try writeVectorMemory(
                writer,
                false,
                nextVectorRegister(vector_reg).?,
                address_reg,
                store.offset + 16,
            );
        }
        return;
    }
    try validateMemoryOffset(store.offset);
    const value_reg = try valueAsStoreReg(writer, context, store.value);
    if (store.label_offset) |offset_name| {
        const offset_symbol = try context.lookup(offset_name);
        const address_reg = try valueAsAddressReg(writer, context, store.address);
        if (offset_symbol.data_label) |label| {
            if (store.offset == 0)
                try writer.print("  {s} {s}, %lo({s})({s})\n", .{
                    storeOp(store.data_type), regName(value_reg), label, regName(address_reg),
                })
            else
                try writer.print("  {s} {s}, %lo({s} + {d})({s})\n", .{
                    storeOp(store.data_type), regName(value_reg), label, store.offset, regName(address_reg),
                });
        } else {
            const offset = offset_symbol.constant orelse return error.ExpectedConstant;
            try validateMemoryOffset(offset);
            try writer.print("  {s} {s}, {d}({s})\n", .{
                storeOp(store.data_type),
                regName(value_reg),
                offset,
                regName(address_reg),
            });
        }
        return;
    }
    if (memoryDataLabel(context, store.address)) |label| {
        if (store.offset == 0) {
            try writer.print("  {s} {s}, %lo({s})($zero)\n", .{
                storeOp(store.data_type),
                regName(value_reg),
                label,
            });
        } else {
            try writer.print("  {s} {s}, %lo({s} + {d})($zero)\n", .{
                storeOp(store.data_type), regName(value_reg), label, store.offset,
            });
        }
        return;
    }
    const address_reg = try valueAsDmemReg(writer, context, store.address);
    try writer.print("  {s} {s}, {d}({s})\n", .{
        storeOp(store.data_type),
        regName(value_reg),
        store.offset,
        regName(address_reg),
    });
}

fn writeQuarterVectorMemory(
    writer: *std.Io.Writer,
    load: bool,
    vector_reg: ast.VectorRegister,
    lane: u3,
    address_reg: Register,
    offset: i64,
) !void {
    if (@mod(offset, 4) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled_offset = @divExact(offset, 4);
    if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
    const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
    const opcode: u32 = if (load) 0x32 else 0x3a;
    const word = (opcode << 26) |
        (@as(u32, @intFromEnum(address_reg)) << 21) |
        (@as(u32, @intFromEnum(vector_reg)) << 16) |
        (0b00010 << 11) |
        (@as(u32, lane) << 8) |
        encoded_offset;
    try writer.print("  .word 0x{x:0>8} # {s} ${s}[{d}], {d}({s})\n", .{
        word,
        if (load) "llv" else "slv",
        vectorRegName(vector_reg),
        lane,
        offset,
        regName(address_reg),
    });
}

fn writeHalfVectorMemory(
    writer: *std.Io.Writer,
    load: bool,
    vector_reg: ast.VectorRegister,
    lane: u3,
    address_reg: Register,
    offset: i64,
) !void {
    if (@mod(offset, 8) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled_offset = @divExact(offset, 8);
    if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
    const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
    const opcode: u32 = if (load) 0x32 else 0x3a;
    const word = (opcode << 26) |
        (@as(u32, @intFromEnum(address_reg)) << 21) |
        (@as(u32, @intFromEnum(vector_reg)) << 16) |
        (0b00011 << 11) |
        (@as(u32, lane) << 8) |
        encoded_offset;
    try writer.print("  .word 0x{x:0>8} # {s} ${s}[{d}], {d}({s})\n", .{
        word,
        if (load) "ldv" else "sdv",
        vectorRegName(vector_reg),
        lane,
        offset,
        regName(address_reg),
    });
}

fn writeVectorLaneMemory(
    writer: *std.Io.Writer,
    load: bool,
    vector_reg: ast.VectorRegister,
    lane: u3,
    address_reg: Register,
    offset: i64,
) !void {
    if (@mod(offset, 2) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled_offset = @divExact(offset, 2);
    if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
    const opcode: u32 = if (load) 0x32 else 0x3a;
    const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
    const word = (opcode << 26) |
        (@as(u32, @intFromEnum(address_reg)) << 21) |
        (@as(u32, @intFromEnum(vector_reg)) << 16) |
        (0b00001 << 11) |
        (@as(u32, lane) << 8) |
        encoded_offset;
    try writer.print("  .word 0x{x:0>8} # {s} ${s}[{d}], {d}({s})\n", .{
        word,
        if (load) "lsv" else "ssv",
        vectorRegName(vector_reg),
        lane,
        offset,
        regName(address_reg),
    });
}

fn writeVectorLoad(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: ast.VectorRegister,
    load: ast.Load,
) !void {
    if (load.label_offset != null) return error.SymbolicOffsetRequiresScalarLoad;
    const address_reg = try valueAsDmemReg(writer, context, load.address);
    if (load.packed_u8 or load.packed_unsigned_u8) {
        if (@mod(load.offset, 8) != 0) return error.VectorMemoryOffsetUnaligned;
        const scaled_offset = @divExact(load.offset, 8);
        if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
        const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
        const word: u32 = (0x32 << 26) |
            (@as(u32, @intFromEnum(address_reg)) << 21) |
            (@as(u32, @intFromEnum(destination)) << 16) |
            (@as(u32, if (load.packed_unsigned_u8) 0b00111 else 0b00110) << 11) | encoded_offset;
        try writer.print("  .word 0x{x:0>8} # {s} ${s}, {d}({s})\n", .{
            word, if (load.packed_unsigned_u8) "luv" else "lpv", vectorRegName(destination), load.offset, regName(address_reg),
        });
        return;
    }
    if (load.partial_u32_lane) |lane| {
        if (@mod(load.offset, 4) != 0) return error.VectorMemoryOffsetUnaligned;
        const scaled_offset = @divExact(load.offset, 4);
        if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
        const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
        const word: u32 = (0x32 << 26) |
            (@as(u32, @intFromEnum(address_reg)) << 21) |
            (@as(u32, @intFromEnum(destination)) << 16) |
            (0b00010 << 11) | (@as(u32, lane) << 8) | encoded_offset;
        try writer.print("  .word 0x{x:0>8} # llv ${s}[{d}], {d}({s})\n", .{
            word, vectorRegName(destination), lane, load.offset, regName(address_reg),
        });
        return;
    }
    try writeVectorMemory(writer, true, destination, address_reg, load.offset);
    if (load.unaligned) try writeVectorReverseLoad(writer, destination, address_reg, load.offset + 16);
    if (load.data_type == .vec32) {
        try writeVectorMemory(
            writer,
            true,
            nextVectorRegister(destination).?,
            address_reg,
            load.offset + 16,
        );
        if (load.unaligned) try writeVectorReverseLoad(
            writer,
            nextVectorRegister(destination).?,
            address_reg,
            load.offset + 32,
        );
    }
}

fn writeVectorReverseLoad(
    writer: *std.Io.Writer,
    vector_reg: ast.VectorRegister,
    address_reg: Register,
    offset: i64,
) !void {
    if (@mod(offset, 16) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled_offset = @divExact(offset, 16);
    if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
    const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
    const word: u32 = (0x32 << 26) |
        (@as(u32, @intFromEnum(address_reg)) << 21) |
        (@as(u32, @intFromEnum(vector_reg)) << 16) |
        (0b00101 << 11) | encoded_offset;
    try writer.print("  .word 0x{x:0>8} # lrv ${s}, {d}({s})\n", .{
        word, vectorRegName(vector_reg), offset, regName(address_reg),
    });
}

fn writeVectorMemory(
    writer: *std.Io.Writer,
    load: bool,
    vector_reg: ast.VectorRegister,
    address_reg: Register,
    offset: i64,
) !void {
    if (@mod(offset, 16) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled_offset = @divExact(offset, 16);
    if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
    const opcode: u32 = if (load) 0x32 else 0x3a;
    const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
    const word = (opcode << 26) |
        (@as(u32, @intFromEnum(address_reg)) << 21) |
        (@as(u32, @intFromEnum(vector_reg)) << 16) |
        (0b00100 << 11) |
        encoded_offset;
    try writer.print("  .word 0x{x:0>8} # {s} ${s}, {d}({s})\n", .{
        word,
        if (load) "lqv" else "sqv",
        vectorRegName(vector_reg),
        offset,
        regName(address_reg),
    });
}

fn writeLoadInto(writer: *std.Io.Writer, context: *FunctionContext, destination_reg: Register, load: ast.Load) !void {
    if (load.unaligned) return error.UnalignedLoadRequiresVectorType;
    try validateMemoryOffset(load.offset);
    if (load.label_offset) |offset_name| {
        const offset_symbol = try context.lookup(offset_name);
        const address_reg = try valueAsAddressReg(writer, context, load.address);
        if (offset_symbol.data_label) |label| {
            if (load.offset == 0)
                try writer.print("  {s} {s}, %lo({s})({s})\n", .{
                    loadOp(load.data_type), regName(destination_reg), label, regName(address_reg),
                })
            else
                try writer.print("  {s} {s}, %lo({s} + {d})({s})\n", .{
                    loadOp(load.data_type), regName(destination_reg), label, load.offset, regName(address_reg),
                });
        } else {
            const offset = offset_symbol.constant orelse return error.ExpectedConstant;
            try validateMemoryOffset(offset);
            try writer.print("  {s} {s}, {d}({s})\n", .{
                loadOp(load.data_type),
                regName(destination_reg),
                offset,
                regName(address_reg),
            });
        }
        return;
    }
    if (memoryDataLabel(context, load.address)) |label| {
        if (load.offset == 0) {
            try writer.print("  {s} {s}, %lo({s})($zero)\n", .{
                loadOp(load.data_type),
                regName(destination_reg),
                label,
            });
        } else {
            try writer.print("  {s} {s}, %lo({s} + {d})($zero)\n", .{
                loadOp(load.data_type), regName(destination_reg), label, load.offset,
            });
        }
        return;
    }
    const address_reg = try valueAsDmemReg(writer, context, load.address);
    try writer.print("  {s} {s}, {d}({s})\n", .{
        loadOp(load.data_type),
        regName(destination_reg),
        load.offset,
        regName(address_reg),
    });
}

fn memoryDataLabel(context: *FunctionContext, address: ast.ValueRef) ?[]const u8 {
    const name = switch (address) {
        .ident => |name| name,
        else => return null,
    };
    const symbol = context.lookup(name) catch return null;
    return symbol.data_label;
}

fn validateMemoryOffset(offset: i64) !void {
    if (offset < std.math.minInt(i16) or offset > std.math.maxInt(i16)) {
        return error.MemoryOffsetOutOfRange;
    }
}

fn writeCall(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    call: ast.Call,
) anyerror!void {
    if (call.module != null) return error.UnresolvedModuleCall;
    const function = findFunction(functions, call.name) orelse return error.UnknownFunction;
    try writeFunctionArguments(writer, functions, context, function, call.arguments, true);

    if (function.inline_call) {
        var inline_context = FunctionContext{
            .label_prefix = context.label_prefix,
            .next_label = context.next_label,
            .clobbers = context.clobbers,
            .functions = functions,
            .function_forbidden_scalar = context.function_forbidden_scalar,
            .function_forbidden_vector = context.function_forbidden_vector,
        };
        for (context.symbols[0..context.symbol_count]) |caller_symbol| {
            if (caller_symbol.automatic and caller_symbol.last_use < context.statement_position) continue;
            var reserved_symbol = caller_symbol;
            reserved_symbol.automatic = false;
            reserved_symbol.last_use = std.math.maxInt(usize);
            try inline_context.add(reserved_symbol);
        }
        try inline_context.prepareLifetimes(functions, function.parameters, function.statements);
        for (function.parameters) |parameter| {
            if (inline_context.lookup(parameter.name) catch null) |existing| {
                if (existing.data_type != parameter.data_type) return error.FunctionArgumentTypeMismatch;
                if (existing.reg != parameter.reg or existing.vector_reg != parameter.vector_reg) {
                    return error.FunctionArgumentRegisterMismatch;
                }
                continue;
            }
            try inline_context.add(.{
                .name = parameter.name,
                .data_type = parameter.data_type,
                .reg = parameter.reg,
                .vector_reg = parameter.vector_reg,
                .constant = null,
            });
        }
        try writeStatements(writer, functions, &inline_context, function.statements);
        context.next_label = inline_context.next_label;
        return;
    }

    try writer.print("  jal {s}\n", .{call.name});
    try writeDelaySlot(writer, functions, context, call.delay_slot);
}

fn writeFunctionArguments(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    function: ast.Function,
    arguments: []const ast.ValueRef,
    allow_signedness_change: bool,
) !void {
    if (arguments.len != function.parameters.len) return error.FunctionArgumentCountMismatch;

    // Register arguments form a parallel assignment. Emit copies before constants,
    // and order them so a destination never destroys a source still needed by a
    // later copy.
    var pending: [64]bool = @splat(false);
    if (arguments.len > pending.len) return error.TooManyFunctionArguments;
    var pending_count: usize = 0;
    for (arguments, function.parameters, 0..) |argument, parameter, index| {
        const name = switch (argument) {
            .ident => |name| name,
            else => continue,
        };
        const symbol = try context.lookup(name);
        if (isVectorType(parameter.data_type) or symbol.reg == null or symbol.reg == parameter.reg) continue;
        var visited: [1024]ParameterWriteVisit = undefined;
        var visited_count: usize = 0;
        if (functionParameterIsWritten(functions, function, index, &visited, &visited_count)) {
            return error.FunctionArgumentRegisterMismatch;
        }
        pending[index] = true;
        pending_count += 1;
    }
    while (pending_count != 0) {
        var emitted = false;
        for (arguments, function.parameters, 0..) |argument, parameter, index| {
            if (!pending[index]) continue;
            const destination = parameter.reg.?;
            var destination_is_source = false;
            for (arguments, 0..) |other_argument, other_index| {
                if (!pending[other_index] or other_index == index) continue;
                const other_name = switch (other_argument) {
                    .ident => |name| name,
                    else => continue,
                };
                if ((try context.lookup(other_name)).reg == destination) {
                    destination_is_source = true;
                    break;
                }
            }
            if (destination_is_source) continue;
            const name = argument.ident;
            const source = (try context.lookup(name)).reg.?;
            try writer.print("  or {s}, {s}, $zero\n", .{ regName(destination), regName(source) });
            pending[index] = false;
            pending_count -= 1;
            emitted = true;
        }
        if (!emitted) return error.FunctionArgumentMoveCycle;
    }

    for (arguments, function.parameters) |argument, parameter| {
        switch (argument) {
            .vector_access => return error.FunctionArgumentTypeMismatch,
            .number => |number| {
                if (isVectorType(parameter.data_type)) return error.VectorArgumentMustBeRegister;
                try loadImmediateInto(writer, parameter.reg orelse return error.InvalidScalarRegister, number);
            },
            .ident => |name| {
                const symbol = try context.lookup(name);
                if (symbol.data_type != parameter.data_type and
                    !(allow_signedness_change and scalarAbiTypesCompatible(symbol.data_type, parameter.data_type)))
                {
                    return error.FunctionArgumentTypeMismatch;
                }
                if (isVectorType(parameter.data_type)) {
                    if (symbol.vector_reg != parameter.vector_reg) {
                        return error.FunctionArgumentRegisterMismatch;
                    }
                } else if (symbol.reg) |_| {
                    // A mismatched scalar register was copied by the parallel
                    // assignment pass above.
                } else {
                    try loadImmediateInto(
                        writer,
                        parameter.reg orelse return error.InvalidScalarRegister,
                        symbol.constant orelse return error.ExpectedConstant,
                    );
                }
            },
        }
    }
}

fn writeBuiltin(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    builtin: ast.Builtin,
) !void {
    switch (builtin) {
        .nop => try writer.writeAll("  nop\n"),
        .breakpoint => |code| if (code == 0)
            try writer.writeAll("  break\n")
        else
            try writer.print("  break 0x{x}\n", .{code}),
        .jump => |jump| {
            if (jump.typed) {
                const address_name = switch (jump.address) {
                    .ident => |name| name,
                    else => return error.TypedJumpRequiresFunctionPointer,
                };
                const address = try context.lookup(address_name);
                if (address.function_type == null) return error.TypedJumpRequiresFunctionPointer;
            }
            const address_reg = try valueAsAddressReg(writer, context, jump.address);
            try writer.print("  jr {s}\n", .{regName(address_reg)});
            try writeDelaySlot(writer, functions, context, jump.delay_slot);
        },
        .return_from_function => |delay_slot| {
            try writer.writeAll("  jr $ra\n");
            try writeDelaySlot(writer, functions, context, delay_slot);
        },
        .direct_goto => |branch| {
            if (branch.target.module != null) return error.UnresolvedModuleCall;
            if (branch.typed) {
                const function = findFunction(functions, branch.target.name) orelse return error.UnknownFunction;
                try writeFunctionArguments(writer, functions, context, function, branch.arguments, true);
            }
            try writer.print("  {s} {s}\n", .{
                if (branch.encoding == .jump) "j" else "b",
                branch.target.name,
            });
            try writeDelaySlot(writer, functions, context, branch.delay_slot);
        },
        .tail => |tail| {
            if (tail.target.module != null) return error.UnresolvedModuleCall;
            const function = findFunction(functions, tail.target.name) orelse return error.UnknownFunction;
            if (function.inline_call) return error.CannotTailInlineFunction;
            try writeFunctionArguments(writer, functions, context, function, tail.arguments, true);
            if (context.statement_position != context.omitted_tail_position or
                context.omitted_tail_target == null or
                !std.mem.eql(u8, context.omitted_tail_target.?, tail.target.name))
            {
                try writer.print("  j {s}\n", .{tail.target.name});
                try writeDelaySlot(writer, functions, context, tail.delay_slot);
            } else if (tail.delay_slot) |delay_slot| {
                try validateDelaySlot(delay_slot);
                try writeStatements(writer, functions, context, delay_slot);
            }
        },
        .write_vector_control => |control_write| {
            const source_reg = try valueAsAddressReg(writer, context, control_write.value);
            const word = @as(u32, 0x48c00000) |
                (@as(u32, @intFromEnum(source_reg)) << 16) |
                (@as(u32, @intFromEnum(control_write.register)) << 11);
            try writer.print("  .word 0x{x:0>8} # ctc2 {s}, ${d}\n", .{
                word, regName(source_reg), @intFromEnum(control_write.register),
            });
        },
        .vector_memory => |memory| {
            const vector = try context.lookup(memory.vector.name);
            if (memory.vector.lane != null) return error.PartialVectorMemoryRequiresVec16;
            const vector_reg = try vectorRegisterForView(vector, memory.vector.view);
            if (vector.data_type != .vec16 and memory.vector.view == null) {
                return error.PartialVectorMemoryRequiresVec16;
            }
            const address_reg = try valueAsDmemReg(writer, context, memory.address);
            switch (memory.operation) {
                .load16 => try writeVectorLaneMemory(writer, true, vector_reg, memory.lane, address_reg, memory.offset),
                .store16 => try writeVectorLaneMemory(writer, false, vector_reg, memory.lane, address_reg, memory.offset),
                .load32 => try writeQuarterVectorMemory(writer, true, vector_reg, memory.lane, address_reg, memory.offset),
                .store32 => try writeQuarterVectorMemory(writer, false, vector_reg, memory.lane, address_reg, memory.offset),
                .load64 => try writeHalfVectorMemory(writer, true, vector_reg, memory.lane, address_reg, memory.offset),
                .store64 => try writeHalfVectorMemory(writer, false, vector_reg, memory.lane, address_reg, memory.offset),
                .load128 => try writeVectorMemory(writer, true, vector_reg, address_reg, memory.offset),
                .store128 => try writeVectorMemory(writer, false, vector_reg, address_reg, memory.offset),
                .load_packed_signed, .load_packed_unsigned => try writeVectorLoad(writer, context, vector_reg, .{
                    .data_type = .vec16,
                    .address = memory.address,
                    .offset = memory.offset,
                    .packed_u8 = memory.operation == .load_packed_signed,
                    .packed_unsigned_u8 = memory.operation == .load_packed_unsigned,
                }),
            }
        },
        .hardware_write => |hardware_write| {
            const source_reg = if (hardware_write.requires_dmem)
                try valueAsDmemReg(writer, context, hardware_write.value)
            else
                try valueAsAddressReg(writer, context, hardware_write.value);
            const register: u4 = switch (hardware_write.operation) {
                .cp0 => |register| register,
            };
            try writer.print("  mtc0 {s}, ${d}\n", .{ regName(source_reg), register });
        },
        .hardware_read_register => |transfer| try writer.print("  mfc0 {s}, ${d}\n", .{
            regName(transfer.destination), transfer.hardware_register,
        }),
        .hardware_write_register => |transfer| try writer.print("  mtc0 {s}, ${d}\n", .{
            regName(transfer.source), transfer.hardware_register,
        }),
    }
}

fn scalarAbiTypesCompatible(lhs: DataType, rhs: DataType) bool {
    if (isVectorType(lhs) or isVectorType(rhs)) return false;
    return (scalarDataSize(lhs) catch return false) == (scalarDataSize(rhs) catch return false);
}

fn writeDelaySlot(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    delay_slot: ?[]ast.Statement,
) !void {
    if (delay_slot) |statements| {
        try validateDelaySlot(statements);
        try writeStatements(writer, functions, context, statements);
    } else {
        try writer.writeAll("  nop\n");
    }
}

fn writeConditionalDirectDelaySlot(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    delay_slot: ?[]ast.Statement,
) !void {
    if (delay_slot != null or context.shared_exit_label == null) {
        return writeDelaySlot(writer, functions, context, delay_slot);
    }
    const delay = context.shared_exit_delay orelse return error.MissingSharedExitSlot;
    try validateDelaySlot(delay);
    try writer.print("LABEL_{s}_blockend_{d}:\n", .{ context.label_prefix, context.shared_exit_label.? });
    try writeStatements(writer, functions, context, delay);
    context.shared_exit_consumed = true;
}

fn writeWhile(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    loop: anytype,
) anyerror!void {
    const label = context.allocLabel();
    if (context.emission_loop_count >= context.emission_loops.len) return error.TooManyNestedLoops;
    context.emission_loops[context.emission_loop_count] = .{
        .name = loop.label,
        .label = label,
        .continue_suffix = "while",
        .break_suffix = "whileend",
    };
    context.emission_loop_count += 1;
    defer context.emission_loop_count -= 1;

    try writer.print("LABEL_{s}_while_{d}:\n", .{ context.label_prefix, label });
    try writeConditionBranchFalse(writer, context, loop.condition, "whileend", label, true);
    const scope = context.pushScope();
    defer context.popScope(scope);
    try writeStatements(writer, functions, context, loop.statements);
    if (!statementsTerminateControlFlow(loop.statements)) {
        try writer.print("  j LABEL_{s}_while_{d}\n", .{ context.label_prefix, label });
        try writer.writeAll("  nop\n");
    }
    try writer.print("LABEL_{s}_whileend_{d}:\n", .{ context.label_prefix, label });
}

fn writeDoWhile(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    loop: anytype,
) anyerror!void {
    const label = context.allocLabel();
    if (context.emission_loop_count >= context.emission_loops.len) return error.TooManyNestedLoops;
    context.emission_loops[context.emission_loop_count] = .{
        .name = loop.label,
        .label = label,
        .continue_suffix = "dowhilecond",
        .break_suffix = "dowhileend",
    };
    context.emission_loop_count += 1;
    defer context.emission_loop_count -= 1;

    const needs_continue_label = statementsContainLoopContinue(loop.statements);
    try writer.print("LABEL_{s}_dowhile_{d}:\n", .{ context.label_prefix, label });
    const scope = context.pushScope();
    defer context.popScope(scope);
    try writeStatements(writer, functions, context, loop.statements);
    if (needs_continue_label) {
        try writer.print("LABEL_{s}_dowhilecond_{d}:\n", .{ context.label_prefix, label });
    }
    if (context.track_statement_position) context.statement_position += 1;
    var inverse = loop.condition;
    inverse.op = invertComparison(inverse.op);
    try writeConditionBranchFalse(writer, context, inverse, "dowhile", label, loop.delay_slot == null);
    if (loop.delay_slot) |delay| {
        try validateDelaySlot(delay);
        try writeStatements(writer, functions, context, delay);
    }
    try writer.print("LABEL_{s}_dowhileend_{d}:\n", .{ context.label_prefix, label });
}

fn writeLabeledBlock(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    block: anytype,
) anyerror!void {
    const label = context.allocLabel();
    if (context.emission_loop_count >= context.emission_loops.len) return error.TooManyNestedLoops;
    context.emission_loops[context.emission_loop_count] = .{
        .name = block.label,
        .label = label,
        .continue_suffix = "",
        .break_suffix = "blockend",
    };
    context.emission_loop_count += 1;
    defer context.emission_loop_count -= 1;

    const scope = context.pushScope();
    defer context.popScope(scope);
    const terminal_can_share = if (block.statements.len == 0)
        false
    else switch (block.statements[block.statements.len - 1]) {
        .conditional_direct_goto => |branch| branch.delay_slot == null,
        .goto => |branch| branch.delay_slot == null,
        .break_loop => |transfer| transfer.delay_slot == null,
        else => false,
    };
    const can_share = block.exit_delay != null and terminal_can_share;
    if (can_share) {
        try writeStatements(writer, functions, context, block.statements[0 .. block.statements.len - 1]);
        const saved_label = context.shared_exit_label;
        const saved_delay = context.shared_exit_delay;
        const saved_consumed = context.shared_exit_consumed;
        context.shared_exit_label = label;
        context.shared_exit_delay = block.exit_delay;
        context.shared_exit_consumed = false;
        defer {
            context.shared_exit_label = saved_label;
            context.shared_exit_delay = saved_delay;
            context.shared_exit_consumed = saved_consumed;
        }
        try writeStatements(writer, functions, context, block.statements[block.statements.len - 1 ..]);
        if (!context.shared_exit_consumed) {
            try writer.print("LABEL_{s}_blockend_{d}:\n", .{ context.label_prefix, label });
            try writeStatements(writer, functions, context, block.exit_delay.?);
        }
    } else {
        try writeStatements(writer, functions, context, block.statements);
        try writer.print("LABEL_{s}_blockend_{d}:\n", .{ context.label_prefix, label });
        if (block.exit_delay) |delay| try writeStatements(writer, functions, context, delay);
    }
}

fn statementsContainLoopContinue(statements: []const ast.Statement) bool {
    for (statements) |statement| switch (statement) {
        .continue_loop => return true,
        .while_loop => |loop| if (statementsContainLoopContinue(loop.statements)) return true,
        .do_while_loop => |loop| if (statementsContainLoopContinue(loop.statements)) return true,
        .if_statement => |branch| {
            if (branch.delay_slot) |items| if (statementsContainLoopContinue(items)) return true;
            if (statementsContainLoopContinue(branch.then_statements)) return true;
            if (branch.else_statements) |items| if (statementsContainLoopContinue(items)) return true;
        },
        .labeled_block => |block| {
            if (statementsContainLoopContinue(block.statements)) return true;
            if (block.exit_delay) |delay| if (statementsContainLoopContinue(delay)) return true;
        },
        .ordered_block => |items| if (statementsContainLoopContinue(items)) return true,
        else => {},
    };
    return false;
}

fn invertComparison(op: ast.CompareOp) ast.CompareOp {
    return switch (op) {
        .eq => .ne,
        .ne => .eq,
        .lt => .ge,
        .le => .gt,
        .gt => .le,
        .ge => .lt,
    };
}

fn statementsTerminateControlFlow(statements: []const ast.Statement) bool {
    if (statements.len == 0) return false;
    return switch (statements[statements.len - 1]) {
        .break_loop, .continue_loop, .goto => true,
        .builtin => |builtin| switch (builtin) {
            .jump, .return_from_function, .direct_goto, .tail => true,
            else => false,
        },
        else => false,
    };
}

fn writeLoopTransfer(
    writer: *std.Io.Writer,
    context: *const FunctionContext,
    name: ?[]const u8,
    is_continue: bool,
) !void {
    var index = context.emission_loop_count;
    while (index > 0) {
        index -= 1;
        const loop = context.emission_loops[index];
        if (name) |requested| {
            const actual = loop.name orelse continue;
            if (!std.mem.eql(u8, requested, actual)) continue;
        }
        if (is_continue and loop.continue_suffix.len == 0) return error.CannotContinueBlock;
        try writer.print("  j LABEL_{s}_{s}_{d}\n  nop\n", .{
            context.label_prefix,
            if (is_continue) loop.continue_suffix else loop.break_suffix,
            loop.label,
        });
        return;
    }
    return error.UnknownLoopLabel;
}

fn writeBreakTransfer(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    transfer: ast.BreakTransfer,
) !void {
    var index = context.emission_loop_count;
    while (index > 0) {
        index -= 1;
        const target = context.emission_loops[index];
        if (transfer.label) |requested| {
            const actual = target.name orelse continue;
            if (!std.mem.eql(u8, requested, actual)) continue;
        }
        try writer.print("  j LABEL_{s}_{s}_{d}\n", .{ context.label_prefix, target.break_suffix, target.label });
        try writeConditionalDirectDelaySlot(writer, functions, context, transfer.delay_slot);
        return;
    }
    return error.UnknownLoopLabel;
}

fn writeIf(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    if_statement: anytype,
) anyerror!void {
    const label = context.allocLabel();
    if (if_statement.else_statements == null and if_statement.then_statements.len == 1 and
        if_statement.then_statements[0] == .break_loop and if_statement.then_statements[0].break_loop.label != null)
    {
        const transfer = if_statement.then_statements[0].break_loop;
        const target_name = transfer.label.?;
        if (if_statement.delay_slot != null and transfer.delay_slot != null) return error.MultipleDelaySlots;
        const delay_slot = if_statement.delay_slot orelse transfer.delay_slot;
        var target_index = context.emission_loop_count;
        while (target_index > 0) {
            target_index -= 1;
            const target = context.emission_loops[target_index];
            if (target.name == null or !std.mem.eql(u8, target.name.?, target_name)) continue;
            var inverse = if_statement.condition;
            inverse.op = invertComparison(inverse.op);
            try writeConditionBranchFalse(writer, context, inverse, target.break_suffix, target.label, delay_slot == null);
            try writeStructuredDelaySlot(writer, functions, context, delay_slot);
            if (context.track_statement_position) context.statement_position += 1;
            return;
        }
        return error.UnknownLoopLabel;
    }
    const then_terminates = statementsTerminateControlFlow(if_statement.then_statements);
    const else_terminates = if (if_statement.else_statements) |items| statementsTerminateControlFlow(items) else false;
    const reorder = if_statement.else_statements != null and else_terminates and !then_terminates;

    if (reorder) {
        var inverse = if_statement.condition;
        inverse.op = invertComparison(inverse.op);
        try writeConditionBranchFalse(writer, context, inverse, "ifthen", label, if_statement.delay_slot == null);
        try writeStructuredDelaySlot(writer, functions, context, if_statement.delay_slot);

        const source_position = context.statement_position;
        const then_count = countFlowStatements(if_statement.then_statements);
        context.statement_position = source_position + then_count;
        const else_scope = context.pushScope();
        try writeStatements(writer, functions, context, if_statement.else_statements.?);
        context.popScope(else_scope);

        try writer.print("LABEL_{s}_ifthen_{d}:\n", .{ context.label_prefix, label });
        context.statement_position = source_position;
        const then_scope = context.pushScope();
        try writeStatements(writer, functions, context, if_statement.then_statements);
        context.popScope(then_scope);
        context.statement_position = source_position + then_count + countFlowStatements(if_statement.else_statements.?);
        try writer.print("LABEL_{s}_ifend_{d}:\n", .{ context.label_prefix, label });
        return;
    }

    const false_suffix: []const u8 = if (if_statement.else_statements != null) "ifelse" else "ifend";
    try writeConditionBranchFalse(writer, context, if_statement.condition, false_suffix, label, if_statement.delay_slot == null);
    try writeStructuredDelaySlot(writer, functions, context, if_statement.delay_slot);

    const then_scope = context.pushScope();
    try writeStatements(writer, functions, context, if_statement.then_statements);
    context.popScope(then_scope);

    if (if_statement.else_statements) |else_statements| {
        if (!then_terminates) {
            try writer.print("  j LABEL_{s}_ifend_{d}\n", .{ context.label_prefix, label });
            try writer.writeAll("  nop\n");
        }
        try writer.print("LABEL_{s}_ifelse_{d}:\n", .{ context.label_prefix, label });
        const else_scope = context.pushScope();
        try writeStatements(writer, functions, context, else_statements);
        context.popScope(else_scope);
    }
    try writer.print("LABEL_{s}_ifend_{d}:\n", .{ context.label_prefix, label });
}

fn writeStructuredDelaySlot(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    delay_slot: ?[]ast.Statement,
) !void {
    const delay = delay_slot orelse return;
    try validateDelaySlot(delay);
    try writeStatements(writer, functions, context, delay);
}

fn validateDelaySlot(statements: []const ast.Statement) !void {
    const instruction_index: usize = if (statements.len == 2 and statements[0] == .label) 1 else 0;
    if (statements.len != instruction_index + 1) return error.InvalidSlot;
    switch (statements[instruction_index]) {
        .builtin => |builtin| switch (builtin) {
            .nop => return error.UnnecessarySlot,
            else => {},
        },
        else => {},
    }
}

fn writeConditionBranchFalse(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    condition: ast.Condition,
    label_suffix: []const u8,
    label: usize,
    emit_nop: bool,
) !void {
    const lhs = try context.lookup(condition.lhs);
    const lhs_reg = lhs.reg orelse return error.ConditionLhsMustBeRegister;
    var rhs_reg: ?Register = null;
    var rhs_immediate: ?i64 = null;
    switch (condition.rhs) {
        .number => |number| rhs_immediate = number,
        .vector_access => return error.ConditionRhsMustBeRegisterOrNumber,
        .vector_operation => return error.ConditionRhsMustBeRegisterOrNumber,
        .vector_shift => return error.ConditionRhsMustBeRegisterOrNumber,
        .accumulator_read => return error.ConditionRhsMustBeRegisterOrNumber,
        .vector_control_read => return error.ConditionRhsMustBeRegisterOrNumber,
        .hardware_read => return error.ConditionRhsMustBeRegisterOrNumber,
        .scalar_comparison => return error.ConditionRhsMustBeRegisterOrNumber,
        .signed_less_than => return error.ConditionRhsMustBeRegisterOrNumber,
        .ident => |name| blk: {
            const rhs = try context.lookup(name);
            try expectSameType(lhs, rhs);
            if (rhs.reg) |reg| {
                rhs_reg = reg;
                break :blk;
            }
            rhs_immediate = rhs.constant orelse return error.ExpectedConstant;
        },
        .load => return error.ConditionRhsMustBeRegisterOrNumber,
        .scalar_expression => return error.ConditionRhsMustBeRegisterOrNumber,
        .function_address, .data_address => return error.ConditionRhsMustBeRegisterOrNumber,
    }

    switch (condition.op) {
        .eq, .ne => {
            if (rhs_reg == null) {
                const immediate = rhs_immediate.?;
                if (immediate == 0) {
                    rhs_reg = .zero;
                } else {
                    const scratch = try backendScratch2(context);
                    try loadImmediateInto(writer, scratch, immediate);
                    rhs_reg = scratch;
                }
            }
            const branch = if (condition.op == .eq) "bne" else "beq";
            try writer.print("  {s} {s}, {s}, LABEL_{s}_{s}_{d}\n", .{
                branch,
                regName(lhs_reg),
                regName(rhs_reg.?),
                context.label_prefix,
                label_suffix,
                label,
            });
        },
        .lt, .le, .gt, .ge => {
            if (rhs_immediate) |immediate| {
                if (isSigned(lhs.data_type) and immediate == 0) {
                    try writer.print("  {s} {s}, LABEL_{s}_{s}_{d}\n", .{
                        switch (condition.op) {
                            .lt => "bgez",
                            .le => "bgtz",
                            .gt => "blez",
                            .ge => "bltz",
                            else => unreachable,
                        },
                        regName(lhs_reg),
                        context.label_prefix,
                        label_suffix,
                        label,
                    });
                    if (emit_nop) try writer.writeAll("  nop\n");
                    return;
                }
                // Unsigned comparisons at the sign-bit boundary are exactly
                // signed zero tests and need no materialized constant or SLTU.
                if (!isSigned(lhs.data_type) and immediate == 0x80000000 and
                    (condition.op == .lt or condition.op == .ge))
                {
                    try writer.print("  {s} {s}, LABEL_{s}_{s}_{d}\n", .{
                        if (condition.op == .lt) "bltz" else "bgez",
                        regName(lhs_reg),
                        context.label_prefix,
                        label_suffix,
                        label,
                    });
                    if (emit_nop) try writer.writeAll("  nop\n");
                    return;
                }
                const adjusted = if (condition.op == .gt or condition.op == .le)
                    std.math.add(i64, immediate, 1) catch null
                else
                    immediate;
                if (adjusted) |value| {
                    if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
                        const instruction = if (isSigned(lhs.data_type)) "slti" else "sltiu";
                        try writer.print("  {s} {s}, {s}, {d}\n", .{
                            instruction,
                            regName(compiler_scratch),
                            regName(lhs_reg),
                            value,
                        });
                        const branch = switch (condition.op) {
                            .lt, .le => "beq",
                            .gt, .ge => "bne",
                            else => unreachable,
                        };
                        try writer.print("  {s} {s}, {s}, LABEL_{s}_{s}_{d}\n", .{
                            branch,
                            regName(compiler_scratch),
                            regName(.zero),
                            context.label_prefix,
                            label_suffix,
                            label,
                        });
                        if (emit_nop) try writer.writeAll("  nop\n");
                        return;
                    }
                }

                const scratch = try backendScratch2(context);
                try loadImmediateInto(writer, scratch, immediate);
                rhs_reg = scratch;
            }

            const instruction = if (isSigned(lhs.data_type)) "slt" else "sltu";
            const reverse = condition.op == .gt or condition.op == .le;
            const first = if (reverse) rhs_reg.? else lhs_reg;
            const second = if (reverse) lhs_reg else rhs_reg.?;
            try writer.print("  {s} {s}, {s}, {s}\n", .{
                instruction,
                regName(compiler_scratch),
                regName(first),
                regName(second),
            });
            const branch = switch (condition.op) {
                .lt, .gt => "beq",
                .le, .ge => "bne",
                else => unreachable,
            };
            try writer.print("  {s} {s}, {s}, LABEL_{s}_{s}_{d}\n", .{
                branch,
                regName(compiler_scratch),
                regName(.zero),
                context.label_prefix,
                label_suffix,
                label,
            });
        },
    }
    if (emit_nop) try writer.writeAll("  nop\n");
}

fn valueAsImmediate(context: *FunctionContext, value: ast.Value) !i64 {
    return switch (value) {
        .number => |number| number,
        .ident => |name| (try context.lookup(name)).constant orelse error.ExpectedConstant,
        .vector_access => error.ExpectedConstant,
        .vector_operation => error.ExpectedConstant,
        .vector_shift => error.ExpectedConstant,
        .accumulator_read => error.ExpectedConstant,
        .vector_control_read => error.ExpectedConstant,
        .hardware_read => error.ExpectedConstant,
        .scalar_comparison => error.ExpectedConstant,
        .signed_less_than => error.ExpectedConstant,
        .load => error.ExpectedConstant,
        .scalar_expression => error.ExpectedConstant,
        .function_address, .data_address => error.ExpectedConstant,
    };
}

fn valueAsAddressReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            if (symbol.reg) |reg| return reg;
            if (symbol.data_label) |label| {
                try loadDataAddress(writer, compiler_scratch, label);
                return compiler_scratch;
            }
            const address = symbol.constant orelse return error.AddressMustBeRegister;
            if (address == 0) return .zero;
            try loadImmediateInto(writer, compiler_scratch, address);
            return compiler_scratch;
        },
        .number => |number| {
            if (number == 0) return .zero;
            try loadImmediateInto(writer, compiler_scratch, number);
            return compiler_scratch;
        },
        .vector_access => return error.AddressMustBeRegister,
    }
}

fn valueAsDmemReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            if (symbol.data_label) |label| {
                try loadDataAddress(writer, compiler_scratch, label);
                return compiler_scratch;
            }
            if (symbol.data_type != .dmem) return error.ExpectedDmemAddress;
            if (symbol.reg) |reg| return reg;
            const address = symbol.constant orelse return error.AddressMustBeRegister;
            if (address < 0 or address >= 4096) return error.DmemAddressOutOfRange;
            if (address == 0) return .zero;
            try loadImmediateInto(writer, compiler_scratch, address);
            return compiler_scratch;
        },
        .number => |number| {
            if (number < 0 or number >= 4096) return error.DmemAddressOutOfRange;
            if (number == 0) return .zero;
            try loadImmediateInto(writer, compiler_scratch, number);
            return compiler_scratch;
        },
        .vector_access => return error.ExpectedDmemAddress,
    }
}

fn loadDataAddress(writer: *std.Io.Writer, reg: Register, label: []const u8) !void {
    try writer.print("  addiu {s}, $zero, %lo({s})\n", .{ regName(reg), label });
}

fn valueAsStoreReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            if (symbol.reg) |reg| return reg;
            return try loadImmediate(writer, context, symbol.constant orelse return error.StoreValueMustBeRegister);
        },
        .number => |number| return try loadImmediate(writer, context, number),
        .vector_access => return error.StoreValueMustBeRegister,
    }
}

fn loadImmediate(writer: *std.Io.Writer, context: *FunctionContext, value: i64) !Register {
    if (value == 0) return .zero;
    const scratch = try backendScratch2(context);
    try loadImmediateInto(writer, scratch, value);
    return scratch;
}

fn backendScratch2(context: *const FunctionContext) !Register {
    if (context.isRegisterInUse(compiler_scratch_2)) return error.BackendScratchRegisterUnavailable;
    return compiler_scratch_2;
}

fn loadImmediateInto(writer: *std.Io.Writer, reg: Register, value: i64) !void {
    if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
        try writer.print("  addiu {s}, {s}, {d}\n", .{ regName(reg), regName(.zero), value });
        return;
    }
    if (value >= 0 and value <= std.math.maxInt(u16)) {
        try writer.print("  ori {s}, {s}, {d}\n", .{ regName(reg), regName(.zero), value });
        return;
    }
    if (value < std.math.minInt(i32) or value > std.math.maxInt(u32)) return error.ImmediateOutOfRange;

    const bits: u32 = if (value < 0)
        @bitCast(@as(i32, @intCast(value)))
    else
        @intCast(value);
    const upper: u16 = @truncate(bits >> 16);
    const lower: u16 = @truncate(bits);
    try writer.print("  lui {s}, {d}\n", .{ regName(reg), upper });
    if (lower != 0) {
        try writer.print("  ori {s}, {s}, {d}\n", .{ regName(reg), regName(reg), lower });
    }
}

fn findFunction(functions: []const ast.Function, name: []const u8) ?ast.Function {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn isScalarRegister(reg: Register) bool {
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

fn isSigned(data_type: DataType) bool {
    return switch (data_type) {
        .i8, .i16, .i32 => true,
        .u8, .u16, .u32, .dmem => false,
        .vec16, .vec32 => unreachable,
    };
}

fn storeOp(data_type: DataType) []const u8 {
    return switch (data_type) {
        .u8, .i8 => "sb",
        .u16, .i16 => "sh",
        .u32, .i32, .dmem => "sw",
        .vec16, .vec32 => unreachable,
    };
}

fn loadOp(data_type: DataType) []const u8 {
    return switch (data_type) {
        .u8 => "lbu",
        .i8 => "lb",
        .u16 => "lhu",
        .i16 => "lh",
        .u32, .i32, .dmem => "lw",
        .vec16, .vec32 => unreachable,
    };
}

fn isVectorType(data_type: DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

fn nextVectorRegister(reg: ast.VectorRegister) ?ast.VectorRegister {
    const index = @intFromEnum(reg);
    if (index == 31) return null;
    return @enumFromInt(index + 1);
}

fn vectorRegisterForView(symbol: Symbol, view: ?ast.VectorView) !ast.VectorRegister {
    const reg = symbol.vector_reg orelse return error.ExpectedVectorRegister;
    if (symbol.data_type == .vec16) return reg;
    if (symbol.data_type != .vec32) return error.ExpectedVectorType;
    return switch (view orelse return reg) {
        .sint, .uint => reg,
        .sfract, .ufract => nextVectorRegister(reg) orelse error.InvalidVectorRegisterPair,
    };
}

fn vectorRegName(reg: ast.VectorRegister) []const u8 {
    return @tagName(reg);
}

fn regName(reg: Register) []const u8 {
    return switch (reg) {
        .zero => "$zero",
        .at => "$at",
        .v0 => "$v0",
        .v1 => "$v1",
        .a0 => "$a0",
        .a1 => "$a1",
        .a2 => "$a2",
        .a3 => "$a3",
        .t0 => "$t0",
        .t1 => "$t1",
        .t2 => "$t2",
        .t3 => "$t3",
        .t4 => "$t4",
        .t5 => "$t5",
        .t6 => "$t6",
        .t7 => "$t7",
        .s0 => "$s0",
        .s1 => "$s1",
        .s2 => "$s2",
        .s3 => "$s3",
        .s4 => "$s4",
        .s5 => "$s5",
        .s6 => "$s6",
        .s7 => "$s7",
        .t8 => "$t8",
        .t9 => "$t9",
        .k0 => "$k0",
        .k1 => "$k1",
        .gp => "$gp",
        .sp => "$sp",
        .fp => "$fp",
        .ra => "$ra",
    };
}
