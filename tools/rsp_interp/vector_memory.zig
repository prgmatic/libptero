//! LWC2/SWC2: vector register loads and stores, including the packed,
//! unaligned, and transposed forms. Byte-level behavior follows ares, whose
//! RSP implementation is validated against hardware test suites.
const std = @import("std");
const Machine = @import("Machine.zig");
const fields = @import("fields.zig");
const vector = @import("vector.zig");

const Error = Machine.Error;
const Vec = vector.Vec;

const Access = struct {
    m: *Machine,
    vt: u5,
    e: u32,
    address: u32,

    fn reg(self: Access) *Vec {
        return &self.m.vu.regs[self.vt];
    }

    fn read(self: Access, address: u32) u8 {
        return self.m.dmemByte(address);
    }

    fn write(self: Access, address: u32, value: u8) void {
        self.m.setDmemByte(address, value);
    }

    /// Address rounded down to eight bytes plus the misalignment minus `e`.
    fn quadBase(self: Access) struct { aligned: u32, index: u32 } {
        return .{ .aligned = self.address & ~@as(u32, 7), .index = (self.address & 7) -% self.e };
    }
};

const Kind = struct { handler: *const fn (Access) void, scale: u32 };

pub fn load(m: *Machine, op: u32) Error!void {
    const kind = (try kindAt(&loads, op)) orelse return error.InvalidInstruction;
    kind.handler(access(m, op, kind.scale));
}

pub fn store(m: *Machine, op: u32) Error!void {
    const kind = (try kindAt(&stores, op)) orelse return error.InvalidInstruction;
    kind.handler(access(m, op, kind.scale));
}

fn kindAt(table: []const ?Kind, op: u32) Error!?Kind {
    const index: usize = @as(u5, @truncate(op >> 11));
    if (index >= table.len) return error.InvalidInstruction;
    return table[index];
}

fn access(m: *Machine, op: u32, scale: u32) Access {
    const offset: u32 = @bitCast(fields.vectorOffset(op) * @as(i32, @intCast(scale)));
    return .{
        .m = m,
        .vt = fields.vt(op),
        .e = fields.byteElement(op),
        .address = m.gpr[fields.rs(op)] +% offset,
    };
}

const loads = [_]?Kind{
    .{ .handler = lbv, .scale = 1 },
    .{ .handler = sequentialLoad(2), .scale = 2 },
    .{ .handler = sequentialLoad(4), .scale = 4 },
    .{ .handler = sequentialLoad(8), .scale = 8 },
    .{ .handler = lqv, .scale = 16 },
    .{ .handler = lrv, .scale = 16 },
    .{ .handler = packedLoad(8), .scale = 8 },
    .{ .handler = packedLoad(7), .scale = 8 },
    .{ .handler = lhv, .scale = 16 },
    .{ .handler = lfv, .scale = 16 },
    null,
    .{ .handler = ltv, .scale = 16 },
};

const stores = [_]?Kind{
    .{ .handler = sbv, .scale = 1 },
    .{ .handler = sequentialStore(2), .scale = 2 },
    .{ .handler = sequentialStore(4), .scale = 4 },
    .{ .handler = sequentialStore(8), .scale = 8 },
    .{ .handler = sqv, .scale = 16 },
    .{ .handler = srv, .scale = 16 },
    .{ .handler = packedStore(false), .scale = 8 },
    .{ .handler = packedStore(true), .scale = 8 },
    .{ .handler = shv, .scale = 16 },
    .{ .handler = sfv, .scale = 16 },
    .{ .handler = swv, .scale = 16 },
    .{ .handler = stv, .scale = 16 },
};

fn lbv(a: Access) void {
    vector.setByte(a.reg(), a.e, a.read(a.address));
}

/// LSV/LLV/LDV: load `size` bytes starting at byte `e`, never past byte 15.
fn sequentialLoad(comptime size: u32) *const fn (Access) void {
    return struct {
        fn run(a: Access) void {
            loadBytes(a, a.e, @min(a.e + size, 16), a.address);
        }
    }.run;
}

fn loadBytes(a: Access, start: u32, end: u32, address: u32) void {
    var source = address;
    var offset = start;
    while (offset < end) : (offset += 1) {
        vector.setByte(a.reg(), offset, a.read(source));
        source +%= 1;
    }
}

fn lqv(a: Access) void {
    loadBytes(a, a.e, @min(16 + a.e - (a.address & 15), 16), a.address);
}

fn lrv(a: Access) void {
    const start: i64 = 16 - (@as(i64, a.address & 15) - a.e);
    loadBytes(a, @intCast(@min(start, 16)), 16, a.address & ~@as(u32, 15));
}

/// LPV (shift 8) and LUV (shift 7): eight bytes expanded into lanes.
fn packedLoad(comptime shift: u4) *const fn (Access) void {
    return struct {
        fn run(a: Access) void {
            const base = a.quadBase();
            for (a.reg(), 0..) |*lane, n| {
                lane.* = @as(u16, a.read(base.aligned + ((base.index +% @as(u32, @intCast(n))) & 15))) << shift;
            }
        }
    }.run;
}

fn lhv(a: Access) void {
    const base = a.quadBase();
    for (a.reg(), 0..) |*lane, n| {
        lane.* = @as(u16, a.read(base.aligned + ((base.index +% @as(u32, @intCast(n * 2))) & 15))) << 7;
    }
}

fn lfv(a: Access) void {
    const base = a.quadBase();
    var expanded: Vec = undefined;
    for (0..4) |n| {
        const offset: u32 = @intCast(n * 4);
        expanded[n] = @as(u16, a.read(base.aligned + ((base.index +% offset) & 15))) << 7;
        expanded[n + 4] = @as(u16, a.read(base.aligned + ((base.index +% offset +% 8) & 15))) << 7;
    }
    var offset = a.e;
    while (offset < @min(a.e + 8, 16)) : (offset += 1) vector.setByte(a.reg(), offset, vector.byte(expanded, offset));
}

/// LTV: load one lane into each of eight consecutive registers, rotating the
/// lane per register to perform a transpose.
fn ltv(a: Access) void {
    const begin = a.address & ~@as(u32, 7);
    var source = begin + ((a.e + (a.address & 8)) & 15);
    const bank = a.vt & ~@as(u5, 7);
    var lane = a.e >> 1;
    for (0..8) |n| {
        const reg = &a.m.vu.regs[bank + (lane & 7)];
        for (0..2) |half| {
            vector.setByte(reg, n * 2 + half, a.read(source));
            source = nextTransposeAddress(source, begin);
        }
        lane += 1;
    }
}

fn nextTransposeAddress(address: u32, begin: u32) u32 {
    const next = address + 1;
    return if (next == begin + 16) begin else next;
}

fn sbv(a: Access) void {
    a.write(a.address, vector.byte(a.reg().*, a.e));
}

/// SSV/SLV/SDV: store `size` bytes from byte `e`, wrapping within the register.
fn sequentialStore(comptime size: u32) *const fn (Access) void {
    return struct {
        fn run(a: Access) void {
            storeBytes(a, a.e, a.e + size, a.address, 0);
        }
    }.run;
}

fn storeBytes(a: Access, start: u32, end: u32, address: u32, rotate: u32) void {
    var destination = address;
    var offset = start;
    while (offset < end) : (offset += 1) {
        a.write(destination, vector.byte(a.reg().*, offset + rotate));
        destination +%= 1;
    }
}

fn sqv(a: Access) void {
    storeBytes(a, a.e, a.e + (16 - (a.address & 15)), a.address, 0);
}

fn srv(a: Access) void {
    const misalignment = a.address & 15;
    storeBytes(a, a.e, a.e + misalignment, a.address & ~@as(u32, 15), 16 - misalignment);
}

/// SPV (`unsigned_first` false) and SUV (true): pack lanes into bytes. Lanes
/// in the first half of the element range use one encoding and the rest the other.
fn packedStore(comptime unsigned_first: bool) *const fn (Access) void {
    return struct {
        fn run(a: Access) void {
            var destination = a.address;
            for (a.e..a.e + 8) |offset| {
                const first_half = (offset & 15) < 8;
                a.write(destination, packedByte(a.reg().*, offset, first_half == unsigned_first));
                destination +%= 1;
            }
        }
    }.run;
}

fn packedByte(v: Vec, offset: usize, unsigned_form: bool) u8 {
    if (unsigned_form) return @truncate(v[offset & 7] >> 7);
    return vector.byte(v, (offset & 7) << 1);
}

fn shv(a: Access) void {
    const v = a.reg().*;
    const index = a.address & 7;
    const aligned = a.address & ~@as(u32, 7);
    for (0..8) |n| {
        const source = a.e + n * 2;
        const value = @as(u16, vector.byte(v, source)) << 1 | vector.byte(v, source + 1) >> 7;
        a.write(aligned + ((index + @as(u32, @intCast(n * 2))) & 15), @truncate(value));
    }
}

/// Lane orders written by SFV for each supported element; others write zeros.
const sfv_orders = blk: {
    var orders: [16]?[4]u3 = @splat(null);
    orders[0] = .{ 0, 1, 2, 3 };
    orders[15] = .{ 0, 1, 2, 3 };
    orders[1] = .{ 6, 7, 4, 5 };
    orders[4] = .{ 1, 2, 3, 0 };
    orders[5] = .{ 7, 4, 5, 6 };
    orders[8] = .{ 4, 5, 6, 7 };
    orders[11] = .{ 3, 0, 1, 2 };
    orders[12] = .{ 5, 6, 7, 4 };
    break :blk orders;
};

fn sfv(a: Access) void {
    const v = a.reg().*;
    const index = a.address & 7;
    const aligned = a.address & ~@as(u32, 7);
    const order = sfv_orders[a.e];
    for (0..4) |n| {
        const value: u8 = if (order) |lanes| @truncate(v[lanes[n]] >> 7) else 0;
        a.write(aligned + ((index + @as(u32, @intCast(n * 4))) & 15), value);
    }
}

fn swv(a: Access) void {
    const v = a.reg().*;
    var position = a.address & 7;
    const aligned = a.address & ~@as(u32, 7);
    for (a.e..a.e + 16) |offset| {
        a.write(aligned + (position & 15), vector.byte(v, offset));
        position += 1;
    }
}

/// STV: store one lane from each of eight registers, the inverse of LTV.
fn stv(a: Access) void {
    const even = a.e & ~@as(u32, 1);
    var element: u32 = 16 - even;
    var position = (a.address & 7) -% even;
    const aligned = a.address & ~@as(u32, 7);
    const bank = a.vt & ~@as(u5, 7);
    for (0..8) |n| {
        const v = a.m.vu.regs[bank + n];
        for (0..2) |_| {
            a.write(aligned + (position & 15), vector.byte(v, element));
            position +%= 1;
            element += 1;
        }
    }
}

const testing = std.testing;
const encode = @import("encode.zig");

fn fillDmem(m: *Machine) void {
    for (&m.dmem, 0..) |*byte, index| byte.* = @truncate(index);
}

fn exec(m: *Machine, op: u32) !void {
    if (fields.opcode(op) == 0x32) return load(m, op);
    return store(m, op);
}

test "sequential loads respect element and register bounds" {
    var m = Machine.init(&.{});
    fillDmem(&m);
    m.gpr[1] = 0x100;
    try exec(&m, encode.vectorLoad(.lbv, 2, 1, 3, 5));
    try testing.expectEqual(@as(u8, 0x05), vector.byte(m.vu.regs[2], 3));
    try exec(&m, encode.vectorLoad(.lsv, 2, 1, 4, 1));
    try testing.expectEqual(@as(u16, 0x0203), m.vu.regs[2][2]);
    try exec(&m, encode.vectorLoad(.llv, 2, 1, 14, 0));
    try testing.expectEqual(@as(u16, 0x0001), m.vu.regs[2][7]);
    try exec(&m, encode.vectorLoad(.ldv, 3, 1, 8, -1));
    try testing.expectEqual(Vec{ 0, 0, 0, 0, 0xf8f9, 0xfafb, 0xfcfd, 0xfeff }, m.vu.regs[3]);
}

test "quad and rest loads split an unaligned quadword" {
    var m = Machine.init(&.{});
    fillDmem(&m);
    m.gpr[1] = 0x106;
    try exec(&m, encode.vectorLoad(.lqv, 4, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0x0607), m.vu.regs[4][0]);
    try testing.expectEqual(@as(u16, 0x0e0f), m.vu.regs[4][4]);
    try testing.expectEqual(@as(u16, 0), m.vu.regs[4][5]);
    m.gpr[1] = 0x116;
    try exec(&m, encode.vectorLoad(.lrv, 4, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0x1011), m.vu.regs[4][5]);
    try testing.expectEqual(@as(u16, 0x1415), m.vu.regs[4][7]);
    try testing.expectEqual(@as(u16, 0x0607), m.vu.regs[4][0]);
    m.gpr[1] = 0x110;
    try exec(&m, encode.vectorLoad(.lrv, 4, 1, 2, 0));
    try testing.expectEqual(@as(u16, 0x0607), m.vu.regs[4][0]);
}

test "packed loads expand bytes into lanes" {
    var m = Machine.init(&.{});
    fillDmem(&m);
    m.gpr[1] = 0x81;
    try exec(&m, encode.vectorLoad(.lpv, 5, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0x8100), m.vu.regs[5][0]);
    try testing.expectEqual(@as(u16, 0x8800), m.vu.regs[5][7]);
    try exec(&m, encode.vectorLoad(.luv, 5, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0x8100 >> 1), m.vu.regs[5][0]);
    m.gpr[1] = 0x80;
    try exec(&m, encode.vectorLoad(.lhv, 6, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0x82 << 7), m.vu.regs[6][1]);
    try exec(&m, encode.vectorLoad(.lfv, 7, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0x84 << 7), m.vu.regs[7][1]);
    try testing.expectEqual(@as(u16, 0x8c << 7), m.vu.regs[7][3]);
    try testing.expectEqual(@as(u16, 0), m.vu.regs[7][4]);
    try testing.expectError(error.InvalidInstruction, exec(&m, encode.vectorLoad(.lwv, 7, 1, 0, 0)));
    try testing.expectError(error.InvalidInstruction, exec(&m, encode.vectorLoad(@enumFromInt(20), 7, 1, 0, 0)));
}

test "transposed load and store are inverses" {
    var m = Machine.init(&.{});
    fillDmem(&m);
    m.gpr[1] = 0x200;
    try exec(&m, encode.vectorLoad(.ltv, 8, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0x0001), m.vu.regs[8][0]);
    try testing.expectEqual(@as(u16, 0x0203), m.vu.regs[9][1]);
    try testing.expectEqual(@as(u16, 0x0e0f), m.vu.regs[15][7]);
    m.gpr[1] = 0x300;
    try exec(&m, encode.vectorStore(.stv, 8, 1, 0, 0));
    try testing.expectEqualSlices(u8, m.dmem[0x200..0x210], m.dmem[0x300..0x310]);
    m.gpr[1] = 0x208;
    try exec(&m, encode.vectorLoad(.ltv, 16, 1, 2, 0));
    try testing.expectEqual(@as(u16, 0x1213), m.vu.regs[17][0]);
}

test "sequential, quad, and rest stores" {
    var m = Machine.init(&.{});
    m.vu.regs[1] = .{ 0x0001, 0x0203, 0x0405, 0x0607, 0x0809, 0x0a0b, 0x0c0d, 0x0e0f };
    m.gpr[2] = 0x400;
    try exec(&m, encode.vectorStore(.sbv, 1, 2, 3, 0));
    try testing.expectEqual(@as(u8, 3), m.dmem[0x400]);
    try exec(&m, encode.vectorStore(.ssv, 1, 2, 15, 1));
    try testing.expectEqualSlices(u8, &.{ 15, 0 }, m.dmem[0x402..0x404]);
    try exec(&m, encode.vectorStore(.slv, 1, 2, 4, 1));
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7 }, m.dmem[0x404..0x408]);
    try exec(&m, encode.vectorStore(.sdv, 1, 2, 8, 1));
    try testing.expectEqualSlices(u8, &.{ 8, 9, 10, 11, 12, 13, 14, 15 }, m.dmem[0x408..0x410]);
    m.gpr[2] = 0x50c;
    try exec(&m, encode.vectorStore(.sqv, 1, 2, 0, 0));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, m.dmem[0x50c..0x510]);
    try testing.expectEqual(@as(u8, 0), m.dmem[0x510]);
    m.gpr[2] = 0x51c;
    try exec(&m, encode.vectorStore(.srv, 1, 2, 0, 0));
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, m.dmem[0x510..0x51c]);
}

test "packed stores" {
    var m = Machine.init(&.{});
    m.vu.regs[1] = .{ 0x0180, 0x0280, 0x0300, 0x0400, 0x0500, 0x0600, 0x0700, 0x7f80 };
    m.gpr[2] = 0x600;
    try exec(&m, encode.vectorStore(.spv, 1, 2, 0, 0));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 0x7f }, m.dmem[0x600..0x608]);
    try exec(&m, encode.vectorStore(.suv, 1, 2, 0, 1));
    try testing.expectEqualSlices(u8, &.{ 3, 5, 6, 8, 10, 12, 14, 0xff }, m.dmem[0x608..0x610]);
    try exec(&m, encode.vectorStore(.spv, 1, 2, 8, 2));
    try testing.expectEqual(@as(u8, 3), m.dmem[0x610]);
    try exec(&m, encode.vectorStore(.suv, 1, 2, 8, 3));
    try testing.expectEqual(@as(u8, 1), m.dmem[0x618]);
}

test "half, fourth, and wrapped stores" {
    var m = Machine.init(&.{});
    m.vu.regs[1] = .{ 0x0100, 0x0200, 0x0300, 0x0400, 0x0500, 0x0600, 0x0700, 0x0800 };
    m.gpr[2] = 0x700;
    try exec(&m, encode.vectorStore(.shv, 1, 2, 0, 0));
    try testing.expectEqual(@as(u8, 0x02), m.dmem[0x700]);
    try testing.expectEqual(@as(u8, 0x04), m.dmem[0x702]);
    try exec(&m, encode.vectorStore(.sfv, 1, 2, 0, 1));
    try testing.expectEqual(@as(u8, 0x02), m.dmem[0x710]);
    try testing.expectEqual(@as(u8, 0x04), m.dmem[0x714]);
    try exec(&m, encode.vectorStore(.sfv, 1, 2, 8, 2));
    try testing.expectEqual(@as(u8, 0x0a), m.dmem[0x720]);
    try exec(&m, encode.vectorStore(.sfv, 1, 2, 2, 3));
    try testing.expectEqual(@as(u8, 0), m.dmem[0x730]);
    m.gpr[2] = 0x804;
    try exec(&m, encode.vectorStore(.swv, 1, 2, 0, 0));
    try testing.expectEqual(@as(u8, 0x01), m.dmem[0x804]);
    try testing.expectEqual(@as(u8, 0x07), m.dmem[0x800]);
}
