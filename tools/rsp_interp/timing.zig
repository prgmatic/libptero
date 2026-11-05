//! Estimated RSP issue timing for executed instructions.
//!
//! The model follows the rules used by RSPL's cost evaluator (derived from the
//! n64brew RSP pipeline notes): one scalar and one vector instruction may
//! dual-issue when independent and outside a branch/delay-slot pair; results
//! become available after a per-class latency; a store issued exactly two
//! cycles after a load stalls once; and a taken branch inserts one bubble.
//! CFC2 additionally waits for flags written by computational vector ops.
//! `calibration.zig` holds the hardware measurements this model must match.
const std = @import("std");
const fields = @import("fields.zig");

pub const Unit = enum { scalar, vector };
const none: u8 = 0xff;
const vector_base: u8 = 32;
/// Pseudo-register for the VCO/VCC/VCE flag registers.
const flags: u8 = 64;

pub const latency = struct {
    pub const scalar_load = 3;
    pub const vector = 4;
    pub const control_move = 3;
    /// Calibrated on hardware: CFC2 cannot issue with the vector op that
    /// produced VCO/VCC/VCE and runs one cycle later (see calibration.zig).
    pub const vector_flags = 1;
};

pub const Info = struct {
    unit: Unit = .scalar,
    sources: [2]u8 = .{ none, none },
    dest: u8 = none,
    latency: u8 = 0,
    /// Computational vector ops also produce the flag registers.
    writes_flags: bool = false,
    branch: bool = false,
    load: bool = false,
    store: bool = false,

    fn reads(self: Info, register: u8) bool {
        return register != none and (self.sources[0] == register or self.sources[1] == register);
    }

    /// True when this instruction reads or overwrites `previous`'s result.
    fn dependsOn(self: Info, previous: Info) bool {
        if (previous.dest == none) return false;
        return self.reads(previous.dest) or self.dest == previous.dest;
    }
};

pub const Pipeline = struct {
    /// Total cycles elapsed after the most recently issued instruction.
    cycles: u64 = 0,
    ready: [65]u64 = @splat(0),
    pair_candidate: ?Info = null,
    last_load_cycle: ?u64 = null,
    in_delay_slot: bool = false,

    pub fn issue(self: *Pipeline, op: u32, taken_branch: bool) void {
        const info = classify(op);
        var cycle = self.cycles;
        if (self.pairsWith(info)) cycle -= 1;
        cycle = @max(cycle, self.operandsReady(info));
        cycle += self.storeStall(info, cycle);
        self.retire(info, cycle);
        self.pair_candidate = self.nextCandidate(info, cycle);
        self.in_delay_slot = info.branch;
        self.cycles = @max(self.cycles, cycle + 1) + @intFromBool(taken_branch);
    }

    fn storeStall(self: *const Pipeline, info: Info, cycle: u64) u64 {
        if (!info.store) return 0;
        const load_cycle = self.last_load_cycle orelse return 0;
        return @intFromBool(load_cycle + 2 == cycle);
    }

    /// An instruction may accept a partner only if it issued alone and is not
    /// part of a branch/delay-slot pair.
    fn nextCandidate(self: *const Pipeline, info: Info, cycle: u64) ?Info {
        if (cycle + 1 == self.cycles) return null;
        if (info.branch or self.in_delay_slot) return null;
        return info;
    }

    fn pairsWith(self: *const Pipeline, info: Info) bool {
        const previous = self.pair_candidate orelse return false;
        if (previous.unit == info.unit or info.branch) return false;
        return !info.dependsOn(previous);
    }

    fn operandsReady(self: *const Pipeline, info: Info) u64 {
        var cycle: u64 = 0;
        for (info.sources) |source| {
            if (source != none) cycle = @max(cycle, self.ready[source]);
        }
        return cycle;
    }

    fn retire(self: *Pipeline, info: Info, cycle: u64) void {
        if (info.dest != none and info.dest != 0) self.ready[info.dest] = cycle + info.latency;
        if (info.writes_flags) self.ready[flags] = cycle + latency.vector_flags;
        if (info.load) self.last_load_cycle = cycle;
    }
};

pub fn classify(op: u32) Info {
    return classifiers[fields.opcode(op)](op);
}

/// Cycles `consumer` waits after `producer` issues when it reads the
/// producer's result; 0 when it does not.
pub fn resultLatency(producer: u32, consumer: u32) u8 {
    const result = classify(producer);
    const reader = classify(consumer);
    if (result.dest != none and reader.reads(result.dest)) return result.latency;
    if (result.writes_flags and reader.reads(flags)) return latency.vector_flags;
    return 0;
}

const Classifier = *const fn (u32) Info;

fn gpr(index: u5) u8 {
    return index;
}

fn vpr(index: u5) u8 {
    return vector_base + @as(u8, index);
}

fn plain(_: u32) Info {
    return .{};
}

fn special(op: u32) Info {
    const funct = fields.funct(op);
    const link = funct == 0x09;
    return .{
        .sources = .{ gpr(fields.rs(op)), gpr(fields.rt(op)) },
        .dest = if (funct == 0x08 or funct == 0x0d) none else gpr(fields.rd(op)),
        .branch = funct == 0x08 or link,
    };
}

fn regimm(op: u32) Info {
    return .{
        .sources = .{ gpr(fields.rs(op)), none },
        .dest = if (fields.rt(op) & 0x10 != 0) 31 else none,
        .branch = true,
    };
}

fn jumpOnly(_: u32) Info {
    return .{ .branch = true };
}

fn jumpLink(_: u32) Info {
    return .{ .branch = true, .dest = 31 };
}

fn branchCompare(op: u32) Info {
    return .{ .sources = .{ gpr(fields.rs(op)), gpr(fields.rt(op)) }, .branch = true };
}

fn immediateAlu(op: u32) Info {
    return .{ .sources = .{ gpr(fields.rs(op)), none }, .dest = gpr(fields.rt(op)) };
}

fn scalarLoad(op: u32) Info {
    return .{ .sources = .{ gpr(fields.rs(op)), none }, .dest = gpr(fields.rt(op)), .latency = latency.scalar_load, .load = true };
}

fn scalarStore(op: u32) Info {
    return .{ .sources = .{ gpr(fields.rs(op)), gpr(fields.rt(op)) }, .store = true };
}

fn cop0(op: u32) Info {
    if (fields.rs(op) == 4) return .{ .sources = .{ gpr(fields.rt(op)), none }, .store = true };
    return .{ .dest = gpr(fields.rt(op)), .latency = latency.control_move, .load = true };
}

fn cop2(op: u32) Info {
    if (op >> 25 & 1 != 0) return .{
        .unit = .vector,
        .sources = .{ vpr(fields.vs(op)), vpr(fields.vt(op)) },
        .dest = vpr(fields.vd(op)),
        .latency = latency.vector,
        .writes_flags = true,
    };
    return cop2Move(op);
}

fn cop2Move(op: u32) Info {
    return switch (fields.rs(op)) {
        0 => .{ .sources = .{ vpr(fields.vs(op)), none }, .dest = gpr(fields.rt(op)), .latency = latency.control_move, .load = true },
        2 => .{ .sources = .{ flags, none }, .dest = gpr(fields.rt(op)), .latency = latency.control_move, .load = true },
        4 => .{ .sources = .{ gpr(fields.rt(op)), none }, .dest = vpr(fields.vs(op)), .latency = latency.vector, .store = true },
        else => .{ .sources = .{ gpr(fields.rt(op)), none }, .latency = latency.control_move, .store = true },
    };
}

fn vectorLoad(op: u32) Info {
    return .{ .sources = .{ gpr(fields.rs(op)), none }, .dest = vpr(fields.vt(op)), .latency = latency.vector, .load = true };
}

fn vectorStore(op: u32) Info {
    return .{ .sources = .{ gpr(fields.rs(op)), vpr(fields.vt(op)) }, .store = true };
}

const classifiers = blk: {
    var table: [64]Classifier = @splat(&plain);
    table[0x00] = &special;
    table[0x01] = &regimm;
    table[0x02] = &jumpOnly;
    table[0x03] = &jumpLink;
    for (0x04..0x08) |index| table[index] = &branchCompare;
    for (0x08..0x10) |index| table[index] = &immediateAlu;
    table[0x10] = &cop0;
    table[0x12] = &cop2;
    for (0x20..0x28) |index| table[index] = &scalarLoad;
    for (0x28..0x2c) |index| table[index] = &scalarStore;
    table[0x32] = &vectorLoad;
    table[0x3a] = &vectorStore;
    break :blk table;
};

const testing = std.testing;
const encode = @import("encode.zig");

fn cyclesFor(ops: []const u32) u64 {
    var pipeline: Pipeline = .{};
    for (ops) |op| pipeline.issue(op, false);
    return pipeline.cycles;
}

test "result latency applies only to consumers of the result" {
    const load = encode.lw(8, 0, 0);
    try testing.expectEqual(@as(u8, 3), resultLatency(load, encode.addiu(9, 8, 1)));
    try testing.expectEqual(@as(u8, 0), resultLatency(load, encode.addiu(9, 10, 1)));
    const carry = encode.vectorOp(0x14, 1, 2, 3, 0);
    try testing.expectEqual(@as(u8, 1), resultLatency(carry, encode.cop2Move(.cfc2, 8, 0, 0)));
}

test "independent scalar and vector instructions dual-issue" {
    const vadd = encode.vectorOp(0x10, 1, 2, 3, 0);
    try testing.expectEqual(@as(u64, 1), cyclesFor(&.{ encode.addiu(8, 0, 1), vadd }));
    try testing.expectEqual(@as(u64, 1), cyclesFor(&.{ vadd, encode.addiu(8, 0, 1) }));
    try testing.expectEqual(@as(u64, 2), cyclesFor(&.{ encode.addiu(8, 0, 1), encode.addiu(9, 0, 1) }));
    try testing.expectEqual(@as(u64, 2), cyclesFor(&.{ encode.addiu(8, 0, 1), vadd, encode.addiu(9, 0, 1), vadd }));
    try testing.expectEqual(@as(u64, 3), cyclesFor(&.{ encode.addiu(8, 0, 1), encode.addiu(9, 0, 1), vadd, vadd }));
}

test "dependent results stall for their latency" {
    const load = encode.lw(8, 0, 0);
    try testing.expectEqual(@as(u64, 4), cyclesFor(&.{ load, encode.addiu(9, 8, 1) }));
    const first = encode.vectorOp(0x10, 1, 2, 3, 0);
    const dependent = encode.vectorOp(0x10, 4, 1, 3, 0);
    try testing.expectEqual(@as(u64, 5), cyclesFor(&.{ first, dependent }));
    // A vector result read by a paired scalar store cannot share its cycle.
    try testing.expectEqual(@as(u64, 5), cyclesFor(&.{ first, encode.vectorStore(.sqv, 1, 0, 0, 0) }));
    try testing.expectEqual(@as(u64, 2), cyclesFor(&.{ encode.vectorLoad(.lqv, 1, 0, 0, 0), encode.vectorOp(0x10, 1, 2, 3, 0) }));
}

test "stores two cycles after loads, branches, and taken bubbles" {
    try testing.expectEqual(@as(u64, 4), cyclesFor(&.{ encode.lw(8, 0, 0), encode.nop, encode.sw(9, 0, 0) }));
    try testing.expectEqual(@as(u64, 2), cyclesFor(&.{ encode.bne(8, 9, 1), encode.vectorOp(0x10, 1, 2, 3, 0) }));
    var pipeline: Pipeline = .{};
    pipeline.issue(encode.jump(0x03, 0x100), true);
    pipeline.issue(encode.nop, false);
    try testing.expectEqual(@as(u64, 3), pipeline.cycles);
}

test "classification covers every operand form" {
    try testing.expectEqual(@as(u8, 31), classify(encode.regimm(0x11, 8, 0)).dest);
    try testing.expectEqual(none, classify(encode.regimm(0x01, 8, 0)).dest);
    try testing.expect(classify(encode.jr(31)).branch);
    try testing.expect(classify(encode.special(0x09, 8, 0, 31, 0)).branch);
    try testing.expectEqual(none, classify(encode.brk).dest);
    try testing.expect(classify(encode.jump(0x02, 0)).branch);
    try testing.expect(classify(encode.cop0Move(true, 8, 4)).store);
    try testing.expect(classify(encode.cop0Move(false, 8, 4)).load);
    try testing.expectEqual(@as(u8, 8), classify(encode.cop2Move(.mfc2, 8, 1, 0)).dest);
    try testing.expectEqual(@as(u8, 8), classify(encode.cop2Move(.cfc2, 8, 1, 0)).dest);
    try testing.expectEqual(vpr(1), classify(encode.cop2Move(.mtc2, 8, 1, 0)).dest);
    try testing.expect(classify(encode.cop2Move(.ctc2, 8, 1, 0)).store);
    try testing.expectEqual(Unit.scalar, classify(0x4c00_0000).unit);
    try testing.expect(classify(encode.vectorOp(0x14, 1, 2, 3, 0)).writes_flags);
}
