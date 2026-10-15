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

pub fn valueAsImmediate(context: *FunctionContext, value: ast.Value) !i64 {
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
        .scalar_materialize => error.ExpectedConstant,
        .load => error.ExpectedConstant,
        .scalar_expression => error.ExpectedConstant,
        .bit_cast, .function_address, .code_address, .data_address => error.ExpectedConstant,
    };
}

pub fn valueAsAddressReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
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
        .bit_cast => |name| {
            const symbol = try context.lookup(name);
            if (isVectorType(symbol.data_type)) return error.AddressMustBeRegister;
            return symbol.reg orelse error.AddressMustBeRegister;
        },
        .number => |number| {
            if (number == 0) return .zero;
            try loadImmediateInto(writer, compiler_scratch, number);
            return compiler_scratch;
        },
        .vector_access => return error.AddressMustBeRegister,
    }
}

pub fn valueAsDmemReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
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
        .bit_cast => |name| {
            const symbol = try context.lookup(name);
            if (isVectorType(symbol.data_type)) return error.ExpectedDmemAddress;
            return symbol.reg orelse error.AddressMustBeRegister;
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

pub fn loadDataAddress(writer: *std.Io.Writer, reg: Register, label: []const u8) !void {
    try writer.print("  addiu {s}, $zero, %lo({s})\n", .{ regName(reg), label });
}

pub fn valueAsStoreReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.ValueRef) !Register {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            if (symbol.reg) |reg| return reg;
            return try loadImmediate(writer, context, symbol.constant orelse return error.StoreValueMustBeRegister);
        },
        .bit_cast => |name| {
            const symbol = try context.lookup(name);
            if (isVectorType(symbol.data_type)) return error.StoreValueMustBeRegister;
            return symbol.reg orelse error.StoreValueMustBeRegister;
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

pub fn backendScratch2(context: *const FunctionContext) !Register {
    if (context.isRegisterInUse(compiler_scratch_2)) return error.BackendScratchRegisterUnavailable;
    return compiler_scratch_2;
}

pub fn loadImmediateInto(writer: *std.Io.Writer, reg: Register, value: i64) !void {
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
