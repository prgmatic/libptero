const std = @import("std");
const model = @import("model.zig");
const style = @import("style.zig");
const text = @import("font.zig");
const GprIndex = @import("../../cpu/trap_frame.zig").GprIndex;
const clip: text.Clip = .{ .left = 26, .top = model.viewport_top + 18, .right = 608, .bottom = model.viewport_top + 18 + model.register_viewport_height };

pub fn draw(img: style.Image, report: *const model.Report, state: model.State) void {
    style.pane(img);
    text.draw(img, style.fg, style.fonts.brand, "GENERAL PURPOSE", 26, 74);
    style.label(img, "64-bit snapshot", 511, 74);
    const regs = &(report.registers orelse {
        text.drawClipped(img, style.muted, style.fonts.data, "Register snapshot unavailable for a Zig panic", 26, 96, clip);
        return;
    });
    img.fillRegion(style.rule, 316, model.viewport_top + 18, 1, model.register_viewport_height);
    var buffer: [16]u8 = undefined;
    const first: usize = @min(state.y / model.register_row_height, 16 - model.register_visible_rows);
    for (first..first + model.register_visible_rows) |row| {
        const y = model.viewport_top + 28 + @as(i32, @intCast(row * model.register_row_height)) - state.y;
        if (y + 4 >= clip.top and y + 4 < clip.bottom)
            img.fillRegion(style.rule, 26, @intCast(y + 4), 574, 1);
        for (0..2) |column| {
            const index = row + column * 16;
            const name = if (index == 0) "r0" else @tagName(@as(GprIndex, @enumFromInt(index)));
            const value = std.fmt.bufPrint(&buffer, "{x:0>16}", .{regs.gpr[index]}) catch unreachable;
            text.drawClipped(img, style.muted, style.fonts.small, name, @intCast(35 + column * 302), y, clip);
            text.drawClipped(img, style.cyan, style.fonts.data, value, @intCast(80 + column * 302), y, clip);
        }
    }
}

pub fn position(report: *const model.Report, state: model.State, buffer: []u8) []const u8 {
    if (report.registers == null) return "No snapshot";
    const start: u16 = @min(state.y / model.register_row_height, 16 - model.register_visible_rows);
    return std.fmt.bufPrint(buffer, "GPR {d:0>2}-{d:0>2} / 16 rows", .{ start, start + (model.register_visible_rows - 1) }) catch "";
}
