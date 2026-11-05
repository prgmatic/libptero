//! What each IR instruction reads, writes, and touches, for dependency
//! analysis. Semantics follow `tools/rsp_interp` (itself checked against
//! ares and hardware): computational vector ops write the accumulator, and
//! the add, compare, clip, and merge families read or clear VCO/VCC/VCE.
const std = @import("std");
const ir = @import("ir.zig");

const Inst = ir.Inst;
const Op = ir.Op;

/// Vector unit and system state that instructions share implicitly.
pub const State = packed struct(u8) {
    accumulator: bool = false,
    carry: bool = false,
    compare: bool = false,
    clip: bool = false,
    divide: bool = false,
    /// COP0 registers: DMA, semaphore, status, and RDP control.
    io: bool = false,
    _: u2 = 0,

    pub fn bits(self: State) u8 {
        return @bitCast(self);
    }

    pub fn overlaps(self: State, other: State) bool {
        return self.bits() & other.bits() != 0;
    }
};

pub const Control = enum { none, branch, jump, call, indirect_jump, indirect_call, halt };

/// A DMEM access. `symbol` and `offset` describe the address relative to the
/// value of `base`; `size` is an upper bound in bytes.
pub const Access = struct {
    store: bool,
    base: ir.Reg,
    symbol: ?[]const u8,
    offset: i32,
    size: u8,
    /// True for transfers whose address range is not known from the operand
    /// (COP0 DMA and status), which conflict with every other access.
    unknown: bool = false,
};

pub const Effects = struct {
    scalar_reads: u32 = 0,
    scalar_writes: u32 = 0,
    vector_reads: u32 = 0,
    vector_writes: u32 = 0,
    state_reads: State = .{},
    state_writes: State = .{},
    memory: ?Access = null,
    control: Control = .none,

    fn readScalar(self: *Effects, reg: ir.Reg) void {
        self.scalar_reads |= scalarBit(reg);
    }

    fn writeScalar(self: *Effects, reg: ir.Reg) void {
        self.scalar_writes |= scalarBit(reg);
    }

    fn readVector(self: *Effects, reg: ir.VReg) void {
        self.vector_reads |= vectorBit(reg);
    }

    fn writeVector(self: *Effects, reg: ir.VReg) void {
        self.vector_writes |= vectorBit(reg);
    }

    /// Partial writes merge into the register's previous value.
    fn modifyVector(self: *Effects, reg: ir.VReg) void {
        self.readVector(reg);
        self.writeVector(reg);
    }

    pub fn isTransfer(self: Effects) bool {
        return self.control != .none;
    }
};

/// Bit for a scalar register; `$zero` is neither read nor written.
pub fn scalarBit(reg: ir.Reg) u32 {
    if (reg == .zero) return 0;
    return @as(u32, 1) << @intFromEnum(reg);
}

pub fn vectorBit(reg: ir.VReg) u32 {
    return @as(u32, 1) << @intFromEnum(reg);
}

pub fn of(inst: Inst) Effects {
    var effects: Effects = .{};
    analyzers.get(inst.op.format())(inst, &effects);
    return effects;
}

const Analyzer = *const fn (Inst, *Effects) void;

const analyzers = std.EnumArray(ir.Format, Analyzer).init(.{
    .none = &noEffects,
    .breakpoint = &halt,
    .register = &registerForm,
    .shift_variable = &registerForm,
    .shift = &shiftForm,
    .immediate = &immediateForm,
    .upper = &immediateForm,
    .memory = &scalarMemory,
    .jump = &jumpForm,
    .jump_register = &jumpRegisterForm,
    .branch_compare = &branchForm,
    .branch_zero = &branchForm,
    .branch_always = &jumpForm,
    .cop0 = &cop0Form,
    .cop2_lane = &cop2LaneForm,
    .cop2_control = &cop2ControlForm,
    .vector = &vectorForm,
    .vector_lane = &vectorLaneForm,
    .vector_memory = &vectorMemory,
});

fn noEffects(_: Inst, _: *Effects) void {}

fn halt(_: Inst, effects: *Effects) void {
    effects.control = .halt;
}

fn registerForm(inst: Inst, effects: *Effects) void {
    effects.readScalar(inst.rs);
    effects.readScalar(inst.rt);
    effects.writeScalar(inst.rd);
}

fn shiftForm(inst: Inst, effects: *Effects) void {
    effects.readScalar(inst.rt);
    effects.writeScalar(inst.rd);
}

fn immediateForm(inst: Inst, effects: *Effects) void {
    effects.readScalar(inst.rs);
    effects.writeScalar(inst.rt);
}

fn isStore(op: Op) bool {
    return switch (op) {
        .sb, .sh, .sw, .sbv, .ssv, .slv, .sdv, .sqv, .srv, .spv, .suv, .stv => true,
        else => false,
    };
}

fn scalarSize(op: Op) u8 {
    return switch (op) {
        .lb, .lbu, .sb => 1,
        .lh, .lhu, .sh => 2,
        else => 4,
    };
}

fn scalarMemory(inst: Inst, effects: *Effects) void {
    const store = isStore(inst.op);
    effects.readScalar(inst.rs);
    if (store) effects.readScalar(inst.rt) else effects.writeScalar(inst.rt);
    effects.memory = .{ .store = store, .base = inst.rs, .symbol = inst.symbol, .offset = inst.imm, .size = scalarSize(inst.op) };
}

fn jumpForm(inst: Inst, effects: *Effects) void {
    if (inst.op == .jal) {
        effects.control = .call;
        effects.writeScalar(.ra);
    } else {
        effects.control = .jump;
    }
}

fn jumpRegisterForm(inst: Inst, effects: *Effects) void {
    effects.readScalar(inst.rs);
    if (inst.op == .jalr) {
        effects.control = .indirect_call;
        effects.writeScalar(.ra);
    } else {
        effects.control = .indirect_jump;
    }
}

fn branchForm(inst: Inst, effects: *Effects) void {
    effects.readScalar(inst.rs);
    effects.readScalar(inst.rt);
    effects.control = .branch;
}

/// COP0 accesses start, poll, or reconfigure DMA and the RDP, so they stay
/// ordered with each other and with every DMEM access.
fn cop0Form(inst: Inst, effects: *Effects) void {
    if (inst.op == .mtc0) effects.readScalar(inst.rt) else effects.writeScalar(inst.rt);
    effects.state_reads.io = true;
    effects.state_writes.io = true;
    effects.memory = .{ .store = true, .base = .zero, .symbol = null, .offset = 0, .size = 0, .unknown = true };
}

fn cop2LaneForm(inst: Inst, effects: *Effects) void {
    if (inst.op == .mfc2) {
        effects.readVector(inst.vt);
        effects.writeScalar(inst.rt);
    } else {
        effects.readScalar(inst.rt);
        effects.modifyVector(inst.vt);
    }
}

fn controlState(index: i32) State {
    return switch (index) {
        0 => .{ .carry = true },
        1 => .{ .compare = true },
        else => .{ .clip = true },
    };
}

fn cop2ControlForm(inst: Inst, effects: *Effects) void {
    if (inst.op == .cfc2) {
        effects.state_reads = controlState(inst.imm);
        effects.writeScalar(inst.rt);
    } else {
        effects.readScalar(inst.rt);
        effects.state_writes = controlState(inst.imm);
    }
}

/// Implicit state each computational vector op reads and writes.
const VectorState = struct { reads: State = .{}, writes: State = .{ .accumulator = true } };

fn vectorState(op: Op) VectorState {
    return vector_states.get(op);
}

const all_flags: State = .{ .accumulator = true, .carry = true, .compare = true, .clip = true };

const vector_states = blk: {
    var table = std.EnumArray(Op, VectorState).initFill(.{});
    for ([_]Op{ .vmacf, .vmacu, .vmadl, .vmadm, .vmadn, .vmadh }) |op| table.set(op, .{ .reads = .{ .accumulator = true } });
    for ([_]Op{ .vadd, .vsub }) |op| table.set(op, .{ .reads = .{ .carry = true }, .writes = .{ .accumulator = true, .carry = true } });
    for ([_]Op{ .vaddc, .vsubc }) |op| table.set(op, .{ .writes = .{ .accumulator = true, .carry = true } });
    for ([_]Op{ .vlt, .veq, .vne, .vge }) |op| {
        table.set(op, .{ .reads = .{ .carry = true }, .writes = .{ .accumulator = true, .carry = true, .compare = true } });
    }
    table.set(.vcl, .{ .reads = .{ .carry = true, .compare = true, .clip = true }, .writes = all_flags });
    table.set(.vch, .{ .writes = all_flags });
    table.set(.vcr, .{ .writes = all_flags });
    table.set(.vmrg, .{ .reads = .{ .compare = true }, .writes = .{ .accumulator = true, .carry = true } });
    table.set(.vsar, .{ .reads = .{ .accumulator = true }, .writes = .{} });
    table.set(.vnop, .{ .writes = .{} });
    break :blk table;
};

fn vectorForm(inst: Inst, effects: *Effects) void {
    const state = vectorState(inst.op);
    effects.state_reads = state.reads;
    effects.state_writes = state.writes;
    if (inst.op == .vnop) return;
    if (inst.op != .vsar) {
        effects.readVector(inst.vs);
        effects.readVector(inst.vt);
    }
    effects.writeVector(inst.vd);
}

fn vectorLaneForm(inst: Inst, effects: *Effects) void {
    effects.readVector(inst.vt);
    effects.modifyVector(inst.vd);
    effects.state_writes.accumulator = true;
    if (inst.op == .vmov) return;
    effects.state_reads.divide = true;
    effects.state_writes.divide = true;
}

/// Bytes a vector transfer may touch, relative to its offset. Quad and rest
/// transfers stop at a 16-byte boundary whose position depends on the
/// runtime address, so they conservatively cover 16 bytes on either side.
fn vectorRange(op: Op) struct { start: i32, size: u8 } {
    return switch (op) {
        .lbv, .sbv => .{ .start = 0, .size = 1 },
        .lsv, .ssv => .{ .start = 0, .size = 2 },
        .llv, .slv => .{ .start = 0, .size = 4 },
        .ldv, .sdv, .lpv, .luv, .spv, .suv => .{ .start = 0, .size = 8 },
        .lqv, .sqv => .{ .start = 0, .size = 16 },
        .lrv, .srv => .{ .start = -16, .size = 32 },
        else => .{ .start = 0, .size = 16 },
    };
}

fn transposeBank(base: ir.VReg) u32 {
    return @as(u32, 0xff) << (@intFromEnum(base) & 0x18);
}

fn vectorMemory(inst: Inst, effects: *Effects) void {
    const store = isStore(inst.op);
    effects.readScalar(inst.rs);
    const registers = if (inst.op == .ltv or inst.op == .stv) transposeBank(inst.vt) else vectorBit(inst.vt);
    effects.vector_reads |= registers;
    if (!store) effects.vector_writes |= registers;
    const range = vectorRange(inst.op);
    effects.memory = .{
        .store = store,
        .base = inst.rs,
        .symbol = inst.symbol,
        .offset = inst.imm + range.start,
        .size = range.size,
    };
}

/// Whether two accesses may touch overlapping bytes. Different symbols, or
/// different bases, could alias, so only same-base, same-symbol accesses
/// with disjoint ranges are known to be independent. The caller ensures the
/// base register holds the same value at both accesses.
pub fn mayAlias(a: Access, b: Access) bool {
    if (a.unknown or b.unknown) return true;
    if (a.base != b.base) return true;
    if (!sameSymbol(a.symbol, b.symbol)) return true;
    return a.offset < b.offset + b.size and b.offset < a.offset + a.size;
}

fn sameSymbol(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const testing = std.testing;

test "scalar instructions report register and memory effects" {
    const add = of(.{ .op = .addu, .rd = .t0, .rs = .t1, .rt = .zero });
    try testing.expectEqual(scalarBit(.t1), add.scalar_reads);
    try testing.expectEqual(scalarBit(.t0), add.scalar_writes);
    const store = of(.{ .op = .sw, .rt = .t0, .rs = .sp, .imm = 8 });
    try testing.expectEqual(scalarBit(.t0) | scalarBit(.sp), store.scalar_reads);
    try testing.expect(store.memory.?.store);
    try testing.expectEqual(@as(u8, 4), store.memory.?.size);
    try testing.expectEqual(Control.call, of(.{ .op = .jal, .symbol = "f" }).control);
    try testing.expectEqual(scalarBit(.ra), of(.{ .op = .jalr, .rs = .t0 }).scalar_writes);
    try testing.expectEqual(Control.halt, of(.{ .op = .@"break" }).control);
    try testing.expect(of(.{ .op = .mtc0, .rt = .t0, .imm = 3 }).memory.?.unknown);
}

test "vector instructions report accumulator, flag, and partial writes" {
    const multiply = of(.{ .op = .vmadh, .vd = .v01, .vs = .v02, .vt = .v03 });
    try testing.expect(multiply.state_reads.accumulator and multiply.state_writes.accumulator);
    const add = of(.{ .op = .vadd, .vd = .v01, .vs = .v02, .vt = .v03 });
    try testing.expect(add.state_reads.carry and add.state_writes.carry);
    try testing.expect(!of(.{ .op = .vxor, .vd = .v01 }).state_writes.carry);
    try testing.expect(of(.{ .op = .vmrg, .vd = .v01 }).state_reads.compare);
    try testing.expect(of(.{ .op = .vsar, .vd = .v01 }).state_reads.accumulator);
    try testing.expect(of(.{ .op = .cfc2, .rt = .t0, .imm = 1 }).state_reads.compare);
    try testing.expect(of(.{ .op = .ctc2, .rt = .t0, .imm = 2 }).state_writes.clip);
    try testing.expect(of(.{ .op = .vrcph, .vd = .v01, .vt = .v02, .element = 8 }).state_reads.divide);
    const lane = of(.{ .op = .mtc2, .rt = .t0, .vt = .v04 });
    try testing.expectEqual(vectorBit(.v04), lane.vector_reads & lane.vector_writes);
    const transpose = of(.{ .op = .ltv, .vt = .v08, .rs = .t0 });
    try testing.expectEqual(@as(u32, 0xff00), transpose.vector_writes);
    try testing.expectEqual(@as(u32, 0xff00), of(.{ .op = .stv, .vt = .v08, .rs = .t0 }).vector_reads & 0xff00);
    try testing.expectEqual(@as(i32, -16), of(.{ .op = .lrv, .vt = .v01, .rs = .t0 }).memory.?.offset);
    try testing.expectEqual(@as(u32, 0), of(.{ .op = .vnop }).vector_writes);
}

test "accesses alias unless they provably cover different bytes" {
    const at = struct {
        fn access(base: ir.Reg, symbol: ?[]const u8, offset: i32, size: u8) Access {
            return .{ .store = true, .base = base, .symbol = symbol, .offset = offset, .size = size };
        }
    }.access;
    try testing.expect(!mayAlias(at(.t0, null, 0, 4), at(.t0, null, 4, 4)));
    try testing.expect(mayAlias(at(.t0, null, 0, 4), at(.t0, null, 2, 4)));
    try testing.expect(mayAlias(at(.t0, null, 0, 4), at(.t1, null, 8, 4)));
    try testing.expect(!mayAlias(at(.zero, "a", 0, 4), at(.zero, "a", 4, 4)));
    try testing.expect(mayAlias(at(.zero, "a", 0, 4), at(.zero, "b", 4, 4)));
    try testing.expect(mayAlias(at(.zero, "a", 0, 4), at(.zero, null, 4, 4)));
    var unknown = at(.zero, null, 0, 0);
    unknown.unknown = true;
    try testing.expect(mayAlias(unknown, at(.t0, null, 100, 4)));
}
