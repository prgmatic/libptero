//! Allocation-free emergency crash UI. Never submits or waits for RSP/RDP work.
const std = @import("std");
const vi = @import("../hw/vi.zig");
const cache = @import("../cpu/cache.zig");
const cp0 = @import("../cpu/cp0.zig");
const backtrace = @import("backtrace.zig");
const srcmap = @import("source_map.zig");
const TrapFrame = @import("../cpu/trap_frame.zig").TrapFrame;
const controls = @import("crash_screen/input.zig");
pub const model = @import("crash_screen/model.zig");
pub const font = @import("crash_screen/font.zig");
pub const ui = @import("crash_screen/ui.zig");
pub const memory = @import("crash_screen/memory.zig");
pub const CrashType = model.Kind;
pub const Report = model.Report;
pub const State = model.State;

// Linker-owned BSS avoids overwriting application data at a guessed RDRAM address.
var framebuffer: [ui.width * ui.height]ui.Pixel align(64) = undefined;
var report: Report = .{};
var state: State = .{};

/// Paint and present a panic report. Interrupts remain disabled; the runtime
/// then calls waitForInput to keep this emergency framebuffer interactive.
pub fn show(kind: CrashType, message: []const u8, trace: ?backtrace.Trace) void {
    prepare(kind, message, trace);
    present();
}

pub fn showException(message: []const u8, trace: ?backtrace.Trace, frame: *const TrapFrame, badvaddr: u32) void {
    prepare(.exception, message, trace);
    report.registers = frame.*;
    report.badvaddr = badvaddr;
    var buffer: [128]u8 = undefined;
    const pc = frame.epc +% (if (frame.cause & (1 << 31) != 0) @as(u32, 4) else 0);
    state.memory = .init(report.memory_bounds, pc);
    const detail = std.fmt.bufPrint(&buffer, "PC 0x{x:0>8}  BadVAddr 0x{x:0>8}  Cause 0x{x:0>8}", .{ pc, badvaddr, frame.cause }) catch "";
    report.detail.set(detail);
    present();
}

fn prepare(kind: CrashType, message: []const u8, trace_opt: ?backtrace.Trace) void {
    cp0.regWrite(.Status, cp0.regRead(.Status) & ~@as(u32, 1));
    report = .{ .kind = kind, .memory_bounds = memory.bounds() };
    state = .{};
    report.message.set(message);
    if (std.mem.indexOfScalar(u8, message, '\n')) |newline| report.detail.set(message[newline + 1 ..]);
    if (trace_opt) |trace| collectTrace(trace);
    state.memory = .init(report.memory_bounds, if (report.frame_count != 0) report.frames[0].address else 0x80000000);
    if (report.detail.len == 0) {
        var buffer: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&buffer, "Execution halted / {d} captured stack frames", .{report.frame_count}) catch "";
        report.detail.set(detail);
    }
    vi.init(.{ .resolution = .@"640x240p", .color_depth = .Rgba5551 });
}

fn collectTrace(initial: backtrace.Trace) void {
    var trace = initial;
    while (trace.next()) |entry| {
        if (report.frame_count == report.frames.len) break;
        const frame = &report.frames[report.frame_count];
        report.frame_count += 1;
        frame.address = entry.addr;
        var filename: [192]u8 = undefined;
        if (srcmap.getLineInfo(entry.addr, .{
            .func_name = &frame.function.bytes,
            .file_name = &filename,
            .line_text = &frame.source.bytes,
        })) |info| {
            if (info.function_name) |name| frame.function.len = @intCast(name.len);
            if (info.line_text) |line| frame.source.len = @intCast(line.len);
            frame.line = info.line;
            frame.column = info.column;
            const location = std.fmt.bufPrint(&frame.location.bytes, "{s}:{d}:{d}", .{ info.file_name orelse "<source>", info.line, info.column }) catch "<source location too long>";
            frame.location.set(location);
        } else {
            frame.function.set("<unknown function>");
            frame.location.set("Source location unavailable");
        }
    }
}

fn present() void {
    if (state.tab == .memory and !state.memory.editing)
        report.memory_view = memory.capture(report.memory_bounds, state.memory, 100_000);
    const img: ui.Image = .{ .width = ui.width, .height = ui.height, .texel_data = &framebuffer };
    ui.render(img, &report, state);
    cache.writebackData(img.texel_data);
    vi.setFrameBuffer(@intFromPtr(img.texel_data.ptr));
}

/// SI waits are bounded. A disconnected controller or stalled transfer leaves
/// the crash display intact. Neither interrupts nor graphics hardware is needed.
pub fn waitForInput() noreturn {
    // Tell a deploy listener the run failed so it exits now instead of
    // waiting for its timeout. The crash screen stays up for inspection.
    @import("../debug.zig").finish(.failure);
    var input: controls.Controller = .{};
    var last_poll = cp0.regRead(.Count);
    while (true) {
        const now = cp0.regRead(.Count);
        if (now -% last_poll < 1_500_000) continue;
        last_poll = now;
        if (input.update(&report, &state, controls.poll())) present();
    }
}
