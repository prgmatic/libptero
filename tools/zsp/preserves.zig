//! `preserves(module.function)`: a function that finishes a call to
//! `function` on its behalf, such as an overlay patch that draws for
//! geometry's triangle sender, must leave every register that function's
//! contract keeps. Linking reserves those registers for the whole function,
//! so automatic allocation avoids them and a callee that writes one is an
//! error. Registers the function pins itself, as parameters or
//! declarations, stay its own responsibility (a restored register, a
//! constant it only reads).
const std = @import("std");
const ast = @import("ast.zig");
const ast_walk = @import("ast_walk.zig");
const registers = @import("registers.zig");

const Masks = struct { scalar: u32 = 0, vector: u32 = 0 };

/// Prepends a reserved declaration for each register `target` keeps.
pub fn apply(allocator: std.mem.Allocator, function: *ast.Function, target: ast.Function) !void {
    if (target.external and !target.has_clobber_contract) return error.PreservedFunctionHasNoContract;
    var kept = keptRegisters(target);
    const pinned = pinnedRegisters(function.*);
    kept.scalar &= ~pinned.scalar;
    kept.vector &= ~pinned.vector;
    const count = @popCount(kept.scalar) + @popCount(kept.vector);
    const statements = try allocator.alloc(ast.Statement, count + function.statements.len);
    var index: usize = 0;
    try reserveScalars(allocator, statements, &index, kept.scalar);
    try reserveVectors(allocator, statements, &index, kept.vector);
    @memcpy(statements[count..], function.statements);
    function.statements = statements;
}

fn reserveScalars(allocator: std.mem.Allocator, statements: []ast.Statement, index: *usize, mask: u32) !void {
    inline for (std.meta.fields(ast.Register)) |field| {
        const reg: ast.Register = @enumFromInt(field.value);
        if (mask & registers.registerBit(reg) != 0) try appendReservation(allocator, statements, index, .{ .scalar = reg }, field.name);
    }
}

fn reserveVectors(allocator: std.mem.Allocator, statements: []ast.Statement, index: *usize, mask: u32) !void {
    inline for (std.meta.fields(ast.VectorRegister)) |field| {
        const reg: ast.VectorRegister = @enumFromInt(field.value);
        if (mask & registers.vectorRegisterBit(reg) != 0) try appendReservation(allocator, statements, index, .{ .vector = reg }, field.name);
    }
}

const Kept = union(enum) { scalar: ast.Register, vector: ast.VectorRegister };

fn appendReservation(allocator: std.mem.Allocator, statements: []ast.Statement, index: *usize, reg: Kept, name: []const u8) !void {
    statements[index.*] = try reservation(allocator, reg, name);
    index.* += 1;
}

/// Every register except `$zero`, `$at`, and those `target` may write.
fn keptRegisters(target: ast.Function) Masks {
    var written: Masks = .{ .scalar = registers.registerBit(.zero) | registers.registerBit(.at) };
    for (target.clobber_regs) |reg| written.scalar |= registers.registerBit(reg);
    for (target.clobber_vector_regs) |reg| written.vector |= registers.vectorRegisterBit(reg);
    return .{ .scalar = ~written.scalar, .vector = ~written.vector };
}

fn pinnedRegisters(function: ast.Function) Masks {
    var pinned: Masks = .{};
    for (function.parameters) |parameter| addPins(&pinned, parameter.data_type, parameter.reg, parameter.vector_reg);
    ast_walk.each(function.statements, ast_walk.DelaySet.initFull(), &pinned, visitDeclaration);
    return pinned;
}

fn visitDeclaration(pinned: *Masks, statement: *const ast.Statement) void {
    if (statement.* != .var_decl) return;
    const decl = statement.var_decl;
    addPins(pinned, decl.data_type, decl.reg, decl.vector_reg);
}

fn addPins(pinned: *Masks, data_type: ast.DataType, reg: ?ast.Register, vector_reg: ?ast.VectorRegister) void {
    if (reg) |scalar| pinned.scalar |= registers.registerBit(scalar);
    const vector = vector_reg orelse return;
    pinned.vector |= registers.vectorRegisterBit(vector);
    if (data_type != .vec32) return;
    if (registers.nextVectorRegister(vector)) |second| pinned.vector |= registers.vectorRegisterBit(second);
}

fn reservation(allocator: std.mem.Allocator, reg: Kept, register_name: []const u8) !ast.Statement {
    return .{ .var_decl = .{
        .is_const = false,
        .is_reserved = true,
        .allow_undefined_read = true,
        .data_type = if (reg == .scalar) .u32 else .vec16,
        .reg = if (reg == .scalar) reg.scalar else null,
        .vector_reg = if (reg == .vector) reg.vector else null,
        .name = try std.fmt.allocPrint(allocator, "preserved#{s}", .{register_name}),
        .value = null,
    } };
}
