const std = @import("std");
const model = @import("model.zig");
const mem = model.memory;
const style = @import("style.zig");
const text = @import("font.zig");

pub fn draw(img: style.Image, report: *const model.Report, state: mem.State) void {
    style.pane(img);
    drawBanks(img, state.bank);
    drawAddress(img, report.memory_bounds, state);
    style.label(img, "ADDRESS", 35, 105);
    style.label(img, "HEX BYTES", 112, 105);
    style.label(img, "ASCII", 484, 105);
    img.fillRegion(style.rule, 100, 109, 1, 75);
    img.fillRegion(style.rule, 474, 109, 1, 75);
    const view = &report.memory_view;
    if (view.status != .ready or view.bank != state.bank) {
        const message = if (view.bank != state.bank) mem.Status.not_loaded.message() else view.status.message();
        text.drawClipped(img, style.amber, style.fonts.data, message, 112, 126, style.body_clip);
        return;
    }
    for (0..mem.visible_rows) |row| {
        if (row * mem.row_bytes >= view.length) break;
        drawRow(img, report, state, row);
    }
}

fn drawBanks(img: style.Image, bank: mem.Bank) void {
    img.fillRegion(style.rule, 26, 79, 574, 1);
    const names = [_][]const u8{ "RDRAM", "Cart", "DMEM", "IMEM" };
    const positions = [_]u16{ 68, 139, 195, 252 };
    for (names, positions, 0..) |name, x, i| {
        const active = @intFromEnum(bank) == i;
        text.draw(img, if (active) style.violet else style.muted, style.fonts.ui, name, x, 73);
        if (active) img.fillRegion(style.violet, x - 3, 77, @intCast(text.measure(style.fonts.ui, name) + 6), 1);
    }
    drawBankKey(img, 26, false);
    drawBankKey(img, 308, true);
    style.label(img, "Memory bank", 600 - text.measure(style.fonts.small, "Memory bank"), 73);
}

fn drawBankKey(img: style.Image, x: u16, forward: bool) void {
    img.fillRegion(style.amber, x, 61, 24, 16);
    img.fillRegion(style.panel, x + 1, 62, 22, 14);
    text.draw(img, style.fg, style.fonts.small, "C", x + 5, 73);
    for (0..5) |row| {
        const span: u16 = @intCast(3 - @abs(@as(i32, @intCast(row)) - 2));
        const left = if (forward) x + 16 else x + 19 - span;
        img.fillRegion(style.amber, left, 66 + @as(u16, @intCast(row)), span, 1);
    }
}

fn drawAddress(img: style.Image, bounds: mem.Bounds, state: mem.State) void {
    var buffer: [10]u8 = undefined;
    const address = std.fmt.bufPrint(&buffer, "0x{x:0>8}", .{state.displayAddress()}) catch unreachable;
    const valid = bounds.contains(state.bank, state.displayAddress());
    style.label(img, "ADDRESS", 26, 91);
    img.fillRegion(if (!valid) style.amber else if (state.editing) style.violet else style.muted, 100, 80, 128, 17);
    img.fillRegion(style.panel, 101, 81, 126, 15);
    style.value(img, address, 109, 92);
    if (state.editing) {
        const index: usize = 2 + @as(usize, state.digit);
        const x: u16 = @intCast(109 + text.measure(style.fonts.data, address[0..index]));
        const width: u16 = @intCast(text.measure(style.fonts.data, address[index .. index + 1]) + 2);
        img.fillRegion(style.violet, x - 1, 82, width, 12);
        text.draw(img, style.bg, style.fonts.data, address[index .. index + 1], x, 92);
        text.draw(img, if (valid) style.muted else style.amber, style.fonts.small, if (valid) "Edit hex address" else "Outside bank", 242, 92);
    } else {
        img.fillRegion(style.muted, 242, 81, 15, 14);
        img.fillRegion(style.panel, 243, 82, 13, 12);
        text.draw(img, style.fg, style.fonts.small, "A", 246, 92);
        text.draw(img, style.fg, style.fonts.ui, "Set address", 264, 92);
    }
    const caption = switch (state.bank) {
        .rdram => "RDRAM / read only",
        .cart => "ROM / read only",
        .dmem, .imem => "4 KiB / read only",
    };
    style.label(img, caption, 600 - text.measure(style.fonts.small, caption), 91);
}

fn drawRow(img: style.Image, report: *const model.Report, state: mem.State, row: usize) void {
    const view = &report.memory_view;
    const first = row * mem.row_bytes;
    const address = view.address + @as(u32, @intCast(first));
    const y: u16 = @intCast(121 + row * 15);
    const selected = state.address() >= address and state.address() - address < mem.row_bytes;
    if (selected) img.fillRegion(style.violet, 23, y - 8, 3, 8);
    var address_buf: [8]u8 = undefined;
    const row_address = std.fmt.bufPrint(&address_buf, "{x:0>8}", .{address}) catch unreachable;
    text.draw(img, if (selected) style.cyan else style.fg, style.fonts.bytes, row_address, 35, y);
    var hex: [50]u8 = @splat(' ');
    var ascii: [16]u8 = @splat(' ');
    const digits = "0123456789abcdef";
    for (0..mem.row_bytes) |i| {
        if (first + i >= view.length) break;
        const byte = view.bytes[first + i];
        const pos = i * 3 + i / 4;
        hex[pos] = digits[byte >> 4];
        hex[pos + 1] = digits[byte & 15];
        ascii[i] = if (byte >= 32 and byte <= 126) byte else '.';
    }
    text.draw(img, style.fg, style.fonts.bytes, &hex, 112, y);
    text.draw(img, style.muted, style.fonts.bytes, &ascii, 484, y);
    if (state.bank == .rdram) {
        if (report.programCounter()) |pc| {
            for (0..mem.row_bytes) |i| {
                if (first + i >= view.length) break;
                const byte_addr = (address + @as(u32, @intCast(i))) & 0x1fffffff;
                const fault = pc & 0x1fffffff;
                if (byte_addr >= fault and @as(u64, byte_addr) < @as(u64, fault) + 4) {
                    const pos = i * 3 + i / 4;
                    text.draw(img, style.amber, style.fonts.bytes, hex[pos .. pos + 2], 112 + text.measure(style.fonts.bytes, hex[0..pos]), y);
                    text.draw(img, style.amber, style.fonts.bytes, ascii[i .. i + 1], 484 + text.measure(style.fonts.bytes, ascii[0..i]), y);
                }
            }
        }
    }
}
