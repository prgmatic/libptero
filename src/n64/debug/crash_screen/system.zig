const std = @import("std");
const model = @import("model.zig");
const style = @import("style.zig");
const text = @import("font.zig");
const codes = @import("../exception_codes.zig");

pub fn draw(img: style.Image, report: *const model.Report) void {
    style.pane(img);
    img.fillRegion(style.rule, 314, 61, 1, 111);
    if (report.registers) |*regs| {
        text.draw(img, style.fg, style.fonts.brand, "CPU EXCEPTION", 26, 74);
        text.draw(img, style.fg, style.fonts.brand, "FLOATING POINT", 334, 74);
        var buffer: [64]u8 = undefined;
        const code = codes.ExceptionCode.fromCauseReg(regs.cause);
        const description = std.fmt.bufPrint(&buffer, "{d} / {s}", .{ @intFromEnum(code), if (code == .FloatingPoint) "Floating point" else codes.name(code) }) catch "";
        style.label(img, "Code", 26, 92);
        text.drawClipped(img, style.cyan, style.fonts.data, description, 102, 92, .{ .left = 102, .top = model.viewport_top, .right = 302, .bottom = model.viewport_bottom });
        const names = [_][]const u8{ "EPC", "Cause", "Status", "BadVAddr" };
        const values = [_]u32{ regs.epc, regs.cause, regs.status, report.badvaddr };
        for (names, values, 0..) |name, value, i| {
            const y: i32 = @intCast(109 + i * 17);
            style.label(img, name, 26, y);
            style.value(img, std.fmt.bufPrint(&buffer, "0x{x:0>8}", .{value}) catch "", 102, y);
        }
        drawFpu(img, code, regs.fcsr, regs.hi, regs.lo);
        style.label(img, "Snapshot captured at exception entry", 26, 181);
    } else drawPanic(img, report);
}

fn drawFpu(img: style.Image, code: codes.ExceptionCode, fcsr: u32, hi: u64, lo: u64) void {
    var buffer: [32]u8 = undefined;
    style.label(img, "FCSR", 334, 92);
    style.value(img, std.fmt.bufPrint(&buffer, "0x{x:0>8}", .{fcsr}) catch "", 378, 92);
    const color = if (code == .FloatingPoint) style.amber else style.muted;
    img.fillRegion(color, 489, 81, 119, 17);
    img.fillRegion(style.panel, 490, 82, 117, 15);
    const badge = if (code == .FloatingPoint) fpuBadge(fcsr) else "NO FPU EXCEPTION";
    text.draw(img, color, style.fonts.small, badge, 548 - @divFloor(text.measure(style.fonts.small, badge), 2), 93);
    style.label(img, "Cause flags", 334, 111);
    const labels = [_][]const u8{ "DIV0", "INVALID", "OVERFLOW", "UNDERFLOW", "INEXACT", "UNIMPL" };
    const bits = [_]u5{ 15, 16, 14, 13, 12, 17 };
    const positions = [_]i32{ 334, 384, 447, 334, 411, 484 };
    for (labels, bits, positions, 0..) |label, bit, x, i| {
        text.drawClipped(img, if (fcsr & (@as(u32, 1) << bit) != 0) style.amber else style.muted, style.fonts.small, label, x, if (i < 3) 124 else 136, style.body_clip);
    }
    style.label(img, "HI", 334, 152);
    style.value(img, std.fmt.bufPrint(&buffer, "{x:0>16}", .{hi}) catch "", 378, 152);
    style.label(img, "LO", 334, 169);
    style.value(img, std.fmt.bufPrint(&buffer, "{x:0>16}", .{lo}) catch "", 378, 169);
}

fn fpuBadge(fcsr: u32) []const u8 {
    const flags = [_]struct { bit: u5, label: []const u8 }{
        .{ .bit = 15, .label = "DIVIDE BY ZERO" },
        .{ .bit = 16, .label = "INVALID OPERATION" },
        .{ .bit = 14, .label = "OVERFLOW" },
        .{ .bit = 13, .label = "UNDERFLOW" },
        .{ .bit = 12, .label = "INEXACT" },
        .{ .bit = 17, .label = "UNIMPLEMENTED" },
    };
    for (flags) |flag| if (fcsr & (@as(u32, 1) << flag.bit) != 0) return flag.label;
    return "FLOATING POINT";
}

fn drawPanic(img: style.Image, report: *const model.Report) void {
    text.draw(img, style.fg, style.fonts.brand, "PANIC STATE", 26, 74);
    text.draw(img, style.fg, style.fonts.brand, "MEMORY BANKS", 334, 74);
    style.label(img, "No CPU exception snapshot", 26, 92);
    var buffer: [48]u8 = undefined;
    style.label(img, "Frames", 26, 121);
    style.value(img, std.fmt.bufPrint(&buffer, "{d} captured", .{report.frame_count}) catch "", 102, 121);
    if (report.programCounter()) |pc| {
        style.label(img, "Origin", 26, 138);
        style.value(img, std.fmt.bufPrint(&buffer, "0x{x:0>8}", .{pc}) catch "", 102, 138);
    }
    style.label(img, "RDRAM", 334, 92);
    style.value(img, std.fmt.bufPrint(&buffer, "{d} MiB", .{report.memory_bounds.rdram_size / (1024 * 1024)}) catch "", 411, 92);
    style.label(img, "Cart", 334, 109);
    style.value(img, "64 MiB ROM window", 411, 109);
    style.label(img, "DMEM", 334, 126);
    style.value(img, "4 KiB", 411, 126);
    style.label(img, "IMEM", 334, 143);
    style.value(img, "4 KiB", 411, 143);
    style.label(img, "Execution halted / CPU-rendered report", 26, 181);
}
