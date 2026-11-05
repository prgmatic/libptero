//! Applies each transfer's parameter contract to the caller's lifetimes:
//! automatic arguments are asked to live in their parameter registers, other
//! arguments make the call's setup write those registers, and parameters the
//! callee writes redefine the caller's value.
const std = @import("std");
const ast = @import("ast.zig");
const ast_walk = @import("ast_walk.zig");
const lifetimes_ = @import("lifetimes.zig");
const registers = @import("registers.zig");

const Lifetimes = lifetimes_.Lifetimes;
const Statement = ast.Statement;
const Tag = std.meta.Tag(Statement);
const Diagnostic = @import("explain.zig").Diagnostic;

pub const ParameterWriteVisit = struct { function: []const u8, parameter: usize };

pub const Requirements = struct {
    lifetimes: *Lifetimes,
    functions: []const ast.Function,
    diagnostic: ?*Diagnostic = null,
    /// The program diagnostics locate statements in.
    program: []const ast.Function = &.{},
    position: usize = 0,

    pub fn statements(self: *Requirements, list: []const Statement) anyerror!void {
        for (list) |*statement| {
            if (self.diagnostic) |diagnostic| diagnostic.selectStatement(self.program, statement);
            self.position += 1;
            try handlers.get(std.meta.activeTag(statement.*))(self, statement, self.position);
        }
    }

    fn optional(self: *Requirements, list: ?[]const Statement) !void {
        try self.statements(list orelse return);
    }

    /// The local callee whose signature matches the argument count.
    fn callee(self: *const Requirements, target: ast.FunctionRef, arguments: []const ast.ValueRef) ?ast.Function {
        if (target.module != null) return null;
        const function = findFunction(self.functions, target.name) orelse return null;
        return if (function.parameters.len == arguments.len) function else null;
    }

    fn setupClobber(self: *Requirements, position: usize, parameter: ast.Parameter) void {
        self.lifetimes.addCallSetup(position, parameterRegisterBits(parameter), parameterVectorBits(parameter));
    }

    /// Coalesces a named argument into the parameter register when it can;
    /// otherwise the call's setup writes the register.
    fn require(self: *Requirements, position: usize, name: []const u8, parameter: ast.Parameter) void {
        if (!self.lifetimes.requireRegister(name, parameter.reg, parameter.vector_reg)) self.setupClobber(position, parameter);
    }
};

pub fn findFunction(functions: []const ast.Function, name: []const u8) ?ast.Function {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn parameterRegisterBits(parameter: ast.Parameter) u32 {
    const reg = parameter.reg orelse return 0;
    return registers.registerBit(reg);
}

fn parameterVectorBits(parameter: ast.Parameter) u32 {
    const reg = parameter.vector_reg orelse return 0;
    var bits = registers.vectorRegisterBit(reg);
    if (parameter.data_type == .vec32) {
        if (registers.nextVectorRegister(reg)) |second| bits |= registers.vectorRegisterBit(second);
    }
    return bits;
}

const Handler = *const fn (*Requirements, *const Statement, usize) anyerror!void;

/// Statement kinds whose nested lists hold further requirements, in order.
const handlers = blk: {
    var table = std.EnumArray(Tag, Handler).initFill(&ignore);
    table.set(.call, &call);
    table.set(.goto, &delayOnly);
    table.set(.conditional_goto, &delayOnly);
    table.set(.conditional_direct_goto, &conditionalDirectGoto);
    table.set(.break_loop, &delayOnly);
    table.set(.do_while_loop, &doWhileLoop);
    table.set(.if_statement, &ifStatement);
    table.set(.labeled_block, &labeledBlock);
    table.set(.ordered_block, &orderedBlock);
    table.set(.builtin, &builtin);
    break :blk table;
};

fn ignore(_: *Requirements, _: *const Statement, _: usize) !void {}

fn delayOnly(requirements: *Requirements, statement: *const Statement, _: usize) !void {
    try requirements.optional(ast_walk.delaySlot(statement));
}

fn call(requirements: *Requirements, statement: *const Statement, current: usize) !void {
    const item = statement.call;
    if (requirements.callee(.{ .module = item.module, .name = item.name }, item.arguments)) |function| {
        for (item.arguments, function.parameters, 0..) |argument, parameter, index| {
            try callArgument(requirements, current, function, index, argument, parameter);
        }
    }
    try requirements.optional(item.delay_slot);
}

fn callArgument(requirements: *Requirements, current: usize, function: ast.Function, index: usize, argument: ast.ValueRef, parameter: ast.Parameter) !void {
    if (function.bindsArgument(parameter)) return boundArgument(requirements, current, function, index, argument);
    switch (argument) {
        .ident => |name| try namedCallArgument(requirements, current, function, index, name, parameter),
        .number => requirements.setupClobber(current, parameter),
        else => {},
    }
}

/// An argument an inline parameter names is used in place: no register is
/// required, but the expansion's writes still redefine it.
fn boundArgument(requirements: *Requirements, current: usize, function: ast.Function, index: usize, argument: ast.ValueRef) !void {
    if (argument != .ident or !requirements.lifetimes.has(argument.ident)) return;
    try trackParameterWrites(requirements, current, function, index, argument.ident);
}

fn namedCallArgument(requirements: *Requirements, current: usize, function: ast.Function, index: usize, name: []const u8, parameter: ast.Parameter) !void {
    if (!requirements.lifetimes.has(name)) return requirements.setupClobber(current, parameter);
    requirements.require(current, name, parameter);
    try trackParameterWrites(requirements, current, function, index, name);
}

/// A parameter the callee writes redefines the caller's value; an in/out
/// parameter also reads it first.
fn trackParameterWrites(requirements: *Requirements, current: usize, function: ast.Function, index: usize, name: []const u8) !void {
    if (!parameterIsWrittenByCall(requirements.functions, function, index)) return;
    if (parameterIsLiveIn(requirements.lifetimes.allocator, function, index)) return requirements.lifetimes.write(name, current);
    try requirements.lifetimes.writeOutput(name, current);
}

fn parameterIsWrittenByCall(functions: []const ast.Function, function: ast.Function, index: usize) bool {
    var visited: [1024]ParameterWriteVisit = undefined;
    var visited_count: usize = 0;
    if (functionParameterIsWritten(functions, function, index, &visited, &visited_count)) return true;
    return function.external and contractWritesParameter(function, function.parameters[index]);
}

fn contractWritesParameter(function: ast.Function, parameter: ast.Parameter) bool {
    if (parameter.reg) |reg| {
        if (std.mem.indexOfScalar(ast.Register, function.clobber_regs, reg) != null) return true;
    }
    const vector = parameter.vector_reg orelse return false;
    return std.mem.indexOfScalar(ast.VectorRegister, function.clobber_vector_regs, vector) != null;
}

fn conditionalDirectGoto(requirements: *Requirements, statement: *const Statement, current: usize) !void {
    const branch = statement.conditional_direct_goto;
    if (branch.typed) try typedArguments(requirements, current, branch.target, branch.arguments, true);
    try requirements.optional(branch.delay_slot);
}

/// Jump arguments coalesce like call arguments. Conditional jumps also
/// count constants and unknown names as setup writes.
fn typedArguments(requirements: *Requirements, current: usize, target: ast.FunctionRef, arguments: []const ast.ValueRef, count_setup: bool) !void {
    const function = requirements.callee(target, arguments) orelse return;
    for (arguments, function.parameters) |argument, parameter| {
        jumpArgument(requirements, current, argument, parameter, count_setup);
    }
}

/// A tracked value must arrive in the parameter's register; anything else
/// the jump materializes there clobbers it.
fn jumpArgument(requirements: *Requirements, current: usize, argument: ast.ValueRef, parameter: ast.Parameter, count_setup: bool) void {
    if (trackedName(requirements, argument)) |name| return requirements.require(current, name, parameter);
    if (count_setup and materialized(argument)) requirements.setupClobber(current, parameter);
}

fn materialized(argument: ast.ValueRef) bool {
    return argument == .ident or argument == .number;
}

fn trackedName(requirements: *const Requirements, argument: ast.ValueRef) ?[]const u8 {
    if (argument != .ident or !requirements.lifetimes.has(argument.ident)) return null;
    return argument.ident;
}

/// The loop condition has its own position after the body.
fn doWhileLoop(requirements: *Requirements, statement: *const Statement, _: usize) !void {
    try requirements.statements(statement.do_while_loop.statements);
    requirements.position += 1;
    try requirements.optional(statement.do_while_loop.delay_slot);
}

fn ifStatement(requirements: *Requirements, statement: *const Statement, _: usize) !void {
    const branch = statement.if_statement;
    try requirements.optional(branch.delay_slot);
    try requirements.statements(branch.then_statements);
    try requirements.optional(branch.else_statements);
}

fn labeledBlock(requirements: *Requirements, statement: *const Statement, _: usize) !void {
    try requirements.statements(statement.labeled_block.statements);
    try requirements.optional(statement.labeled_block.exit_delay);
}

fn orderedBlock(requirements: *Requirements, statement: *const Statement, _: usize) !void {
    try requirements.statements(statement.ordered_block);
}

fn builtin(requirements: *Requirements, statement: *const Statement, current: usize) !void {
    const item = statement.builtin;
    switch (item) {
        .direct_goto => |branch| if (branch.typed) try typedArguments(requirements, current, branch.target, branch.arguments, false),
        .tail => |transfer| try typedArguments(requirements, current, transfer.target, transfer.arguments, false),
        .jump, .return_from_function => {},
        else => return,
    }
    try requirements.optional(ast_walk.builtinDelaySlot(&item));
}

// ------------------------------------------------------ parameter writes

/// Whether a function body, transitively through the calls it passes the
/// parameter to, may write a parameter.
pub fn functionParameterIsWritten(
    functions: []const ast.Function,
    function: ast.Function,
    parameter_index: usize,
    visited: *[1024]ParameterWriteVisit,
    visited_count: *usize,
) bool {
    if (parameter_index >= function.parameters.len or visited_count.* >= visited.len) return true;
    if (function.external and contractWritesParameter(function, function.parameters[parameter_index])) return true;
    if (alreadyVisited(visited[0..visited_count.*], function.name, parameter_index)) return false;
    visited[visited_count.*] = .{ .function = function.name, .parameter = parameter_index };
    visited_count.* += 1;
    var search: WriteSearch = .{
        .functions = functions,
        .name = function.parameters[parameter_index].name,
        .visited = visited,
        .visited_count = visited_count,
    };
    return ast_walk.anyWith(function.statements, write_search_delays, &search, WriteSearch.writes);
}

fn alreadyVisited(visited: []const ParameterWriteVisit, function: []const u8, parameter: usize) bool {
    for (visited) |item| {
        if (item.parameter == parameter and std.mem.eql(u8, item.function, function)) return true;
    }
    return false;
}

const write_search_delays = ast_walk.DelaySet.initMany(&.{
    .call, .goto, .conditional_goto, .conditional_direct_goto, .break_loop, .jump, .return_from_function,
});

const WriteSearch = struct {
    functions: []const ast.Function,
    name: []const u8,
    visited: *[1024]ParameterWriteVisit,
    visited_count: *usize,

    fn writes(self: *WriteSearch, statement: *const Statement) bool {
        return switch (statement.*) {
            .assignment => |item| std.mem.eql(u8, item.destination, self.name),
            .call => |item| self.passedToWriter(item),
            .builtin => |item| loadsNamedVector(item, self.name),
            else => false,
        };
    }

    /// Passing the parameter on to a callee that writes it writes it too.
    fn passedToWriter(self: *WriteSearch, item: ast.Call) bool {
        if (item.module != null) return false;
        const target = findFunction(self.functions, item.name) orelse return false;
        for (item.arguments, 0..) |argument, index| {
            if (self.passes(argument) and functionParameterIsWritten(self.functions, target, index, self.visited, self.visited_count)) return true;
        }
        return false;
    }

    fn passes(self: *const WriteSearch, argument: ast.ValueRef) bool {
        return argument == .ident and std.mem.eql(u8, argument.ident, self.name);
    }
};

fn loadsNamedVector(item: ast.Builtin, name: []const u8) bool {
    if (item != .vector_memory) return false;
    const memory = item.vector_memory;
    return @import("lifetime_scan.zig").isVectorLoad(memory.operation) and std.mem.eql(u8, memory.vector.name, name);
}

/// Whether the callee may read a parameter's incoming value. Bodies the
/// lifetime analysis cannot follow are assumed to. The body is analyzed
/// without its own callees, so their arguments count as reads.
///
/// External functions only declare which registers they write, so their
/// written parameters keep the convention of pure outputs.
pub fn parameterIsLiveIn(allocator: std.mem.Allocator, function: ast.Function, parameter_index: usize) bool {
    if (function.external) return false;
    var lifetimes = Lifetimes.init(allocator);
    defer lifetimes.deinit();
    const prepared = @import("lifetime_analysis.zig").prepare(&lifetimes, .{}, function.parameters, function.statements) catch return true;
    if (!prepared or !lifetimes.reuse) return true;
    return lifetimes.valueLivesAcross(function.parameters[parameter_index].name, 1);
}

/// External contracts that write a parameter register.
pub fn externalWritesScalarParameter(function: ast.Function, reg: ast.Register) bool {
    if (std.mem.indexOfScalar(ast.Register, function.clobber_regs, reg) == null) return false;
    for (function.parameters) |parameter| {
        if (parameter.reg == reg) return true;
    }
    return false;
}

pub fn externalWritesVectorParameter(function: ast.Function, reg: ast.VectorRegister) bool {
    if (std.mem.indexOfScalar(ast.VectorRegister, function.clobber_vector_regs, reg) == null) return false;
    for (function.parameters) |parameter| {
        if (parameter.vector_reg == reg) return true;
    }
    return false;
}

test "parameter registers become setup write masks" {
    try std.testing.expectEqual(registers.registerBit(.a0), parameterRegisterBits(.{ .name = "x", .data_type = .u32, .reg = .a0 }));
    try std.testing.expectEqual(@as(u32, 0), parameterRegisterBits(.{ .name = "x", .data_type = .vec16, .vector_reg = .v01 }));
    try std.testing.expectEqual(@as(u32, 0b1100), parameterVectorBits(.{ .name = "x", .data_type = .vec32, .vector_reg = .v02 }));
    try std.testing.expectEqual(@as(u32, 0), parameterVectorBits(.{ .name = "x", .data_type = .u32 }));
}
