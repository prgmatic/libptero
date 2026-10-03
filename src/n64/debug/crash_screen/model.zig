//! Owned crash data and pure navigation; no MMIO, allocator or live stack reads.
const std = @import("std");
const font = @import("font.zig");
const TrapFrame = @import("../cpu_state.zig").TrapFrame;
pub const memory = @import("memory_model.zig");
pub const Kind = enum { panic, exception };
pub const Tab = enum(u2) { trace, registers, memory, system };
pub const max_frames = 20;
pub const viewport_width = 546;
// Coordinates are native 640x240 pixels; the display stretches rows at 4:3.
pub const viewport_top = 61;
pub const viewport_bottom = 209;
pub const viewport_height = viewport_bottom - viewport_top;
pub const register_row_height = 15;
pub const register_visible_rows = 8;
pub const register_viewport_height = register_row_height * register_visible_rows;

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: u16 = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @intCast(@min(value.len, capacity));
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Frame = struct {
    address: u32 = 0,
    function: Text(128) = .{},
    location: Text(256) = .{},
    source: Text(512) = .{},
    line: u16 = 0,
    column: u16 = 0,
    pub fn height(self: *const Frame) u16 {
        return if (self.source.len != 0) 51 else 31;
    }
};

pub const Report = struct {
    kind: Kind = .panic,
    message: Text(256) = .{},
    detail: Text(256) = .{},
    frames: [max_frames]Frame = @splat(.{}),
    frame_count: u8 = 0,
    registers: ?TrapFrame = null,
    badvaddr: u32 = 0,
    memory_bounds: memory.Bounds = .{},
    memory_view: memory.View = .{},

    pub fn programCounter(self: *const Report) ?u32 {
        if (self.registers) |*regs| return @import("../exception_codes.zig").faultPc(regs.cause, regs.epc);
        return if (self.frame_count != 0) self.frames[0].address else null;
    }

    pub fn contentHeight(self: *const Report, tab: Tab) u16 {
        return switch (tab) {
            .trace => blk: {
                var result: u16 = 0;
                for (self.frames[0..self.frame_count]) |*frame| result += frame.height();
                break :blk result;
            },
            .registers => if (self.registers != null) 16 * register_row_height else 0,
            .memory => 0,
            .system => if (self.registers != null) viewport_height else 2 * 16,
        };
    }

    pub fn contentWidth(self: *const Report, tab: Tab) u16 {
        if (tab != .trace) return viewport_width;
        var result: i32 = viewport_width;
        for (self.frames[0..self.frame_count]) |*frame| {
            // The fixed address column reduces the function-name viewport by 81px.
            result = @max(result, 81 + font.measure(font.assets.data, frame.function.slice()));
            result = @max(result, font.measure(font.assets.data, frame.location.slice()));
            result = @max(result, 36 + font.measure(font.assets.data, frame.source.slice()));
        }
        return @intCast(result);
    }
};

pub const State = struct {
    tab: Tab = .trace,
    x: u16 = 0,
    y: u16 = 0,
    memory: memory.State = .{},

    pub fn move(self: *State, report: *const Report, dx: i32, dy: i32, tab_step: i32) bool {
        const previous = self.*;
        if (tab_step != 0) {
            self.tab = @enumFromInt(@as(u2, @intCast(@mod(@as(i32, @intFromEnum(self.tab)) + tab_step, 4))));
            self.x = 0;
            self.y = 0;
            self.memory.editing = false;
        }
        self.x = @intCast(std.math.clamp(@as(i32, self.x) + dx, 0, self.maxX(report)));
        self.y = @intCast(std.math.clamp(@as(i32, self.y) + dy, 0, self.maxY(report)));
        return !std.meta.eql(previous, self.*);
    }

    pub fn maxX(self: State, report: *const Report) u16 {
        return report.contentWidth(self.tab) -| viewport_width;
    }
    pub fn maxY(self: State, report: *const Report) u16 {
        const visible: u16 = if (self.tab == .registers) register_viewport_height else viewport_height;
        return report.contentHeight(self.tab) -| visible;
    }
};

pub const Thumb = struct { offset: u16, length: u16 };
pub fn thumb(track: u16, viewport: u16, content: u16, offset: u16) Thumb {
    if (content <= viewport) return .{ .offset = 0, .length = track };
    const length: u16 = @intCast(@max(4, @as(u32, track) * viewport / content));
    return .{ .offset = @intCast(@as(u32, @min(offset, content - viewport)) * (track - length) / (content - viewport)), .length = length };
}

test "scrolling clamps and tab changes reset offsets with wraparound" {
    var report: Report = .{ .frame_count = 8 };
    report.frames[0].source.set("0123456789" ** 20);
    var state: State = .{};
    try std.testing.expect(state.move(&report, 9999, 9999, 0));
    try std.testing.expectEqual(state.maxX(&report), state.x);
    try std.testing.expectEqual(state.maxY(&report), state.y);
    try std.testing.expect(!state.move(&report, 1, 1, 0));
    try std.testing.expect(state.move(&report, 0, 0, -1));
    try std.testing.expectEqual(Tab.system, state.tab);
    try std.testing.expectEqual(@as(u16, 0), state.x);
    try std.testing.expect(state.move(&report, 0, 0, 1));
    try std.testing.expectEqual(Tab.trace, state.tab);
    _ = state.move(&report, -999, -999, 0);
    try std.testing.expectEqual(@as(u16, 0), state.y);
}

test "scrollbar thumbs cover empty views and reach the end of overflowing views" {
    try std.testing.expectEqual(Thumb{ .offset = 0, .length = 124 }, thumb(124, 124, 0, 0));
    const end = thumb(124, 124, 496, 372);
    try std.testing.expectEqual(@as(u16, 31), end.length);
    try std.testing.expectEqual(@as(u16, 124), end.offset + end.length);
}

test "horizontal scrolling exposes a long function name beside its fixed address" {
    var report: Report = .{ .frame_count = 1 };
    report.frames[0].function.set("long_function_name_" ** 6);
    const measured = font.measure(font.assets.data, report.frames[0].function.slice());
    const state: State = .{};
    try std.testing.expectEqual(@as(u16, @intCast(measured - 465)), state.maxX(&report));
}
