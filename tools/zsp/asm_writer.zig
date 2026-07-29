const std = @import("std");
const ast = @import("ast.zig");

const Register = ast.Register;
const DataType = ast.DataType;

const compiler_scratch: Register = .at;
const compiler_scratch_2: Register = .v1;
const alloc_scalar_registers = [_]Register{
    .t0, .t1, .t2, .t3, .t4, .t5, .t6, .t7, .t8, .t9,
    .k0, .k1, .sp, .fp, .s0, .s1, .s2, .s3, .s4, .s5,
    .s6, .s7,
};
const alloc_vector_registers = [_]ast.VectorRegister{
    .v01, .v02, .v03, .v04, .v05, .v06, .v07,
    .v08, .v09, .v10, .v11, .v12, .v13, .v14,
    .v15, .v16, .v17, .v18, .v19, .v20, .v21,
    .v22, .v23, .v24, .v25, .v26, .v27, .v28,
};

pub fn write(writer: *std.Io.Writer, functions: []const ast.Function) !void {
    try writer.writeAll(".set noreorder\n");
    try writer.writeAll(".set noat\n");
    try writer.writeAll(".text\n\n");

    var top_level_context = FunctionContext{ .label_prefix = "top_level" };
    for (functions) |function| {
        if (function.inline_call) continue;
        if (function.export_symbol and function.emit_label) {
            try writer.print(".globl {s}\n", .{function.name});
        }
        if (function.emit_label) {
            try writer.print("{s}:\n", .{function.name});
        }
        var function_context = top_level_context.child(function.name);
        const context = if (function.emit_label) &function_context else &top_level_context;
        try bindParameters(context, function.parameters);
        try writeStatements(writer, functions, context, function.statements);
        if (!function.no_return) {
            try writer.writeAll("  jr $ra\n");
            try writer.writeAll("  nop\n");
        }
        try writer.writeByte('\n');
    }
}

fn bindParameters(context: *FunctionContext, parameters: []const ast.Parameter) !void {
    for (parameters) |parameter| {
        if (isVectorType(parameter.data_type)) {
            const vector_reg = parameter.vector_reg orelse return error.ExpectedVectorRegister;
            try validateVectorRegisterBinding(context, parameter.data_type, vector_reg);
        } else {
            const reg = parameter.reg orelse return error.InvalidScalarRegister;
            if (!isScalarRegister(reg)) return error.InvalidScalarRegister;
            if (reg == compiler_scratch or reg == compiler_scratch_2) {
                return error.RegisterReservedForBackend;
            }
            if (context.isRegisterInUse(reg)) return error.RegisterAlreadyInUse;
        }
        try context.add(.{
            .name = parameter.name,
            .data_type = parameter.data_type,
            .reg = parameter.reg,
            .vector_reg = parameter.vector_reg,
            .constant = null,
        });
    }
}

const Symbol = struct {
    name: []const u8,
    data_type: DataType,
    reg: ?Register,
    vector_reg: ?ast.VectorRegister = null,
    constant: ?i64,
};

const FunctionContext = struct {
    label_prefix: []const u8,
    symbols: [64]Symbol = undefined,
    symbol_count: usize = 0,
    next_label: usize = 0,

    fn add(self: *FunctionContext, symbol: Symbol) !void {
        if (self.symbol_count >= self.symbols.len) return error.TooManySymbols;
        if (self.contains(symbol.name)) return error.SymbolAlreadyDefined;
        self.symbols[self.symbol_count] = symbol;
        self.symbol_count += 1;
    }

    fn child(self: *const FunctionContext, label_prefix: []const u8) FunctionContext {
        var result = FunctionContext{ .label_prefix = label_prefix };
        @memcpy(result.symbols[0..self.symbol_count], self.symbols[0..self.symbol_count]);
        result.symbol_count = self.symbol_count;
        return result;
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

    fn allocRegister(self: *const FunctionContext, data_type: DataType) !Register {
        if (isVectorType(data_type)) return error.ExpectedScalarType;
        for (alloc_scalar_registers) |reg| {
            if (!self.isRegisterInUse(reg)) return reg;
        }
        return error.OutOfFreeRegisters;
    }

    fn allocVectorRegister(self: *const FunctionContext, data_type: DataType) !ast.VectorRegister {
        if (!isVectorType(data_type)) return error.ExpectedVectorType;
        for (alloc_vector_registers) |reg| {
            if (self.isVectorRegisterInUse(reg)) continue;
            if (data_type == .vec32) {
                const second = nextVectorRegister(reg) orelse continue;
                if (@intFromEnum(second) >= 29) continue;
                if (self.isVectorRegisterInUse(second)) continue;
            }
            return reg;
        }
        return error.OutOfFreeVectorRegisters;
    }

    fn isRegisterInUse(self: *const FunctionContext, reg: Register) bool {
        for (self.symbols[0..self.symbol_count]) |symbol| {
            if (symbol.reg) |symbol_reg| {
                if (symbol_reg == reg) return true;
            }
        }
        return false;
    }

    fn isVectorRegisterInUse(self: *const FunctionContext, reg: ast.VectorRegister) bool {
        for (self.symbols[0..self.symbol_count]) |symbol| {
            const symbol_reg = symbol.vector_reg orelse continue;
            if (symbol_reg == reg) return true;
            if (symbol.data_type == .vec32 and nextVectorRegister(symbol_reg) == reg) return true;
        }
        return false;
    }
};

fn writeStatements(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    statements: []const ast.Statement,
) anyerror!void {
    for (statements) |statement| {
        switch (statement) {
            .var_decl => |decl| try writeVarDecl(writer, context, decl),
            .assignment => |assignment| try writeAssignment(writer, context, assignment),
            .store => |store| try writeStore(writer, context, store),
            .call => |call| try writeCall(writer, functions, context, call),
            .builtin => |builtin| try writeBuiltin(writer, builtin),
            .while_loop => |loop| try writeWhile(writer, functions, context, loop),
            .if_statement => |if_statement| try writeIf(writer, functions, context, if_statement),
            .asm_line => |asm_line| try writer.print("  {s}\n", .{asm_line}),
        }
    }
}

fn writeVarDecl(writer: *std.Io.Writer, context: *FunctionContext, decl: ast.VarDecl) !void {
    if (decl.is_const) {
        if (isVectorType(decl.data_type)) return error.VectorConstUnsupported;
        try context.add(.{
            .name = decl.name,
            .data_type = decl.data_type,
            .reg = null,
            .constant = try valueAsImmediate(context, decl.value),
        });
        return;
    }

    if (isVectorType(decl.data_type)) {
        if (decl.reg != null) return error.InvalidVectorRegister;
        const vector_reg = decl.vector_reg orelse try context.allocVectorRegister(decl.data_type);
        try validateVectorRegisterBinding(context, decl.data_type, vector_reg);
        try writeVectorInitialValue(writer, context, vector_reg, decl.data_type, decl.value);
        try context.add(.{
            .name = decl.name,
            .data_type = decl.data_type,
            .reg = null,
            .vector_reg = vector_reg,
            .constant = null,
        });
        return;
    }

    if (decl.vector_reg != null) return error.InvalidScalarRegister;
    const reg = decl.reg orelse try context.allocRegister(decl.data_type);
    if (!isScalarRegister(reg)) return error.InvalidScalarRegister;
    if (reg == compiler_scratch or reg == compiler_scratch_2) {
        return error.RegisterReservedForBackend;
    }
    if (context.isRegisterInUse(reg)) return error.RegisterAlreadyInUse;
    switch (decl.value) {
        .load => |load| {
            if (decl.data_type != load.data_type) return error.RegisterTypeMismatch;
            try writeLoadInto(writer, context, reg, load);
        },
        else => try loadImmediateInto(writer, reg, try valueAsImmediate(context, decl.value)),
    }
    try context.add(.{
        .name = decl.name,
        .data_type = decl.data_type,
        .reg = reg,
        .constant = null,
    });
}

fn validateVectorRegisterBinding(
    context: *const FunctionContext,
    data_type: DataType,
    vector_reg: ast.VectorRegister,
) !void {
    if (vector_reg == .v00 or @intFromEnum(vector_reg) >= 29) {
        return error.VectorRegisterReservedForBackend;
    }
    if (context.isVectorRegisterInUse(vector_reg)) return error.RegisterAlreadyInUse;
    if (data_type == .vec32) {
        const second = nextVectorRegister(vector_reg) orelse return error.InvalidVectorRegisterPair;
        if (@intFromEnum(second) >= 29) return error.VectorRegisterReservedForBackend;
        if (context.isVectorRegisterInUse(second)) return error.RegisterAlreadyInUse;
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
        .number => |number| {
            if (number != 0) return error.VectorImmediateUnsupported;
            try writeVectorOp(writer, .vxor, destination, destination, destination, 0);
            if (data_type == .vec32) {
                const fraction = nextVectorRegister(destination).?;
                try writeVectorOp(writer, .vxor, fraction, fraction, fraction, 0);
            }
        },
    }
}

fn writeAssignment(writer: *std.Io.Writer, context: *FunctionContext, assignment: ast.Assignment) !void {
    const destination = try context.lookup(assignment.destination);
    if (isVectorType(destination.data_type)) {
        return writeVectorAssignment(writer, context, destination, assignment);
    }
    const destination_reg = destination.reg orelse return error.CannotAssignConst;

    switch (assignment.op) {
        .set => {
            if (assignment.rhs != null) return error.InvalidAssignment;
            try writeSet(writer, context, destination, destination_reg, assignment.lhs);
        },
        .bit_not => {
            if (assignment.rhs != null) return error.InvalidAssignment;
            try writeBitNot(writer, context, destination, destination_reg, assignment.lhs);
        },
        else => {
            const rhs = assignment.rhs orelse return error.InvalidAssignment;
            try writeBinary(writer, context, destination, destination_reg, assignment.lhs, assignment.op, rhs);
        },
    }
}

const VectorOp = enum(u6) {
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
    const lhs = switch (assignment.lhs) {
        .ident => |name| try context.lookup(name),
        .number => return error.VectorImmediateUnsupported,
        .load => |load| {
            if (assignment.op != .set or assignment.rhs != null) return error.InvalidAssignment;
            if (load.data_type != destination.data_type) return error.RegisterTypeMismatch;
            return writeVectorLoad(writer, context, destination_reg, load);
        },
    };
    if (lhs.data_type != destination.data_type) return error.RegisterTypeMismatch;
    const lhs_reg = lhs.vector_reg orelse return error.ExpectedVectorRegister;

    if (assignment.op == .set) {
        if (assignment.rhs != null) return error.InvalidAssignment;
        try writeVectorOp(writer, .vor, destination_reg, lhs_reg, lhs_reg, 0);
        if (destination.data_type == .vec32) {
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
        try writeVectorOp(writer, .vnor, destination_reg, lhs_reg, lhs_reg, 0);
        if (destination.data_type == .vec32) {
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

    const rhs_value = assignment.rhs orelse return error.InvalidAssignment;
    const rhs = switch (rhs_value) {
        .ident => |name| try context.lookup(name),
        else => return error.VectorImmediateUnsupported,
    };
    if (rhs.data_type != destination.data_type) return error.RegisterTypeMismatch;
    const rhs_reg = rhs.vector_reg orelse return error.ExpectedVectorRegister;

    if (destination.data_type == .vec32) {
        const destination_fraction = nextVectorRegister(destination_reg).?;
        const lhs_fraction = nextVectorRegister(lhs_reg).?;
        const rhs_fraction = nextVectorRegister(rhs_reg).?;
        switch (assignment.op) {
            .add => {
                try writeVectorOp(writer, .vaddc, destination_fraction, lhs_fraction, rhs_fraction, 0);
                try writeVectorOp(writer, .vadd, destination_reg, lhs_reg, rhs_reg, 0);
            },
            .sub => {
                try writeVectorOp(writer, .vsubc, destination_fraction, lhs_fraction, rhs_fraction, 0);
                try writeVectorOp(writer, .vsub, destination_reg, lhs_reg, rhs_reg, 0);
            },
            .bit_and, .bit_or, .bit_xor, .bit_nor => {
                const op = vectorLogicOp(assignment.op);
                try writeVectorOp(writer, op, destination_reg, lhs_reg, rhs_reg, 0);
                try writeVectorOp(writer, op, destination_fraction, lhs_fraction, rhs_fraction, 0);
            },
            else => return error.UnsupportedVectorOperator,
        }
        return;
    }

    const op: VectorOp = switch (assignment.op) {
        .add => .vaddc,
        .sub => .vsubc,
        .bit_and, .bit_or, .bit_xor, .bit_nor => vectorLogicOp(assignment.op),
        else => return error.UnsupportedVectorOperator,
    };
    try writeVectorOp(writer, op, destination_reg, lhs_reg, rhs_reg, 0);
}

fn vectorLogicOp(op: ast.AssignOp) VectorOp {
    return switch (op) {
        .bit_and => .vand,
        .bit_or => .vor,
        .bit_xor => .vxor,
        .bit_nor => .vnor,
        else => unreachable,
    };
}

fn writeVectorOp(
    writer: *std.Io.Writer,
    op: VectorOp,
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
        @as(u32, @intFromEnum(op));
    try writer.print("  .word 0x{x:0>8} # {s} ${s}, ${s}, ${s}\n", .{
        word,
        @tagName(op),
        vectorRegName(destination),
        vectorRegName(lhs),
        vectorRegName(rhs),
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
            try expectSameType(destination, source);
            if (source.reg) |source_reg| {
                try writer.print("  or {s}, {s}, {s}\n", .{
                    regName(destination_reg),
                    regName(.zero),
                    regName(source_reg),
                });
            } else {
                try loadImmediateInto(writer, destination_reg, source.constant orelse return error.ExpectedConstant);
            }
        },
        .load => |load| {
            if (destination.data_type != load.data_type) return error.RegisterTypeMismatch;
            try writeLoadInto(writer, context, destination_reg, load);
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
        .number => return error.BitNotRequiresRegister,
        .load => return error.BitNotRequiresRegister,
    };
    try expectSameType(destination, source);
    const source_reg = source.reg orelse return error.BitNotRequiresRegister;
    try writer.print("  nor {s}, {s}, {s}\n", .{
        regName(destination_reg),
        regName(.zero),
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
        .number => return error.ArithmeticLhsMustBeRegister,
        .load => return error.ArithmeticLhsMustBeRegister,
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
            try expectSameType(destination, rhs);
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
                    destination_reg,
                    lhs_reg,
                    op,
                    rhs.constant orelse return error.ExpectedConstant,
                );
            }
        },
        .number => |number| try writeBinaryImmediate(writer, destination_reg, lhs_reg, op, number),
        .load => return error.ArithmeticRhsMustBeRegisterOrNumber,
    }
}

fn writeBinaryImmediate(
    writer: *std.Io.Writer,
    destination: Register,
    lhs: Register,
    op: ast.AssignOp,
    immediate: i64,
) !void {
    switch (op) {
        .add, .sub => {
            const addend = if (op == .add) immediate else std.math.negate(immediate) catch
                return error.ImmediateOutOfRange;
            if (addend >= std.math.minInt(i16) and addend <= std.math.maxInt(i16)) {
                try writer.print("  addiu {s}, {s}, {d}\n", .{
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

    try loadImmediateInto(writer, compiler_scratch_2, immediate);
    const instruction = registerBinaryInstruction(op) orelse return error.UnsupportedOperator;
    try writer.print("  {s} {s}, {s}, {s}\n", .{
        instruction,
        regName(destination),
        regName(lhs),
        regName(compiler_scratch_2),
    });
}

fn registerBinaryInstruction(op: ast.AssignOp) ?[]const u8 {
    return switch (op) {
        .add => "addu",
        .sub => "subu",
        .bit_and => "and",
        .bit_or => "or",
        .bit_xor => "xor",
        .bit_nor => "nor",
        else => null,
    };
}

fn immediateBinaryInstruction(op: ast.AssignOp) ?[]const u8 {
    return switch (op) {
        .add, .sub => "addiu",
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
        .load => return error.PowerOfTwoConstantRequired,
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
        .load => return error.ShiftAmountMustBeRegisterOrNumber,
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
    if (lhs.data_type != rhs.data_type) return error.RegisterTypeMismatch;
}

fn writeStore(writer: *std.Io.Writer, context: *FunctionContext, store: anytype) !void {
    if (isVectorType(store.data_type)) {
        const value_name = switch (store.value) {
            .ident => |name| name,
            .number => return error.ExpectedVectorRegister,
        };
        const value = try context.lookup(value_name);
        if (value.data_type != store.data_type) return error.RegisterTypeMismatch;
        const vector_reg = value.vector_reg orelse return error.ExpectedVectorRegister;
        const address_reg = try valueAsAddressReg(writer, context, store.address);
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
    const address_reg = try valueAsAddressReg(writer, context, store.address);
    const value_reg = try valueAsStoreReg(writer, context, store.value);
    try writer.print("  {s} {s}, {d}({s})\n", .{
        storeOp(store.data_type),
        regName(value_reg),
        store.offset,
        regName(address_reg),
    });
}

fn writeVectorLoad(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    destination: ast.VectorRegister,
    load: ast.Load,
) !void {
    const address_reg = try valueAsAddressReg(writer, context, load.address);
    try writeVectorMemory(writer, true, destination, address_reg, load.offset);
    if (load.data_type == .vec32) {
        try writeVectorMemory(
            writer,
            true,
            nextVectorRegister(destination).?,
            address_reg,
            load.offset + 16,
        );
    }
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
    try validateMemoryOffset(load.offset);
    const address_reg = try valueAsAddressReg(writer, context, load.address);
    try writer.print("  {s} {s}, {d}({s})\n", .{
        loadOp(load.data_type),
        regName(destination_reg),
        load.offset,
        regName(address_reg),
    });
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
    if (call.arguments.len != function.parameters.len) return error.FunctionArgumentCountMismatch;
    for (call.arguments, function.parameters) |argument, parameter| {
        switch (argument) {
            .number => |number| {
                if (isVectorType(parameter.data_type)) return error.VectorArgumentMustBeRegister;
                try loadImmediateInto(writer, parameter.reg orelse return error.InvalidScalarRegister, number);
            },
            .ident => |name| {
                const symbol = try context.lookup(name);
                if (symbol.data_type != parameter.data_type) return error.FunctionArgumentTypeMismatch;
                if (isVectorType(parameter.data_type)) {
                    if (symbol.vector_reg != parameter.vector_reg) {
                        return error.FunctionArgumentRegisterMismatch;
                    }
                } else if (symbol.reg) |argument_reg| {
                    if (argument_reg != parameter.reg.?) return error.FunctionArgumentRegisterMismatch;
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

    if (function.inline_call) {
        const scope = context.pushScope();
        defer context.popScope(scope);
        for (function.parameters) |parameter| {
            if (context.lookup(parameter.name) catch null) |existing| {
                if (existing.data_type != parameter.data_type) return error.FunctionArgumentTypeMismatch;
                if (existing.reg != parameter.reg or existing.vector_reg != parameter.vector_reg) {
                    return error.FunctionArgumentRegisterMismatch;
                }
                continue;
            }
            try context.add(.{
                .name = parameter.name,
                .data_type = parameter.data_type,
                .reg = parameter.reg,
                .vector_reg = parameter.vector_reg,
                .constant = null,
            });
        }
        try writeStatements(writer, functions, context, function.statements);
        return;
    }

    try writer.print("  jal {s}\n", .{call.name});
    try writer.writeAll("  nop\n");
}

fn writeBuiltin(writer: *std.Io.Writer, builtin: ast.Builtin) !void {
    switch (builtin) {
        .nop => try writer.writeAll("  nop\n"),
        .breakpoint => try writer.writeAll("  break\n"),
    }
}

fn writeWhile(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    loop: anytype,
) anyerror!void {
    const label = context.allocLabel();

    try writer.print("LABEL_{s}_while_{d}:\n", .{ context.label_prefix, label });
    try writeConditionBranchFalse(writer, context, loop.condition, "whileend", label);
    const scope = context.pushScope();
    defer context.popScope(scope);
    try writeStatements(writer, functions, context, loop.statements);
    try writer.print("  j LABEL_{s}_while_{d}\n", .{ context.label_prefix, label });
    try writer.writeAll("  nop\n");
    try writer.print("LABEL_{s}_whileend_{d}:\n", .{ context.label_prefix, label });
}

fn writeIf(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    if_statement: anytype,
) anyerror!void {
    const label = context.allocLabel();
    const false_suffix: []const u8 = if (if_statement.else_statements != null) "ifelse" else "ifend";
    try writeConditionBranchFalse(writer, context, if_statement.condition, false_suffix, label);

    const then_scope = context.pushScope();
    try writeStatements(writer, functions, context, if_statement.then_statements);
    context.popScope(then_scope);

    if (if_statement.else_statements) |else_statements| {
        try writer.print("  j LABEL_{s}_ifend_{d}\n", .{ context.label_prefix, label });
        try writer.writeAll("  nop\n");
        try writer.print("LABEL_{s}_ifelse_{d}:\n", .{ context.label_prefix, label });
        const else_scope = context.pushScope();
        try writeStatements(writer, functions, context, else_statements);
        context.popScope(else_scope);
    }
    try writer.print("LABEL_{s}_ifend_{d}:\n", .{ context.label_prefix, label });
}

fn writeConditionBranchFalse(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    condition: ast.Condition,
    label_suffix: []const u8,
    label: usize,
) !void {
    const lhs = try context.lookup(condition.lhs);
    const lhs_reg = lhs.reg orelse return error.ConditionLhsMustBeRegister;
    var rhs_reg: ?Register = null;
    var rhs_immediate: ?i64 = null;
    switch (condition.rhs) {
        .number => |number| rhs_immediate = number,
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
    }

    switch (condition.op) {
        .eq, .ne => {
            if (rhs_reg == null) {
                const immediate = rhs_immediate.?;
                if (immediate == 0) {
                    rhs_reg = .zero;
                } else {
                    try loadImmediateInto(writer, compiler_scratch_2, immediate);
                    rhs_reg = compiler_scratch_2;
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
                        try writer.writeAll("  nop\n");
                        return;
                    }
                }

                try loadImmediateInto(writer, compiler_scratch_2, immediate);
                rhs_reg = compiler_scratch_2;
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
    try writer.writeAll("  nop\n");
}

fn valueAsImmediate(context: *FunctionContext, value: ast.Value) !i64 {
    return switch (value) {
        .number => |number| number,
        .ident => |name| (try context.lookup(name)).constant orelse error.ExpectedConstant,
        .load => error.ExpectedConstant,
    };
}

fn valueAsAddressReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            return symbol.reg orelse error.AddressMustBeRegister;
        },
        .number => |number| {
            if (number == 0) return .zero;
            try loadImmediateInto(writer, compiler_scratch, number);
            return compiler_scratch;
        },
    }
}

fn valueAsStoreReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            if (symbol.reg) |reg| return reg;
            return try loadImmediate(writer, symbol.constant orelse return error.StoreValueMustBeRegister);
        },
        .number => |number| return try loadImmediate(writer, number),
    }
}

fn loadImmediate(writer: *std.Io.Writer, value: i64) !Register {
    if (value == 0) return .zero;
    try loadImmediateInto(writer, compiler_scratch_2, value);
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
        .u8, .u16, .u32 => false,
        .vec16, .vec32 => unreachable,
    };
}

fn storeOp(data_type: DataType) []const u8 {
    return switch (data_type) {
        .u8, .i8 => "sb",
        .u16, .i16 => "sh",
        .u32, .i32 => "sw",
        .vec16, .vec32 => unreachable,
    };
}

fn loadOp(data_type: DataType) []const u8 {
    return switch (data_type) {
        .u8 => "lbu",
        .i8 => "lb",
        .u16 => "lhu",
        .i16 => "lh",
        .u32, .i32 => "lw",
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
