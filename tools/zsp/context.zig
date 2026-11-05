//! The state of one function during lowering: visible symbols, register
//! allocation over the function's lifetimes, and emission bookkeeping.
const std = @import("std");
const ast = @import("ast.zig");
const lifetime_analysis = @import("lifetime_analysis.zig");
const lifetimes_ = @import("lifetimes.zig");
const registers = @import("registers.zig");

const Register = ast.Register;
const VReg = ast.VectorRegister;
const DataType = ast.DataType;
const Lifetimes = lifetimes_.Lifetimes;
const registerBit = registers.registerBit;
const vectorRegisterBit = registers.vectorRegisterBit;
const nextVectorRegister = registers.nextVectorRegister;

pub const Diagnostic = @import("explain.zig").Diagnostic;
pub const ExplainReport = @import("explain.zig").ExplainReport;
pub const FunctionClobberRegistry = @import("clobbers.zig").FunctionClobberRegistry;

pub const Symbol = struct {
    name: []const u8,
    data_type: DataType,
    reg: ?Register,
    vector_reg: ?VReg = null,
    function_type: ?ast.FunctionType = null,
    constant: ?i64,
    data_label: ?[]const u8 = null,
    automatic: bool = false,
    first_live: usize = 0,
    last_use: usize = std.math.maxInt(usize),
};

/// A rarely run `if` body written after the function: it starts at
/// `label`'s cold label and jumps back to its end label.
pub const ColdBlock = struct {
    statements: []const ast.Statement,
    position: usize,
    label: usize,
};

/// A loop or labeled block that `break` and `continue` may target.
pub const EmissionLoop = struct {
    name: ?[]const u8,
    label: usize,
    continue_suffix: []const u8,
    break_suffix: []const u8,
};

const expression_temporary_names = [_][]const u8{
    "__expression_temporary_0", "__expression_temporary_1", "__expression_temporary_2", "__expression_temporary_3",
    "__expression_temporary_4", "__expression_temporary_5", "__expression_temporary_6", "__expression_temporary_7",
};

pub fn isVectorType(data_type: DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

pub const FunctionContext = struct {
    allocator: std.mem.Allocator,
    label_prefix: []const u8,
    functions: []const ast.Function = &.{},
    diagnostic: ?*Diagnostic = null,
    explain: ?*ExplainReport = null,
    explain_function_name: ?[]const u8 = null,
    symbols: std.ArrayList(Symbol) = .empty,
    next_label: usize = 0,
    emission_loops: std.ArrayList(EmissionLoop) = .empty,
    lifetimes: Lifetimes,
    statement_position: usize = 0,
    track_statement_position: bool = true,
    clobbers: ?*const FunctionClobberRegistry = null,
    function_forbidden_scalar: u32 = 0,
    function_forbidden_vector: u32 = 0,
    omitted_tail_target: ?[]const u8 = null,
    omitted_tail_position: usize = 0,
    shared_exit_label: ?usize = null,
    shared_exit_delay: ?[]const ast.Statement = null,
    shared_exit_consumed: bool = false,
    expression_temporary_depth: usize = 0,
    /// Whether rarely run `if` bodies may be placed after the function.
    cold_blocks_allowed: bool = false,
    /// Nested blocks being written; cold bodies move only from depth 0.
    block_depth: usize = 0,
    cold_blocks: std.ArrayList(ColdBlock) = .empty,

    pub fn init(allocator: std.mem.Allocator, label_prefix: []const u8) FunctionContext {
        return .{ .allocator = allocator, .label_prefix = label_prefix, .lifetimes = .init(allocator) };
    }

    pub fn deinit(self: *FunctionContext) void {
        self.symbols.deinit(self.allocator);
        self.emission_loops.deinit(self.allocator);
        self.cold_blocks.deinit(self.allocator);
        self.lifetimes.deinit();
    }

    pub fn add(self: *FunctionContext, symbol: Symbol) !void {
        if (self.contains(symbol.name)) return error.SymbolAlreadyDefined;
        try self.symbols.append(self.allocator, symbol);
        if (self.explain) |report| try self.reportAllocation(report, symbol);
    }

    /// Named register values appear in `zsp explain`; backend temporaries do not.
    fn reportAllocation(self: *const FunctionContext, report: *ExplainReport, symbol: Symbol) !void {
        if (symbol.reg == null and symbol.vector_reg == null) return;
        if (std.mem.startsWith(u8, symbol.name, "__")) return;
        try report.addAllocation(.{
            .function_name = self.explain_function_name orelse self.label_prefix,
            .symbol_name = symbol.name,
            .data_type = symbol.data_type,
            .reg = symbol.reg,
            .vector_reg = symbol.vector_reg,
            .automatic = symbol.automatic,
        });
    }

    /// A context for a function body that sees the program's global symbols.
    pub fn child(self: *const FunctionContext, label_prefix: []const u8) !FunctionContext {
        var result = FunctionContext.init(self.allocator, label_prefix);
        result.clobbers = self.clobbers;
        result.functions = self.functions;
        result.diagnostic = self.diagnostic;
        result.explain = self.explain;
        result.explain_function_name = self.explain_function_name;
        result.function_forbidden_scalar = self.function_forbidden_scalar;
        result.function_forbidden_vector = self.function_forbidden_vector;
        try result.symbols.appendSlice(self.allocator, self.symbols.items);
        return result;
    }

    pub fn prepareLifetimes(self: *FunctionContext, functions: []const ast.Function, parameters: []const ast.Parameter, statements: []const ast.Statement) !void {
        self.statement_position = 0;
        const options: lifetime_analysis.Options = .{ .functions = functions, .diagnostic = self.diagnostic, .program = self.functions };
        if (!try lifetime_analysis.prepare(&self.lifetimes, options, parameters, statements)) return;
        if (try self.lifetimes.firstUnassignedRead()) |name| {
            if (self.diagnostic) |diagnostic| diagnostic.symbol_name = name;
            return error.RegisterReadBeforeAssignment;
        }
        self.applyCallClobbers();
    }

    /// Automatic values live across a call avoid every register it writes.
    fn applyCallClobbers(self: *FunctionContext) void {
        const registry = self.clobbers orelse return;
        for (self.lifetimes.calls.items) |call| {
            const clobber = registry.find(call.target) orelse continue;
            self.forbidAcrossCall(call, clobber);
        }
    }

    fn forbidAcrossCall(self: *FunctionContext, call: lifetimes_.Call, clobber: @import("clobbers.zig").FunctionClobber) void {
        for (self.lifetimes.lifetimes.items) |*lifetime| {
            if (!lifetime.automatic or !self.lifetimes.livesAcrossCall(lifetime.*, call)) continue;
            lifetime.forbidden_scalar |= clobber.scalar | call.setup_scalar;
            lifetime.forbidden_vector |= clobber.vector | call.setup_vector;
        }
    }

    pub fn findLifetimeLabel(self: *const FunctionContext, name: []const u8) ?lifetimes_.Label {
        return self.lifetimes.findLabel(name);
    }

    pub fn lastUse(self: *const FunctionContext, name: []const u8) usize {
        return self.lifetimes.lastUse(name);
    }

    pub fn firstLive(self: *const FunctionContext, name: []const u8) usize {
        return self.lifetimes.firstLive(name);
    }

    pub fn lookup(self: *const FunctionContext, name: []const u8) !Symbol {
        if (self.find(name)) |symbol| return symbol;
        if (self.diagnostic) |diagnostic| diagnostic.symbol_name = name;
        return error.UnknownSymbol;
    }

    fn find(self: *const FunctionContext, name: []const u8) ?Symbol {
        var index = self.symbols.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.symbols.items[index].name, name)) return self.symbols.items[index];
        }
        return null;
    }

    pub fn contains(self: *const FunctionContext, name: []const u8) bool {
        _ = self.lookup(name) catch return false;
        return true;
    }

    pub fn allocLabel(self: *FunctionContext) usize {
        defer self.next_label += 1;
        return self.next_label;
    }

    pub fn pushScope(self: *const FunctionContext) usize {
        return self.symbols.items.len;
    }

    pub fn popScope(self: *FunctionContext, scope: usize) void {
        self.symbols.shrinkRetainingCapacity(scope);
    }

    // ------------------------------------------------------- scalar registers

    fn functionForbids(self: *const FunctionContext, reg: Register) bool {
        return self.function_forbidden_scalar & registerBit(reg) != 0;
    }

    /// The register a call wants the value in when it is usable for the
    /// whole lifetime; otherwise the first free one, and the call moves it.
    pub fn allocRegister(self: *const FunctionContext, data_type: DataType, name: []const u8) !Register {
        if (isVectorType(data_type)) return error.ExpectedScalarType;
        if (self.lifetimes.requiredRegister(name)) |reg| {
            if (self.checkRequiredRegister(name, reg)) |usable| return usable else |_| {}
        }
        for (registers.alloc_scalar_registers) |reg| {
            if (self.scalarCandidate(name, reg)) return reg;
        }
        self.reportLive(name, false);
        return error.OutOfFreeRegisters;
    }

    /// Lists the values whose registers overlap `name`'s lifetime.
    fn reportLive(self: *const FunctionContext, name: []const u8, vector: bool) void {
        const diagnostic = self.diagnostic orelse return;
        diagnostic.symbol_name = name;
        const range = self.liveRange(name);
        for (self.symbols.items) |symbol| {
            if (!overlaps(range, symbol)) continue;
            const reg = registerName(symbol, vector) orelse continue;
            diagnostic.recordLive(symbol.name, reg);
        }
    }

    fn registerName(symbol: Symbol, vector: bool) ?[]const u8 {
        if (vector) return if (symbol.vector_reg) |reg| registers.vectorDollarName(reg) else null;
        return if (symbol.reg) |reg| registers.regName(reg) else null;
    }

    fn checkRequiredRegister(self: *const FunctionContext, name: []const u8, reg: Register) !Register {
        if (self.functionForbids(reg) or self.lifetimes.registerForbidden(name, reg)) return error.AutomaticRegisterClobberedByCall;
        if (self.scalarLifetimeConflicts(name, reg)) return error.RegisterAlreadyInUse;
        return reg;
    }

    fn scalarCandidate(self: *const FunctionContext, name: []const u8, reg: Register) bool {
        if (self.functionForbids(reg) or self.lifetimes.registerForbidden(name, reg)) return false;
        return !self.scalarLifetimeConflicts(name, reg) and !self.lifetimes.pinnedOverlaps(name, .{ .scalar = reg });
    }

    pub fn allocExpressionRegister(self: *const FunctionContext) !Register {
        for (registers.alloc_scalar_registers) |reg| {
            if (!self.functionForbids(reg) and !self.isRegisterInUse(reg)) return reg;
        }
        return error.OutOfFreeRegistersInExpression;
    }

    /// A temporary for the right side of a nested scalar expression.
    pub fn pushExpressionTemporary(self: *FunctionContext, data_type: DataType) !struct { usize, Symbol } {
        if (self.expression_temporary_depth >= expression_temporary_names.len) return error.ExpressionNestingTooDeep;
        const scope = self.pushScope();
        const name = expression_temporary_names[self.expression_temporary_depth];
        self.expression_temporary_depth += 1;
        const symbol: Symbol = .{
            .name = name,
            .data_type = data_type,
            .reg = try self.allocExpressionRegister(),
            .constant = null,
            .first_live = self.statement_position,
        };
        try self.add(symbol);
        return .{ scope, symbol };
    }

    pub fn popExpressionTemporary(self: *FunctionContext, scope: usize) void {
        self.popScope(scope);
        self.expression_temporary_depth -= 1;
    }

    pub fn isRegisterInUse(self: *const FunctionContext, reg: Register) bool {
        for (self.symbols.items) |symbol| {
            if (symbol.last_use >= self.statement_position and symbol.reg == reg) return true;
        }
        return false;
    }

    pub fn scalarLifetimeConflicts(self: *const FunctionContext, name: []const u8, reg: Register) bool {
        const range = self.liveRange(name);
        for (self.symbols.items) |symbol| {
            if (symbol.reg == reg and overlaps(range, symbol)) return true;
        }
        return false;
    }

    const Range = struct { first: usize, last: usize };

    fn liveRange(self: *const FunctionContext, name: []const u8) Range {
        return .{ .first = self.firstLive(name), .last = self.lastUse(name) };
    }

    fn overlaps(range: Range, symbol: Symbol) bool {
        return range.first <= symbol.last_use and symbol.first_live <= range.last;
    }

    // ------------------------------------------------------- vector registers

    fn functionForbidsVector(self: *const FunctionContext, reg: VReg) bool {
        return self.function_forbidden_vector & vectorRegisterBit(reg) != 0;
    }

    pub fn allocVectorRegister(self: *const FunctionContext, data_type: DataType, name: []const u8) !VReg {
        if (!isVectorType(data_type)) return error.ExpectedVectorType;
        if (self.lifetimes.requiredVectorRegister(name)) |reg| return self.checkRequiredVector(data_type, name, reg);
        for (registers.alloc_vector_registers) |reg| {
            if (self.vectorCandidate(data_type, name, reg)) return reg;
        }
        self.reportLive(name, true);
        return error.OutOfFreeVectorRegisters;
    }

    fn checkRequiredVector(self: *const FunctionContext, data_type: DataType, name: []const u8, reg: VReg) !VReg {
        if (self.functionForbidsVector(reg) or self.lifetimes.vectorRegisterForbidden(name, reg)) return error.AutomaticRegisterClobberedByCall;
        try validateVectorRegisterBinding(self, data_type, reg, name);
        return reg;
    }

    /// `vec32` values need an allocatable second register too.
    fn vectorCandidate(self: *const FunctionContext, data_type: DataType, name: []const u8, reg: VReg) bool {
        if (self.functionForbidsVector(reg) or !self.vectorFree(name, reg)) return false;
        if (data_type != .vec32) return true;
        const second = nextVectorRegister(reg) orelse return false;
        return @intFromEnum(second) < 29 and self.vectorFree(name, second);
    }

    fn vectorFree(self: *const FunctionContext, name: []const u8, reg: VReg) bool {
        if (self.lifetimes.vectorRegisterForbidden(name, reg)) return false;
        return !self.vectorLifetimeConflicts(name, reg) and !self.lifetimes.pinnedOverlaps(name, .{ .vector = reg });
    }

    pub fn isVectorRegisterInUse(self: *const FunctionContext, reg: VReg) bool {
        for (self.symbols.items) |symbol| {
            if (symbol.last_use >= self.statement_position and occupies(symbol, reg)) return true;
        }
        return false;
    }

    pub fn vectorLifetimeConflicts(self: *const FunctionContext, name: []const u8, reg: VReg) bool {
        const range = self.liveRange(name);
        for (self.symbols.items) |symbol| {
            if (occupies(symbol, reg) and overlaps(range, symbol)) return true;
        }
        return false;
    }

    fn occupies(symbol: Symbol, reg: VReg) bool {
        const symbol_reg = symbol.vector_reg orelse return false;
        return symbol_reg == reg or (symbol.data_type == .vec32 and nextVectorRegister(symbol_reg) == reg);
    }
};

/// Checks a vector binding against overlapping lifetimes, or against values
/// in use now when the binding has no lifetime of its own.
pub fn validateVectorRegisterBinding(context: *const FunctionContext, data_type: DataType, vector_reg: VReg, lifetime_name: ?[]const u8) !void {
    if (vectorBindingConflicts(context, vector_reg, lifetime_name)) return error.RegisterAlreadyInUse;
    if (data_type != .vec32) return;
    const second = nextVectorRegister(vector_reg) orelse return error.InvalidVectorRegisterPair;
    if (vectorBindingConflicts(context, second, lifetime_name)) return error.RegisterAlreadyInUse;
}

fn vectorBindingConflicts(context: *const FunctionContext, reg: VReg, lifetime_name: ?[]const u8) bool {
    const name = lifetime_name orelse return context.isVectorRegisterInUse(reg);
    return context.vectorLifetimeConflicts(name, reg);
}

/// `ltv` writes eight registers. Explicit bank bindings stay usable, but
/// automatic allocation must leave the whole bank free afterwards.
pub fn reserveTransposeBank(context: *FunctionContext, bank: Symbol, reg: VReg) !u32 {
    if (bank.automatic or @intFromEnum(reg) % 8 != 0) return error.TransposeRequiresRegisterBank;
    const mask = @as(u32, 0xff) << @as(u5, @intCast(@intFromEnum(reg)));
    for (context.symbols.items) |symbol| {
        if (liveAutomaticIn(context, symbol, mask)) return error.RegisterAlreadyInUse;
    }
    context.function_forbidden_vector |= mask;
    return mask;
}

fn liveAutomaticIn(context: *const FunctionContext, symbol: Symbol, mask: u32) bool {
    return symbol.automatic and symbol.last_use >= context.statement_position and occupiedBits(symbol) & mask != 0;
}

fn occupiedBits(symbol: Symbol) u32 {
    const reg = symbol.vector_reg orelse return 0;
    var bits = vectorRegisterBit(reg);
    if (symbol.data_type == .vec32) bits |= vectorRegisterBit(nextVectorRegister(reg).?);
    return bits;
}

/// Binds a function's parameters to their fixed registers.
pub fn bindParameters(context: *FunctionContext, parameters: []const ast.Parameter) !void {
    for (parameters) |parameter| {
        try validateParameter(context, parameter);
        if (std.mem.eql(u8, parameter.name, "_")) continue;
        try context.add(.{
            .name = parameter.name,
            .data_type = parameter.data_type,
            .reg = parameter.reg,
            .vector_reg = parameter.vector_reg,
            .constant = null,
            .first_live = context.firstLive(parameter.name),
            .last_use = context.lastUse(parameter.name),
        });
    }
}

fn validateParameter(context: *FunctionContext, parameter: ast.Parameter) !void {
    if (isVectorType(parameter.data_type)) return validateVectorParameter(context, parameter);
    const reg = parameter.reg orelse return error.InvalidScalarRegister;
    if (reg == registers.compiler_scratch_2 or reg == registers.command_return) return error.RegisterReservedForBackend;
    if (context.isRegisterInUse(reg)) return error.RegisterAlreadyInUse;
}

fn validateVectorParameter(context: *FunctionContext, parameter: ast.Parameter) !void {
    const vector_reg = parameter.vector_reg orelse return error.ExpectedVectorRegister;
    return validateVectorRegisterBinding(context, parameter.data_type, vector_reg, null);
}

/// A `vec32`'s integer half is its first register, its fraction the second.
pub fn vectorRegisterForView(symbol: Symbol, view: ?ast.VectorView) !VReg {
    const reg = symbol.vector_reg orelse return error.ExpectedVectorRegister;
    return switch (symbol.data_type) {
        .vec16 => reg,
        .vec32 => pairRegisterForView(reg, view),
        else => error.ExpectedVectorType,
    };
}

fn pairRegisterForView(reg: VReg, view: ?ast.VectorView) !VReg {
    if (!selectsFraction(view)) return reg;
    return nextVectorRegister(reg) orelse error.InvalidVectorRegisterPair;
}

fn selectsFraction(view: ?ast.VectorView) bool {
    const selected = view orelse return false;
    return selected != .sint and selected != .uint;
}

const testing = std.testing;

test "scopes, labels, and expression temporaries" {
    var context = FunctionContext.init(testing.allocator, "f");
    defer context.deinit();
    try context.add(.{ .name = "a", .data_type = .u32, .reg = .t0, .constant = null });
    const scope = context.pushScope();
    try context.add(.{ .name = "b", .data_type = .u32, .reg = .t1, .constant = null });
    try testing.expectError(error.SymbolAlreadyDefined, context.add(.{ .name = "b", .data_type = .u32, .reg = .t1, .constant = null }));
    context.popScope(scope);
    try testing.expectError(error.UnknownSymbol, context.lookup("b"));
    try testing.expectEqual(@as(usize, 0), context.allocLabel());
    try testing.expectEqual(@as(usize, 1), context.allocLabel());
    const temporary = try context.pushExpressionTemporary(.u32);
    try testing.expectEqual(@as(?Register, .t1), temporary[1].reg);
    context.popExpressionTemporary(temporary[0]);
    var nested = try context.child("g");
    defer nested.deinit();
    try testing.expect(nested.contains("a"));
    try testing.expectError(error.ExpectedScalarType, context.allocRegister(.vec16, "v"));
    try testing.expectError(error.ExpectedVectorType, context.allocVectorRegister(.u32, "x"));
}

test "vector views select halves of a vec32" {
    const pair: Symbol = .{ .name = "p", .data_type = .vec32, .reg = null, .vector_reg = .v04, .constant = null };
    try testing.expectEqual(VReg.v05, try vectorRegisterForView(pair, .sfract));
    try testing.expectEqual(VReg.v04, try vectorRegisterForView(pair, .sint));
    try testing.expectEqual(VReg.v04, try vectorRegisterForView(pair, null));
    var scalar = pair;
    scalar.data_type = .u32;
    try testing.expectError(error.ExpectedVectorType, vectorRegisterForView(scalar, null));
    var last = pair;
    last.vector_reg = .v31;
    try testing.expectError(error.InvalidVectorRegisterPair, vectorRegisterForView(last, .ufract));
}
