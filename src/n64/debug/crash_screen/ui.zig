//! CPU-only crash-report presentation, also used by the public dummy example.
const std = @import("std");
const text = @import("font.zig");
const model = @import("model.zig");
const style = @import("style.zig");
const registers = @import("registers.zig");
const system_page = @import("system.zig");
const memory_page = @import("memory_ui.zig");
const fonts = text.assets;
pub const Pixel = style.Pixel;
pub const Image = style.Image;
pub const width = 640;
pub const height = 240;

const bg = style.bg;
const header = style.header;
const panel = style.panel;
const rule = style.rule;
const fg = style.fg;
const muted = style.muted;
const violet = style.violet;
const cyan = style.cyan;
const amber = style.amber;

pub fn render(img: Image, report: *const model.Report, state: model.State) void {
    std.debug.assert(img.width == width and img.height == height);
    img.fillRegion(bg, 0, 0, width, height);
    drawHeader(img, state.tab);
    drawSummary(img, report);
    switch (state.tab) {
        .trace => drawTrace(img, report, state),
        .registers => registers.draw(img, report, state),
        .memory => memory_page.draw(img, report, state.memory),
        .system => system_page.draw(img, report),
    }
    drawScrollbars(img, report, state);
    img.fillRegion(rule, 16, 219, 608, 1);
    drawDpad(img, 16, 222);
    drawFooter(img, report, state);
}

fn drawHeader(img: Image, tab: model.Tab) void {
    img.fillRegion(header, 0, 0, width, 21);
    text.draw(img, fg, fonts.brand, "libptero", 16, 15);
    drawShoulder(img, 96, "LB");
    const labels = [_][]const u8{ "Stack Trace", "Registers", "Memory", "System" };
    const positions = [_]u16{ 136, 238, 328, 406 };
    for (labels, positions, 0..) |label, x, i| {
        const selected = @intFromEnum(tab) == i;
        text.draw(img, if (selected) violet else muted, fonts.ui, label, x, 15);
        if (selected) img.fillRegion(violet, x - 4, 19, @intCast(text.measure(fonts.ui, label) + 8), 1);
    }
    drawShoulder(img, 474, "RB");
    img.fillRegion(rule, 16, 21, 608, 1);
}

fn drawSummary(img: Image, report: *const model.Report) void {
    const label = if (report.kind == .panic) "PANIC" else "EXCEPTION";
    text.draw(img, amber, fonts.small, label, 16, 34);
    const message = report.message.slice();
    const end = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
    text.drawClipped(img, fg, fonts.title, message[0..end], 32 + text.measure(fonts.small, label), 35, .{ .right = 551, .bottom = 39 });
    img.fillRegion(amber, 566, 27, 3, 3);
    right(img, amber, fonts.small, "HALTED", 624, 34);
    text.drawClipped(img, muted, fonts.data, report.detail.slice(), 16, 49, .{ .right = 624, .bottom = 53 });
    img.fillRegion(rule, 16, 55, 608, 1);
}

const viewport: text.Clip = .{ .left = 26, .top = model.viewport_top, .right = 608, .bottom = model.viewport_bottom };
const trace_clip: text.Clip = .{ .left = 55, .top = model.viewport_top, .right = 601, .bottom = model.viewport_bottom };

fn drawTrace(img: Image, report: *const model.Report, state: model.State) void {
    if (report.frame_count == 0) return bodyText(img, "Backtrace unavailable", 26, model.viewport_top + 20);
    var row: i32 = model.viewport_top - @as(i32, state.y);
    for (report.frames[0..report.frame_count], 0..) |*frame, index| {
        if (row < viewport.bottom and row + frame.height() > viewport.top)
            drawFrame(img, frame, index, row, state.x);
        row += frame.height();
    }
}

fn drawFrame(img: Image, frame: *const model.Frame, index: usize, row: i32, scroll_x: u16) void {
    if (index == 0) {
        fillClipped(img, panel, 16, row, 592, frame.height() - 2);
        fillClipped(img, violet, 16, row, 2, frame.height() - 2);
    } else fillClipped(img, rule, 26, row + frame.height() - 2, 574, 1);
    var buffer: [32]u8 = undefined;
    const number = std.fmt.bufPrint(&buffer, "{d:0>2}", .{index}) catch "";
    text.drawClipped(img, muted, fonts.small, number, 26, row + 11, viewport);
    const function_clip: text.Clip = .{ .left = 55, .top = model.viewport_top, .right = 520, .bottom = model.viewport_bottom };
    text.drawClipped(img, cyan, fonts.data, frame.function.slice(), 55 - @as(i32, scroll_x), row + 11, function_clip);
    const address = std.fmt.bufPrint(&buffer, "0x{x:0>8}", .{frame.address}) catch "";
    text.drawClipped(img, muted, fonts.small, address, 600 - text.measure(fonts.small, address), row + 11, viewport);
    text.drawClipped(img, fg, fonts.data, frame.location.slice(), 55 - @as(i32, scroll_x), row + 25, trace_clip);
    if (frame.source.len != 0) drawSource(img, frame, row, scroll_x);
}

fn drawSource(img: Image, frame: *const model.Frame, row: i32, scroll_x: u16) void {
    var buffer: [16]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{d}", .{frame.line}) catch "";
    text.drawClipped(img, muted, fonts.small, line, 55 - @as(i32, scroll_x), row + 39, trace_clip);
    fillClipped(img, rule, 80 - @as(i32, scroll_x), row + 29, 1, 14);
    const x = 91 - @as(i32, scroll_x);
    const source = frame.source.slice();
    text.drawClipped(img, fg, fonts.data, source, x, row + 39, trace_clip);
    if (frame.column == 0 or frame.column > source.len) return;
    const column = frame.column - 1;
    const mark = x + text.measure(fonts.data, source[0..column]);
    text.drawClipped(img, amber, fonts.data, source[column .. column + 1], mark, row + 39, trace_clip);
    text.drawClipped(img, amber, fonts.small, "^", mark, row + 50, trace_clip);
}

fn fillClipped(img: Image, color: Pixel, x: i32, y: i32, w: i32, h: i32) void {
    const left = @max(16, x);
    const top = @max(viewport.top, y);
    const right_edge = @min(viewport.right, x + w);
    const bottom = @min(viewport.bottom, y + h);
    if (left < right_edge and top < bottom)
        img.fillRegion(color, @intCast(left), @intCast(top), @intCast(right_edge - left), @intCast(bottom - top));
}

fn bodyText(img: Image, str: []const u8, x: i32, baseline: i32) void {
    text.drawClipped(img, muted, fonts.data, str, x, baseline, viewport);
}

fn drawFooter(img: Image, report: *const model.Report, state: model.State) void {
    if (state.tab == .memory and state.memory.editing) {
        text.draw(img, fg, fonts.ui, "Digit / value", 54, 233);
        style.keyHint(img, 224, "A", "Apply");
        style.keyHint(img, 306, "B", "Cancel");
        right(img, muted, fonts.small, "Editing address", 624, 233);
        return;
    }
    const hint = switch (state.tab) {
        .trace => "Scroll trace",
        .registers => "Scroll registers",
        .memory => "Scroll memory",
        .system => "Scroll view",
    };
    text.draw(img, fg, fonts.ui, hint, 54, 233);
    var buffer: [48]u8 = undefined;
    switch (state.tab) {
        .trace => drawPosition(img, report, state),
        .registers => text.draw(img, muted, fonts.small, registers.position(report, state, &buffer), 223, 233),
        .memory => text.draw(img, muted, fonts.small, "16-byte rows", 223, 233),
        .system => text.draw(img, muted, fonts.small, if (report.registers != null) "Saved CPU state" else "Panic state", 223, 233),
    }
    right(img, muted, fonts.small, "Reset console to restart", 624, 233);
}

fn drawPosition(img: Image, report: *const model.Report, state: model.State) void {
    if (state.tab != .trace) return;
    var start: usize = 0;
    var end: usize = 0;
    var y: u16 = 0;
    for (report.frames[0..report.frame_count], 0..) |*frame, i| {
        const next = y + frame.height();
        if (next <= state.y) start = i + 1;
        if (y < state.y + model.viewport_height) end = i + 1;
        y = next;
    }
    var buffer: [48]u8 = undefined;
    const str = if (report.frame_count == 0) "0 frames" else std.fmt.bufPrint(&buffer, "{d}-{d} / {d} frames", .{ start + 1, end, report.frame_count }) catch "";
    text.draw(img, muted, fonts.small, str, 223, 233);
}

fn right(img: Image, color: Pixel, font: fonts.Font, str: []const u8, x: i32, baseline: i32) void {
    text.draw(img, color, font, str, x - text.measure(font, str), baseline);
}

fn drawShoulder(img: Image, x: u16, label: []const u8) void {
    for (0..14) |row| {
        const inset: u16 = if (row == 0 or row == 13) 2 else if (row == 1 or row == 12) 1 else 0;
        const y: u16 = @intCast(3 + row);
        const span = 24 - 2 * inset;
        img.fillRegion(if (row == 0 or row == 13) muted else panel, x + inset, y, span, 1);
        img.set(x + inset, y, muted);
        img.set(x + 23 - inset, y, muted);
    }
    text.draw(img, fg, fonts.small, label, x + 6, 14);
}

fn drawScrollbars(img: Image, report: *const model.Report, state: model.State) void {
    if (state.tab == .memory) return;
    const visible: u16 = if (state.tab == .registers) model.register_viewport_height else model.viewport_height;
    const vertical = model.thumb(model.viewport_height, visible, report.contentHeight(state.tab), state.y);
    img.fillRegion(rule, 619, model.viewport_top, 4, model.viewport_height);
    img.fillRegion(if (state.maxY(report) > 0) violet else muted, 619, model.viewport_top + vertical.offset, 4, vertical.length);
    if (state.tab == .trace) {
        const horizontal = model.thumb(582, model.viewport_width, report.contentWidth(state.tab), state.x);
        img.fillRegion(rule, 26, 212, 582, 3);
        img.fillRegion(if (state.maxX(report) > 0) violet else muted, 26 + horizontal.offset, 212, horizontal.length, 3);
    }
}

fn drawDpad(img: Image, x: u16, y: u16) void {
    // The 640x240 display doubles row height at 4:3. Double columns too,
    // making this 30x15 native bitmap appear square with uniform strokes.
    img.fillRegion(header, x + 10, y, 10, 15);
    img.fillRegion(header, x, y + 5, 30, 5);
    const outline = [_]u16{ 0x3e0, 0x220, 0x220, 0x220, 0x220, 0x7e3f, 0x4001, 0x4001, 0x4001, 0x7e3f, 0x220, 0x220, 0x220, 0x220, 0x3e0 };
    const arrows = [_]u16{ 0, 0, 0x80, 0x80, 0x1c0, 0, 0x410, 0x1c1c, 0x410, 0, 0x1c0, 0x80, 0x80, 0, 0 };
    drawMask(img, muted, &outline, x, y);
    drawMask(img, violet, &arrows, x, y);
}

/// Fifteen-bit icon rows; each bit paints two native columns for the TV aspect.
fn drawMask(img: Image, color: Pixel, rows: []const u16, x: u16, y: u16) void {
    for (rows, 0..) |bits, row| {
        for (0..15) |col| {
            if (bits & (@as(u16, 1) << @as(u4, @intCast(14 - col))) != 0)
                img.fillRegion(color, x + @as(u16, @intCast(col * 2)), y + @as(u16, @intCast(row)), 2, 1);
        }
    }
}

test "CPU renderer fills the native framebuffer without touching guard pixels" {
    var pixels: [width * height + 2]Pixel = undefined;
    pixels[0] = .red;
    pixels[pixels.len - 1] = .red;
    const img = try Image.initBuffer(pixels[1 .. pixels.len - 1], width, height);
    var report: model.Report = .{ .frame_count = model.max_frames };
    report.message.set("Test crash");
    report.frames[0].source.set("long line " ** 40);
    report.frames[0].column = 65535;
    render(img, &report, .{});
    try std.testing.expectEqual(@as(u16, @bitCast(Pixel.red)), @as(u16, @bitCast(pixels[0])));
    try std.testing.expectEqual(@as(u16, @bitCast(Pixel.red)), @as(u16, @bitCast(pixels[pixels.len - 1])));
    try std.testing.expectEqual(bg, img.get(0, 239));
    try std.testing.expectEqual(header, img.get(0, 0));
    try std.testing.expectEqual(violet, img.get(16, model.viewport_top));
    try std.testing.expectEqual(rule, img.get(16, 219));
    for (img.texel_data) |pixel| try std.testing.expect(pixel.a == 1);
    var state: model.State = .{};
    _ = state.move(&report, 9999, 9999, 0);
    render(img, &report, state);
    report.registers = std.mem.zeroes(@import("../cpu_state.zig").TrapFrame);
    for ([_]model.Tab{ .registers, .memory, .system }) |tab| {
        state = .{ .tab = tab };
        _ = state.move(&report, 9999, 9999, 0);
        render(img, &report, state);
    }
    try std.testing.expectEqual(Pixel.red, pixels[0]);
    try std.testing.expectEqual(Pixel.red, pixels[pixels.len - 1]);
}

test {
    _ = text;
}

test "non-trace pages suppress horizontal bars and memory suppresses both" {
    var pixels: [width * height]Pixel = undefined;
    const img = try Image.initBuffer(&pixels, width, height);
    var report: model.Report = .{};
    report.registers = std.mem.zeroes(@import("../cpu_state.zig").TrapFrame);
    for ([_]model.Tab{ .registers, .system, .memory }) |tab| {
        render(img, &report, .{ .tab = tab });
        for (26..608) |x| try std.testing.expectEqual(bg, img.get(@intCast(x), 213));
        if (tab == .memory) {
            for (model.viewport_top..model.viewport_bottom) |y| try std.testing.expectEqual(bg, img.get(620, @intCast(y)));
        } else try std.testing.expect(img.get(620, model.viewport_top) != bg);
    }
}

test "memory data, all bank selectors and invalid digit edits remain clipped" {
    var pixels: [width * height + 2]Pixel = undefined;
    pixels[0] = .red;
    pixels[pixels.len - 1] = .red;
    const img = try Image.initBuffer(pixels[1 .. pixels.len - 1], width, height);
    var report: model.Report = .{};
    report.memory_view = .{ .status = .ready, .length = model.memory.page_bytes };
    for (&report.memory_view.bytes, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    for (std.enums.values(model.memory.Bank)) |bank| {
        var state: model.State = .{ .tab = .memory };
        state.memory.bank = bank;
        report.memory_view.bank = bank;
        report.memory_view.address = state.memory.address();
        render(img, &report, state);
        state.memory.beginEdit();
        state.memory.draft = 0xffffffff;
        for (0..8) |digit| {
            state.memory.digit = @intCast(digit);
            render(img, &report, state);
        }
    }
    try std.testing.expectEqual(Pixel.red, pixels[0]);
    try std.testing.expectEqual(Pixel.red, pixels[pixels.len - 1]);
}
