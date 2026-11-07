//! SP DMA transfers run in order: a read queued behind a write to the same
//! RDRAM bytes sees the written data, however soon it is issued. Microcode
//! (and the interpreter's DMA model) rely on this to skip waiting for writes.
const n64 = @import("n64");
const runner = @import("runner.zig");
const encode = @import("rsp_calibration").encode;

const rsp = n64.rsp;
const sp = n64.hw.sp;

pub const tests = [_]runner.Test{
    .{ .name = "RSP DMA: read after write ordering", .run = measure },
};

const t0 = 8;
const t1 = 9;
const t2 = 10;
const x_reg = 11;
const y_reg = 12;

const source = 0x000;
const result = 0x100;
const other = 0x300;
const address_slot = 0x200;
const length = 63;

fn dmaStart(comptime mem: u16, comptime dram_reg: u5, comptime write: bool) [4]u32 {
    return .{
        encode.ori(t0, 0, mem),
        encode.cop0Move(true, t0, 0),
        encode.cop0Move(true, dram_reg, 1),
        encode.cop0Move(true, t1, if (write) 3 else 2),
    };
}

const wait_busy = [_]u32{ encode.cop0Move(false, t2, 6), encode.bne(t2, 0, -2), encode.nop };

fn nops(comptime count: usize) [count]u32 {
    return @splat(encode.nop);
}

const prologue = [_]u32{
    encode.lw(x_reg, 0, address_slot),
    encode.lw(y_reg, 0, address_slot + 4),
    encode.ori(t1, 0, length),
};

fn program(comptime body: []const u32) []align(8) const u32 {
    const words = prologue ++ body ++ wait_busy ++ [_]u32{encode.brk};
    const padded = if (words.len % 2 == 0) words else words ++ [_]u32{encode.nop};
    const final: [padded.len]u32 align(8) = padded[0..padded.len].*;
    return &final;
}

const Variant = struct { name: []const u8, text: []align(8) const u32 };

const variants = [_]Variant{
    .{ .name = "back_to_back", .text = program(&(dmaStart(source, x_reg, true) ++ dmaStart(result, x_reg, false))) },
    .{ .name = "wait_then_read", .text = program(&(dmaStart(source, x_reg, true) ++ wait_busy ++ dmaStart(result, x_reg, false))) },
    .{ .name = "other_read_between", .text = program(&(dmaStart(source, x_reg, true) ++ dmaStart(other, y_reg, false) ++ wait_busy ++ dmaStart(result, x_reg, false))) },
    .{ .name = "gap_256", .text = program(&(dmaStart(source, x_reg, true) ++ wait_busy ++ nops(256) ++ dmaStart(result, x_reg, false))) },
};

var target: [64]u8 align(16) = undefined;
var unrelated: [64]u8 align(16) = undefined;

fn measure() !void {
    for (variants) |variant| {
        for (0..16) |trial| {
            if (try runVariant(variant, @intCast(trial))) {
                n64.debug.print(" {s} read stale data", .{variant.name});
                return error.StaleDmaRead;
            }
        }
    }
}

fn runVariant(variant: Variant, trial: u8) !bool {
    const uncached: *volatile [64]u8 = @ptrFromInt(n64.cpu.kseg1_addr | n64.cpu.physicalAddress(@intFromPtr(&target)));
    for (uncached) |*byte| byte.* = 0xbb;
    for (0..16) |word| {
        sp.readDmem(u32, source + word * 4).* = 0x0101_0101 * @as(u32, @intCast(word + 1)) +% trial;
        sp.readDmem(u32, result + word * 4).* = 0;
    }
    sp.readDmem(u32, address_slot).* = n64.cpu.physicalAddress(@intFromPtr(&target));
    sp.readDmem(u32, address_slot + 4).* = n64.cpu.physicalAddress(@intFromPtr(&unrelated));
    rsp.runProgram(.{ .text = @ptrCast(variant.text) });
    var remaining: u32 = 1_000_000;
    while (!rsp.isBroke()) : (remaining -= 1) {
        if (remaining == 0) return error.RspTimeout;
    }
    var stale = false;
    for (0..16) |word| {
        if (sp.readDmem(u32, result + word * 4).* != sp.readDmem(u32, source + word * 4).*) stale = true;
    }
    return stale;
}
