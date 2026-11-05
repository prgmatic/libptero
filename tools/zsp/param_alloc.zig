//! Chooses registers for the unpinned parameters of internal functions.
//!
//! Only exported functions, command handlers, external declarations, and
//! functions whose address is taken have a fixed calling convention. For
//! every other function, each unpinned parameter takes the register its call
//! sites already hold the argument in, so no argument move is needed,
//! avoiding registers the function's own pins, other parameters, and callees
//! use. Without a usable vote, scalars keep their `$a0`-`$a3` default and
//! other parameters take the first free register.
const std = @import("std");
const ast = @import("ast.zig");
const ast_walk = @import("ast_walk.zig");
const registers = @import("registers.zig");
const FunctionClobberRegistry = @import("clobbers.zig").FunctionClobberRegistry;

const Statement = ast.Statement;
const Register = ast.Register;
const VReg = ast.VectorRegister;
const registerBit = registers.registerBit;
const vectorRegisterBit = registers.vectorRegisterBit;

const all_delays = ast_walk.DelaySet.initFull();

/// Scalar registers a parameter may use, in preference order.
const scalar_candidates = [_]Register{ .a0, .a1, .a2, .a3, .v0 } ++ registers.alloc_scalar_registers;

/// Returns `functions` with every automatic parameter assigned. The result
/// and any rewritten parameter lists are allocated with `allocator`.
pub fn assign(allocator: std.mem.Allocator, functions: []const ast.Function) ![]const ast.Function {
    if (!hasAutomaticParameters(functions)) return functions;
    const result = try allocator.dupe(ast.Function, functions);
    for (result) |*function| try assignProvisional(allocator, function);
    var registry = FunctionClobberRegistry.init(allocator, result, null) catch return result;
    defer registry.deinit();
    for (result) |*function| {
        if (choosesParameters(result, function.*)) try chooseParameters(allocator, result, function, &registry);
    }
    return result;
}

fn hasAutomaticParameters(functions: []const ast.Function) bool {
    for (functions) |function| {
        for (function.parameters) |parameter| if (parameter.automatic) return true;
    }
    return false;
}

/// Internal functions get chosen registers; an inline expansion binds each
/// parameter to its argument instead.
fn choosesParameters(functions: []const ast.Function, function: ast.Function) bool {
    return !function.inline_call and isInternal(functions, function);
}

fn isInternal(functions: []const ast.Function, function: ast.Function) bool {
    if (function.export_symbol or function.external or function.command_indices.len != 0) return false;
    return !addressTaken(functions, function.name);
}

// ----------------------------------------------------------- register sets

/// Registers taken in one function, as scalar and vector masks.
const Mask = struct {
    scalar: u32 = 0,
    vector: u32 = 0,

    fn add(self: *Mask, parameter: ast.Parameter) void {
        if (parameter.reg) |reg| self.scalar |= registerBit(reg);
        if (parameter.vector_reg) |reg| self.vector |= vectorBits(parameter.data_type, reg);
    }

    fn merge(self: *Mask, other: Mask) void {
        self.scalar |= other.scalar;
        self.vector |= other.vector;
    }
};

fn vectorBits(data_type: ast.DataType, reg: VReg) u32 {
    var bits = vectorRegisterBit(reg);
    if (data_type == .vec32) {
        if (registers.nextVectorRegister(reg)) |second| bits |= vectorRegisterBit(second);
    }
    return bits;
}

/// Registers pinned anywhere in a function body.
fn pinnedRegisters(function: ast.Function) Mask {
    var mask: Mask = .{};
    ast_walk.each(function.statements, all_delays, &mask, addPin);
    return mask;
}

fn addPin(mask: *Mask, statement: *const Statement) void {
    if (statement.* != .var_decl) return;
    const decl = statement.var_decl;
    if (decl.reg) |reg| mask.scalar |= registerBit(reg);
    if (decl.vector_reg) |reg| mask.vector |= vectorBits(decl.data_type, reg);
}

/// Registers written by everything the function transfers to.
fn calleeWrites(function: ast.Function, registry: *const FunctionClobberRegistry) Mask {
    var collector: CalleeWrites = .{ .registry = registry };
    ast_walk.each(function.statements, all_delays, &collector, CalleeWrites.visit);
    return collector.mask;
}

const CalleeWrites = struct {
    registry: *const FunctionClobberRegistry,
    mask: Mask = .{},

    fn visit(self: *CalleeWrites, statement: *const Statement) void {
        const site = callSite(statement) orelse return;
        const entry = self.registry.find(site.target) orelse return;
        self.mask.scalar |= entry.scalar;
        self.mask.vector |= entry.vector;
    }
};

// -------------------------------------------------------------- call sites

const CallSite = struct { target: []const u8, arguments: []const ast.ValueRef };

/// A transfer that passes arguments to a named local function.
fn callSite(statement: *const Statement) ?CallSite {
    return switch (statement.*) {
        .call => |call| if (call.module == null) .{ .target = call.name, .arguments = call.arguments } else null,
        .conditional_direct_goto => |branch| typedSite(branch.typed, branch.target, branch.arguments),
        .builtin => |builtin| builtinSite(builtin),
        else => null,
    };
}

fn builtinSite(builtin: ast.Builtin) ?CallSite {
    return switch (builtin) {
        .tail => |tail| typedSite(true, tail.target, tail.arguments),
        .direct_goto => |branch| typedSite(branch.typed, branch.target, branch.arguments),
        else => null,
    };
}

fn typedSite(typed: bool, target: ast.FunctionRef, arguments: []const ast.ValueRef) ?CallSite {
    if (!typed or target.module != null) return null;
    return .{ .target = target.name, .arguments = arguments };
}

/// Counts, per register, the call sites passing parameter `index` in it.
const Votes = struct {
    target: []const u8,
    index: usize,
    caller: ast.Function = undefined,
    scalar: [32]u16 = @splat(0),
    vector: [32]u16 = @splat(0),

    fn collect(self: *Votes, functions: []const ast.Function) void {
        for (functions) |function| {
            self.caller = function;
            ast_walk.each(function.statements, all_delays, self, visit);
        }
    }

    fn visit(self: *Votes, statement: *const Statement) void {
        const site = callSite(statement) orelse return;
        const name = self.argumentName(site) orelse return;
        const binding = declaredBinding(self.caller, name) orelse return;
        if (binding.reg) |reg| self.scalar[@intFromEnum(reg)] += 1;
        if (binding.vector_reg) |reg| self.vector[@intFromEnum(reg)] += 1;
    }

    /// The variable this site passes as the counted parameter, if any.
    fn argumentName(self: *const Votes, site: CallSite) ?[]const u8 {
        if (!std.mem.eql(u8, site.target, self.target) or self.index >= site.arguments.len) return null;
        const argument = site.arguments[self.index];
        return if (argument == .ident) argument.ident else null;
    }
};

const Binding = struct { reg: ?Register = null, vector_reg: ?VReg = null };

/// The register a caller's parameter or pinned local named `name` lives in.
fn declaredBinding(function: ast.Function, name: []const u8) ?Binding {
    for (function.parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, name)) return .{ .reg = parameter.reg, .vector_reg = parameter.vector_reg };
    }
    var search: DeclarationSearch = .{ .name = name };
    _ = ast_walk.anyWith(function.statements, all_delays, &search, DeclarationSearch.visit);
    return search.found;
}

const DeclarationSearch = struct {
    name: []const u8,
    found: ?Binding = null,

    fn visit(self: *DeclarationSearch, statement: *const Statement) bool {
        if (statement.* != .var_decl or !std.mem.eql(u8, statement.var_decl.name, self.name)) return false;
        const decl = statement.var_decl;
        if (decl.reg == null and decl.vector_reg == null) return false;
        self.found = .{ .reg = decl.reg, .vector_reg = decl.vector_reg };
        return true;
    }
};

// ---------------------------------------------------------------- choosing

/// Gives parameters without a default a register so analysis can run.
fn assignProvisional(allocator: std.mem.Allocator, function: *ast.Function) !void {
    if (!needsProvisional(function.parameters)) return;
    const parameters = try allocator.dupe(ast.Parameter, function.parameters);
    var taken = pinnedRegisters(function.*);
    for (parameters) |parameter| taken.add(parameter);
    for (parameters) |*parameter| {
        if (parameter.reg != null or parameter.vector_reg != null) continue;
        try takeFirstFree(parameter, &taken);
    }
    function.parameters = parameters;
}

fn needsProvisional(parameters: []const ast.Parameter) bool {
    for (parameters) |parameter| {
        if (parameter.reg == null and parameter.vector_reg == null) return true;
    }
    return false;
}

fn takeFirstFree(parameter: *ast.Parameter, taken: *Mask) !void {
    if (isVector(parameter.data_type)) {
        parameter.vector_reg = firstFreeVector(parameter.data_type, taken.*, null) orelse return error.OutOfFreeVectorRegisters;
    } else {
        parameter.reg = firstFreeScalar(taken.*, null) orelse return error.OutOfFreeRegisters;
    }
    taken.add(parameter.*);
}

fn isVector(data_type: ast.DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

fn chooseParameters(allocator: std.mem.Allocator, functions: []const ast.Function, function: *ast.Function, registry: *const FunctionClobberRegistry) !void {
    var avoid = pinnedRegisters(function.*);
    avoid.merge(calleeWrites(function.*, registry));
    var taken: Mask = .{};
    for (function.parameters) |parameter| {
        if (!parameter.automatic) taken.add(parameter);
    }
    const parameters = try allocator.dupe(ast.Parameter, function.parameters);
    for (parameters, 0..) |*parameter, index| {
        if (!parameter.automatic) continue;
        var votes: Votes = .{ .target = function.name, .index = index };
        votes.collect(functions);
        choose(parameter, votes, avoid, &taken);
    }
    function.parameters = parameters;
}

/// The most-voted usable register, else the current one when usable, else
/// the first free one. An unusable current register is kept as a last
/// resort so analysis reports the conflict.
fn choose(parameter: *ast.Parameter, votes: Votes, avoid: Mask, taken: *Mask) void {
    var blocked = taken.*;
    blocked.merge(avoid);
    if (isVector(parameter.data_type)) {
        parameter.vector_reg = bestVector(parameter.*, votes, blocked) orelse parameter.vector_reg;
    } else {
        parameter.reg = bestScalar(parameter.*, votes, blocked) orelse parameter.reg;
    }
    taken.add(parameter.*);
}

fn bestScalar(parameter: ast.Parameter, votes: Votes, blocked: Mask) ?Register {
    if (firstFreeScalar(blocked, votes.scalar)) |reg| {
        if (votes.scalar[@intFromEnum(reg)] != 0) return reg;
    }
    const current = parameter.reg orelse return firstFreeScalar(blocked, null);
    if (blocked.scalar & registerBit(current) == 0) return current;
    return firstFreeScalar(blocked, null);
}

fn bestVector(parameter: ast.Parameter, votes: Votes, blocked: Mask) ?VReg {
    if (firstFreeVector(parameter.data_type, blocked, votes.vector)) |reg| {
        if (votes.vector[@intFromEnum(reg)] != 0) return reg;
    }
    const current = parameter.vector_reg orelse return firstFreeVector(parameter.data_type, blocked, null);
    if (blocked.vector & vectorBits(parameter.data_type, current) == 0) return current;
    return firstFreeVector(parameter.data_type, blocked, null);
}

/// The free register with the most votes, or the first free one.
fn firstFreeScalar(blocked: Mask, votes: ?[32]u16) ?Register {
    var best: ?Register = null;
    for (scalar_candidates) |reg| {
        if (blocked.scalar & registerBit(reg) != 0) continue;
        if (best == null or voteCount(votes, @intFromEnum(reg)) > voteCount(votes, @intFromEnum(best.?))) best = reg;
    }
    return best;
}

fn firstFreeVector(data_type: ast.DataType, blocked: Mask, votes: ?[32]u16) ?VReg {
    var best: ?VReg = null;
    for (registers.alloc_vector_registers) |reg| {
        if (!vectorFits(data_type, reg, blocked)) continue;
        if (best == null or voteCount(votes, @intFromEnum(reg)) > voteCount(votes, @intFromEnum(best.?))) best = reg;
    }
    return best;
}

fn vectorFits(data_type: ast.DataType, reg: VReg, blocked: Mask) bool {
    if (data_type == .vec32 and @intFromEnum(reg) >= 28) return false;
    return blocked.vector & vectorBits(data_type, reg) == 0;
}

fn voteCount(votes: ?[32]u16, index: usize) u16 {
    const counts = votes orelse return 0;
    return counts[index];
}

// --------------------------------------------------------- address taking

/// Functions used as values must keep the structural calling convention.
fn addressTaken(functions: []const ast.Function, name: []const u8) bool {
    for (functions) |function| {
        if (ast_walk.anyWith(function.statements, all_delays, name, takesAddress)) return true;
    }
    return false;
}

fn takesAddress(name: []const u8, statement: *const Statement) bool {
    const value = assignedValue(statement) orelse return false;
    return addresses(value, name);
}

fn assignedValue(statement: *const Statement) ?ast.Value {
    return switch (statement.*) {
        .var_decl => |decl| decl.value,
        .assignment => |assignment| assignment.lhs,
        else => null,
    };
}

fn addresses(value: ast.Value, name: []const u8) bool {
    return switch (value) {
        .function_address => |target| std.mem.eql(u8, target.name, name),
        .code_address => |address| std.mem.eql(u8, address.label, name),
        else => false,
    };
}

const testing = std.testing;

fn parseAndAssign(arena: std.mem.Allocator, source: []const u8) ![]const ast.Function {
    var parser = try @import("parser.zig").Parser.init(arena, source);
    return assign(arena, try parser.parse());
}

test "unpinned parameters take the register their callers use" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const functions = try parseAndAssign(arena.allocator(),
        \\fn scale(value: u32, vector: vec16) { rsp.cp0.setSpStatus(value); }
        \\fn entry() {
        \\  reg($t5) count: u32 = 3;
        \\  reg($v07) data: vec16 = 0;
        \\  scale(count, data);
        \\}
    );
    try testing.expectEqual(@as(?Register, .t5), functions[0].parameters[0].reg);
    try testing.expectEqual(@as(?VReg, .v07), functions[0].parameters[1].vector_reg);
}

test "boundaries keep their convention and conflicts fall back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const functions = try parseAndAssign(arena.allocator(),
        \\export fn visible(value: u32) { rsp.cp0.setSpStatus(value); }
        \\fn pointed(value: u32) { rsp.cp0.setSpStatus(value); }
        \\fn pinned(value: u32) { reg($t5) other: u32 = 1; rsp.cp0.setSpStatus(other); rsp.cp0.setSpStatus(value); }
        \\fn wide(value: vec32) { rsp.nop(); }
        \\fn entry() {
        \\  reg($t5) count: u32 = 3;
        \\  reg target: fn(u32) = &pointed;
        \\  visible(count);
        \\  pinned(count);
        \\  reg($v01) pair: vec32 = 0;
        \\  wide(pair);
        \\}
    );
    try testing.expectEqual(@as(?Register, .a0), functions[0].parameters[0].reg);
    try testing.expectEqual(@as(?Register, .a0), functions[1].parameters[0].reg);
    try testing.expectEqual(@as(?Register, .a0), functions[2].parameters[0].reg);
    try testing.expectEqual(@as(?VReg, .v01), functions[3].parameters[0].vector_reg);
}

test "tail calls and typed branches vote like calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const functions = try parseAndAssign(arena.allocator(),
        \\fn finish(value: u32) noreturn { rsp.cp0.setSpStatus(value); rsp.halt(); }
        \\fn entry() noreturn {
        \\  reg($t6) count: u32 = 3;
        \\  tail finish(count);
        \\}
    );
    try testing.expectEqual(@as(?Register, .t6), functions[0].parameters[0].reg);
}

test "vector choices respect pairs and votes" {
    try testing.expect(!vectorFits(.vec32, .v28, .{}));
    try testing.expect(vectorFits(.vec16, .v28, .{}));
    try testing.expectEqual(@as(u16, 0), voteCount(null, 3));
    var votes: [32]u16 = @splat(0);
    votes[9] = 2;
    try testing.expectEqual(@as(?Register, .t1), firstFreeScalar(.{}, votes));
    try testing.expectEqual(@as(?Register, .a0), firstFreeScalar(.{}, null));
    try testing.expectEqual(@as(?Register, null), firstFreeScalar(.{ .scalar = std.math.maxInt(u32) }, null));
}
