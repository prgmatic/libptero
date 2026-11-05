//! Vector-unit instruction selection: copies, arithmetic, multiplies,
//! lane operations, accumulator reads, and vector memory transfers.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const common = @import("emit_common.zig");
const ir = @import("ir.zig");
const operands = @import("emit_operands.zig");
const registers = @import("registers.zig");
const Emitter = @import("Emitter.zig");

const Gen = common.Gen;
const DataType = ast.DataType;
const Register = ast.Register;
const VReg = ast.VectorRegister;
const Symbol = analysis.Symbol;
const next = registers.nextVectorRegister;
const ValueTag = std.meta.Tag(ast.Value);

/// The IR op for a source-level vector operation.
pub fn irOp(op: ast.VectorOp) ir.Op {
    return vector_ops.get(op);
}

const vector_ops = blk: {
    var table = std.EnumArray(ast.VectorOp, ir.Op).initUndefined();
    for (std.enums.values(ast.VectorOp)) |op| table.set(op, @field(ir.Op, @tagName(op)));
    break :blk table;
};

fn secondHalf(reg: VReg) VReg {
    return next(reg).?;
}

// ---------------------------------------------------------------- operands

const VectorOperand = struct {
    data_type: DataType,
    reg: VReg,
    element: u4,
};

fn vectorOperand(g: Gen, access: ast.VectorAccess) !VectorOperand {
    const symbol = try g.lookup(access.name);
    if (!analysis.isVectorType(symbol.data_type)) return error.ExpectedVectorType;
    return .{
        .data_type = if (access.view != null) .vec16 else symbol.data_type,
        .reg = try analysis.vectorRegisterForView(symbol, access.view),
        .element = access.element,
    };
}

/// Two-operand vector values; only the right operand may be swizzled.
fn vec16Operands(g: Gen, operation: ast.VectorOperation) ![2]VectorOperand {
    const lhs = try vectorOperand(g, operation.lhs);
    const rhs = try vectorOperand(g, operation.rhs);
    if (lhs.data_type != .vec16 or rhs.data_type != .vec16) return error.VectorMultiplyRequiresVec16Operands;
    if (lhs.element != 0) return error.VectorSwizzleOnlyAllowedOnRhs;
    return .{ lhs, rhs };
}

/// A view-selected destination; whole `vec32` values need a view.
fn viewDestination(destination: Symbol, view: ?ast.VectorView, failure: anyerror) !VReg {
    const reg = try analysis.vectorRegisterForView(destination, view);
    if (destination.data_type == .vec32 and view == null) return failure;
    return reg;
}

// ------------------------------------------------------- primitive emission

/// Applies `op` to one register, or to both halves of a `vec32`.
fn emitPair(out: *Emitter, op: ir.Op, data_type: DataType, vd: VReg, vs: VReg, vt: VReg) !void {
    try out.vector(op, vd, vs, vt, 0);
    if (data_type == .vec32) try out.vector(op, secondHalf(vd), secondHalf(vs), secondHalf(vt), 0);
}

fn emitCopy(out: *Emitter, data_type: DataType, destination: VReg, source: VReg) !void {
    try emitPair(out, .vor, data_type, destination, source, source);
}

fn emitZero(out: *Emitter, data_type: DataType, destination: VReg) !void {
    try emitPair(out, .vxor, data_type, destination, destination, destination);
}

fn emitAccumulatorRead(out: *Emitter, destination: VReg, part: ast.AccumulatorPart) !void {
    try out.vector(.vsar, destination, .v00, .v00, @intFromEnum(part));
}

fn emitOperation(out: *Emitter, destination: VReg, operation: ast.VectorOp, operands_: [2]VectorOperand) !void {
    try out.vector(irOp(operation), destination, operands_[0].reg, operands_[1].reg, operands_[1].element);
}

pub fn writeMfc2(out: *Emitter, destination: Register, source: VReg, lane: u3) !void {
    try out.laneMove(.mfc2, destination, source, lane);
}

const ShiftForm = struct { op: ir.Op, element: u4 };

fn shiftForm(kind: @FieldType(ast.VectorShift, "kind"), amount: u8) ShiftForm {
    return switch (kind) {
        .left_8 => .{ .op = .vsll8, .element = @intCast(23 - amount) },
        .right_arithmetic => .{ .op = .vsra, .element = @intCast(7 + amount) },
        .right_logical => .{ .op = .vsrl, .element = @intCast(7 + amount) },
    };
}

/// Multiply-based shifts read their power-of-two factors from `$v31`.
fn emitShift(out: *Emitter, destination: VReg, source: VReg, form: ShiftForm) !void {
    try out.vector(form.op, destination, source, .v31, form.element);
}

fn writeNamedVectorShift(g: Gen, destination: VReg, shift: ast.VectorShift) !void {
    const source = try vectorOperand(g, shift.source);
    if (source.data_type != .vec16 or source.element != 0) return error.UnsupportedVectorShift;
    try emitShift(g.out, destination, source.reg, shiftForm(shift.kind, shift.amount));
}

// ------------------------------------------------------- initial values

const InitialValue = struct { g: Gen, destination: VReg, data_type: DataType, value: ast.Value };
const InitialWriter = *const fn (InitialValue) anyerror!void;

pub fn writeVectorInitialValue(g: Gen, destination: VReg, data_type: DataType, value: ast.Value) !void {
    const request: InitialValue = .{ .g = g, .destination = destination, .data_type = data_type, .value = value };
    return initial_writers.get(std.meta.activeTag(value))(request);
}

const initial_writers = blk: {
    var table = std.EnumArray(ValueTag, InitialWriter).initFill(&initialTypeMismatch);
    table.set(.load, &initialLoad);
    table.set(.ident, &initialCopy);
    table.set(.vector_access, &initialSwizzle);
    table.set(.vector_operation, &initialOperation);
    table.set(.vector_shift, &initialShift);
    table.set(.accumulator_read, &initialAccumulator);
    table.set(.number, &initialZero);
    table.set(.scalar_expression, &initialExpression);
    break :blk table;
};

fn initialTypeMismatch(_: InitialValue) !void {
    return error.RegisterTypeMismatch;
}

fn initialExpression(_: InitialValue) !void {
    return error.UnsupportedScalarExpressionTree;
}

fn initialLoad(request: InitialValue) !void {
    const load = request.value.load;
    if (load.data_type != request.data_type) return error.RegisterTypeMismatch;
    try writeVectorLoad(request.g, request.destination, load);
}

fn initialCopy(request: InitialValue) !void {
    const source = try request.g.lookup(request.value.ident);
    if (source.data_type != request.data_type) return error.RegisterTypeMismatch;
    const source_reg = source.vector_reg orelse return error.ExpectedVectorRegister;
    try emitCopy(request.g.out, request.data_type, request.destination, source_reg);
}

fn initialSwizzle(request: InitialValue) !void {
    const access = request.value.vector_access;
    if (access.lane != null) return error.VectorLaneInitializationUnsupported;
    const source = try request.g.lookup(access.name);
    const source_reg = try analysis.vectorRegisterForView(source, access.view);
    if (request.data_type != .vec16 or source.data_type != .vec16) return error.RegisterTypeMismatch;
    try request.g.out.vector(.vor, request.destination, .v00, source_reg, access.element);
}

fn initialOperation(request: InitialValue) !void {
    if (request.data_type != .vec16) return error.Vec32ViewRequired;
    const operation = request.value.vector_operation;
    try emitOperation(request.g.out, request.destination, operation.op, try vec16Operands(request.g, operation));
}

fn initialShift(request: InitialValue) !void {
    if (request.data_type != .vec16) return error.UnsupportedVectorShift;
    try writeNamedVectorShift(request.g, request.destination, request.value.vector_shift);
}

fn initialAccumulator(request: InitialValue) !void {
    if (request.data_type != .vec16) return error.AccumulatorReadRequiresVec16;
    try emitAccumulatorRead(request.g.out, request.destination, request.value.accumulator_read);
}

fn initialZero(request: InitialValue) !void {
    if (request.value.number != 0) return error.VectorImmediateUnsupported;
    try emitZero(request.g.out, request.data_type, request.destination);
}

// ------------------------------------------------------------ assignments

pub fn writeVectorAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    _ = destination.vector_reg orelse return error.ExpectedVectorRegister;
    return switch (assignment.lhs) {
        .accumulator_read => writeAccumulatorAssignment(g, destination, assignment),
        .vector_operation => writeVectorOperationAssignment(g, destination, assignment),
        .vector_shift => writeVectorShiftAssignment(g, destination, assignment),
        else => writeVectorValueAssignment(g, destination, assignment),
    };
}

fn expectPlainSet(assignment: ast.Assignment) !void {
    if (assignment.op != .set or assignment.rhs != null) return error.InvalidAssignment;
}

fn writeAccumulatorAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    try expectPlainSet(assignment);
    if (assignment.destination_lane != null) return error.InvalidVectorLaneAssignment;
    const result = try viewDestination(destination, assignment.destination_view, error.AccumulatorReadRequiresVec16);
    try emitAccumulatorRead(g.out, result, assignment.lhs.accumulator_read);
}

fn isLaneOperation(op: ast.VectorOp) bool {
    return switch (op) {
        .vrcp, .vrcpl, .vrcph, .vrsq, .vrsql, .vrsqh, .vmov => true,
        else => false,
    };
}

fn writeVectorOperationAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    try expectPlainSet(assignment);
    const operation = assignment.lhs.vector_operation;
    if (isLaneOperation(operation.op)) return writeLaneOperation(g, destination, assignment, operation);
    if (assignment.destination_lane != null) return error.InvalidVectorLaneAssignment;
    const pair = try vec16Operands(g, operation);
    const result = try viewDestination(destination, assignment.destination_view, error.Vec32ViewRequired);
    try emitOperation(g.out, result, operation.op, pair);
}

/// A lane-selected source: `vector[lane]` encodes elements 8 through 15.
fn laneSource(g: Gen, access: ast.VectorAccess) !VectorOperand {
    const source = try vectorOperand(g, access);
    if (source.data_type != .vec16 or source.element < 8 or access.lane == null) {
        return error.VectorLaneOperationRequiresLane;
    }
    return source;
}

fn writeLaneOperation(g: Gen, destination: Symbol, assignment: ast.Assignment, operation: ast.VectorOperation) !void {
    const destination_lane = assignment.destination_lane orelse return error.VectorLaneOperationRequiresLane;
    const result = try viewDestination(destination, assignment.destination_view, error.Vec32ViewRequired);
    const source = try laneSource(g, operation.lhs);
    const encoded_lane = destination_lane + @as(u4, if (operation.explicit_lane_encoding) 8 else 0);
    try g.out.vectorLane(irOp(operation.op), result, encoded_lane, source.reg, source.element);
}

fn writeVectorShiftAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    const whole_vec32 = destination.data_type != .vec16 and assignment.destination_view == null;
    if (assignment.op != .set or assignment.rhs != null or assignment.destination_lane != null or whole_vec32) {
        return error.UnsupportedVectorShift;
    }
    const result = try analysis.vectorRegisterForView(destination, assignment.destination_view);
    try writeNamedVectorShift(g, result, assignment.lhs.vector_shift);
}

fn writeVectorValueAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    if (assignment.destination_lane != null) return writeVectorLaneAssignment(g, destination, assignment);
    if (assignment.op == .set and assignment.lhs == .number) return writeVectorZeroAssignment(g, destination, assignment);
    if (assignment.lhs == .load) return writeVectorLoadAssignment(g, destination, assignment);
    return writeVectorBasicAssignment(g, destination, assignment);
}

fn writeVectorZeroAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    if (assignment.lhs.number != 0 or assignment.rhs != null) return error.VectorImmediateUnsupported;
    const reg = destination.vector_reg.?;
    try g.out.vector(.vxor, reg, reg, reg, 0);
}

fn writeVectorLoadAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    try expectPlainSet(assignment);
    const load = assignment.lhs.load;
    if (load.data_type != destination.data_type) return error.RegisterTypeMismatch;
    try writeVectorLoad(g, destination.vector_reg.?, load);
}

fn writeVectorLaneAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    expectPlainSet(assignment) catch return error.InvalidVectorLaneAssignment;
    const lane = assignment.destination_lane.?;
    const result = try viewDestination(destination, assignment.destination_view, error.Vec32ViewRequired);
    return switch (assignment.lhs) {
        .load => |load| writeLaneLoad(g, result, lane, load),
        .ident => |name| writeLaneInsert(g, result, lane, name),
        .vector_access => |access| writeLaneMove(g, result, lane, access),
        else => error.VectorLaneSourceMustBeScalarRegister,
    };
}

fn writeLaneLoad(g: Gen, result: VReg, lane: u3, load: ast.Load) !void {
    if (load.data_type != .vec16) return error.PartialVectorMemoryRequiresVec16;
    const address = try operands.valueAsDmemReg(g, load.address);
    try vectorMemory(g.out, .lsv, result, lane, address, load.offset);
}

fn writeLaneInsert(g: Gen, result: VReg, lane: u3, name: []const u8) !void {
    const source = (try g.lookup(name)).reg orelse return error.VectorLaneSourceMustBeScalarRegister;
    try g.out.laneMove(.mtc2, source, result, lane);
}

fn writeLaneMove(g: Gen, result: VReg, lane: u3, access: ast.VectorAccess) !void {
    const source = try laneSource(g, access);
    try g.out.vectorLane(.vmov, result, lane, source.reg, source.element);
}

/// The vector operand an assignment's left side names, or why it cannot.
fn assignmentOperand(g: Gen, value: ast.Value) !VectorOperand {
    return switch (value) {
        .ident => |name| vectorOperand(g, .{ .name = name }),
        .vector_access => |access| vectorOperand(g, access),
        else => operand_errors.get(std.meta.activeTag(value)),
    };
}

const operand_errors = blk: {
    var table = std.EnumArray(ValueTag, anyerror).initFill(error.InvalidAssignment);
    table.set(.scalar_expression, error.UnsupportedVectorExpressionTree);
    for ([_]ValueTag{ .bit_cast, .function_address, .code_address, .data_address }) |tag| table.set(tag, error.RegisterTypeMismatch);
    table.set(.number, error.VectorImmediateUnsupported);
    break :blk table;
};

const Basic = struct {
    g: Gen,
    destination: Symbol,
    assignment: ast.Assignment,
    lhs: VectorOperand,
    data_type: DataType,
    view_reg: VReg,
};

/// A view selects one register of a `vec32`.
fn assignedType(destination: Symbol, view: ?ast.VectorView) DataType {
    return if (view != null) .vec16 else destination.data_type;
}

fn writeVectorBasicAssignment(g: Gen, destination: Symbol, assignment: ast.Assignment) !void {
    const lhs = try assignmentOperand(g, assignment.lhs);
    const data_type = assignedType(destination, assignment.destination_view);
    if (lhs.data_type != data_type) return error.RegisterTypeMismatch;
    const basic: Basic = .{
        .g = g,
        .destination = destination,
        .assignment = assignment,
        .lhs = lhs,
        .data_type = data_type,
        .view_reg = try analysis.vectorRegisterForView(destination, assignment.destination_view),
    };
    return switch (assignment.op) {
        .set => writeBasicCopy(basic),
        .bit_not => writeBasicInvert(basic),
        .logical_shift_right, .shift_right, .shift_left => writeBasicShift(basic),
        else => writeBasicBinary(basic),
    };
}

fn writeBasicCopy(basic: Basic) !void {
    if (basic.assignment.rhs != null) return error.InvalidAssignment;
    const lhs = basic.lhs;
    try basic.g.out.vector(.vor, basic.view_reg, if (lhs.element == 0) lhs.reg else .v00, lhs.reg, lhs.element);
    if (basic.data_type == .vec32) try emitCopy(basic.g.out, .vec16, secondHalf(basic.destination.vector_reg.?), secondHalf(lhs.reg));
}

fn writeBasicInvert(basic: Basic) !void {
    if (basic.assignment.rhs != null) return error.InvalidAssignment;
    const lhs = basic.lhs;
    try basic.g.out.vector(.vnor, basic.view_reg, lhs.reg, lhs.reg, lhs.element);
    if (basic.data_type == .vec32) {
        const half = secondHalf(lhs.reg);
        try basic.g.out.vector(.vnor, secondHalf(basic.destination.vector_reg.?), half, half, 0);
    }
}

/// `vec16 >> n`, `>>> n`, and `<< n` lower to multiply-based shifts.
fn writeBasicShift(basic: Basic) !void {
    const rhs = basic.assignment.rhs orelse return error.InvalidAssignment;
    if (rhs != .number) return error.UnsupportedVectorShift;
    if (basic.data_type != .vec16) return error.UnsupportedVectorShift;
    const form = basicShiftForm(basic.assignment.op, rhs.number) orelse return error.UnsupportedVectorShift;
    try emitShift(basic.g.out, basic.view_reg, basic.lhs.reg, form);
}

fn basicShiftForm(op: ast.AssignOp, amount: i64) ?ShiftForm {
    if (op == .shift_left) return leftShiftForm(amount);
    if (amount < 1 or amount > 8) return null;
    return shiftForm(if (op == .shift_right) .right_arithmetic else .right_logical, @intCast(amount));
}

fn leftShiftForm(amount: i64) ?ShiftForm {
    if (amount < 8 or amount > 15) return null;
    return shiftForm(.left_8, @intCast(amount));
}

fn rhsOperand(g: Gen, value: ast.Value) !VectorOperand {
    return switch (value) {
        .ident => |name| vectorOperand(g, .{ .name = name }),
        .vector_access => |access| vectorOperand(g, access),
        else => error.VectorImmediateUnsupported,
    };
}

fn logicOp(op: ast.AssignOp) ?ir.Op {
    return switch (op) {
        .bit_and => .vand,
        .bit_or => .vor,
        .bit_xor => .vxor,
        .bit_nor => .vnor,
        else => null,
    };
}

fn writeBasicBinary(basic: Basic) !void {
    const rhs = try rhsOperand(basic.g, basic.assignment.rhs orelse return error.InvalidAssignment);
    if (rhs.data_type != basic.data_type) return error.RegisterTypeMismatch;
    if (basic.lhs.element != 0) return error.VectorSwizzleOnlyAllowedOnRhs;
    if (basic.data_type == .vec32) return writeVec32Binary(basic, rhs);
    const op = vec16BinaryOp(basic.assignment.op) orelse return error.UnsupportedVectorOperator;
    try basic.g.out.vector(op, basic.view_reg, basic.lhs.reg, rhs.reg, rhs.element);
}

/// Scalar-style vector addition and subtraction propagate carry and borrow.
fn vec16BinaryOp(op: ast.AssignOp) ?ir.Op {
    return switch (op) {
        .add => .vaddc,
        .sub => .vsubc,
        else => logicOp(op),
    };
}

/// 16.16 arithmetic: the fraction half produces the carry the integer
/// half consumes; logic applies to both halves independently.
fn writeVec32Binary(basic: Basic, rhs: VectorOperand) !void {
    const out = basic.g.out;
    const destination = basic.destination.vector_reg.?;
    const lhs = basic.lhs.reg;
    const e = rhs.element;
    const carry: ?[2]ir.Op = switch (basic.assignment.op) {
        .add => .{ .vaddc, .vadd },
        .sub => .{ .vsubc, .vsub },
        else => null,
    };
    if (carry) |ops| {
        try out.vector(ops[0], secondHalf(destination), secondHalf(lhs), secondHalf(rhs.reg), e);
        return out.vector(ops[1], destination, lhs, rhs.reg, e);
    }
    const op = logicOp(basic.assignment.op) orelse return error.UnsupportedVectorOperator;
    try out.vector(op, destination, lhs, rhs.reg, e);
    try out.vector(op, secondHalf(destination), secondHalf(lhs), secondHalf(rhs.reg), e);
}

// ---------------------------------------------------------------- memory

/// Emits a vector transfer after checking its offset against the op's
/// scaled, signed seven-bit encoding.
pub fn vectorMemory(out: *Emitter, op: ir.Op, vt: VReg, lane: u4, base: Register, offset: i64) !void {
    try vectorTransfer(out, op, vt, lane, base, offset, true);
}

fn vectorTransfer(out: *Emitter, op: ir.Op, vt: VReg, lane: u4, base: Register, offset: i64, show_lane: bool) !void {
    try validateOffset(op, offset);
    try out.vectorMemory(op, vt, lane, base, offset, show_lane);
}

fn validateOffset(op: ir.Op, offset: i64) !void {
    const scale: i64 = op.info().scale;
    if (@mod(offset, scale) != 0) return error.VectorMemoryOffsetUnaligned;
    const scaled = @divExact(offset, scale);
    if (scaled < -64 or scaled > 63) return error.VectorMemoryOffsetOutOfRange;
}

/// Full 128-bit `lqv`/`sqv`.
pub fn writeVectorMemory(out: *Emitter, load: bool, vt: VReg, base: Register, offset: i64) !void {
    try vectorTransfer(out, if (load) .lqv else .sqv, vt, 0, base, offset, false);
}

/// Statement-form vector memory operations.
pub fn writeVectorMemoryOperation(g: Gen, operation: ast.VectorMemoryOperation, vt: VReg, lane: u3, base: Register, offset: i64) !void {
    const form = memory_forms.get(operation);
    try validateOffset(form.op, offset);
    if (operation == .load_transpose and @intFromEnum(vt) % 8 != 0) return error.TransposeRequiresRegisterBank;
    try g.out.vectorMemory(form.op, vt, if (form.show_lane) lane else 0, base, offset, form.show_lane);
}

const MemoryForm = struct { op: ir.Op, show_lane: bool = true };

const memory_forms = std.EnumArray(ast.VectorMemoryOperation, MemoryForm).init(.{
    .load16 = .{ .op = .lsv },
    .store16 = .{ .op = .ssv },
    .load32 = .{ .op = .llv },
    .store32 = .{ .op = .slv },
    .load64 = .{ .op = .ldv },
    .store64 = .{ .op = .sdv },
    .load128 = .{ .op = .lqv, .show_lane = false },
    .store128 = .{ .op = .sqv, .show_lane = false },
    .load_quad_lane = .{ .op = .lqv },
    .load_right = .{ .op = .lrv },
    .store_right = .{ .op = .srv },
    .load_transpose = .{ .op = .ltv },
    .load_packed_signed = .{ .op = .lpv, .show_lane = false },
    .load_packed_unsigned = .{ .op = .luv, .show_lane = false },
    .store_packed_signed = .{ .op = .spv },
    .store_packed_unsigned = .{ .op = .suv },
});

/// Expression-form vector loads: full, packed, one word lane, or unaligned.
pub fn writeVectorLoad(g: Gen, destination: VReg, load: ast.Load) !void {
    if (load.label_offset != null) return error.SymbolicOffsetRequiresScalarLoad;
    const base = try operands.valueAsDmemReg(g, load.address);
    if (packedLoadOp(load)) |op| return vectorTransfer(g.out, op, destination, 0, base, load.offset, false);
    if (load.partial_u32_lane) |lane| return vectorMemory(g.out, .llv, destination, lane, base, load.offset);
    try writeQuadLoad(g.out, destination, base, load.offset, load.unaligned);
    if (load.data_type == .vec32) try writeQuadLoad(g.out, secondHalf(destination), base, load.offset + 16, load.unaligned);
}

/// Packed byte loads expand eight bytes into the vector's lanes.
fn packedLoadOp(load: ast.Load) ?ir.Op {
    if (load.packed_unsigned_u8) return .luv;
    if (load.packed_u8) return .lpv;
    return null;
}

/// An `lqv`, plus the `lrv` completing an unaligned load.
fn writeQuadLoad(out: *Emitter, destination: VReg, base: Register, offset: i64, unaligned: bool) !void {
    try writeVectorMemory(out, true, destination, base, offset);
    if (unaligned) try vectorTransfer(out, .lrv, destination, 0, base, offset + 16, false);
}

const testing = std.testing;

test "vector memory validates the scaled offset encoding" {
    var out = Emitter.init(testing.allocator);
    defer out.deinit();
    try vectorMemory(&out, .lsv, .v01, 2, .t0, 4);
    try testing.expectError(error.VectorMemoryOffsetUnaligned, vectorMemory(&out, .llv, .v01, 0, .t0, 2));
    try testing.expectError(error.VectorMemoryOffsetOutOfRange, vectorMemory(&out, .lqv, .v01, 0, .t0, 1024));
    try testing.expectEqual(@as(usize, 1), out.len());
    try testing.expectEqual(ir.Op.vmadh, irOp(.vmadh));
    try testing.expectEqual(@as(?ShiftForm, null), basicShiftForm(.shift_left, 7));
    try testing.expectEqual(@as(?ir.Op, null), vec16BinaryOp(.mul));
}
