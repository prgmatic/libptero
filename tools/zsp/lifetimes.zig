//! Per-function value lifetimes and statement-position liveness.
//!
//! Statements are numbered in source order (delay slots included), and every
//! named value records the positions that read and write it. A flow graph
//! over those positions (`flow.zig`) lets queries ask whether a value is
//! read again before being redefined along any path.
const std = @import("std");
const ast = @import("ast.zig");
const registers = @import("registers.zig");

const Register = ast.Register;
const VReg = ast.VectorRegister;
const registerBit = registers.registerBit;
const vectorRegisterBit = registers.vectorRegisterBit;

pub const Lifetime = struct {
    name: []const u8,
    declaration: usize,
    last_use: usize,
    automatic: bool,
    initially_defined: bool,
    first_live: usize,
    data_type: ast.DataType,
    fixed_reg: ?Register = null,
    fixed_vector_reg: ?VReg = null,
    /// Register a call argument asks an automatic value to live in.
    required_reg: ?Register = null,
    required_vector_reg: ?VReg = null,
    /// Registers written by calls the value is live across.
    forbidden_scalar: u32 = 0,
    forbidden_vector: u32 = 0,
    /// `reserved`: the register is the value's for the whole function and
    /// across every call it makes.
    reserved: bool = false,
};

/// A register an automatic value may take, checked against pinned values.
pub const Pinned = union(enum) {
    scalar: Register,
    vector: VReg,

    fn heldBy(self: Pinned, lifetime: Lifetime) bool {
        return switch (self) {
            .scalar => |reg| lifetime.fixed_reg == reg,
            .vector => |reg| holdsVector(lifetime, reg),
        };
    }

    /// An automatic value that must arrive in this register for a call.
    fn requiredBy(self: Pinned, lifetime: Lifetime) bool {
        return switch (self) {
            .scalar => |reg| lifetime.required_reg == reg,
            .vector => |reg| lifetime.required_vector_reg == reg,
        };
    }
};

fn holdsVector(lifetime: Lifetime, reg: VReg) bool {
    const fixed = lifetime.fixed_vector_reg orelse return false;
    if (fixed == reg) return true;
    return lifetime.data_type == .vec32 and @intFromEnum(fixed) < 31 and @intFromEnum(fixed) + 1 == @intFromEnum(reg);
}

pub const Label = struct { name: []const u8, position: usize, exported: bool = false };
pub const Edge = struct { target: []const u8, position: usize };
pub const Call = struct {
    target: []const u8,
    position: usize,
    resume_position: usize,
    /// Parameter registers the call's argument setup writes.
    setup_scalar: u32 = 0,
    setup_vector: u32 = 0,
};

/// `output_write` marks a value defined by a callee through a parameter;
/// it is not a use of the caller's previous value.
pub const EventKind = enum { read, write, output_write };
pub const Event = struct { name: []const u8, position: usize, kind: EventKind };
pub const FlowLoop = struct { name: ?[]const u8, continue_position: usize, break_position: usize };

pub const Declaration = struct {
    name: []const u8,
    position: usize,
    automatic: bool,
    initially_defined: bool,
    data_type: ast.DataType,
    fixed_reg: ?Register = null,
    fixed_vector_reg: ?VReg = null,
    reserved: bool = false,
};

pub const Lifetimes = struct {
    allocator: std.mem.Allocator,
    lifetimes: std.ArrayList(Lifetime) = .empty,
    labels: std.ArrayList(Label) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    calls: std.ArrayList(Call) = .empty,
    events: std.ArrayList(Event) = .empty,
    /// Events grouped by position, built once all events are known.
    event_index: std.ArrayList(usize) = .empty,
    sorted_events: std.ArrayList(Event) = .empty,
    successors: std.ArrayList([2]usize) = .empty,
    successor_counts: std.ArrayList(u2) = .empty,
    flow_loops: std.ArrayList(FlowLoop) = .empty,
    /// Structured `do`/`while` loops as [first body position, condition].
    loops: std.ArrayList([2]usize) = .empty,
    flow_statement_count: usize = 0,
    /// Lifetimes are only reused when every path is understood.
    reuse: bool = false,

    pub fn init(allocator: std.mem.Allocator) Lifetimes {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Lifetimes) void {
        inline for (.{ "lifetimes", "labels", "edges", "calls", "events", "event_index", "sorted_events", "successors", "successor_counts", "flow_loops", "loops" }) |field| {
            @field(self, field).deinit(self.allocator);
        }
    }

    pub fn reset(self: *Lifetimes) void {
        const allocator = self.allocator;
        self.deinit();
        self.* = .init(allocator);
    }

    pub fn declare(self: *Lifetimes, declaration: Declaration) !void {
        const whole = declaration.reserved;
        try self.lifetimes.append(self.allocator, .{
            .name = declaration.name,
            .declaration = declaration.position,
            .last_use = if (whole) std.math.maxInt(usize) else declaration.position,
            .automatic = declaration.automatic,
            .initially_defined = declaration.initially_defined,
            .first_live = if (whole) 0 else if (declaration.initially_defined) declaration.position else std.math.maxInt(usize),
            .data_type = declaration.data_type,
            .fixed_reg = declaration.fixed_reg,
            .fixed_vector_reg = declaration.fixed_vector_reg,
            .reserved = whole,
        });
    }

    pub fn addLabel(self: *Lifetimes, name: []const u8, position: usize, exported: bool) !void {
        try self.labels.append(self.allocator, .{ .name = name, .position = position, .exported = exported });
    }

    pub fn addEdge(self: *Lifetimes, target: []const u8, position: usize) !void {
        try self.edges.append(self.allocator, .{ .target = target, .position = position });
    }

    pub fn addCall(self: *Lifetimes, target: []const u8, position: usize, resume_position: usize) !void {
        try self.calls.append(self.allocator, .{ .target = target, .position = position, .resume_position = resume_position });
    }

    /// Records the registers a call's argument setup writes.
    pub fn addCallSetup(self: *Lifetimes, position: usize, scalar: u32, vector: u32) void {
        for (self.calls.items) |*call| {
            if (call.position != position) continue;
            call.setup_scalar |= scalar;
            call.setup_vector |= vector;
            return;
        }
    }

    pub fn findLabel(self: *const Lifetimes, name: []const u8) ?Label {
        for (self.labels.items) |label| {
            if (std.mem.eql(u8, label.name, name)) return label;
        }
        return null;
    }

    pub fn labelPosition(self: *const Lifetimes, name: []const u8) usize {
        const label = self.findLabel(name) orelse return 0;
        return label.position;
    }

    /// The most recently declared lifetime with this name.
    pub fn find(self: *Lifetimes, name: []const u8) ?*Lifetime {
        var index = self.lifetimes.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.lifetimes.items[index].name, name)) return &self.lifetimes.items[index];
        }
        return null;
    }

    fn findConst(self: *const Lifetimes, name: []const u8) ?Lifetime {
        const lifetime = (@constCast(self)).find(name) orelse return null;
        return lifetime.*;
    }

    /// The first lifetime with this name, as allocation queries expect.
    fn findFirst(self: *const Lifetimes, name: []const u8) ?Lifetime {
        for (self.lifetimes.items) |lifetime| {
            if (std.mem.eql(u8, lifetime.name, name)) return lifetime;
        }
        return null;
    }

    pub fn has(self: *const Lifetimes, name: []const u8) bool {
        return self.findFirst(name) != null;
    }

    pub fn read(self: *Lifetimes, name: []const u8, position: usize) !void {
        try self.addEvent(name, position, .read);
        self.extend(name, position);
    }

    pub fn write(self: *Lifetimes, name: []const u8, position: usize) !void {
        try self.writeKind(name, position, .write);
    }

    pub fn writeOutput(self: *Lifetimes, name: []const u8, position: usize) !void {
        try self.writeKind(name, position, .output_write);
    }

    fn writeKind(self: *Lifetimes, name: []const u8, position: usize, kind: EventKind) !void {
        try self.addEvent(name, position, kind);
        const lifetime = self.find(name) orelse return;
        lifetime.first_live = @min(lifetime.first_live, position);
        lifetime.last_use = @max(lifetime.last_use, position);
    }

    fn extend(self: *Lifetimes, name: []const u8, position: usize) void {
        const lifetime = self.find(name) orelse return;
        lifetime.last_use = @max(lifetime.last_use, position);
    }

    fn addEvent(self: *Lifetimes, name: []const u8, position: usize, kind: EventKind) !void {
        try self.events.append(self.allocator, .{ .name = name, .position = position, .kind = kind });
    }

    /// Values live at a label reached by a backward branch stay live until
    /// that branch.
    pub fn extendBackwardEdges(self: *Lifetimes) void {
        for (self.edges.items) |edge| {
            const target = (self.findLabel(edge.target) orelse continue).position;
            if (target < edge.position) self.extendLoop(target, edge.position);
        }
        for (self.loops.items) |loop| self.extendCarried(loop[0], loop[1]);
    }

    pub fn addLoop(self: *Lifetimes, first: usize, condition: usize) !void {
        try self.loops.append(self.allocator, .{ first, condition });
    }

    /// Values from before a structured loop that it uses may be read again
    /// by the next iteration, so they live until its back edge.
    fn extendCarried(self: *Lifetimes, first: usize, back_edge: usize) void {
        for (self.lifetimes.items) |*lifetime| {
            if (lifetime.declaration < first and lifetime.last_use >= first) {
                lifetime.last_use = @max(lifetime.last_use, back_edge);
            }
        }
    }

    /// Values declared before a loop's back edge and used inside it live
    /// through the whole loop.
    fn extendLoop(self: *Lifetimes, start: usize, back_edge: usize) void {
        for (self.lifetimes.items) |*lifetime| {
            if (lifetime.declaration <= back_edge and lifetime.last_use >= start) {
                lifetime.last_use = @max(lifetime.last_use, back_edge);
            }
        }
    }

    /// Groups events by position, keeping their recorded order.
    pub fn indexEvents(self: *Lifetimes) !void {
        var last = self.flow_statement_count;
        for (self.events.items) |event| last = @max(last, event.position);
        self.event_index.clearRetainingCapacity();
        try self.event_index.appendNTimes(self.allocator, 0, last + 2);
        for (self.events.items) |event| self.event_index.items[event.position + 1] += 1;
        for (1..self.event_index.items.len) |index| self.event_index.items[index] += self.event_index.items[index - 1];
        try self.sorted_events.resize(self.allocator, self.events.items.len);
        const cursor = try self.allocator.dupe(usize, self.event_index.items);
        defer self.allocator.free(cursor);
        for (self.events.items) |event| {
            self.sorted_events.items[cursor[event.position]] = event;
            cursor[event.position] += 1;
        }
    }

    fn eventsAt(self: *const Lifetimes, position: usize) []const Event {
        if (position + 1 >= self.event_index.items.len) return &.{};
        return self.sorted_events.items[self.event_index.items[position]..self.event_index.items[position + 1]];
    }

    fn isFlowPosition(self: *const Lifetimes, position: usize) bool {
        return position != 0 and position <= self.flow_statement_count;
    }

    pub fn valueLivesAcross(self: *const Lifetimes, name: []const u8, position: usize) bool {
        if (!self.isFlowPosition(position)) return false;
        var visited = std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.flow_statement_count + 1) catch return true;
        defer visited.deinit(self.allocator);
        return self.readBeforeWrite(name, position, &visited);
    }

    /// Whether some path from `position` reads `name` before writing it.
    pub fn readBeforeWrite(self: *const Lifetimes, name: []const u8, position: usize, visited: *std.DynamicBitSetUnmanaged) bool {
        if (!self.isFlowPosition(position) or visited.isSet(position)) return false;
        visited.set(position);
        if (self.firstEventAt(name, position)) |kind| return kind == .read;
        for (self.successorsOf(position)) |successor| {
            if (self.readBeforeWrite(name, successor, visited)) return true;
        }
        return false;
    }

    /// The decisive event for `name` at a position: a callee definition
    /// wins, else the first read or write recorded there.
    fn firstEventAt(self: *const Lifetimes, name: []const u8, position: usize) ?EventKind {
        const events = self.eventsAt(position);
        for (events) |event| {
            if (event.kind == .output_write and std.mem.eql(u8, event.name, name)) return .output_write;
        }
        for (events) |event| {
            if (std.mem.eql(u8, event.name, name)) return event.kind;
        }
        return null;
    }

    pub fn successorsOf(self: *const Lifetimes, position: usize) []const usize {
        return self.successors.items[position][0..self.successor_counts.items[position]];
    }

    pub fn valueDefinedAt(self: *const Lifetimes, name: []const u8, position: usize) bool {
        for (self.eventsAt(position)) |event| {
            if (event.kind != .read and std.mem.eql(u8, event.name, name)) return true;
        }
        return false;
    }

    /// Rejects values a path may read before any assignment.
    pub fn firstUnassignedRead(self: *const Lifetimes) !?[]const u8 {
        if (!self.reuse) return null;
        for (self.lifetimes.items) |lifetime| {
            if (lifetime.initially_defined) continue;
            var visited = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.flow_statement_count + 1);
            defer visited.deinit(self.allocator);
            if (self.readBeforeWrite(lifetime.name, lifetime.declaration, &visited)) return lifetime.name;
        }
        return null;
    }

    pub fn lastUse(self: *const Lifetimes, name: []const u8) usize {
        if (!self.reuse) return std.math.maxInt(usize);
        const lifetime = self.findConst(name) orelse return std.math.maxInt(usize);
        return lifetime.last_use;
    }

    pub fn firstLive(self: *const Lifetimes, name: []const u8) usize {
        if (!self.reuse) return 0;
        const lifetime = self.findConst(name) orelse return 0;
        return lifetime.first_live;
    }

    /// Asks an automatic value to live in a call's parameter register.
    /// Returns false when that conflicts with an earlier request or a pin.
    pub fn requireRegister(self: *Lifetimes, name: []const u8, reg: ?Register, vector_reg: ?VReg) bool {
        const lifetime = self.find(name) orelse return false;
        if (!lifetime.automatic) return lifetime.fixed_reg == reg and lifetime.fixed_vector_reg == vector_reg;
        if (conflictingRequirement(lifetime.*, reg, vector_reg)) return false;
        lifetime.required_reg = reg;
        lifetime.required_vector_reg = vector_reg;
        return true;
    }

    fn conflictingRequirement(lifetime: Lifetime, reg: ?Register, vector_reg: ?VReg) bool {
        if (lifetime.required_reg != null and lifetime.required_reg != reg) return true;
        return lifetime.required_vector_reg != null and lifetime.required_vector_reg != vector_reg;
    }

    pub fn requiredRegister(self: *const Lifetimes, name: []const u8) ?Register {
        const lifetime = self.findFirst(name) orelse return null;
        return lifetime.required_reg;
    }

    pub fn requiredVectorRegister(self: *const Lifetimes, name: []const u8) ?VReg {
        const lifetime = self.findFirst(name) orelse return null;
        return lifetime.required_vector_reg;
    }

    pub fn registerForbidden(self: *const Lifetimes, name: []const u8, reg: Register) bool {
        const lifetime = self.findFirst(name) orelse return false;
        return lifetime.forbidden_scalar & registerBit(reg) != 0;
    }

    pub fn vectorRegisterForbidden(self: *const Lifetimes, name: []const u8, reg: VReg) bool {
        const lifetime = self.findFirst(name) orelse return false;
        return lifetime.forbidden_vector & vectorRegisterBit(reg) != 0;
    }

    /// Whether a value pinned to `reg` is live at the same time as `name`,
    /// including one declared later; automatic values must avoid it.
    /// Without reuse, ranges are unknown and the in-scope checks decide.
    pub fn pinnedOverlaps(self: *const Lifetimes, name: []const u8, reg: Pinned) bool {
        if (!self.reuse) return false;
        const own = self.findFirst(name) orelse return false;
        for (self.lifetimes.items) |other| {
            if (pinnedConflict(own, other, reg)) return true;
        }
        return false;
    }

    /// `other` holds `reg` while `own` is live: pinned there, or an
    /// automatic value required there that `own` does not also want.
    fn pinnedConflict(own: Lifetime, other: Lifetime, reg: Pinned) bool {
        if (std.mem.eql(u8, other.name, own.name) or !claims(own, other, reg)) return false;
        return own.first_live <= other.last_use and other.first_live <= own.last_use;
    }

    fn claims(own: Lifetime, other: Lifetime, reg: Pinned) bool {
        if (!other.automatic) return reg.heldBy(other);
        return reg.requiredBy(other) and !reg.requiredBy(own);
    }

    /// Whether a lifetime is live after `call` returns without the call
    /// itself defining it.
    pub fn livesAcrossCall(self: *const Lifetimes, lifetime: Lifetime, call: Call) bool {
        if (lifetime.reserved) return true;
        if (lifetime.declaration >= call.resume_position) return false;
        if (!self.valueLivesAcross(lifetime.name, call.resume_position)) return false;
        return !self.valueDefinedAt(lifetime.name, call.position);
    }
};

const testing = std.testing;

test "liveness follows successors and stops at writes" {
    var lifetimes = Lifetimes.init(testing.allocator);
    defer lifetimes.deinit();
    lifetimes.reuse = true;
    lifetimes.flow_statement_count = 3;
    try lifetimes.successors.appendNTimes(testing.allocator, .{ 0, 0 }, 4);
    try lifetimes.successor_counts.appendNTimes(testing.allocator, 0, 4);
    lifetimes.successors.items[1] = .{ 2, 0 };
    lifetimes.successor_counts.items[1] = 1;
    lifetimes.successors.items[2] = .{ 3, 0 };
    lifetimes.successor_counts.items[2] = 1;
    try lifetimes.declare(.{ .name = "x", .position = 1, .automatic = true, .initially_defined = false, .data_type = .u32 });
    try lifetimes.write("x", 2);
    try lifetimes.read("x", 3);
    try lifetimes.writeOutput("y", 3);
    try lifetimes.read("y", 3);
    try lifetimes.indexEvents();
    try testing.expect(lifetimes.valueLivesAcross("x", 3));
    try testing.expect(!lifetimes.valueLivesAcross("x", 2));
    try testing.expect(!lifetimes.valueLivesAcross("y", 3));
    try testing.expect(!lifetimes.valueLivesAcross("x", 0));
    try testing.expect(lifetimes.valueDefinedAt("x", 2) and !lifetimes.valueDefinedAt("x", 3));
    try testing.expectEqual(@as(?[]const u8, null), try lifetimes.firstUnassignedRead());
    try testing.expectEqual(@as(usize, 3), lifetimes.lastUse("x"));
    try testing.expectEqual(@as(usize, 2), lifetimes.firstLive("x"));
    try testing.expect(lifetimes.requireRegister("x", .t0, null));
    try testing.expect(!lifetimes.requireRegister("x", .t1, null));
    try testing.expect(!lifetimes.requireRegister("missing", .t1, null));
    try testing.expectEqual(@as(?Register, .t0), lifetimes.requiredRegister("x"));
    try testing.expectEqual(@as(?VReg, null), lifetimes.requiredVectorRegister("x"));
    try testing.expect(!lifetimes.registerForbidden("x", .t0) and !lifetimes.vectorRegisterForbidden("missing", .v01));
    try testing.expectEqual(@as(usize, 0), lifetimes.labelPosition("none"));
}

test "unassigned reads and backward edges extend lifetimes" {
    var lifetimes = Lifetimes.init(testing.allocator);
    defer lifetimes.deinit();
    lifetimes.reuse = true;
    lifetimes.flow_statement_count = 2;
    try lifetimes.successors.appendNTimes(testing.allocator, .{ 2, 0 }, 3);
    try lifetimes.successor_counts.appendNTimes(testing.allocator, 1, 3);
    try lifetimes.declare(.{ .name = "x", .position = 1, .automatic = true, .initially_defined = false, .data_type = .u32 });
    try lifetimes.read("x", 2);
    try lifetimes.addLabel("top", 1, false);
    try lifetimes.addEdge("top", 2);
    try lifetimes.addEdge("missing", 2);
    try lifetimes.addCall("f", 1, 2);
    lifetimes.addCallSetup(1, 1, 2);
    lifetimes.addCallSetup(9, 1, 2);
    try testing.expectEqual(@as(u32, 1), lifetimes.calls.items[0].setup_scalar);
    lifetimes.extendBackwardEdges();
    try lifetimes.indexEvents();
    try testing.expectEqualStrings("x", (try lifetimes.firstUnassignedRead()).?);
    try testing.expect(lifetimes.has("x") and !lifetimes.has("y"));
    lifetimes.reuse = false;
    try testing.expectEqual(@as(usize, std.math.maxInt(usize)), lifetimes.lastUse("x"));
    try testing.expectEqual(@as(usize, 0), lifetimes.firstLive("x"));
    lifetimes.reset();
    try testing.expectEqual(@as(usize, 0), lifetimes.lifetimes.items.len);
}
