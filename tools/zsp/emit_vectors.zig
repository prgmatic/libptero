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

pub fn writeVectorInitialValue(
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
        .scalar_materialize => return error.RegisterTypeMismatch,
        .number => |number| {
            if (number != 0) return error.VectorImmediateUnsupported;
            try writeVectorOp(writer, .vxor, destination, destination, destination, 0);
            if (data_type == .vec32) {
                const fraction = nextVectorRegister(destination).?;
                try writeVectorOp(writer, .vxor, fraction, fraction, fraction, 0);
            }
        },
        .scalar_expression => return error.UnsupportedScalarExpressionTree,
        .bit_cast, .function_address, .code_address, .data_address => return error.RegisterTypeMismatch,
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

pub fn writeVectorAssignment(writer: *std.Io.Writer, context: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
    _ = destination.vector_reg orelse return error.ExpectedVectorRegister;
    return switch (assignment.lhs) {
        .accumulator_read => writeAccumulatorAssignment(writer, context, destination, assignment),
        .vector_operation => writeVectorOperationAssignment(writer, context, destination, assignment),
        .vector_shift => writeVectorShiftAssignment(writer, context, destination, assignment),
        else => writeVectorValueAssignment(writer, context, destination, assignment),
    };
}

fn writeVectorValueAssignment(writer: *std.Io.Writer, context: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
    if (assignment.destination_lane != null) return writeVectorLaneAssignment(writer, context, destination, assignment);
    if (assignment.op == .set and assignment.lhs == .number) return writeVectorZeroAssignment(writer, context, destination, assignment);
    return writeVectorBasicAssignment(writer, context, destination, assignment);
}

fn writeVectorBasicAssignment(writer: *std.Io.Writer, context: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
    const destination_reg = destination.vector_reg.?;
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
        .scalar_materialize => return error.InvalidAssignment,
        .scalar_expression => return error.UnsupportedVectorExpressionTree,
        .bit_cast, .function_address, .code_address, .data_address => return error.RegisterTypeMismatch,
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

fn writeAccumulatorAssignment(writer: *std.Io.Writer, _: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
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

fn writeVectorOperationAssignment(writer: *std.Io.Writer, context: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
    if (assignment.op != .set or assignment.rhs != null) return error.InvalidAssignment;
    const operation = assignment.lhs.vector_operation;
    if (operation.op == .vrcp or operation.op == .vrcpl or operation.op == .vrcph or
        operation.op == .vrsq or operation.op == .vrsql or operation.op == .vrsqh or
        operation.op == .vmov)
    {
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

fn writeVectorShiftAssignment(writer: *std.Io.Writer, context: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
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

fn writeVectorLaneAssignment(writer: *std.Io.Writer, context: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
    const lane = assignment.destination_lane.?;
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

fn writeVectorZeroAssignment(writer: *std.Io.Writer, _: *FunctionContext, destination: Symbol, assignment: ast.Assignment) !void {
    const destination_reg = destination.vector_reg.?;
    if (assignment.lhs.number != 0 or assignment.rhs != null) return error.VectorImmediateUnsupported;
    return writeVectorOp(writer, .vxor, destination_reg, destination_reg, destination_reg, 0);
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

pub fn writeMfc2(
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

pub fn writeQuarterVectorMemory(
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

pub fn writeHalfVectorMemory(
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

pub fn writeVectorLaneMemory(
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

pub fn writeVectorLoad(
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

pub fn writePackedVectorStore(
    writer: *std.Io.Writer,
    unsigned: bool,
    vector_reg: ast.VectorRegister,
    lane: u3,
    address_reg: Register,
    offset: i64,
) !void {
    if (@mod(offset, 8) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled_offset = @divExact(offset, 8);
    if (scaled_offset < -64 or scaled_offset > 63) return error.VectorMemoryOffsetOutOfRange;
    const encoded_offset: u32 = @as(u7, @bitCast(@as(i7, @intCast(scaled_offset))));
    const word: u32 = (0x3a << 26) |
        (@as(u32, @intFromEnum(address_reg)) << 21) |
        (@as(u32, @intFromEnum(vector_reg)) << 16) |
        (@as(u32, if (unsigned) 0b00111 else 0b00110) << 11) |
        (@as(u32, lane) << 7) |
        encoded_offset;
    try writer.print("  .word 0x{x:0>8} # {s} ${s}[{d}], {d}({s})\n", .{
        word, if (unsigned) "suv" else "spv", vectorRegName(vector_reg), lane, offset, regName(address_reg),
    });
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

pub fn writeSpecialVectorMemory(
    writer: *std.Io.Writer,
    operation: ast.VectorMemoryOperation,
    vector: ast.VectorRegister,
    lane: u3,
    address: Register,
    offset: i64,
) !void {
    if (@mod(offset, 16) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled = @divExact(offset, 16);
    if (scaled < -64 or scaled > 63) return error.VectorMemoryOffsetOutOfRange;
    if (operation == .load_transpose and @intFromEnum(vector) % 8 != 0) return error.TransposeRequiresRegisterBank;
    const store = operation == .store_right;
    const op: u32 = switch (operation) {
        .load_quad_lane => 4,
        .load_right, .store_right => 5,
        .load_transpose => 11,
        else => unreachable,
    };
    const mnemonic = switch (operation) {
        .load_quad_lane => "lqv",
        .load_right => "lrv",
        .store_right => "srv",
        .load_transpose => "ltv",
        else => unreachable,
    };
    const word = (@as(u32, if (store) 0x3a else 0x32) << 26) |
        (@as(u32, @intFromEnum(address)) << 21) | (@as(u32, @intFromEnum(vector)) << 16) |
        (op << 11) | (@as(u32, lane) << 8) | @as(u7, @bitCast(@as(i7, @intCast(scaled))));
    try writer.print("  .word 0x{x:0>8} # {s} ${s}[{d}], {d}({s})\n", .{ word, mnemonic, vectorRegName(vector), lane, offset, regName(address) });
}

pub fn writeVectorMemory(
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
