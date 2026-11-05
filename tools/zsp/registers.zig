const std = @import("std");
const ast = @import("ast.zig");
const Register = ast.Register;

pub fn registerBit(reg: Register) u32 {
    return @as(u32, 1) << @intFromEnum(reg);
}

pub fn vectorRegisterBit(reg: ast.VectorRegister) u32 {
    return @as(u32, 1) << @intFromEnum(reg);
}

pub fn allAutomaticScalarRegisters() u32 {
    var result: u32 = 0;
    for (alloc_scalar_registers) |reg| result |= registerBit(reg);
    return result;
}

pub fn allAutomaticVectorRegisters() u32 {
    var result: u32 = 0;
    for (alloc_vector_registers) |reg| result |= vectorRegisterBit(reg);
    return result;
}

pub fn nextVectorRegister(reg: ast.VectorRegister) ?ast.VectorRegister {
    const index = @intFromEnum(reg);
    if (index == 31) return null;
    return @enumFromInt(index + 1);
}

pub fn vectorRegName(reg: ast.VectorRegister) []const u8 {
    return @tagName(reg);
}

/// `$v01`, as written in source and diagnostics.
pub fn vectorDollarName(reg: ast.VectorRegister) []const u8 {
    return vector_dollar_names.get(reg);
}

const vector_dollar_names = blk: {
    var table = std.EnumArray(ast.VectorRegister, []const u8).initUndefined();
    for (std.enums.values(ast.VectorRegister)) |reg| table.set(reg, "$" ++ @tagName(reg));
    break :blk table;
};

const scalar_names = std.EnumArray(Register, []const u8).init(.{
    .zero = "$zero",
    .at = "$at",
    .v0 = "$v0",
    .v1 = "$v1",
    .a0 = "$a0",
    .a1 = "$a1",
    .a2 = "$a2",
    .a3 = "$a3",
    .t0 = "$t0",
    .t1 = "$t1",
    .t2 = "$t2",
    .t3 = "$t3",
    .t4 = "$t4",
    .t5 = "$t5",
    .t6 = "$t6",
    .t7 = "$t7",
    .s0 = "$s0",
    .s1 = "$s1",
    .s2 = "$s2",
    .s3 = "$s3",
    .s4 = "$s4",
    .s5 = "$s5",
    .s6 = "$s6",
    .s7 = "$s7",
    .t8 = "$t8",
    .t9 = "$t9",
    .k0 = "$k0",
    .k1 = "$k1",
    .gp = "$gp",
    .sp = "$sp",
    .fp = "$fp",
    .ra = "$ra",
});

pub fn regName(reg: Register) []const u8 {
    return scalar_names.get(reg);
}

/// Parses a scalar register spelled as in assembly, such as `$t0`.
pub fn parseScalar(text: []const u8) ?Register {
    for (std.enums.values(Register)) |reg| {
        if (std.mem.eql(u8, scalar_names.get(reg), text)) return reg;
    }
    return null;
}

test "scalar register names parse back to registers" {
    try std.testing.expectEqual(@as(?Register, .t0), parseScalar("$t0"));
    try std.testing.expectEqual(@as(?Register, .zero), parseScalar("$zero"));
    try std.testing.expectEqual(@as(?Register, null), parseScalar("$v01"));
    try std.testing.expectEqual(@as(?Register, null), parseScalar("t0"));
}

pub const compiler_scratch: Register = .at;

pub const compiler_scratch_2: Register = .v1;

pub const command_return: Register = .k1;

pub const alloc_scalar_registers = [_]Register{
    .t0, .t1, .t2, .t3, .t4, .t5, .t6, .t7, .t8, .t9,
    .k0, .sp, .fp, .s0, .s1, .s2, .s3, .s4, .s5, .s6,
    .s7,
};

pub const alloc_vector_registers = [_]ast.VectorRegister{
    .v01, .v02, .v03, .v04, .v05, .v06, .v07,
    .v08, .v09, .v10, .v11, .v12, .v13, .v14,
    .v15, .v16, .v17, .v18, .v19, .v20, .v21,
    .v22, .v23, .v24, .v25, .v26, .v27, .v28,
};
