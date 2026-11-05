//! Interprocedural register contracts. Each function's write set is the
//! registers its body and argument setup write plus everything its callees
//! write, iterated to a fixed point. Its forbidden set holds the pinned
//! registers callers keep live across calls to it.
const std = @import("std");
const ast = @import("ast.zig");
const ast_walk = @import("ast_walk.zig");
const call_requirements = @import("call_requirements.zig");
const context_ = @import("context.zig");
const lifetime_scan = @import("lifetime_scan.zig");
const lifetimes_ = @import("lifetimes.zig");
const registers = @import("registers.zig");

const FunctionContext = context_.FunctionContext;
const Diagnostic = @import("explain.zig").Diagnostic;
const Statement = ast.Statement;
const Tag = std.meta.Tag(Statement);
const registerBit = registers.registerBit;
const vectorRegisterBit = registers.vectorRegisterBit;

pub const FunctionClobber = struct {
    name: []const u8,
    scalar: u32 = 0,
    vector: u32 = 0,
    forbidden_scalar: u32 = 0,
    forbidden_vector: u32 = 0,

    fn sameWrites(self: FunctionClobber, other: FunctionClobber) bool {
        return self.scalar == other.scalar and self.vector == other.vector;
    }

    fn violatesForbidden(self: FunctionClobber) bool {
        return self.scalar & self.forbidden_scalar != 0 or self.vector & self.forbidden_vector != 0;
    }
};

const max_iterations = 32;

pub const FunctionClobberRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(FunctionClobber) = .empty,

    pub fn init(allocator: std.mem.Allocator, functions: []const ast.Function, diagnostic: ?*Diagnostic) !FunctionClobberRegistry {
        var analysis: Analysis = .{ .allocator = allocator, .functions = functions, .diagnostic = diagnostic };
        defer analysis.deinit();
        try analysis.collectDirect();
        try analysis.collectForbidden();
        for (0..max_iterations) |_| {
            if (try analysis.iterate()) return analysis.take();
        }
        return error.RegisterClobberAnalysisDidNotConverge;
    }

    pub fn deinit(self: *FunctionClobberRegistry) void {
        self.entries.deinit(self.allocator);
    }

    pub fn find(self: *const FunctionClobberRegistry, name: []const u8) ?FunctionClobber {
        const entry = (@constCast(self)).findPtr(name) orelse return null;
        return entry.*;
    }

    pub fn findPtr(self: *FunctionClobberRegistry, name: []const u8) ?*FunctionClobber {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

const Analysis = struct {
    allocator: std.mem.Allocator,
    functions: []const ast.Function,
    diagnostic: ?*Diagnostic,
    /// Body and contract writes, plus forbidden sets, before propagation.
    direct: std.ArrayList(FunctionClobber) = .empty,
    result: FunctionClobberRegistry = undefined,
    taken: bool = false,

    fn deinit(self: *Analysis) void {
        self.direct.deinit(self.allocator);
        if (!self.taken) self.result.deinit();
    }

    fn take(self: *Analysis) FunctionClobberRegistry {
        self.taken = true;
        return self.result;
    }

    fn collectDirect(self: *Analysis) !void {
        self.result = .{ .allocator = self.allocator };
        for (self.functions) |function| {
            var entry: FunctionClobber = .{ .name = function.name };
            scanDirectFunctionClobbers(self.functions, function, &entry);
            try self.result.entries.append(self.allocator, entry);
        }
    }

    fn context(self: *Analysis, function: ast.Function) FunctionContext {
        var result = FunctionContext.init(self.allocator, function.name);
        result.functions = self.functions;
        result.diagnostic = self.diagnostic;
        return result;
    }

    /// Prepares lifetimes, naming the function in any diagnostic.
    fn prepare(self: *Analysis, function_context: *FunctionContext, function: ast.Function) !void {
        function_context.prepareLifetimes(self.functions, function.parameters, function.statements) catch |err| return self.fail(function, err);
    }

    fn fail(self: *Analysis, function: ast.Function, err: anyerror) anyerror {
        if (self.diagnostic) |value| value.function_name = function.source_name;
        return err;
    }

    /// Pinned caller values live across a call forbid the callee from
    /// writing their registers.
    fn collectForbidden(self: *Analysis) !void {
        for (self.functions) |function| {
            var function_context = self.context(function);
            defer function_context.deinit();
            try self.prepare(&function_context, function);
            for (function_context.lifetimes.calls.items) |call| try self.forbidAcrossCall(&function_context, function, call);
        }
        try self.direct.appendSlice(self.allocator, self.result.entries.items);
    }

    fn forbidAcrossCall(self: *Analysis, function_context: *const FunctionContext, function: ast.Function, call: lifetimes_.Call) !void {
        const target = self.result.findPtr(call.target) orelse return;
        const target_function = call_requirements.findFunction(self.functions, call.target) orelse return;
        const pins: Pins = .{ .target = target, .target_function = target_function, .call = call, .diagnostic = self.diagnostic, .caller = function };
        for (function_context.lifetimes.lifetimes.items) |lifetime| {
            if (lifetime.automatic or !function_context.lifetimes.livesAcrossCall(lifetime, call)) continue;
            try pins.forbid(lifetime);
        }
    }

    /// One propagation round from the previous round's write sets. Returns
    /// true once the write sets stop changing.
    fn iterate(self: *Analysis) !bool {
        var previous = try self.cloneResult();
        defer previous.deinit();
        @memcpy(self.result.entries.items, self.direct.items);
        for (self.functions, 0..) |function, index| try self.simulate(function, index, &previous);
        self.propagateCalls();
        try self.checkForbidden();
        return sameWriteSets(self.result.entries.items, previous.entries.items);
    }

    fn cloneResult(self: *Analysis) !FunctionClobberRegistry {
        var copy: FunctionClobberRegistry = .{ .allocator = self.allocator };
        try copy.entries.appendSlice(self.allocator, self.result.entries.items);
        return copy;
    }

    /// Adds argument setup and automatic allocations to a function's writes.
    fn simulate(self: *Analysis, function: ast.Function, index: usize, previous: *const FunctionClobberRegistry) !void {
        var function_context = self.context(function);
        defer function_context.deinit();
        function_context.clobbers = previous;
        function_context.function_forbidden_scalar = self.direct.items[index].forbidden_scalar;
        function_context.function_forbidden_vector = self.direct.items[index].forbidden_vector;
        try self.prepare(&function_context, function);
        const entry = &self.result.entries.items[index];
        for (function_context.lifetimes.calls.items) |call| {
            entry.scalar |= call.setup_scalar;
            entry.vector |= call.setup_vector;
        }
        context_.bindParameters(&function_context, function.parameters) catch |err| return self.fail(function, err);
        var simulation: Simulation = .{ .context = &function_context, .clobber = entry };
        simulation.statements(function.statements) catch |err| return self.fail(function, err);
    }

    fn propagateCalls(self: *Analysis) void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.functions, 0..) |function, index| changed = self.addCalledWrites(function, index) or changed;
        }
    }

    fn addCalledWrites(self: *Analysis, function: ast.Function, index: usize) bool {
        var collector: CalledWrites = .{ .registry = &self.result };
        ast_walk.each(function.statements, called_delays, &collector, CalledWrites.visit);
        const entry = &self.result.entries.items[index];
        const before = entry.*;
        entry.scalar |= collector.scalar;
        entry.vector |= collector.vector;
        return !entry.sameWrites(before);
    }

    fn checkForbidden(self: *Analysis) !void {
        for (self.result.entries.items, self.functions) |entry, function| {
            if (entry.violatesForbidden()) return self.fail(function, error.PinnedRegisterClobberedByCall);
        }
    }
};

fn sameWriteSets(current: []const FunctionClobber, previous: []const FunctionClobber) bool {
    for (current, previous) |entry, before| {
        if (!entry.sameWrites(before)) return false;
    }
    return true;
}

/// Checks one pinned caller value against a callee's contract.
const Pins = struct {
    target: *FunctionClobber,
    target_function: ast.Function,
    call: lifetimes_.Call,
    diagnostic: ?*Diagnostic,
    caller: ast.Function,

    fn forbid(self: Pins, lifetime: lifetimes_.Lifetime) !void {
        if (lifetime.fixed_reg) |reg| try self.forbidScalar(lifetime, reg);
        if (lifetime.fixed_vector_reg) |reg| try self.forbidVector(lifetime, reg);
    }

    fn forbidScalar(self: Pins, lifetime: lifetimes_.Lifetime, reg: ast.Register) !void {
        const bit = registerBit(reg);
        if (self.call.setup_scalar & bit != 0) return error.PinnedRegisterOverwrittenByCallArgument;
        const clobbered = self.target.scalar & bit != 0 and !call_requirements.externalWritesScalarParameter(self.target_function, reg);
        if (self.target_function.external and clobbered) return self.externalClobber(lifetime);
        self.target.forbidden_scalar |= bit;
    }

    fn forbidVector(self: Pins, lifetime: lifetimes_.Lifetime, reg: ast.VectorRegister) !void {
        try self.forbidVectorRegister(lifetime, reg, true);
        if (lifetime.data_type != .vec32) return;
        const second = registers.nextVectorRegister(reg) orelse return;
        try self.forbidVectorRegister(lifetime, second, false);
    }

    /// The first register of a pair may be an external's own parameter.
    fn forbidVectorRegister(self: Pins, lifetime: lifetimes_.Lifetime, reg: ast.VectorRegister, allow_parameter: bool) !void {
        const bit = vectorRegisterBit(reg);
        if (self.call.setup_vector & bit != 0) return error.PinnedRegisterOverwrittenByCallArgument;
        const parameter = allow_parameter and call_requirements.externalWritesVectorParameter(self.target_function, reg);
        if (self.target_function.external and self.target.vector & bit != 0 and !parameter) return self.externalClobber(lifetime);
        self.target.forbidden_vector |= bit;
    }

    fn externalClobber(self: Pins, lifetime: lifetimes_.Lifetime) anyerror {
        if (self.diagnostic) |value| {
            value.function_name = self.caller.source_name;
            value.symbol_name = lifetime.name;
        }
        return error.PinnedRegisterClobberedByExternalCall;
    }
};

// ------------------------------------------------------------ direct writes

/// Registers a function writes itself: its contract, written parameters,
/// initialized pinned locals, and raw assembly.
fn scanDirectFunctionClobbers(functions: []const ast.Function, function: ast.Function, result: *FunctionClobber) void {
    if (function.external and !function.has_clobber_contract) {
        result.scalar = std.math.maxInt(u32);
        result.vector = std.math.maxInt(u32);
        return;
    }
    for (function.clobber_regs) |reg| result.scalar |= registerBit(reg);
    for (function.clobber_vector_regs) |reg| result.vector |= vectorRegisterBit(reg);
    if (!function.has_clobber_contract) addWrittenParameters(functions, function, result);
    ast_walk.each(function.statements, direct_delays, result, visitDirect);
}

fn addWrittenParameters(functions: []const ast.Function, function: ast.Function, result: *FunctionClobber) void {
    for (function.parameters, 0..) |parameter, index| {
        var visited: [1024]call_requirements.ParameterWriteVisit = undefined;
        var visited_count: usize = 0;
        if (!call_requirements.functionParameterIsWritten(functions, function, index, &visited, &visited_count)) continue;
        if (parameter.reg) |reg| result.scalar |= registerBit(reg);
        if (parameter.vector_reg) |reg| result.vector |= vectorBits(parameter.data_type, reg);
    }
}

fn vectorBits(data_type: ast.DataType, reg: ast.VectorRegister) u32 {
    var bits = vectorRegisterBit(reg);
    if (data_type == .vec32) {
        if (registers.nextVectorRegister(reg)) |second| bits |= vectorRegisterBit(second);
    }
    return bits;
}

const direct_delays = ast_walk.DelaySet.initMany(&.{
    .goto, .conditional_goto, .conditional_direct_goto, .break_loop, .jump, .return_from_function,
});

fn visitDirect(result: *FunctionClobber, statement: *const Statement) void {
    switch (statement.*) {
        .var_decl => |decl| addDeclaration(result, decl),
        .builtin => |builtin| if (builtin == .hardware_read_register) {
            result.scalar |= registerBit(builtin.hardware_read_register.destination);
        },
        .asm_line => {
            result.scalar |= registers.allAutomaticScalarRegisters();
            result.vector |= registers.allAutomaticVectorRegisters();
        },
        else => {},
    }
}

fn addDeclaration(result: *FunctionClobber, decl: ast.VarDecl) void {
    if (decl.is_const or decl.value == null) return;
    if (decl.vector_reg) |reg| result.vector |= vectorBits(decl.data_type, reg);
    if (decl.reg) |reg| result.scalar |= registerBit(reg);
}

// ----------------------------------------------------------- called writes

const called_delays = ast_walk.DelaySet.initMany(&.{
    .call, .goto, .conditional_goto, .conditional_direct_goto, .break_loop, .tail, .jump, .return_from_function,
});

const CalledWrites = struct {
    registry: *const FunctionClobberRegistry,
    scalar: u32 = 0,
    vector: u32 = 0,

    fn visit(self: *CalledWrites, statement: *const Statement) void {
        const target = transferTarget(statement) orelse return;
        if (target.module != null) return;
        const entry = self.registry.find(target.name) orelse return;
        self.scalar |= entry.scalar;
        self.vector |= entry.vector;
    }
};

/// The function a call, tail call, or direct jump transfers to.
fn transferTarget(statement: *const Statement) ?ast.FunctionRef {
    return switch (statement.*) {
        .call => |call| .{ .module = call.module, .name = call.name },
        .conditional_direct_goto => |branch| branch.target,
        .builtin => |builtin| builtinTarget(builtin),
        else => null,
    };
}

fn builtinTarget(builtin: ast.Builtin) ?ast.FunctionRef {
    return switch (builtin) {
        .direct_goto => |branch| branch.target,
        .tail => |tail| tail.target,
        else => null,
    };
}

// ---------------------------------------------------- automatic allocation

/// Replays allocation of a function's automatic values to learn which
/// registers they occupy.
const Simulation = struct {
    context: *FunctionContext,
    clobber: *FunctionClobber,

    fn statements(self: *Simulation, list: []const Statement) anyerror!void {
        for (list) |*statement| {
            if (self.context.diagnostic) |diagnostic| diagnostic.selectStatement(self.context.functions, statement);
            if (self.context.track_statement_position) self.context.statement_position += 1;
            try simulators.get(std.meta.activeTag(statement.*))(self, statement);
        }
    }

    fn optional(self: *Simulation, list: ?[]const Statement) !void {
        try self.statements(list orelse return);
    }

    fn scoped(self: *Simulation, list: []const Statement) !void {
        const scope = self.context.pushScope();
        defer self.context.popScope(scope);
        try self.statements(list);
    }

    fn addVector(self: *Simulation, data_type: ast.DataType, reg: ast.VectorRegister) !void {
        self.clobber.vector |= vectorRegisterBit(reg);
        if (data_type != .vec32) return;
        const second = registers.nextVectorRegister(reg) orelse return error.InvalidVectorRegisterPair;
        self.clobber.vector |= vectorRegisterBit(second);
    }
};

const Simulator = *const fn (*Simulation, *const Statement) anyerror!void;

const simulators = blk: {
    var table = std.EnumArray(Tag, Simulator).initFill(&ignoreStatement);
    table.set(.var_decl, &simulateDeclaration);
    table.set(.assignment, &simulateAssignment);
    for ([_]Tag{ .goto, .conditional_goto, .conditional_direct_goto, .break_loop, .call }) |tag| table.set(tag, &simulateDelay);
    table.set(.do_while_loop, &simulateDoWhile);
    table.set(.if_statement, &simulateIf);
    table.set(.labeled_block, &simulateBlock);
    table.set(.ordered_block, &simulateOrdered);
    table.set(.builtin, &simulateBuiltin);
    break :blk table;
};

fn ignoreStatement(_: *Simulation, _: *const Statement) !void {}

fn simulateDelay(simulation: *Simulation, statement: *const Statement) !void {
    try simulation.optional(ast_walk.delaySlot(statement));
}

fn simulateDoWhile(simulation: *Simulation, statement: *const Statement) !void {
    const scope = simulation.context.pushScope();
    defer simulation.context.popScope(scope);
    try simulation.statements(statement.do_while_loop.statements);
    try simulation.optional(statement.do_while_loop.delay_slot);
}

fn simulateIf(simulation: *Simulation, statement: *const Statement) !void {
    const branch = statement.if_statement;
    try simulation.optional(branch.delay_slot);
    try simulation.scoped(branch.then_statements);
    if (branch.else_statements) |items| try simulation.scoped(items);
}

fn simulateBlock(simulation: *Simulation, statement: *const Statement) !void {
    const scope = simulation.context.pushScope();
    defer simulation.context.popScope(scope);
    try simulation.statements(statement.labeled_block.statements);
    try simulation.optional(statement.labeled_block.exit_delay);
}

fn simulateOrdered(simulation: *Simulation, statement: *const Statement) !void {
    try simulation.statements(statement.ordered_block);
}

fn simulateBuiltin(simulation: *Simulation, statement: *const Statement) !void {
    switch (statement.builtin) {
        .vector_memory => |memory| try simulateVectorLoad(simulation, memory),
        .jump, .return_from_function => try simulation.optional(ast_walk.builtinDelaySlot(&statement.builtin)),
        else => {},
    }
}

fn simulateVectorLoad(simulation: *Simulation, memory: @FieldType(ast.Builtin, "vector_memory")) !void {
    if (!lifetime_scan.isVectorLoad(memory.operation)) return;
    const symbol = try simulation.context.lookup(memory.vector.name);
    const reg = try context_.vectorRegisterForView(symbol, memory.vector.view);
    const transpose = memory.operation == .load_transpose;
    simulation.clobber.vector |= if (transpose) try context_.reserveTransposeBank(simulation.context, symbol, reg) else vectorRegisterBit(reg);
}

fn simulateDeclaration(simulation: *Simulation, statement: *const Statement) !void {
    const decl = statement.var_decl;
    if (decl.is_const) return simulation.context.add(.{ .name = decl.name, .data_type = decl.data_type, .reg = null, .constant = 0 });
    if (context_.isVectorType(decl.data_type)) return simulateVectorDeclaration(simulation, decl);
    return simulateScalarDeclaration(simulation, decl);
}

fn simulateVectorDeclaration(simulation: *Simulation, decl: ast.VarDecl) !void {
    const context = simulation.context;
    const reg = decl.vector_reg orelse try context.allocVectorRegister(decl.data_type, decl.name);
    try context_.validateVectorRegisterBinding(context, decl.data_type, reg, decl.name);
    if (decl.value != null) try simulation.addVector(decl.data_type, reg);
    try context.add(.{
        .name = decl.name,
        .data_type = decl.data_type,
        .reg = null,
        .vector_reg = reg,
        .function_type = decl.function_type,
        .constant = null,
        .automatic = decl.vector_reg == null,
        .first_live = context.firstLive(decl.name),
        .last_use = context.lastUse(decl.name),
    });
}

fn simulateScalarDeclaration(simulation: *Simulation, decl: ast.VarDecl) !void {
    const context = simulation.context;
    const reg = decl.reg orelse try context.allocRegister(decl.data_type, decl.name);
    if (context.scalarLifetimeConflicts(decl.name, reg)) return error.RegisterAlreadyInUse;
    if (decl.value != null) simulation.clobber.scalar |= registerBit(reg);
    var symbol: context_.Symbol = .{
        .name = decl.name,
        .data_type = decl.data_type,
        .reg = reg,
        .function_type = decl.function_type,
        .constant = null,
        .automatic = decl.reg == null,
        .first_live = 0,
        .last_use = std.math.maxInt(usize),
    };
    if (!decl.is_reserved) {
        symbol.first_live = context.firstLive(decl.name);
        symbol.last_use = context.lastUse(decl.name);
    }
    try context.add(symbol);
}

fn simulateAssignment(simulation: *Simulation, statement: *const Statement) !void {
    const assignment = statement.assignment;
    const destination = try simulation.context.lookup(assignment.destination);
    if (destination.reg) |reg| simulation.clobber.scalar |= registerBit(reg);
    if (destination.vector_reg) |reg| try simulation.addVector(destination.data_type, reg);
    if (!context_.isVectorType(destination.data_type)) try simulateTemporaries(simulation, assignment.lhs, destination);
}

/// Expression temporaries take registers too.
fn simulateTemporaries(simulation: *Simulation, value: ast.Value, destination: context_.Symbol) !void {
    if (value != .scalar_expression) return;
    const expression = value.scalar_expression;
    if (!@import("analysis.zig").isPureScalarExpression(value)) return error.SideEffectsNotAllowedInScalarExpression;
    try simulateTemporaries(simulation, expression.lhs, destination);
    if (!needsTemporary(expression, destination.name)) return;
    const temporary = try simulation.context.pushExpressionTemporary(destination.data_type);
    defer simulation.context.popExpressionTemporary(temporary[0]);
    simulation.clobber.scalar |= registerBit(temporary[1].reg.?);
    try simulateTemporaries(simulation, expression.rhs, temporary[1]);
}

fn needsTemporary(expression: *const ast.ScalarExpression, destination: []const u8) bool {
    if (expression.rhs == .scalar_expression) return true;
    return expression.lhs == .scalar_expression and @import("analysis.zig").valueReadsName(expression.rhs, destination);
}

test "write sets compare and forbidden overlaps are detected" {
    const entry: FunctionClobber = .{ .name = "f", .scalar = 1, .forbidden_scalar = 1 };
    try std.testing.expect(entry.violatesForbidden());
    try std.testing.expect(entry.sameWrites(.{ .name = "g", .scalar = 1 }));
    try std.testing.expect(!sameWriteSets(&.{entry}, &.{.{ .name = "f", .scalar = 2 }}));
    try std.testing.expectEqual(@as(u32, 0b11 << 4), vectorBits(.vec32, .v04));
}
