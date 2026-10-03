const std = @import("std");
const model = @import("model.zig");
const joypad = @import("../../io/joypad.zig");
const joybus = @import("../../io/joybus.zig");
const si = @import("../../interfaces/serial.zig");
var buffer: joybus.JoybusBuffer align(64) = .{};

pub fn poll() joypad.State {
    if (!si.waitDmaIoTimeout(100_000)) return .{};
    si.setPifJoybusMode();
    const command = buffer.roundTripCommandTimeout(joybus.Commands.CommandJoypadStateAll, 100_000) catch return .{};
    return joypad.stateFromResponse(command.port0);
}

pub const Controller = struct {
    previous: joypad.State = .{},
    repeat_ticks: u8 = 0,
    pub fn update(self: *Controller, report: *const model.Report, state: *model.State, current: joypad.State) bool {
        const held = current.d_up or current.d_down or current.d_left or current.d_right;
        const edge = (current.d_up and !self.previous.d_up) or (current.d_down and !self.previous.d_down) or
            (current.d_left and !self.previous.d_left) or (current.d_right and !self.previous.d_right);
        self.repeat_ticks = if (held and !edge) @min(self.repeat_ticks + 1, 12) else 0;
        const repeat = edge or self.repeat_ticks >= 10;
        if (self.repeat_ticks >= 10) self.repeat_ticks = 8;
        const dx: i32 = if (repeat) @as(i32, @intFromBool(current.d_right)) - @as(i32, @intFromBool(current.d_left)) else 0;
        const dy: i32 = if (repeat) @as(i32, @intFromBool(current.d_down)) - @as(i32, @intFromBool(current.d_up)) else 0;
        const tab_step: i32 = @as(i32, @intFromBool(current.r and !self.previous.r)) - @as(i32, @intFromBool(current.l and !self.previous.l));
        const previous = self.previous;
        self.previous = current;
        if (tab_step != 0) return state.move(report, 0, 0, tab_step);
        if (state.tab == .memory) return updateMemory(report, state, current, previous, dx, dy);
        return state.move(report, if (state.tab == .trace) dx * 24 else 0, dy * (if (state.tab == .registers) @as(i32, model.register_row_height) else 14), 0);
    }
};

fn updateMemory(report: *const model.Report, state: *model.State, current: joypad.State, previous: joypad.State, dx: i32, dy: i32) bool {
    const before = state.memory;
    const bank_step: i32 = @as(i32, @intFromBool(current.c_right and !previous.c_right)) - @as(i32, @intFromBool(current.c_left and !previous.c_left));
    if (bank_step != 0) {
        state.memory.switchBank(bank_step);
    } else if (current.b and !previous.b and state.memory.editing) {
        state.memory.editing = false;
    } else if (current.a and !previous.a) {
        if (state.memory.editing) {
            _ = state.memory.apply(report.memory_bounds);
        } else state.memory.beginEdit();
    } else if (state.memory.editing) {
        state.memory.edit(dx, -dy);
    } else state.memory.navigate(report.memory_bounds, dx, dy);
    return !std.meta.eql(before, state.memory);
}

test "D-pad repeats after a delay while shoulders switch only on press edges" {
    var report: model.Report = .{ .frame_count = 20 };
    var state: model.State = .{};
    var input: Controller = .{};
    try std.testing.expect(input.update(&report, &state, .{ .d_down = true }));
    try std.testing.expectEqual(@as(u16, 14), state.y);
    for (0..9) |_| try std.testing.expect(!input.update(&report, &state, .{ .d_down = true }));
    try std.testing.expect(input.update(&report, &state, .{ .d_down = true }));
    try std.testing.expect(input.update(&report, &state, .{ .r = true }));
    try std.testing.expectEqual(model.Tab.registers, state.tab);
    try std.testing.expect(!input.update(&report, &state, .{ .r = true }));
    _ = input.update(&report, &state, .{});
    try std.testing.expect(input.update(&report, &state, .{ .l = true }));
    try std.testing.expectEqual(model.Tab.trace, state.tab);
}

test "memory controls distinguish bank switching, address editing and browsing" {
    const report: model.Report = .{};
    var state: model.State = .{ .tab = .memory };
    var input: Controller = .{};
    try std.testing.expect(input.update(&report, &state, .{ .a = true }));
    try std.testing.expect(state.memory.editing);
    try std.testing.expect(!input.update(&report, &state, .{ .a = true }));
    _ = input.update(&report, &state, .{});
    try std.testing.expect(input.update(&report, &state, .{ .d_up = true }));
    try std.testing.expectEqual(@as(u32, 0x80000010), state.memory.draft);
    _ = input.update(&report, &state, .{});
    try std.testing.expect(input.update(&report, &state, .{ .a = true }));
    try std.testing.expect(!state.memory.editing);
    try std.testing.expectEqual(@as(u32, 0x80000010), state.memory.address());
    _ = input.update(&report, &state, .{});
    _ = input.update(&report, &state, .{ .d_down = true });
    try std.testing.expectEqual(@as(u32, 0x80000020), state.memory.address());
    _ = input.update(&report, &state, .{ .a = true });
    _ = input.update(&report, &state, .{ .d_up = true });
    _ = input.update(&report, &state, .{ .b = true });
    try std.testing.expectEqual(@as(u32, 0x80000020), state.memory.address());
    try std.testing.expect(!state.memory.editing);
    _ = input.update(&report, &state, .{ .c_right = true });
    try std.testing.expectEqual(model.memory.Bank.cart, state.memory.bank);
    try std.testing.expect(!input.update(&report, &state, .{ .c_right = true }));
    _ = input.update(&report, &state, .{});
    _ = input.update(&report, &state, .{ .c_left = true });
    try std.testing.expectEqual(@as(u32, 0x80000020), state.memory.address());
    _ = input.update(&report, &state, .{ .a = true });
    _ = input.update(&report, &state, .{ .r = true });
    try std.testing.expectEqual(model.Tab.system, state.tab);
    try std.testing.expect(!state.memory.editing);
}
