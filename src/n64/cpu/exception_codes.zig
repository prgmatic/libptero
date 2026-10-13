//! Pure R4300 exception decoding. Reference: libdragon src/exception.c.
//! No instruction dereferences or CP0 access; callers supply safe snapshots.
const std = @import("std");

pub const ExceptionCode = enum(u5) {
    Interrupt = 0,
    TlbModification = 1,
    TlbLoad = 2,
    TlbStore = 3,
    AddrLoad = 4,
    AddrStore = 5,
    BusInst = 6,
    BusData = 7,
    SysCall = 8,
    Breakpoint = 9,
    ReservedInstruction = 10,
    CoProcessorUnusable = 11,
    ArithmaticOverflow = 12,
    Trap = 13,
    FloatingPoint = 15,
    Watch = 23,
    Emux = 24,
    _,

    // Preserve the earlier spelling and cache-code constant for source consumers.
    pub const ArithmeticOverflow = ExceptionCode.ArithmaticOverflow;
    pub const Cache: ExceptionCode = @enumFromInt(30);
    pub fn fromCauseReg(cause: u32) ExceptionCode {
        return @enumFromInt(@as(u5, @truncate(cause >> 2)));
    }
};

pub const Context = struct {
    cause: u32,
    epc: u32 = 0,
    badvaddr: u32 = 0,
    fcsr: u32 = 0,
    instruction: ?u32 = null,
    fpr: ?*const [32]u64 = null,
    cache_error: u32 = 0,
};

pub fn faultPc(cause: u32, epc: u32) u32 {
    return epc +% (if (cause & (1 << 31) != 0) @as(u32, 4) else 0);
}

pub fn name(code: ExceptionCode) []const u8 {
    return switch (code) {
        .Interrupt => "Interrupt",
        .TlbModification => "TLB modification",
        .TlbLoad => "TLB miss (load/instruction fetch)",
        .TlbStore => "TLB miss (store)",
        .AddrLoad => "Address error (load/instruction fetch)",
        .AddrStore => "Address error (store)",
        .BusInst => "Bus error (instruction fetch)",
        .BusData => "Bus error (load/store)",
        .SysCall => "Unhandled syscall",
        .Breakpoint => "Breakpoint",
        .ReservedInstruction => "Reserved instruction",
        .CoProcessorUnusable => "Coprocessor unusable",
        .ArithmaticOverflow => "Arithmetic overflow",
        .Trap => "Trap",
        .FloatingPoint => "Floating-point exception",
        .Watch => "Watchpoint exception",
        .Emux => "Emulator exception",
        else => "Reserved exception code",
    };
}

pub fn describe(context: Context) []const u8 {
    const code = ExceptionCode.fromCauseReg(context.cause);
    const pc = faultPc(context.cause, context.epc);
    return switch (code) {
        .TlbModification => "Write to read-only memory",
        .TlbLoad => if (pc == context.badvaddr) "Invalid program counter address" else if (context.badvaddr < 128) "NULL pointer dereference (read)" else "Read from invalid memory address",
        .TlbStore => if (context.badvaddr < 128) "NULL pointer dereference (write)" else "Write to invalid memory address",
        .AddrLoad => if (pc == context.badvaddr) "Misaligned program counter address" else "Misaligned read from memory",
        .AddrStore => "Misaligned write to memory",
        .CoProcessorUnusable => switch ((context.cause >> 28) & 3) {
            0 => "Coprocessor 0 unusable",
            1 => "Coprocessor 1 (FPU) unusable",
            2 => "Coprocessor 2 unusable",
            3 => "Coprocessor 3 unusable",
            else => unreachable,
        },
        .FloatingPoint => floatingPoint(context),
        .Trap => if (context.instruction) |op| if ((op >> 6) & 0x3ff == 7) "Integer divide by zero" else name(code) else name(code),
        .Breakpoint => if (context.instruction) |op| if ((op >> 6) & 0xfffff == 7) "Integer divide by zero" else name(code) else name(code),
        .Emux => switch (context.cache_error & 0xff) {
            0 => "Cached access to non-RDRAM area",
            1 => "64-bit read from non-RDRAM area",
            2 => "Access to unmapped RCP area",
            else => "Unknown emulator exception",
        },
        else => name(code),
    };
}

fn floatingPoint(context: Context) []const u8 {
    if (context.instruction) |op| {
        if (op >> 26 == 0x11) {
            if (operandProblem(context, op)) |problem| return problem;
            const function = op & 0x3f;
            if ((function == 0x0d or function == 0x09) and context.fcsr & (1 << 17) != 0)
                return "Floating-point integer cast overflow";
        }
    }
    const flags = [_]struct { bit: u5, message: []const u8 }{
        .{ .bit = 15, .message = "Floating-point divide by zero" },
        .{ .bit = 16, .message = "Floating-point invalid operation" },
        .{ .bit = 14, .message = "Floating-point overflow" },
        .{ .bit = 13, .message = "Floating-point underflow" },
        .{ .bit = 12, .message = "Floating-point inexact operation" },
        .{ .bit = 17, .message = "Unimplemented floating-point operation" },
    };
    for (flags) |flag| if (context.fcsr & (@as(u32, 1) << flag.bit) != 0) return flag.message;
    return "Floating-point exception";
}

fn operandProblem(context: Context, op: u32) ?[]const u8 {
    const regs = context.fpr orelse return null;
    const format = (op >> 21) & 31;
    if (format != 16 and format != 17) return null;
    const fs = regs[(op >> 11) & 31];
    const ft = regs[(op >> 16) & 31];
    const function = op & 0x3f;
    // Unary instructions do not consume ft; stale contents must not diagnose them.
    if (denormal(fs, format) or ((function <= 3 or function >= 0x30) and denormal(ft, format)))
        return "Invalid floating-point value (denormal)";
    const sign: u64 = if (format == 16) 0x80000000 else 0x8000000000000000;
    const value = if (format == 16) fs & 0xffffffff else fs;
    if (function == 4 and value & sign != 0 and value & ~sign != 0)
        return "Floating-point negative square root";
    return null;
}

fn denormal(value: u64, format: u32) bool {
    const exponent: u64 = if (format == 16) 0x7f800000 else 0x7ff0000000000000;
    const fraction: u64 = if (format == 16) 0x007fffff else 0x000fffffffffffff;
    return value & exponent == 0 and value & fraction != 0;
}

test "all 32 cause codes decode safely, including reserved and missing codes" {
    for (0..32) |i| {
        const cause: u32 = @as(u32, @intCast(i)) << 2;
        const code = ExceptionCode.fromCauseReg(cause | 0xf000ff03);
        try std.testing.expectEqual(i, @as(usize, @intFromEnum(code)));
        try std.testing.expect(name(code).len > 0);
        try std.testing.expect(describe(.{ .cause = cause }).len > 0);
    }
    try std.testing.expectEqualStrings("Reserved instruction", name(.ReservedInstruction));
    try std.testing.expectEqualStrings("Reserved exception code", name(@enumFromInt(31)));
}

test "address faults use delay-slot PC and the full null-member boundary" {
    try std.testing.expectEqual(@as(u32, 0), faultPc(1 << 31, 0xfffffffc));
    try std.testing.expectEqualStrings("Invalid program counter address", describe(.{ .cause = (2 << 2) | (1 << 31), .epc = 0x80000000, .badvaddr = 0x80000004 }));
    try std.testing.expectEqualStrings("NULL pointer dereference (read)", describe(.{ .cause = 2 << 2, .epc = 0x80000000, .badvaddr = 127 }));
    try std.testing.expectEqualStrings("Read from invalid memory address", describe(.{ .cause = 2 << 2, .epc = 0x80000000, .badvaddr = 128 }));
    try std.testing.expectEqualStrings("Misaligned write to memory", describe(.{ .cause = 5 << 2 }));
    try std.testing.expectEqualStrings("Coprocessor 1 (FPU) unusable", describe(.{ .cause = (11 << 2) | (1 << 28) }));
    try std.testing.expectEqualStrings("Integer divide by zero", describe(.{ .cause = 13 << 2, .instruction = (7 << 6) | 0x34 }));
}

test "FPU causes and unary operands do not inspect unused registers" {
    var regs = [_]u64{0} ** 32;
    regs[1] = 0xbf800000;
    regs[2] = 1;
    var context: Context = .{ .cause = 15 << 2, .fpr = &regs, .instruction = (0x11 << 26) | (16 << 21) | (2 << 16) | (1 << 11) | 4 };
    try std.testing.expectEqualStrings("Floating-point negative square root", describe(context));
    regs[1] = 0x80000000; // sqrt(-0) is valid, and ft is not an operand.
    try std.testing.expectEqualStrings("Floating-point exception", describe(context));
    context.instruction = null;
    const bits = [_]u5{ 15, 16, 14, 13, 12, 17 };
    const messages = [_][]const u8{ "Floating-point divide by zero", "Floating-point invalid operation", "Floating-point overflow", "Floating-point underflow", "Floating-point inexact operation", "Unimplemented floating-point operation" };
    for (bits, messages) |bit, message| {
        context.fcsr = @as(u32, 1) << bit;
        try std.testing.expectEqualStrings(message, describe(context));
    }
}
