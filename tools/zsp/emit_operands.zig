//! Materializes immediates, data addresses, and scalar operands in registers.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const common = @import("emit_common.zig");
const registers = @import("registers.zig");
const Emitter = @import("Emitter.zig");

const Gen = common.Gen;
const Register = ast.Register;
const Symbol = analysis.Symbol;
const compiler_scratch = registers.compiler_scratch;
const compiler_scratch_2 = registers.compiler_scratch_2;

pub fn valueAsImmediate(g: Gen, value: ast.Value) !i64 {
    if (value == .number) return value.number;
    const name = common.identName(value) orelse return error.ExpectedConstant;
    return (try g.lookup(name)).constant orelse error.ExpectedConstant;
}

/// A register holding `value`, using `$at` to materialize constants.
pub fn valueAsAddressReg(g: Gen, value: ast.ValueRef) !Register {
    return switch (value) {
        .ident => |name| symbolAsAddressReg(g, try g.lookup(name)),
        .bit_cast => |name| bitCastRegister(g, name, error.AddressMustBeRegister, error.AddressMustBeRegister),
        .number => |number| constantInScratch(g, number),
        .vector_access => error.AddressMustBeRegister,
    };
}

fn symbolAsAddressReg(g: Gen, symbol: Symbol) !Register {
    if (symbol.reg) |reg| return reg;
    if (symbol.data_label) |label| return labelInScratch(g, label);
    return constantInScratch(g, symbol.constant orelse return error.AddressMustBeRegister);
}

fn bitCastRegister(g: Gen, name: []const u8, vector_error: anyerror, missing_error: anyerror) !Register {
    const symbol = try g.lookup(name);
    if (analysis.isVectorType(symbol.data_type)) return vector_error;
    return symbol.reg orelse missing_error;
}

fn labelInScratch(g: Gen, label: []const u8) !Register {
    try loadDataAddress(g.out, compiler_scratch, label);
    return compiler_scratch;
}

fn constantInScratch(g: Gen, value: i64) !Register {
    if (value == 0) return .zero;
    try loadImmediateInto(g.out, compiler_scratch, value);
    return compiler_scratch;
}

/// A register holding a DMEM address; constants must be dereferenceable.
pub fn valueAsDmemReg(g: Gen, value: ast.ValueRef) !Register {
    return switch (value) {
        .ident => |name| symbolAsDmemReg(g, try g.lookup(name)),
        .bit_cast => |name| bitCastRegister(g, name, error.ExpectedDmemAddress, error.AddressMustBeRegister),
        .number => |number| dmemConstant(g, number),
        .vector_access => error.ExpectedDmemAddress,
    };
}

fn symbolAsDmemReg(g: Gen, symbol: Symbol) !Register {
    if (symbol.data_label) |label| return labelInScratch(g, label);
    if (symbol.data_type != .dmem) return error.ExpectedDmemAddress;
    if (symbol.reg) |reg| return reg;
    return dmemConstant(g, symbol.constant orelse return error.AddressMustBeRegister);
}

fn dmemConstant(g: Gen, address: i64) !Register {
    if (address < 0 or address >= 4096) return error.DmemAddressOutOfRange;
    return constantInScratch(g, address);
}

pub fn loadDataAddress(out: *Emitter, reg: Register, label: []const u8) !void {
    try out.immediateSymbol(.addiu, reg, .zero, label, 0);
}

/// A register holding a stored value, using `$v1` for constants.
pub fn valueAsStoreReg(g: Gen, value: ast.ValueRef) !Register {
    return switch (value) {
        .ident => |name| symbolAsStoreReg(g, try g.lookup(name)),
        .bit_cast => |name| bitCastRegister(g, name, error.StoreValueMustBeRegister, error.StoreValueMustBeRegister),
        .number => |number| loadImmediate(g, number),
        .vector_access => error.StoreValueMustBeRegister,
    };
}

fn symbolAsStoreReg(g: Gen, symbol: Symbol) !Register {
    if (symbol.reg) |reg| return reg;
    return loadImmediate(g, symbol.constant orelse return error.StoreValueMustBeRegister);
}

/// Materializes a constant in the second backend scratch register.
pub fn loadImmediate(g: Gen, value: i64) !Register {
    if (value == 0) return .zero;
    const scratch = try backendScratch2(g.context);
    try loadImmediateInto(g.out, scratch, value);
    return scratch;
}

pub fn backendScratch2(context: *const analysis.FunctionContext) !Register {
    if (context.isRegisterInUse(compiler_scratch_2)) return error.BackendScratchRegisterUnavailable;
    return compiler_scratch_2;
}

/// The shortest `addiu`, `ori`, or `lui`/`ori` sequence for a 32-bit value.
/// Unsigned and signed spellings of the same register bits are equivalent.
pub fn loadImmediateInto(out: *Emitter, reg: Register, value: i64) !void {
    if (value < std.math.minInt(i32) or value > std.math.maxInt(u32)) return error.ImmediateOutOfRange;
    const bits: u32 = @truncate(@as(u64, @bitCast(value)));
    const signed: i32 = @bitCast(bits);
    if (common.fitsSigned16(signed)) return out.immediate(.addiu, reg, .zero, signed);
    if (common.fitsUnsigned16(value)) return out.immediate(.ori, reg, .zero, value);
    try out.upper(reg, @truncate(bits >> 16));
    const lower: u16 = @truncate(bits);
    if (lower != 0) try out.immediate(.ori, reg, reg, lower);
}

const testing = std.testing;

fn printed(out: *const Emitter) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer text.deinit();
    try @import("ir_print.zig").writeItems(&text.writer, out.items.items);
    return text.toOwnedSlice();
}

test "immediates use the shortest materialization" {
    var out = Emitter.init(testing.allocator);
    defer out.deinit();
    try loadImmediateInto(&out, .t0, -5);
    try loadImmediateInto(&out, .t0, 0xffff);
    try loadImmediateInto(&out, .t0, 0x12340000);
    try loadImmediateInto(&out, .t0, -0x12345678);
    try loadImmediateInto(&out, .t0, 0xffff800c);
    try testing.expectError(error.ImmediateOutOfRange, loadImmediateInto(&out, .t0, 1 << 33));
    const text = try printed(&out);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  addiu $t0, $zero, -5
        \\  ori $t0, $zero, 65535
        \\  lui $t0, 4660
        \\  lui $t0, 60875
        \\  ori $t0, $t0, 43400
        \\  addiu $t0, $zero, -32756
        \\
    , text);
}
