const std = @import("std");
const ast = @import("ast.zig");
const Register = ast.Register;
const DataType = ast.DataType;
const registerBit = @import("registers.zig").registerBit;
const vectorRegisterBit = @import("registers.zig").vectorRegisterBit;
const regName = @import("registers.zig").regName;
const vectorRegName = @import("registers.zig").vectorRegName;
const nextVectorRegister = @import("registers.zig").nextVectorRegister;

pub const Diagnostic = struct {
    source_path: ?[]const u8 = null,
    location: ?ast.SourceLocation = null,
    function_name: ?[]const u8 = null,
    symbol_name: ?[]const u8 = null,
    /// The values occupying registers when an allocation failed.
    live: [max_live]LiveValue = undefined,
    live_count: usize = 0,
    live_total: usize = 0,
    /// Free registers the failed value still could not use, and why.
    blocked: [32]Blocked = undefined,
    blocked_count: usize = 0,
    /// The failure was for a vector value.
    vector: bool = false,

    /// Enough for every vector register, so a vector failure lists them all.
    pub const max_live = 32;
    pub const LiveValue = struct { name: []const u8, reg: []const u8 };
    pub const BlockReason = enum {
        /// A call made while the value is live writes the register.
        call_writes,
        /// A pinned value that overlaps this one needs the register.
        pinned,

        fn text(self: BlockReason) []const u8 {
            return switch (self) {
                .call_writes => "written by a call",
                .pinned => "pinned",
            };
        }
    };
    pub const Blocked = struct { reg: []const u8, reason: BlockReason };

    pub fn recordBlocked(self: *Diagnostic, reg: []const u8, reason: BlockReason) void {
        if (self.blocked_count == self.blocked.len) return;
        self.blocked[self.blocked_count] = .{ .reg = reg, .reason = reason };
        self.blocked_count += 1;
    }

    pub fn recordLive(self: *Diagnostic, name: []const u8, reg: []const u8) void {
        if (self.live_count < max_live) {
            self.live[self.live_count] = .{ .name = name, .reg = reg };
            self.live_count += 1;
        }
        self.live_total += 1;
    }

    /// `  live: a in $t0, b in $t1 (+3 more)`
    pub fn writeLive(self: *const Diagnostic, writer: *std.Io.Writer) !void {
        if (self.live_total == 0) return;
        try writer.print("  {d} live values:", .{self.live_total});
        for (self.live[0..self.live_count], 0..) |value, index| {
            try writer.print("{s} {s} in {s}", .{ if (index == 0) "" else ",", value.name, value.reg });
        }
        if (self.live_total > self.live_count) try writer.print(" (+{d} more)", .{self.live_total - self.live_count});
        try writer.writeByte('\n');
        try self.writeBlocked(writer);
        if (self.vector) try writer.writeAll("  automatic vectors use $v01-$v28; $v00 and $v29-$v31 must be pinned\n");
    }

    /// `  also unavailable: $v13 (written by a call), $v29 (pinned)`
    fn writeBlocked(self: *const Diagnostic, writer: *std.Io.Writer) !void {
        if (self.blocked_count == 0) return;
        try writer.writeAll("  also unavailable:");
        for (self.blocked[0..self.blocked_count], 0..) |entry, index| {
            try writer.print("{s} {s} ({s})", .{ if (index == 0) "" else ",", entry.reg, entry.reason.text() });
        }
        try writer.writeByte('\n');
    }

    pub fn selectStatement(self: *Diagnostic, functions: []const ast.Function, statement: *const ast.Statement) void {
        for (functions) |function| {
            for (function.source_locations) |entry| {
                if (entry.statement != statement) continue;
                self.source_path = function.source_path;
                self.function_name = function.source_name;
                self.location = entry.location;
                self.symbol_name = null;
                return;
            }
        }
    }
};

test "allocation failures list the values occupying registers" {
    var diagnostic: Diagnostic = .{};
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try diagnostic.writeLive(&writer);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    for (0..Diagnostic.max_live + 2) |_| diagnostic.recordLive("x", "$t0");
    diagnostic.recordBlocked("$v13", .call_writes);
    diagnostic.recordBlocked("$v29", .pinned);
    diagnostic.vector = true;
    var large: [1024]u8 = undefined;
    var large_writer = std.Io.Writer.fixed(&large);
    try diagnostic.writeLive(&large_writer);
    try std.testing.expect(std.mem.startsWith(u8, large_writer.buffered(), "  34 live values: x in $t0, x in $t0"));
    try std.testing.expect(std.mem.endsWith(u8, large_writer.buffered(), " (+2 more)\n  also unavailable: $v13 (written by a call), $v29 (pinned)\n  automatic vectors use $v01-$v28; $v00 and $v29-$v31 must be pinned\n"));
}

pub const ExplainAllocation = struct {
    function_name: []const u8,
    symbol_name: []const u8,
    data_type: DataType,
    reg: ?Register,
    vector_reg: ?ast.VectorRegister,
    automatic: bool,
};

pub const ExplainWrites = struct {
    function_name: []const u8,
    scalar: u32,
    vector: u32,
};

pub const ExplainReport = struct {
    allocations: [2048]ExplainAllocation = undefined,
    allocation_count: usize = 0,
    writes: [1024]ExplainWrites = undefined,
    writes_count: usize = 0,

    pub fn addAllocation(self: *ExplainReport, allocation: ExplainAllocation) !void {
        if (self.allocation_count >= self.allocations.len) return error.TooManyExplainAllocations;
        self.allocations[self.allocation_count] = allocation;
        self.allocation_count += 1;
    }

    pub fn write(self: *const ExplainReport, writer: *std.Io.Writer) !void {
        try writer.writeAll("registers:\n");
        try self.writeAllocations(writer);
        try writer.writeAll("writes:\n");
        for (self.writes[0..self.writes_count]) |entry| try writeClobbers(writer, entry);
    }

    fn writeAllocations(self: *const ExplainReport, writer: *std.Io.Writer) !void {
        var current_function: []const u8 = "";
        for (self.allocations[0..self.allocation_count]) |allocation| {
            if (!std.mem.eql(u8, current_function, allocation.function_name)) {
                current_function = allocation.function_name;
                try writer.print("  {s}:\n", .{allocation.function_name});
            }
            try writeAllocation(writer, allocation);
        }
        if (self.allocation_count == 0) try writer.writeAll("  none\n");
    }
};

fn writeAllocation(writer: *std.Io.Writer, allocation: ExplainAllocation) !void {
    try writer.print("    {s}: {s} -> ", .{ allocation.symbol_name, @tagName(allocation.data_type) });
    if (allocation.reg) |reg| {
        try writer.writeAll(regName(reg));
    } else if (allocation.vector_reg) |reg| {
        try writer.print("${s}", .{vectorRegName(reg)});
        if (allocation.data_type == .vec32) try writer.print("/${s}", .{vectorRegName(nextVectorRegister(reg).?)});
    }
    try writer.print(" ({s})\n", .{if (allocation.automatic) "automatic" else "fixed"});
}

fn writeClobbers(writer: *std.Io.Writer, entry: ExplainWrites) !void {
    try writer.print("  {s}:", .{entry.function_name});
    try writeRegisterSet(writer, Register, entry.scalar);
    try writeRegisterSet(writer, ast.VectorRegister, entry.vector);
    if (entry.scalar | entry.vector == 0) try writer.writeAll(" none");
    try writer.writeByte('\n');
}

fn writeRegisterSet(writer: *std.Io.Writer, comptime Reg: type, bits: u32) !void {
    for (std.enums.values(Reg)) |reg| {
        if (bits & (@as(u32, 1) << @intFromEnum(reg)) == 0) continue;
        try writer.print(" ${s}", .{@tagName(reg)});
    }
}

test "explain prints grouped allocations, vector pairs and write contracts" {
    var report: ExplainReport = .{};
    try report.addAllocation(.{ .function_name = "entry", .symbol_name = "count", .data_type = .u32, .reg = .a0, .vector_reg = null, .automatic = false });
    try report.addAllocation(.{ .function_name = "entry", .symbol_name = "pair", .data_type = .vec32, .reg = null, .vector_reg = .v01, .automatic = true });
    report.writes[0] = .{ .function_name = "entry", .scalar = registerBit(.a0), .vector = vectorRegisterBit(.v01) };
    report.writes[1] = .{ .function_name = "finish", .scalar = 0, .vector = 0 };
    report.writes_count = 2;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try report.write(&output.writer);
    try std.testing.expectEqualStrings("registers:\n  entry:\n    count: u32 -> $a0 (fixed)\n    pair: vec32 -> $v01/$v02 (automatic)\nwrites:\n  entry: $a0 $v01\n  finish: none\n", output.written());
}

test "empty explain report and allocation limit" {
    var report: ExplainReport = .{};
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try report.write(&output.writer);
    try std.testing.expectEqualStrings("registers:\n  none\nwrites:\n", output.written());
    report.allocation_count = report.allocations.len;
    try std.testing.expectError(error.TooManyExplainAllocations, report.addAllocation(.{ .function_name = "entry", .symbol_name = "count", .data_type = .u32, .reg = .a0, .vector_reg = null, .automatic = true }));
}
