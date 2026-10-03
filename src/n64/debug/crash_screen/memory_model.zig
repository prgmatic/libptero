//! Pure memory-bank bounds, address editing and fixed-size snapshot data.
const std = @import("std");
pub const Bank = enum(u2) { rdram, cart, dmem, imem };
pub const row_bytes = 16;
pub const visible_rows = 5;
pub const page_bytes = row_bytes * visible_rows;

pub const Bounds = struct {
    rdram_size: u32 = 4 * 1024 * 1024,

    pub fn range(self: Bounds, bank: Bank, address: u32) Range {
        return switch (bank) {
            .rdram => .{
                .base = if (address & 0xe0000000 == 0xa0000000) 0xa0000000 else 0x80000000,
                .length = if (self.rdram_size == 8 * 1024 * 1024) self.rdram_size else 4 * 1024 * 1024,
            },
            .cart => .{ .base = 0xb0000000, .length = 64 * 1024 * 1024 },
            .dmem => .{ .base = 0xa4000000, .length = 4096 },
            .imem => .{ .base = 0xa4001000, .length = 4096 },
        };
    }

    pub fn contains(self: Bounds, bank: Bank, address: u32) bool {
        return self.range(bank, address).contains(address);
    }
};

pub const Range = struct {
    base: u32,
    length: u32,
    pub fn contains(self: Range, address: u32) bool {
        return address >= self.base and address - self.base < self.length;
    }
};

pub const Window = struct { address: u32, length: u8 };

/// Include one preceding row when possible, without crossing either bank edge.
pub fn window(bounds: Bounds, bank: Bank, address: u32) ?Window {
    const range = bounds.range(bank, address);
    if (!range.contains(address)) return null;
    var first = address & ~@as(u32, row_bytes - 1);
    if (first - range.base >= row_bytes) first -= row_bytes;
    return .{ .address = first, .length = @intCast(@min(page_bytes, range.base + range.length - first)) };
}

pub const Status = enum {
    not_loaded,
    ready,
    pi_busy,
    pi_timeout,
    pi_error,
    invalid_address,
    pub fn message(self: Status) []const u8 {
        return switch (self) {
            .not_loaded => "Memory snapshot unavailable",
            .ready => "",
            .pi_busy => "Cartridge unavailable: PI is busy",
            .pi_timeout => "Cartridge read timed out",
            .pi_error => "Cartridge read failed",
            .invalid_address => "Address outside selected memory bank",
        };
    }
};

pub const View = struct {
    bank: Bank = .rdram,
    address: u32 = 0x80000000,
    bytes: [page_bytes]u8 = @splat(0),
    length: u8 = 0,
    status: Status = .not_loaded,
};

pub const State = struct {
    bank: Bank = .rdram,
    addresses: [4]u32 = .{ 0x80000000, 0xb0000000, 0xa4000000, 0xa4001000 },
    editing: bool = false,
    draft: u32 = 0,
    digit: u3 = 6,

    pub fn init(bounds: Bounds, pc: u32) State {
        var self: State = .{};
        if (bounds.contains(.rdram, pc)) self.addresses[0] = pc;
        return self;
    }

    pub fn address(self: State) u32 {
        return self.addresses[@intFromEnum(self.bank)];
    }

    pub fn displayAddress(self: State) u32 {
        return if (self.editing) self.draft else self.address();
    }

    pub fn switchBank(self: *State, step: i32) void {
        self.bank = @enumFromInt(@as(u2, @intCast(@mod(@as(i32, @intFromEnum(self.bank)) + step, 4))));
        self.editing = false;
    }

    pub fn beginEdit(self: *State) void {
        self.draft = self.address();
        self.digit = 6;
        self.editing = true;
    }

    pub fn apply(self: *State, bounds: Bounds) bool {
        if (!bounds.contains(self.bank, self.draft)) return false;
        self.addresses[@intFromEnum(self.bank)] = self.draft;
        self.editing = false;
        return true;
    }

    pub fn edit(self: *State, dx: i32, dy: i32) void {
        self.digit = @intCast(@mod(@as(i32, self.digit) + dx, 8));
        const shift: u5 = @intCast(28 - @as(u32, self.digit) * 4);
        const nibble: u32 = @intCast(@mod(@as(i32, @intCast((self.draft >> shift) & 15)) + dy, 16));
        self.draft = (self.draft & ~(@as(u32, 15) << shift)) | (nibble << shift);
    }

    pub fn navigate(self: *State, bounds: Bounds, columns: i32, rows: i32) void {
        const range = bounds.range(self.bank, self.address());
        const next = @as(i64, self.address()) + @as(i64, columns) * page_bytes + @as(i64, rows) * row_bytes;
        self.addresses[@intFromEnum(self.bank)] = @intCast(std.math.clamp(next, range.base, @as(i64, range.base) + range.length - 1));
    }
};

test "bank bounds reject unrelated MMIO, wraparound and absent expansion memory" {
    const bounds: Bounds = .{};
    try std.testing.expect(bounds.contains(.rdram, 0x803fffff));
    try std.testing.expect(!bounds.contains(.rdram, 0x80400000));
    try std.testing.expect(bounds.contains(.rdram, 0xa0000100));
    try std.testing.expect(!bounds.contains(.rdram, 0xa4000000));
    try std.testing.expect((Bounds{ .rdram_size = 8 * 1024 * 1024 }).contains(.rdram, 0x807fffff));
    try std.testing.expect(bounds.contains(.cart, 0xb3ffffff));
    try std.testing.expect(!bounds.contains(.cart, 0xb4000000));
    try std.testing.expect(bounds.contains(.dmem, 0xa4000fff));
    try std.testing.expect(!bounds.contains(.dmem, 0xa4001000));
    try std.testing.expect(bounds.contains(.imem, 0xa4001000));
    try std.testing.expect(!bounds.contains(.imem, 0xa4040000));
    try std.testing.expect(!bounds.contains(.imem, 0xffffffff));
}

test "unaligned address windows preserve context and stop at each bank end" {
    const bounds: Bounds = .{};
    for (std.enums.values(Bank)) |bank| {
        const range = bounds.range(bank, (State{}).addresses[@intFromEnum(bank)]);
        const first = window(bounds, bank, range.base + 3).?;
        try std.testing.expectEqual(range.base, first.address);
        try std.testing.expectEqual(@as(u8, page_bytes), first.length);
        const last = window(bounds, bank, range.base + range.length - 1).?;
        try std.testing.expectEqual(range.base + range.length - 32, last.address);
        try std.testing.expectEqual(@as(u8, 32), last.length);
        try std.testing.expect(window(bounds, bank, range.base + range.length) == null);
    }
    try std.testing.expectEqual(@as(u32, 0x800004e0), window(bounds, .rdram, 0x800004f3).?.address);
}

test "memory editing wraps digits, rejects invalid apply and remembers bank addresses" {
    const bounds: Bounds = .{};
    var state = State.init(bounds, 0x800004f0);
    state.beginEdit();
    state.edit(0, 1);
    try std.testing.expectEqual(@as(u32, 0x80000400), state.draft);
    try std.testing.expect(state.apply(bounds));
    state.beginEdit();
    state.edit(2, 0); // Wrap from digit 6 to digit 0.
    state.edit(0, 1);
    try std.testing.expect(!state.apply(bounds));
    try std.testing.expect(state.editing);
    try std.testing.expectEqual(@as(u32, 0x80000400), state.address());
    state.switchBank(1);
    try std.testing.expect(!state.editing);
    state.navigate(bounds, 1, 1);
    try std.testing.expectEqual(@as(u32, 0xb0000060), state.address());
    state.switchBank(-1);
    try std.testing.expectEqual(@as(u32, 0x80000400), state.address());
    state.navigate(bounds, -999999, -999999);
    try std.testing.expectEqual(@as(u32, 0x80000000), state.address());
    state.navigate(bounds, 999999999, 999999999);
    try std.testing.expectEqual(@as(u32, 0x803fffff), state.address());
}
