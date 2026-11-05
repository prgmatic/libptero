//! COP0: SP DMA/status registers (0-7) and RDP command registers (8-15).
//!
//! DMA completes synchronously when its length register is written, so busy
//! and full always read as zero. RDP commands are consumed immediately when
//! DP_END is written and are forwarded to `Machine.rdp_output`.
const std = @import("std");
const Machine = @import("Machine.zig");
const fields = @import("fields.zig");

const Error = Machine.Error;

pub const Dma = struct {
    /// DMEM/IMEM byte address; bit 12 selects IMEM.
    mem_address: u13 = 0,
    dram_address: u24 = 0,
    length: u12 = 0,
    count: u8 = 0,
    skip: u12 = 0,
};

pub const Sp = struct {
    pending: Dma = .{},
    current: Dma = .{},
    halted: bool = true,
    broken: bool = false,
    single_step: bool = false,
    interrupt_on_break: bool = false,
    signals: u8 = 0,
    semaphore: bool = false,
    /// Number of SP interrupts raised by BREAK or SP_STATUS writes.
    interrupts: u32 = 0,
};

pub const Dp = struct {
    start: u24 = 0,
    end: u24 = 0,
    current: u24 = 0,
    xbus: bool = false,
    freeze: bool = false,
    flush: bool = false,
    start_pending: bool = false,
};

const sp_status_bits = struct {
    const halt = 1 << 0;
    const broke = 1 << 1;
    const dma_busy = 1 << 2;
    const dma_full = 1 << 3;
};
const dp_status_cbuf_ready = 1 << 7;
const dp_status_start_pending = 1 << 10;

pub fn execute(m: *Machine, op: u32) Error!void {
    return switch (fields.rs(op)) {
        0 => m.setReg(fields.rt(op), read(m, fields.rd(op))),
        4 => write(m, fields.rd(op), m.gpr[fields.rt(op)]),
        else => error.InvalidInstruction,
    };
}

pub fn read(m: *Machine, index: u5) u32 {
    return readers[index & 15](m);
}

pub fn write(m: *Machine, index: u5, value: u32) Error!void {
    return writers[index & 15](m, value);
}

const Reader = *const fn (*Machine) u32;
const Writer = *const fn (*Machine, u32) Error!void;

const readers = [16]Reader{
    readMemAddress, readDramAddress, readLength,      readLength,
    readSpStatus,   readZero,        readZero,        readSemaphore,
    readDpStart,    readDpEnd,       readDpCurrent,   readDpStatus,
    readDpClock,    readZero,        readZero,        readZero,
};

const writers = [16]Writer{
    writeMemAddress, writeDramAddress, writeReadLength, writeWriteLength,
    writeSpStatus,   ignore,           ignore,          writeSemaphore,
    writeDpStart,    writeDpEnd,       ignore,          writeDpStatus,
    ignore,          ignore,           ignore,          ignore,
};

fn readZero(_: *Machine) u32 {
    return 0;
}

fn ignore(_: *Machine, _: u32) Error!void {}

fn readMemAddress(m: *Machine) u32 {
    return m.sp.current.mem_address;
}

fn readDramAddress(m: *Machine) u32 {
    return m.sp.current.dram_address;
}

fn readLength(m: *Machine) u32 {
    const dma = m.sp.current;
    return @as(u32, dma.skip) << 20 | @as(u32, dma.count) << 12 | dma.length;
}

fn readSpStatus(m: *Machine) u32 {
    var value: u32 = @as(u32, m.sp.signals) << 7;
    value |= @intFromBool(m.sp.halted);
    value |= @as(u32, @intFromBool(m.sp.broken)) << 1;
    value |= @as(u32, @intFromBool(m.sp.single_step)) << 5;
    return value | @as(u32, @intFromBool(m.sp.interrupt_on_break)) << 6;
}

fn readSemaphore(m: *Machine) u32 {
    const value = m.sp.semaphore;
    m.sp.semaphore = true;
    return @intFromBool(value);
}

fn writeSemaphore(m: *Machine, _: u32) Error!void {
    m.sp.semaphore = false;
}

fn writeMemAddress(m: *Machine, value: u32) Error!void {
    m.sp.pending.mem_address = @truncate(value & 0x1ff8);
}

fn writeDramAddress(m: *Machine, value: u32) Error!void {
    m.sp.pending.dram_address = @truncate(value & 0xff_fff8);
}

fn latchLength(m: *Machine, value: u32) void {
    m.sp.pending.length = @truncate(value & 0xff8);
    m.sp.pending.count = @truncate(value >> 12);
    m.sp.pending.skip = @truncate((value >> 20) & 0xff8);
}

fn writeReadLength(m: *Machine, value: u32) Error!void {
    latchLength(m, value);
    return transfer(m, .to_rsp);
}

fn writeWriteLength(m: *Machine, value: u32) Error!void {
    latchLength(m, value);
    return transfer(m, .to_rdram);
}

const Direction = enum { to_rsp, to_rdram };

fn transfer(m: *Machine, direction: Direction) Error!void {
    var dma = m.sp.pending;
    const row_len = @as(usize, dma.length) + 8;
    for (0..@as(usize, dma.count) + 1) |_| {
        try copyRow(m, &dma, row_len, direction);
        dma.dram_address +%= dma.skip;
    }
    dma.length = 0xff8;
    dma.count = 0;
    m.sp.current = dma;
}

fn copyRow(m: *Machine, dma: *Dma, row_len: usize, direction: Direction) Error!void {
    const rdram = try m.rdramSlice(dma.dram_address, row_len);
    for (rdram) |*byte| {
        const local = rspMemory(m, dma.mem_address);
        if (direction == .to_rsp) local.* = byte.* else byte.* = local.*;
        dma.mem_address = (dma.mem_address & 0x1000) | ((dma.mem_address +% 1) & 0xfff);
    }
    dma.dram_address +%= @intCast(row_len);
}

fn rspMemory(m: *Machine, address: u13) *u8 {
    const offset = address & 0xfff;
    return if (address & 0x1000 != 0) &m.imem[offset] else &m.dmem[offset];
}

/// Applies an SP_STATUS clear/set bit pair; writing both or neither keeps the value.
fn statusPair(value: u32, clear_bit: u5, current: bool) bool {
    const clear = value >> clear_bit & 1 != 0;
    const set = value >> (clear_bit + 1) & 1 != 0;
    if (clear == set) return current;
    return set;
}

fn writeSpStatus(m: *Machine, value: u32) Error!void {
    m.sp.halted = statusPair(value, 0, m.sp.halted);
    if (value & sp_status_bits.dma_busy != 0) m.sp.broken = false;
    m.sp.interrupts += @intFromBool(statusPair(value, 3, false));
    m.sp.single_step = statusPair(value, 5, m.sp.single_step);
    m.sp.interrupt_on_break = statusPair(value, 7, m.sp.interrupt_on_break);
    for (0..8) |signal| {
        const bit: u3 = @intCast(signal);
        const current = m.sp.signals >> bit & 1 != 0;
        const next = statusPair(value, @intCast(9 + signal * 2), current);
        m.sp.signals = (m.sp.signals & ~(@as(u8, 1) << bit)) | (@as(u8, @intFromBool(next)) << bit);
    }
}

/// DPC_CLOCK counts RCP cycles; the interpreter reports its estimate.
fn readDpClock(m: *Machine) u32 {
    return @as(u32, @truncate(m.pipeline.cycles)) & 0xff_ffff;
}

fn readDpStart(m: *Machine) u32 {
    return m.dp.start;
}

fn readDpEnd(m: *Machine) u32 {
    return m.dp.end;
}

fn readDpCurrent(m: *Machine) u32 {
    return m.dp.current;
}

fn readDpStatus(m: *Machine) u32 {
    var value: u32 = dp_status_cbuf_ready;
    value |= @intFromBool(m.dp.xbus);
    value |= @as(u32, @intFromBool(m.dp.freeze)) << 1;
    value |= @as(u32, @intFromBool(m.dp.flush)) << 2;
    if (m.dp.start_pending) value |= dp_status_start_pending;
    return value;
}

fn writeDpStart(m: *Machine, value: u32) Error!void {
    if (m.dp.start_pending) return;
    m.dp.start = @truncate(value & 0xff_fff8);
    m.dp.start_pending = true;
}

fn writeDpEnd(m: *Machine, value: u32) Error!void {
    m.dp.end = @truncate(value & 0xff_fff8);
    if (m.dp.start_pending) m.dp.current = m.dp.start;
    m.dp.start_pending = false;
    try submitRdpCommands(m);
    m.dp.current = m.dp.end;
}

fn submitRdpCommands(m: *Machine) Error!void {
    if (m.dp.end <= m.dp.current) return;
    const len: usize = m.dp.end - m.dp.current;
    var dmem_window: [Machine.memory_size]u8 = undefined;
    const bytes = if (m.dp.xbus) dmemWindow(m, &dmem_window, len) else try m.rdramSlice(m.dp.current, len);
    const output = m.rdp_output orelse return;
    output.writeAll(bytes) catch return error.RdpOutputFailed;
}

fn dmemWindow(m: *Machine, buffer: *[Machine.memory_size]u8, len: usize) []const u8 {
    const count = @min(len, buffer.len);
    for (buffer[0..count], 0..) |*byte, index| byte.* = m.dmemByte(@as(u32, m.dp.current) + @as(u32, @intCast(index)));
    return buffer[0..count];
}

fn writeDpStatus(m: *Machine, value: u32) Error!void {
    m.dp.xbus = statusPair(value, 0, m.dp.xbus);
    m.dp.freeze = statusPair(value, 2, m.dp.freeze);
    m.dp.flush = statusPair(value, 4, m.dp.flush);
}

const testing = std.testing;

test "SP DMA copies rows with count and skip in both directions" {
    var rdram: [64]u8 = undefined;
    for (&rdram, 0..) |*byte, index| byte.* = @intCast(index);
    var m = Machine.init(&rdram);
    try write(&m, 0, 0x100);
    try write(&m, 1, 0x8);
    // Two rows of eight bytes, skipping eight bytes between rows.
    try write(&m, 2, (8 << 20) | (1 << 12) | 7);
    try testing.expectEqualSlices(u8, rdram[8..16], m.dmem[0x100..0x108]);
    try testing.expectEqualSlices(u8, rdram[24..32], m.dmem[0x108..0x110]);
    try testing.expectEqual(@as(u32, 0x110), read(&m, 0));
    try testing.expectEqual(@as(u32, 40), read(&m, 1));
    try testing.expectEqual(@as(u32, (8 << 20) | 0xff8), read(&m, 2));
    try testing.expectEqual(@as(u32, 0), read(&m, 5) | read(&m, 6));

    @memset(m.imem[0..8], 0xaa);
    try write(&m, 0, 0x1000);
    try write(&m, 1, 0x30);
    try write(&m, 3, 7);
    try testing.expectEqualSlices(u8, &(@as([8]u8, @splat(0xaa))), rdram[0x30..0x38]);
    try write(&m, 1, 0x40);
    try testing.expectError(error.RdramOutOfBounds, write(&m, 2, 7));
}

test "SP status pairs, interrupts, signals, and semaphore" {
    var m = Machine.init(&.{});
    try write(&m, 4, 1 << 0);
    try testing.expect(!m.sp.halted);
    try write(&m, 4, 0b11);
    try testing.expect(!m.sp.halted);
    m.sp.broken = true;
    try write(&m, 4, (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 24));
    try testing.expect(!m.sp.broken);
    try testing.expectEqual(@as(u32, 1), m.sp.interrupts);
    try testing.expect(m.sp.single_step and m.sp.interrupt_on_break);
    try testing.expectEqual(@as(u8, 0b1000_0001), m.sp.signals);
    try testing.expectEqual(@as(u32, (0b1000_0001 << 7) | (1 << 5) | (1 << 6)), read(&m, 4));
    try write(&m, 4, (1 << 9) | 2);
    try testing.expectEqual(@as(u8, 0b1000_0000), m.sp.signals);
    try testing.expectEqual(@as(u32, 1), read(&m, 4) & 1);
    try testing.expectEqual(@as(u32, 0), read(&m, 7));
    try testing.expectEqual(@as(u32, 1), read(&m, 7));
    try write(&m, 7, 0);
    try testing.expectEqual(@as(u32, 0), read(&m, 7));
    try write(&m, 5, 0);
}

test "RDP command registers forward DMEM and RDRAM ranges" {
    var rdram: [32]u8 = @splat(0x55);
    var m = Machine.init(&rdram);
    var captured: [64]u8 = undefined;
    var sink = std.Io.Writer.fixed(&captured);
    m.rdp_output = &sink;
    m.writeDmem(u64, 0x40, 0xe900_0000_0000_0000);
    try write(&m, 11, 2);
    try testing.expectEqual(@as(u32, dp_status_cbuf_ready | 1), read(&m, 11));
    try write(&m, 8, 0x40);
    try write(&m, 8, 0x80);
    try testing.expectEqual(@as(u32, dp_status_start_pending), read(&m, 11) & dp_status_start_pending);
    try write(&m, 9, 0x48);
    try testing.expectEqual(@as(u32, 0x40), read(&m, 8));
    try testing.expectEqual(@as(u32, 0x48), read(&m, 9));
    try testing.expectEqual(@as(u32, 0x48), read(&m, 10));
    try testing.expectEqualSlices(u8, &.{ 0xe9, 0, 0, 0, 0, 0, 0, 0 }, sink.buffered());
    try write(&m, 9, 0x48);
    try write(&m, 11, 1 | (1 << 3) | (1 << 5));
    try testing.expectEqual(@as(u32, 0b110), read(&m, 11) & 0b111);
    try write(&m, 8, 0x10);
    try write(&m, 9, 0x18);
    try testing.expectEqual(@as(usize, 16), sink.buffered().len);
    m.pipeline.cycles = 0x1_2345_6789;
    try testing.expectEqual(@as(u32, 0x45_6789), read(&m, 12));
    try write(&m, 10, 0);
    m.rdp_output = null;
    try write(&m, 9, 0x20);
}

test "COP0 moves and invalid subops" {
    var m = Machine.init(&.{});
    m.gpr[8] = 1 << 1;
    try execute(&m, (0x10 << 26) | (4 << 21) | (8 << 16) | (4 << 11));
    try testing.expect(m.sp.halted);
    try execute(&m, (0x10 << 26) | (0 << 21) | (9 << 16) | (4 << 11));
    try testing.expectEqual(@as(u32, 1), m.gpr[9]);
    try testing.expectError(error.InvalidInstruction, execute(&m, (0x10 << 26) | (2 << 21)));
}
