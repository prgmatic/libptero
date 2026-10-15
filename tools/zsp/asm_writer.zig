const writeHalfVectorMemory = @import("emit_vectors.zig").writeHalfVectorMemory;
const writeMfc2 = @import("emit_vectors.zig").writeMfc2;
const writePackedVectorStore = @import("emit_vectors.zig").writePackedVectorStore;
const writeQuarterVectorMemory = @import("emit_vectors.zig").writeQuarterVectorMemory;
const writeSpecialVectorMemory = @import("emit_vectors.zig").writeSpecialVectorMemory;
const writeVectorAssignment = @import("emit_vectors.zig").writeVectorAssignment;
const writeVectorInitialValue = @import("emit_vectors.zig").writeVectorInitialValue;
const writeVectorLaneMemory = @import("emit_vectors.zig").writeVectorLaneMemory;
const writeVectorLoad = @import("emit_vectors.zig").writeVectorLoad;
const writeVectorMemory = @import("emit_vectors.zig").writeVectorMemory;
const backendScratch2 = @import("emit_operands.zig").backendScratch2;
const loadDataAddress = @import("emit_operands.zig").loadDataAddress;
const loadImmediateInto = @import("emit_operands.zig").loadImmediateInto;
const valueAsAddressReg = @import("emit_operands.zig").valueAsAddressReg;
const valueAsDmemReg = @import("emit_operands.zig").valueAsDmemReg;
const valueAsImmediate = @import("emit_operands.zig").valueAsImmediate;
const valueAsStoreReg = @import("emit_operands.zig").valueAsStoreReg;
const FunctionClobberRegistry = @import("analysis.zig").FunctionClobberRegistry;
const FunctionContext = @import("analysis.zig").FunctionContext;
const ParameterWriteVisit = @import("analysis.zig").ParameterWriteVisit;
const Symbol = @import("analysis.zig").Symbol;
const bindParameters = @import("analysis.zig").bindParameters;
const countFlowStatements = @import("analysis.zig").countFlowStatements;
const findFunction = @import("analysis.zig").findFunction;
const functionParameterIsWritten = @import("analysis.zig").functionParameterIsWritten;
const isPureScalarExpression = @import("analysis.zig").isPureScalarExpression;
const isScalarRegister = @import("analysis.zig").isScalarRegister;
const isVectorType = @import("analysis.zig").isVectorType;
const reserveTransposeBank = @import("analysis.zig").reserveTransposeBank;
const validateVectorRegisterBinding = @import("analysis.zig").validateVectorRegisterBinding;
const valueReadsName = @import("analysis.zig").valueReadsName;
const vectorRegisterForView = @import("analysis.zig").vectorRegisterForView;
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
    const placement = try @import("placement.zig").Plan.init(functions);
    for (placement.order[0..placement.len]) |function_index| {
        writeFunction(writer, functions, &top_level_context, function_index, placement.fallthrough[function_index]) catch |err| {
            if (diagnostic) |value| value.function_name = functions[function_index].source_name;
            return err;
        };
    }
    try writeCommandManifest(writer, functions, &command_analysis);
}

fn writeFunction(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    top_level_context: *FunctionContext,
    function_index: usize,
    fallthrough: ?usize,
) !void {
    const function = functions[function_index];
    if (function.external or function.inline_call) return;
    const terminal_jump = endsWithTerminalTransfer(function.statements);
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
    if (fallthrough) |target_index| {
        context.omitted_tail_target = functions[target_index].name;
        context.omitted_tail_position = countFlowStatements(function.statements);
    }
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

fn endsWithTerminalTransfer(statements: []const ast.Statement) bool {
    if (statements.len == 0) return false;
    return switch (statements[statements.len - 1]) {
        .ordered_block => |items| endsWithTerminalTransfer(items),
        .builtin => |builtin| switch (builtin) {
            .direct_goto, .tail, .jump, .return_from_function => true,
            else => false,
        },
        else => false,
    };
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

fn writeStatements(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    statements: []const ast.Statement,
) anyerror!void {
    var statement_index: usize = 0;
    while (statement_index < statements.len) : (statement_index += 1) {
        const statement = statements[statement_index];
        if (context.diagnostic) |diagnostic| diagnostic.selectStatement(functions, &statements[statement_index]);
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
            .exported_label => |name| try writer.print(".globl {s}\n{s}:\n", .{ name, name }),
            .goto => |branch| {
                try writer.print("  {s} LABEL_{s}_{s}_0\n", .{
                    if (branch.encoding == .jump) "j" else "b",
                    context.label_prefix,
                    branch.target,
                });
                try writeConditionalDirectDelaySlot(writer, functions, context, branch.delay_slot);
            },
            .conditional_goto => |branch| {
                const target_label = context.findLifetimeLabel(branch.target);
                if ((target_label == null or target_label.?.exported) and
                    (branch.condition.op == .eq or branch.condition.op == .ne))
                {
                    const lhs = try context.lookup(branch.condition.lhs);
                    const lhs_reg = lhs.reg orelse return error.ConditionLhsMustBeRegister;
                    const rhs_reg: Register = switch (branch.condition.rhs) {
                        .number => |number| if (number == 0)
                            .zero
                        else
                            return error.ConditionRhsMustBeRegisterOrNumber,
                        .ident => |name| blk: {
                            const rhs = try context.lookup(name);
                            try expectSameType(lhs, rhs);
                            break :blk rhs.reg orelse return error.ConditionRhsMustBeRegisterOrNumber;
                        },
                        else => return error.ConditionRhsMustBeRegisterOrNumber,
                    };
                    try writer.print("  {s} {s}, {s}, {s}\n", .{
                        if (branch.condition.op == .eq) "beq" else "bne",
                        regName(lhs_reg),
                        regName(rhs_reg),
                        branch.target,
                    });
                    if (branch.delay_slot) |delay_slot| {
                        try validateDelaySlot(delay_slot);
                        try writeStatements(writer, functions, context, delay_slot);
                    } else try writer.writeAll("  nop\n");
                    continue;
                }
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
                    // Saved overlay state is part of the loadable DMEM image.
                    // Keep zero-only declarations in the same PROGBITS section so
                    // initialized and reserved state retain their source order.
                    .state_block => ".section .state,\"aw\",@progbits\n",
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
    if (decl.is_reserved and reg != compiler_scratch_2 and reg != command_return) {
        return error.InvalidReservedRegister;
    }
    if (!decl.is_reserved and (reg == compiler_scratch_2 or reg == command_return)) {
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
        .vector_control_read, .hardware_read, .scalar_comparison, .signed_less_than, .scalar_materialize, .bit_cast, .function_address, .code_address, .data_address => try writeSet(
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
        .scalar_materialize => |materialize| switch (materialize.encoding) {
            .unsigned => {
                if (materialize.value < 0 or materialize.value > std.math.maxInt(u16)) {
                    return error.ImmediateOutOfRange;
                }
                try writer.print("  ori {s}, $zero, {d}\n", .{
                    regName(destination_reg), materialize.value,
                });
            },
            .zero => try writer.print("  or {s}, $zero, $zero\n", .{regName(destination_reg)}),
        },
        .bit_cast => |source_ref| {
            const source_name = switch (source_ref) {
                .ident => |name| name,
                else => return error.RegisterTypeMismatch,
            };
            const source = try context.lookup(source_name);
            if (source.vector_reg != null or source.reg == null) return error.RegisterTypeMismatch;
            const source_reg = source.reg.?;
            if (source_reg != destination_reg) {
                try writer.print("  or {s}, {s}, $zero\n", .{
                    regName(destination_reg), regName(source_reg),
                });
            }
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
        .code_address => |address| {
            const instruction = if (address.unsigned) "ori" else "addiu";
            if (findFunction(context.functions, address.label)) |function| {
                if (destination.function_type) |expected_type| {
                    if (!functionMatchesType(function, expected_type)) return error.FunctionTypeMismatch;
                }
                try writer.print("  {s} {s}, $zero, %lo({s})\n", .{
                    instruction, regName(destination_reg), address.label,
                });
            } else if (context.findLifetimeLabel(address.label)) |label| {
                if (label.exported) {
                    try writer.print("  {s} {s}, $zero, %lo({s})\n", .{
                        instruction, regName(destination_reg), address.label,
                    });
                } else {
                    try writer.print("  {s} {s}, $zero, %lo(LABEL_{s}_{s}_0)\n", .{
                        instruction, regName(destination_reg), context.label_prefix, address.label,
                    });
                }
            } else {
                return error.UnknownFunction;
            }
        },
        .data_address => |address| {
            if (destination.data_type != .dmem) return error.ExpectedDmemAddress;
            const data = try context.lookup(address.label);
            const label = data.data_label orelse return error.ExpectedDataLabel;
            const instruction = if (address.unsigned) "ori" else "addiu";
            if (address.offset == 0) {
                try writer.print("  {s} {s}, $zero, %lo({s})\n", .{ instruction, regName(destination_reg), label });
            } else {
                try writer.print("  {s} {s}, $zero, %lo({s} + {d})\n", .{
                    instruction, regName(destination_reg), label, address.offset,
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
        .bit_cast => |name| {
            const rhs = try context.lookup(name);
            if (isVectorType(rhs.data_type)) return error.ExpectedScalarType;
            rhs_reg = rhs.reg orelse return error.ComparisonRhsMustBeRegister;
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
        .scalar_materialize => return error.BitNotRequiresRegister,
        .number => return error.BitNotRequiresRegister,
        .load => return error.BitNotRequiresRegister,
        .scalar_expression => return error.BitNotRequiresRegister,
        .bit_cast, .function_address, .code_address, .data_address => return error.BitNotRequiresRegister,
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
    const lhs_is_bit_cast = lhs_value == .bit_cast;
    const lhs = switch (lhs_value) {
        .ident => |name| try context.lookup(name),
        .bit_cast => |source| switch (source) {
            .ident => |name| try context.lookup(name),
            else => return error.ArithmeticLhsMustBeRegister,
        },
        .vector_access => return error.ArithmeticLhsMustBeRegister,
        .vector_operation => return error.ArithmeticLhsMustBeRegister,
        .vector_shift => return error.ArithmeticLhsMustBeRegister,
        .accumulator_read => return error.ArithmeticLhsMustBeRegister,
        .vector_control_read => return error.ArithmeticLhsMustBeRegister,
        .hardware_read => return error.ArithmeticLhsMustBeRegister,
        .scalar_comparison => return error.ArithmeticLhsMustBeRegister,
        .signed_less_than => return error.ArithmeticLhsMustBeRegister,
        .scalar_materialize => return error.ArithmeticLhsMustBeRegister,
        .number => return error.ArithmeticLhsMustBeRegister,
        .load => return error.ArithmeticLhsMustBeRegister,
        .scalar_expression => return error.ArithmeticLhsMustBeRegister,
        .function_address, .code_address, .data_address => return error.ArithmeticLhsMustBeRegister,
    };
    if (!lhs_is_bit_cast) try expectSameType(destination, lhs);
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
            if (rhs.data_label) |label| {
                if (op != .add and op != .add_wrap) return error.UnsupportedOperator;
                try writer.print("  {s} {s}, {s}, %lo({s})\n", .{
                    if (op == .add) "addi" else "addiu",
                    regName(destination_reg),
                    regName(lhs_reg),
                    label,
                });
                return;
            }
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
        .bit_cast => |source| {
            const name = switch (source) {
                .ident => |name| name,
                else => return error.ArithmeticRhsMustBeRegisterOrNumber,
            };
            const rhs = try context.lookup(name);
            if (isVectorType(rhs.data_type)) return error.ArithmeticRhsMustBeRegisterOrNumber;
            const rhs_reg = rhs.reg orelse return error.ArithmeticRhsMustBeRegisterOrNumber;
            const instruction = registerBinaryInstruction(op) orelse return error.UnsupportedOperator;
            try writer.print("  {s} {s}, {s}, {s}\n", .{
                instruction, regName(destination_reg), regName(lhs_reg), regName(rhs_reg),
            });
        },
        .vector_access => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .vector_operation => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .vector_shift => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .accumulator_read => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .vector_control_read => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .hardware_read => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .scalar_comparison => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .signed_less_than => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .scalar_materialize => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .load => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .scalar_expression => return error.ArithmeticRhsMustBeRegisterOrNumber,
        .function_address, .code_address, .data_address => return error.ArithmeticRhsMustBeRegisterOrNumber,
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
        .scalar_materialize => return error.PowerOfTwoConstantRequired,
        .load => return error.PowerOfTwoConstantRequired,
        .scalar_expression => return error.PowerOfTwoConstantRequired,
        .bit_cast, .function_address, .code_address, .data_address => return error.PowerOfTwoConstantRequired,
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
        .scalar_materialize => return error.ShiftAmountMustBeRegisterOrNumber,
        .load => return error.ShiftAmountMustBeRegisterOrNumber,
        .scalar_expression => return error.ShiftAmountMustBeRegisterOrNumber,
        .bit_cast, .function_address, .code_address, .data_address => return error.ShiftAmountMustBeRegisterOrNumber,
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
            .bit_cast => return error.ExpectedVectorRegister,
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
    if (store.address == .number) {
        const absolute_offset = try std.math.add(i64, store.address.number, store.offset);
        if (absolute_offset < 0 or absolute_offset >= 4096) return error.DmemAddressOutOfRange;
        try validateMemoryOffset(absolute_offset);
        try writer.print("  {s} {s}, {d}($zero)\n", .{
            storeOp(store.data_type), regName(value_reg), absolute_offset,
        });
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
    if (load.address == .number) {
        const absolute_offset = try std.math.add(i64, load.address.number, load.offset);
        if (absolute_offset < 0 or absolute_offset >= 4096) return error.DmemAddressOutOfRange;
        try validateMemoryOffset(absolute_offset);
        try writer.print("  {s} {s}, {d}($zero)\n", .{
            loadOp(load.data_type), regName(destination_reg), absolute_offset,
        });
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
            .bit_cast => |name| {
                const symbol = try context.lookup(name);
                if (isVectorType(symbol.data_type) or isVectorType(parameter.data_type)) {
                    return error.FunctionArgumentTypeMismatch;
                }
                const destination = parameter.reg orelse return error.InvalidScalarRegister;
                const source = symbol.reg orelse return error.InvalidScalarRegister;
                if (destination != source) {
                    try writer.print("  or {s}, $zero, {s}\n", .{ regName(destination), regName(source) });
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
        .indirect_call => |call| {
            const address_reg = try valueAsAddressReg(writer, context, call.address);
            try writer.print("  jal {s}\n", .{regName(address_reg)});
            try writeDelaySlot(writer, functions, context, call.delay_slot);
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
            if (memory.operation == .load_transpose) _ = try reserveTransposeBank(context, vector, vector_reg);
            const address_reg = try valueAsDmemReg(writer, context, memory.address);
            switch (memory.operation) {
                .load16 => try writeVectorLaneMemory(writer, true, vector_reg, memory.lane, address_reg, memory.offset),
                .store16 => try writeVectorLaneMemory(writer, false, vector_reg, memory.lane, address_reg, memory.offset),
                .load32 => try writeQuarterVectorMemory(writer, true, vector_reg, memory.lane, address_reg, memory.offset),
                .store32 => try writeQuarterVectorMemory(writer, false, vector_reg, memory.lane, address_reg, memory.offset),
                .load64 => try writeHalfVectorMemory(writer, true, vector_reg, memory.lane, address_reg, memory.offset),
                .store64 => try writeHalfVectorMemory(writer, false, vector_reg, memory.lane, address_reg, memory.offset),
                .load_quad_lane, .load_right, .store_right, .load_transpose => try writeSpecialVectorMemory(writer, memory.operation, vector_reg, memory.lane, address_reg, memory.offset),
                .load128 => try writeVectorMemory(writer, true, vector_reg, address_reg, memory.offset),
                .store128 => try writeVectorMemory(writer, false, vector_reg, address_reg, memory.offset),
                .load_packed_signed, .load_packed_unsigned => try writeVectorLoad(writer, context, vector_reg, .{
                    .data_type = .vec16,
                    .address = memory.address,
                    .offset = memory.offset,
                    .packed_u8 = memory.operation == .load_packed_signed,
                    .packed_unsigned_u8 = memory.operation == .load_packed_unsigned,
                }),
                .store_packed_signed, .store_packed_unsigned => try writePackedVectorStore(
                    writer,
                    memory.operation == .store_packed_unsigned,
                    vector_reg,
                    memory.lane,
                    address_reg,
                    memory.offset,
                ),
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
    var instruction_index: usize = 0;
    while (instruction_index < statements.len and
        (statements[instruction_index] == .label or statements[instruction_index] == .exported_label))
    {
        instruction_index += 1;
    }
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
        .scalar_materialize => return error.ConditionRhsMustBeRegisterOrNumber,
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
        .bit_cast, .function_address, .code_address, .data_address => return error.ConditionRhsMustBeRegisterOrNumber,
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

pub fn writeWithExplain(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    diagnostic: ?*Diagnostic,
    explain: ?*ExplainReport,
) !void {
    return writeInternal(writer, functions, diagnostic, explain);
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
