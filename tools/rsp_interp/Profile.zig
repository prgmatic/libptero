//! Per-instruction execution counts and estimated cycles, attributable to
//! named IMEM symbols after a run.
const std = @import("std");

const Profile = @This();

const word_count = 1024;

instructions: [word_count]u64 = @splat(0),
cycles: [word_count]u64 = @splat(0),

pub fn record(self: *Profile, pc: u32, cycles: u64) void {
    const index = (pc & 0xfff) >> 2;
    self.instructions[index] += 1;
    self.cycles[index] += cycles;
}

pub const Symbol = struct { name: []const u8, offset: u16 };

pub const Cost = struct {
    name: []const u8,
    instructions: u64 = 0,
    cycles: u64 = 0,
};

/// Attributes every IMEM word in `[start, end)` to the closest preceding
/// symbol. `symbols` must be sorted by offset. Words before the first symbol
/// in range are attributed to `fallback`. Returns one cost per symbol that
/// executed at least once, plus the fallback when it did.
pub fn attribute(
    self: *const Profile,
    allocator: std.mem.Allocator,
    symbols: []const Symbol,
    start: u16,
    end: u16,
    fallback: []const u8,
) ![]Cost {
    var costs: std.ArrayList(Cost) = .empty;
    errdefer costs.deinit(allocator);
    var current: Cost = .{ .name = fallback };
    var next_symbol: usize = firstSymbolAtOrAfter(symbols, start);
    var offset = start;
    while (offset < end) : (offset += 4) {
        while (next_symbol < symbols.len and symbols[next_symbol].offset <= offset) : (next_symbol += 1) {
            try appendExecuted(allocator, &costs, current);
            current = .{ .name = symbols[next_symbol].name };
        }
        current.instructions += self.instructions[offset >> 2];
        current.cycles += self.cycles[offset >> 2];
    }
    try appendExecuted(allocator, &costs, current);
    return costs.toOwnedSlice(allocator);
}

fn firstSymbolAtOrAfter(symbols: []const Symbol, start: u16) usize {
    for (symbols, 0..) |symbol, index| {
        if (symbol.offset >= start) return index;
    }
    return symbols.len;
}

fn appendExecuted(allocator: std.mem.Allocator, costs: *std.ArrayList(Cost), cost: Cost) !void {
    if (cost.instructions != 0) try costs.append(allocator, cost);
}

/// Sorts a copy of a symbol table by offset for `attribute`.
pub fn sortedSymbols(allocator: std.mem.Allocator, symbols: []const Symbol) ![]Symbol {
    const copy = try allocator.dupe(Symbol, symbols);
    std.mem.sort(Symbol, copy, {}, struct {
        fn lessThan(_: void, a: Symbol, b: Symbol) bool {
            return a.offset < b.offset;
        }
    }.lessThan);
    return copy;
}

const testing = std.testing;

test "costs are attributed to the preceding symbol within a range" {
    var profile: Profile = .{};
    profile.record(0x000, 1);
    profile.record(0x100, 2);
    profile.record(0x104, 3);
    profile.record(0x104, 1);
    profile.record(0x200, 5);
    profile.record(0x1300, 7);
    const symbols = try sortedSymbols(testing.allocator, &.{
        .{ .name = "second", .offset = 0x200 },
        .{ .name = "outside", .offset = 0x080 },
        .{ .name = "first", .offset = 0x100 },
        .{ .name = "idle", .offset = 0x180 },
    });
    defer testing.allocator.free(symbols);
    const costs = try profile.attribute(testing.allocator, symbols, 0x0c0, 0x400, "prologue");
    defer testing.allocator.free(costs);
    try testing.expectEqual(@as(usize, 2), costs.len);
    try testing.expectEqualStrings("first", costs[0].name);
    try testing.expectEqual(@as(u64, 3), costs[0].instructions);
    try testing.expectEqual(@as(u64, 6), costs[0].cycles);
    try testing.expectEqualStrings("second", costs[1].name);
    try testing.expectEqual(@as(u64, 12), costs[1].cycles);
    const whole = try profile.attribute(testing.allocator, &.{}, 0, 0x1000, "all");
    defer testing.allocator.free(whole);
    try testing.expectEqual(@as(u64, 6), whole[0].instructions);
    try testing.expectEqual(@as(usize, 3), firstSymbolAtOrAfter(symbols, 0x1f0));
    try testing.expectEqual(symbols.len, firstSymbolAtOrAfter(symbols, 0x300));
}
