//! Scalar loads and stores, and the store statement's vector forms.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const common = @import("emit_common.zig");
const ir = @import("ir.zig");
const operands = @import("emit_operands.zig");
const vectors = @import("emit_vectors.zig");
const registers = @import("registers.zig");

const Gen = common.Gen;
const DataType = ast.DataType;
const Register = ast.Register;

pub const Store = @FieldType(ast.Statement, "store");

pub fn storeOp(data_type: DataType) ir.Op {
    return switch (data_type) {
        .u8, .i8 => .sb,
        .u16, .i16 => .sh,
        else => .sw,
    };
}

pub fn loadOp(data_type: DataType) ir.Op {
    return switch (data_type) {
        .u8 => .lbu,
        .i8 => .lb,
        .u16 => .lhu,
        .i16 => .lh,
        else => .lw,
    };
}

/// A resolved scalar memory operand: `%lo(symbol + offset)(base)`.
const Address = struct { base: Register, symbol: ?[]const u8 = null, offset: i64 };

fn memoryDataLabel(g: Gen, address: ast.ValueRef) ?[]const u8 {
    const name = common.refName(address) orelse return null;
    const symbol = g.lookup(name) catch return null;
    return symbol.data_label;
}

/// Resolves the address forms of scalar memory: a storage label plus a
/// runtime base, a storage label alone, an absolute DMEM address, or a
/// register.
fn scalarAddress(g: Gen, address: ast.ValueRef, offset: i64, label_offset: ?[]const u8) !Address {
    if (label_offset) |name| return labeledAddress(g, address, offset, try g.lookup(name));
    if (memoryDataLabel(g, address)) |label| return .{ .base = .zero, .symbol = label, .offset = offset };
    if (address == .number) return absoluteAddress(address.number, offset);
    return .{ .base = try operands.valueAsDmemReg(g, address), .offset = offset };
}

fn labeledAddress(g: Gen, address: ast.ValueRef, offset: i64, label: analysis.Symbol) !Address {
    const base = try operands.valueAsAddressReg(g, address);
    if (label.data_label) |symbol| return .{ .base = base, .symbol = symbol, .offset = offset };
    const constant = label.constant orelse return error.ExpectedConstant;
    try common.validateMemoryOffset(constant);
    return .{ .base = base, .offset = constant };
}

fn absoluteAddress(address: i64, offset: i64) !Address {
    const absolute = try std.math.add(i64, address, offset);
    if (absolute < 0 or absolute >= 4096) return error.DmemAddressOutOfRange;
    try common.validateMemoryOffset(absolute);
    return .{ .base = .zero, .offset = absolute };
}

fn emitScalarMemory(g: Gen, op: ir.Op, reg: Register, address: Address) !void {
    try g.out.memory(op, reg, address.base, address.symbol, address.offset);
}

pub fn writeLoadInto(g: Gen, destination: Register, load: ast.Load) !void {
    if (load.unaligned) return error.UnalignedLoadRequiresVectorType;
    try common.validateMemoryOffset(load.offset);
    const address = try scalarAddress(g, load.address, load.offset, load.label_offset);
    try emitScalarMemory(g, loadOp(load.data_type), destination, address);
}

pub fn writeStore(g: Gen, store: Store) !void {
    if (analysis.isVectorType(store.data_type)) return writeVectorStore(g, store);
    try common.validateMemoryOffset(store.offset);
    const value = try operands.valueAsStoreReg(g, store.value);
    const address = try scalarAddress(g, store.address, store.offset, store.label_offset);
    try emitScalarMemory(g, storeOp(store.data_type), value, address);
}

fn storedVector(value: ast.ValueRef) !ast.VectorAccess {
    return switch (value) {
        .ident => |name| .{ .name = name },
        .vector_access => |access| access,
        else => error.ExpectedVectorRegister,
    };
}

fn writeVectorStore(g: Gen, store: Store) !void {
    if (store.label_offset != null) return error.VectorMemorySymbolicOffsetUnsupported;
    const access = try storedVector(store.value);
    const vector = try storedRegister(g, store, access);
    const base = try operands.valueAsDmemReg(g, store.address);
    const lane = access.lane orelse return writeFullVectorStore(g, store, vector, base);
    if (store.data_type != .vec16) return error.PartialVectorMemoryRequiresVec16;
    try vectors.vectorMemory(g.out, .ssv, vector, lane, base, store.offset);
}

fn storedRegister(g: Gen, store: Store, access: ast.VectorAccess) !ast.VectorRegister {
    const value = try g.lookup(access.name);
    const value_type: DataType = if (access.view != null) .vec16 else value.data_type;
    if (value_type != store.data_type) return error.RegisterTypeMismatch;
    return analysis.vectorRegisterForView(value, access.view);
}

fn writeFullVectorStore(g: Gen, store: Store, vector: ast.VectorRegister, base: Register) !void {
    try vectors.writeVectorMemory(g.out, false, vector, base, store.offset);
    if (store.data_type == .vec32) {
        try vectors.writeVectorMemory(g.out, false, registers.nextVectorRegister(vector).?, base, store.offset + 16);
    }
}

test "memory ops follow the scalar type width and signedness" {
    try std.testing.expectEqual(ir.Op.sh, storeOp(.i16));
    try std.testing.expectEqual(ir.Op.sw, storeOp(.dmem));
    try std.testing.expectEqual(ir.Op.lb, loadOp(.i8));
    try std.testing.expectEqual(ir.Op.lhu, loadOp(.u16));
    try std.testing.expectEqual(ir.Op.lw, loadOp(.i32));
    try std.testing.expectError(error.DmemAddressOutOfRange, absoluteAddress(4000, 100));
    try std.testing.expectEqual(@as(i64, 4004), (try absoluteAddress(4000, 4)).offset);
}
