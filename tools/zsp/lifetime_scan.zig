//! Records each statement's reads, writes, declarations, labels, branches,
//! and calls in a function's `Lifetimes`, numbering statements in source
//! order.
const std = @import("std");
const ast = @import("ast.zig");
const ast_walk = @import("ast_walk.zig");
const Lifetimes = @import("lifetimes.zig").Lifetimes;

const Statement = ast.Statement;
const Tag = std.meta.Tag(Statement);
const ValueTag = std.meta.Tag(ast.Value);

pub const Scan = struct {
    lifetimes: *Lifetimes,
    position: usize = 0,

    pub fn statements(self: *Scan, list: []const Statement) anyerror!void {
        for (list) |*statement| {
            self.position += 1;
            try scanners.get(std.meta.activeTag(statement.*))(self, statement, self.position);
        }
    }

    fn optional(self: *Scan, list: ?[]const Statement) !void {
        try self.statements(list orelse return);
    }

    fn read(self: *Scan, name: []const u8, position: usize) !void {
        try self.lifetimes.read(name, position);
    }

    fn ref(self: *Scan, item: ast.ValueRef, position: usize) !void {
        switch (item) {
            .ident, .bit_cast => |name| try self.read(name, position),
            .vector_access => |access| try self.read(access.name, position),
            .number => {},
        }
    }

    fn refs(self: *Scan, items: []const ast.ValueRef, position: usize) !void {
        for (items) |item| try self.ref(item, position);
    }

    pub fn value(self: *Scan, item: ast.Value, position: usize) anyerror!void {
        try value_scanners.get(std.meta.activeTag(item))(self, item, position);
    }

    fn condition(self: *Scan, item: ast.Condition, position: usize) !void {
        try self.read(item.lhs, position);
        try self.value(item.rhs, position);
    }
};

const Scanner = *const fn (*Scan, *const Statement, usize) anyerror!void;

const scanners = blk: {
    var table = std.EnumArray(Tag, Scanner).initFill(&ignore);
    table.set(.var_decl, &varDecl);
    table.set(.assignment, &assignment);
    table.set(.store, &store);
    table.set(.call, &call);
    table.set(.builtin, &builtin);
    table.set(.label, &label);
    table.set(.exported_label, &exportedLabel);
    table.set(.conditional_goto, &conditionalGoto);
    table.set(.conditional_direct_goto, &conditionalDirectGoto);
    table.set(.goto, &goto);
    table.set(.break_loop, &breakLoop);
    table.set(.while_loop, &whileLoop);
    table.set(.do_while_loop, &doWhileLoop);
    table.set(.if_statement, &ifStatement);
    table.set(.labeled_block, &labeledBlock);
    table.set(.ordered_block, &orderedBlock);
    break :blk table;
};

fn ignore(_: *Scan, _: *const Statement, _: usize) !void {}

fn varDecl(scan: *Scan, statement: *const Statement, current: usize) !void {
    const decl = statement.var_decl;
    if (decl.is_const) return scanOptionalValue(scan, decl.value, current);
    const defined = decl.value != null or decl.allow_undefined_read;
    try scan.lifetimes.declare(.{
        .name = decl.name,
        .position = current,
        .automatic = decl.reg == null and decl.vector_reg == null,
        .initially_defined = defined,
        .data_type = decl.data_type,
        .fixed_reg = decl.reg,
        .fixed_vector_reg = decl.vector_reg,
    });
    try scanOptionalValue(scan, decl.value, current);
    if (defined) try scan.lifetimes.write(decl.name, current);
}

fn scanOptionalValue(scan: *Scan, item: ?ast.Value, position: usize) !void {
    try scan.value(item orelse return, position);
}

fn assignment(scan: *Scan, statement: *const Statement, current: usize) !void {
    const item = statement.assignment;
    try scan.value(item.lhs, current);
    try scanOptionalValue(scan, item.rhs, current);
    for (item.continuation) |step| try scan.value(step.rhs, current);
    try scan.lifetimes.write(item.destination, current);
}

fn store(scan: *Scan, statement: *const Statement, current: usize) !void {
    const item = statement.store;
    try scan.ref(item.address, current);
    try scan.ref(item.value, current);
    if (item.label_offset) |name| try scan.read(name, current);
}

fn call(scan: *Scan, statement: *const Statement, current: usize) !void {
    const item = statement.call;
    try scan.refs(item.arguments, current);
    try scan.optional(item.delay_slot);
    try scan.lifetimes.addCall(item.name, current, scan.position + 1);
}

fn label(scan: *Scan, statement: *const Statement, current: usize) !void {
    try scan.lifetimes.addLabel(statement.label, current, false);
}

fn exportedLabel(scan: *Scan, statement: *const Statement, current: usize) !void {
    try scan.lifetimes.addLabel(statement.exported_label, current, true);
}

fn conditionalGoto(scan: *Scan, statement: *const Statement, current: usize) !void {
    const branch = statement.conditional_goto;
    try scan.condition(branch.condition, current);
    try scan.lifetimes.addEdge(branch.target, current);
    try scan.optional(branch.delay_slot);
}

fn conditionalDirectGoto(scan: *Scan, statement: *const Statement, current: usize) !void {
    const branch = statement.conditional_direct_goto;
    try scan.condition(branch.condition, current);
    try scan.refs(branch.arguments, current);
    try scan.optional(branch.delay_slot);
}

fn goto(scan: *Scan, statement: *const Statement, current: usize) !void {
    try scan.lifetimes.addEdge(statement.goto.target, current);
    try scan.optional(statement.goto.delay_slot);
}

fn breakLoop(scan: *Scan, statement: *const Statement, _: usize) !void {
    try scan.optional(statement.break_loop.delay_slot);
}

fn whileLoop(scan: *Scan, statement: *const Statement, current: usize) !void {
    try scan.condition(statement.while_loop.condition, current);
    try scan.statements(statement.while_loop.statements);
}

/// The condition of a `do`/`while` loop has its own position after the body.
fn doWhileLoop(scan: *Scan, statement: *const Statement, _: usize) !void {
    const loop = statement.do_while_loop;
    try scan.statements(loop.statements);
    scan.position += 1;
    try scan.condition(loop.condition, scan.position);
    try scan.optional(loop.delay_slot);
}

fn ifStatement(scan: *Scan, statement: *const Statement, current: usize) !void {
    const branch = statement.if_statement;
    try scan.condition(branch.condition, current);
    try scan.optional(branch.delay_slot);
    try scan.statements(branch.then_statements);
    try scan.optional(branch.else_statements);
}

fn labeledBlock(scan: *Scan, statement: *const Statement, _: usize) !void {
    try scan.statements(statement.labeled_block.statements);
    try scan.optional(statement.labeled_block.exit_delay);
}

fn orderedBlock(scan: *Scan, statement: *const Statement, _: usize) !void {
    try scan.statements(statement.ordered_block);
}

// ----------------------------------------------------------------- builtins

fn builtin(scan: *Scan, statement: *const Statement, current: usize) !void {
    try builtin_scanners.get(std.meta.activeTag(statement.builtin))(scan, statement.builtin, current);
}

const BuiltinScanner = *const fn (*Scan, ast.Builtin, usize) anyerror!void;

const builtin_scanners = blk: {
    var table = std.EnumArray(std.meta.Tag(ast.Builtin), BuiltinScanner).initFill(&ignoreBuiltin);
    table.set(.tail, &tail);
    table.set(.jump, &jump);
    table.set(.direct_goto, &directGoto);
    table.set(.return_from_function, &returnFromFunction);
    table.set(.write_vector_control, &writeVectorControl);
    table.set(.vector_memory, &vectorMemory);
    table.set(.hardware_write, &hardwareWrite);
    break :blk table;
};

fn ignoreBuiltin(_: *Scan, _: ast.Builtin, _: usize) !void {}

fn tail(scan: *Scan, item: ast.Builtin, current: usize) !void {
    try scan.refs(item.tail.arguments, current);
    try scan.optional(item.tail.delay_slot);
}

fn jump(scan: *Scan, item: ast.Builtin, current: usize) !void {
    try scan.ref(item.jump.address, current);
    try scan.optional(item.jump.delay_slot);
}

fn directGoto(scan: *Scan, item: ast.Builtin, current: usize) !void {
    try scan.refs(item.direct_goto.arguments, current);
    try scan.optional(item.direct_goto.delay_slot);
}

fn returnFromFunction(scan: *Scan, item: ast.Builtin, _: usize) !void {
    try scan.optional(item.return_from_function);
}

fn writeVectorControl(scan: *Scan, item: ast.Builtin, current: usize) !void {
    try scan.ref(item.write_vector_control.value, current);
}

/// Vector loads define their register; stores read it.
fn vectorMemory(scan: *Scan, item: ast.Builtin, current: usize) !void {
    const memory = item.vector_memory;
    if (isVectorLoad(memory.operation)) {
        try scan.lifetimes.write(memory.vector.name, current);
    } else {
        try scan.read(memory.vector.name, current);
    }
    try scan.ref(memory.address, current);
}

pub fn isVectorLoad(operation: ast.VectorMemoryOperation) bool {
    return switch (operation) {
        .load16, .load32, .load64, .load128, .load_packed_signed, .load_packed_unsigned, .load_quad_lane, .load_right, .load_transpose => true,
        else => false,
    };
}

fn hardwareWrite(scan: *Scan, item: ast.Builtin, current: usize) !void {
    try scan.ref(item.hardware_write.value, current);
}

// ------------------------------------------------------------------- values

const ValueScanner = *const fn (*Scan, ast.Value, usize) anyerror!void;

const value_scanners = blk: {
    var table = std.EnumArray(ValueTag, ValueScanner).initFill(&ignoreValue);
    table.set(.ident, &identValue);
    table.set(.vector_access, &vectorAccessValue);
    table.set(.vector_operation, &vectorOperationValue);
    table.set(.vector_shift, &vectorShiftValue);
    table.set(.scalar_comparison, &comparisonValue);
    table.set(.signed_less_than, &signedLessThanValue);
    table.set(.bit_cast, &bitCastValue);
    table.set(.load, &loadValue);
    table.set(.scalar_expression, &expressionValue);
    break :blk table;
};

fn ignoreValue(_: *Scan, _: ast.Value, _: usize) !void {}

fn identValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.read(item.ident, position);
}

fn vectorAccessValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.read(item.vector_access.name, position);
}

fn vectorOperationValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.read(item.vector_operation.lhs.name, position);
    try scan.read(item.vector_operation.rhs.name, position);
}

fn vectorShiftValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.read(item.vector_shift.source.name, position);
}

fn comparisonValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.ref(item.scalar_comparison.lhs, position);
    try scan.ref(item.scalar_comparison.rhs, position);
}

fn signedLessThanValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.ref(item.signed_less_than.lhs, position);
    try scan.ref(item.signed_less_than.rhs, position);
}

fn bitCastValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.ref(item.bit_cast, position);
}

fn loadValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.ref(item.load.address, position);
    if (item.load.label_offset) |name| try scan.read(name, position);
}

fn expressionValue(scan: *Scan, item: ast.Value, position: usize) !void {
    try scan.value(item.scalar_expression.lhs, position);
    try scan.value(item.scalar_expression.rhs, position);
}

// ------------------------------------------------------- unstructured code

/// Raw assembly hides control flow and register use from the analysis.
pub fn containsUnstructuredControlFlow(statements: []const Statement) bool {
    const delays = ast_walk.DelaySet.initMany(&.{ .conditional_direct_goto, .break_loop, .return_from_function });
    return ast_walk.anyWith(statements, delays, {}, isAssembly);
}

fn isAssembly(_: void, statement: *const Statement) bool {
    return statement.* == .asm_line;
}

/// Without lifetime reuse only label names matter; they sit at position 0.
pub fn collectLabels(lifetimes: *Lifetimes, statements: []const Statement) !void {
    for (statements) |*statement| {
        try collectLabel(lifetimes, statement.*);
        const nested = ast_walk.structuredChildren(statement);
        for (nested.slice()) |list| try collectLabels(lifetimes, list);
    }
}

fn collectLabel(lifetimes: *Lifetimes, statement: Statement) !void {
    switch (statement) {
        .label => |name| try lifetimes.addLabel(name, 0, false),
        .exported_label => |name| try lifetimes.addLabel(name, 0, true),
        else => {},
    }
}

test "vector memory operations classify loads" {
    try std.testing.expect(isVectorLoad(.load_transpose));
    try std.testing.expect(!isVectorLoad(.store_right));
}
