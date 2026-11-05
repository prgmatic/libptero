//! Structured control flow, local branches, and condition lowering.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const ast_walk = @import("ast_walk.zig");
const common = @import("emit_common.zig");
const calls = @import("emit_calls.zig");
const ir = @import("ir.zig");
const operands = @import("emit_operands.zig");
const statements_ = @import("emit_statements.zig");
const registers = @import("registers.zig");

const Gen = common.Gen;
const Register = ast.Register;
const Statement = ast.Statement;
const Symbol = analysis.Symbol;
const scratch = registers.compiler_scratch;
const writeStatements = statements_.writeStatements;

// -------------------------------------------------------------- conditions

/// The right side of a condition: a register or an immediate.
const ConditionRhs = union(enum) { reg: Register, immediate: i64 };

fn conditionLhs(g: Gen, condition: ast.Condition) !Symbol {
    const lhs = try g.lookup(condition.lhs);
    _ = lhs.reg orelse return error.ConditionLhsMustBeRegister;
    return lhs;
}

fn conditionRhs(g: Gen, lhs: Symbol, rhs: ast.Value) !ConditionRhs {
    if (rhs == .number) return .{ .immediate = rhs.number };
    const name = common.identName(rhs) orelse return error.ConditionRhsMustBeRegisterOrNumber;
    const symbol = try g.lookup(name);
    try common.expectSameType(lhs, symbol);
    if (symbol.reg) |reg| return .{ .reg = reg };
    return .{ .immediate = symbol.constant orelse return error.ExpectedConstant };
}

fn rhsRegister(g: Gen, rhs: ConditionRhs) !Register {
    return switch (rhs) {
        .reg => |reg| reg,
        .immediate => |immediate| operands.loadImmediate(g, immediate),
    };
}

const Branch = struct { g: Gen, lhs: Symbol, target: []const u8, emit_nop: bool };

/// Branches to `LABEL_<suffix>_<label>` when `condition` is false.
pub fn writeConditionBranchFalse(g: Gen, condition: ast.Condition, suffix: []const u8, label: usize, emit_nop: bool) !void {
    const lhs = try conditionLhs(g, condition);
    const rhs = try conditionRhs(g, lhs, condition.rhs);
    const branch: Branch = .{ .g = g, .lhs = lhs, .target = try g.localLabel(suffix, label), .emit_nop = emit_nop };
    switch (condition.op) {
        .eq, .ne => try writeEqualityBranch(branch, condition.op, rhs),
        else => try writeOrderedBranch(branch, condition.op, rhs),
    }
    if (emit_nop) try g.out.nop();
}

fn writeEqualityBranch(branch: Branch, op: ast.CompareOp, rhs: ConditionRhs) !void {
    const rhs_reg = try rhsRegister(branch.g, rhs);
    try branch.g.out.branch(if (op == .eq) .bne else .beq, branch.lhs.reg.?, rhs_reg, branch.target);
}

fn writeOrderedBranch(branch: Branch, op: ast.CompareOp, rhs: ConditionRhs) !void {
    if (rhs == .immediate and try writeImmediateOrderedBranch(branch, op, rhs.immediate)) return;
    const rhs_reg = try rhsRegister(branch.g, rhs);
    try writeSetLessThan(branch.g, branch.lhs, op, rhs_reg);
    const taken_when_clear = op == .lt or op == .gt;
    try branch.g.out.branch(if (taken_when_clear) .beq else .bne, scratch, .zero, branch.target);
}

/// `$at = lhs < rhs`, or `rhs < lhs` for `>` and `<=`.
fn writeSetLessThan(g: Gen, lhs: Symbol, op: ast.CompareOp, rhs_reg: Register) !void {
    const reverse = op == .gt or op == .le;
    const first = if (reverse) rhs_reg else lhs.reg.?;
    const second = if (reverse) lhs.reg.? else rhs_reg;
    try g.out.register(if (common.isSigned(lhs.data_type)) .slt else .sltu, scratch, first, second);
}

/// Inverse sign tests against zero, used for false branches.
fn falseZeroBranch(op: ast.CompareOp) ir.Op {
    return switch (op) {
        .lt => .bgez,
        .le => .bgtz,
        .gt => .blez,
        else => .bltz,
    };
}

/// Sign tests against zero, used for direct true branches.
fn trueZeroBranch(op: ast.CompareOp) ir.Op {
    return falseZeroBranch(common.invertComparison(op));
}

/// `x > n` and `x <= n` compare against `n + 1`; null when that overflows.
fn adjustedImmediate(op: ast.CompareOp, immediate: i64) ?i64 {
    if (op != .gt and op != .le) return immediate;
    return std.math.add(i64, immediate, 1) catch null;
}

/// Immediate comparisons that avoid materializing the constant. Returns
/// false when the generic register form is needed.
fn writeImmediateOrderedBranch(branch: Branch, op: ast.CompareOp, immediate: i64) !bool {
    if (zeroTestBranch(common.isSigned(branch.lhs.data_type), op, immediate)) |zero_op| {
        try branch.g.out.branchZero(zero_op, branch.lhs.reg.?, branch.target);
        return true;
    }
    const adjusted = fittingImmediate(op, immediate) orelse return false;
    try writeSetLessThanImmediate(branch.g, branch.lhs, adjusted);
    try branch.g.out.branch(if (op == .lt or op == .le) .beq else .bne, scratch, .zero, branch.target);
    return true;
}

/// The false-branch sign test equivalent to comparing with `immediate`:
/// signed comparisons with zero, and unsigned ones at the sign bit.
fn zeroTestBranch(signed: bool, op: ast.CompareOp, immediate: i64) ?ir.Op {
    if (signed) return if (immediate == 0) falseZeroBranch(op) else null;
    if (immediate != 0x80000000) return null;
    return signBitBranch(op);
}

/// Unsigned `x < 0x80000000` holds exactly when the sign bit is clear.
fn signBitBranch(op: ast.CompareOp) ?ir.Op {
    return switch (op) {
        .lt => .bltz,
        .ge => .bgez,
        else => null,
    };
}

/// The adjusted immediate when it fits `slti`/`sltiu`.
fn fittingImmediate(op: ast.CompareOp, immediate: i64) ?i64 {
    const adjusted = adjustedImmediate(op, immediate) orelse return null;
    return if (common.fitsSigned16(adjusted)) adjusted else null;
}

fn writeSetLessThanImmediate(g: Gen, lhs: Symbol, immediate: i64) !void {
    try g.out.immediate(if (common.isSigned(lhs.data_type)) .slti else .sltiu, scratch, lhs.reg.?, immediate);
}

// ----------------------------------------------------------- local gotos

pub fn writeGoto(g: Gen, statement: *const Statement) !void {
    const branch = statement.goto;
    const target = try g.localLabel(branch.target, 0);
    try g.out.jump(if (branch.encoding == .jump) .j else .b, target);
    try statements_.writeConditionalDirectDelaySlot(g, branch.delay_slot);
}

/// Equality tests against exported or external labels branch directly;
/// other conditions branch past an inverted test.
pub fn writeConditionalGoto(g: Gen, statement: *const Statement) !void {
    const branch = statement.conditional_goto;
    const local = g.context.findLifetimeLabel(branch.target);
    const direct = local == null or local.?.exported;
    if (direct and (branch.condition.op == .eq or branch.condition.op == .ne)) return writeDirectEqualityGoto(g, branch);
    var inverse = branch.condition;
    inverse.op = common.invertComparison(inverse.op);
    try writeConditionBranchFalse(g, inverse, branch.target, 0, branch.delay_slot == null);
    try statements_.writeStructuredDelaySlot(g, branch.delay_slot);
}

fn writeDirectEqualityGoto(g: Gen, branch: @FieldType(Statement, "conditional_goto")) !void {
    const lhs = try conditionLhs(g, branch.condition);
    const rhs = try directEqualityRhs(g, lhs, branch.condition.rhs);
    try g.out.branch(if (branch.condition.op == .eq) .beq else .bne, lhs.reg.?, rhs, branch.target);
    try statements_.writeDelaySlot(g, branch.delay_slot);
}

fn directEqualityRhs(g: Gen, lhs: Symbol, rhs: ast.Value) !Register {
    if (rhs == .number) return if (rhs.number == 0) .zero else error.ConditionRhsMustBeRegisterOrNumber;
    const name = common.identName(rhs) orelse return error.ConditionRhsMustBeRegisterOrNumber;
    const symbol = try g.lookup(name);
    try common.expectSameType(lhs, symbol);
    return symbol.reg orelse error.ConditionRhsMustBeRegisterOrNumber;
}

// ------------------------------------------------- conditional direct jumps

const DirectGoto = @FieldType(Statement, "conditional_direct_goto");

/// `if (condition) jump target(...)`: a branch straight to a function.
/// `if (c) tail f(args)`. The argument setup must not disturb the test, so
/// a single setup instruction goes in the branch's delay slot when the
/// source gives none; longer setup runs first and must not conflict.
pub fn writeConditionalDirectGoto(g: Gen, statement: *const Statement) !void {
    const branch = statement.conditional_direct_goto;
    try common.expectLocal(branch.target.module);
    var setup: Setup = .{};
    if (branch.typed) {
        const start = g.out.items.items.len;
        try calls.writeFunctionArguments(g, try common.findFunction(g, branch.target.name), branch.arguments, true);
        try setup.take(&g.out.items, start);
    }
    const condition_start = g.out.items.items.len;
    try writeDirectTest(g, branch);
    if (setup.len == 1 and branch.delay_slot == null and g.context.shared_exit_label == null) {
        return g.out.item(setup.items[0]);
    }
    try setup.placeBefore(g.out, condition_start);
    try statements_.writeConditionalDirectDelaySlot(g, branch.delay_slot);
}

fn writeDirectTest(g: Gen, branch: DirectGoto) !void {
    const lhs = try conditionLhs(g, branch.condition);
    const target = branch.target.name;
    switch (branch.condition.op) {
        .eq, .ne => try writeDirectEqualityJump(g, lhs, branch.condition, target),
        else => try writeDirectOrderedJump(g, lhs, branch.condition, target),
    }
}

/// Argument setup held aside while the condition is emitted.
const Setup = struct {
    items: [16]ir.Item = undefined,
    len: usize = 0,

    fn take(self: *Setup, list: *std.ArrayList(ir.Item), start: usize) !void {
        const taken = list.items[start..];
        if (taken.len > self.items.len) return error.TooManyFunctionArguments;
        @memcpy(self.items[0..taken.len], taken);
        self.len = taken.len;
        list.shrinkRetainingCapacity(start);
    }

    /// Reinserts the setup ahead of the test, which must neither read a
    /// register the setup writes nor overwrite one it sets.
    fn placeBefore(self: *const Setup, out: *@import("Emitter.zig"), condition_start: usize) !void {
        const setup = self.items[0..self.len];
        const condition = out.items.items[condition_start..];
        if (scalarMask(setup, .writes) & (scalarMask(condition, .reads) | scalarMask(condition, .writes)) != 0) {
            return error.ConditionalTailArgumentConflict;
        }
        try out.items.insertSlice(out.arena.allocator(), condition_start, setup);
    }
};

fn scalarMask(items: []const ir.Item, comptime kind: enum { reads, writes }) u32 {
    const effects = @import("ir_effects.zig");
    var mask: u32 = 0;
    for (items) |entry| {
        if (entry != .instruction) continue;
        const effect = effects.of(entry.instruction);
        mask |= if (kind == .reads) effect.scalar_reads else effect.scalar_writes;
    }
    return mask;
}

fn writeDirectOrderedJump(g: Gen, lhs: Symbol, condition: ast.Condition, target: []const u8) !void {
    if (condition.rhs == .number and try writeDirectImmediateJump(g, lhs, condition.op, condition.rhs.number, target)) return;
    const name = common.identName(condition.rhs) orelse return error.ConditionalDirectGotoRequiresRegisterOperands;
    const rhs = try g.lookup(name);
    try common.expectSameType(lhs, rhs);
    try writeSetLessThan(g, lhs, condition.op, rhs.reg orelse return error.ConditionRhsMustBeRegisterOrNumber);
    try g.out.branchZero(setLessThanBranch(condition.op), scratch, target);
}

/// `slt` leaves 1 in scratch for `<` and, with swapped operands, for `>`.
fn setLessThanBranch(op: ast.CompareOp) ir.Op {
    return if (op == .lt or op == .gt) .bnez else .beqz;
}

fn writeDirectImmediateJump(g: Gen, lhs: Symbol, op: ast.CompareOp, immediate: i64, target: []const u8) !bool {
    if (immediate == 0 and common.isSigned(lhs.data_type)) {
        try g.out.branchZero(trueZeroBranch(op), lhs.reg.?, target);
        return true;
    }
    const adjusted = fittingImmediate(op, immediate) orelse return false;
    try writeSetLessThanImmediate(g, lhs, adjusted);
    try g.out.branchZero(if (op == .lt or op == .le) .bnez else .beqz, scratch, target);
    return true;
}

/// Direct jumps accept a literal or a register, not a named constant.
fn directJumpRhs(g: Gen, lhs: Symbol, rhs: ast.Value) !ConditionRhs {
    if (rhs == .number) return .{ .immediate = rhs.number };
    const name = common.identName(rhs) orelse return error.ConditionRhsMustBeRegisterOrNumber;
    const symbol = try g.lookup(name);
    try common.expectSameType(lhs, symbol);
    return .{ .reg = symbol.reg orelse return error.ConditionRhsMustBeRegisterOrNumber };
}

fn writeDirectEqualityJump(g: Gen, lhs: Symbol, condition: ast.Condition, target: []const u8) !void {
    const rhs = try directJumpRhs(g, lhs, condition.rhs);
    const equal = condition.op == .eq;
    if (rhs == .immediate and rhs.immediate == 0) return g.out.branchZero(if (equal) .beqz else .bnez, lhs.reg.?, target);
    try g.out.branch(if (equal) .beq else .bne, lhs.reg.?, try scratchRegister(g, rhs), target);
}

/// A register operand, materializing an immediate in `$at`.
fn scratchRegister(g: Gen, rhs: ConditionRhs) !Register {
    if (rhs == .reg) return rhs.reg;
    try operands.loadImmediateInto(g.out, scratch, rhs.immediate);
    return scratch;
}

// -------------------------------------------------------- loops and blocks

const EmissionLoop = @import("context.zig").EmissionLoop;

fn pushLoop(g: Gen, loop: EmissionLoop) !void {
    try g.context.emission_loops.append(g.context.allocator, loop);
}

fn popLoop(g: Gen) void {
    _ = g.context.emission_loops.pop();
}

/// The innermost enclosing loop or block, or the one named `name`.
fn findLoop(g: Gen, name: ?[]const u8) !EmissionLoop {
    var index = g.context.emission_loops.items.len;
    while (index > 0) {
        index -= 1;
        const loop = g.context.emission_loops.items[index];
        if (loopMatches(loop, name)) return loop;
    }
    return error.UnknownLoopLabel;
}

/// An unlabeled `break` or `continue` names the innermost loop; blocks
/// need their label.
fn loopMatches(loop: EmissionLoop, name: ?[]const u8) bool {
    const requested = name orelse return loop.continue_suffix.len != 0;
    const actual = loop.name orelse return false;
    return std.mem.eql(u8, requested, actual);
}

/// Writes statements in their own symbol scope.
fn writeScoped(g: Gen, statements: []const Statement) !void {
    const scope = g.context.pushScope();
    defer g.context.popScope(scope);
    try writeStatements(g, statements);
}

fn terminatesControlFlow(statements: []const Statement) bool {
    if (statements.len == 0) return false;
    return switch (statements[statements.len - 1]) {
        .break_loop, .continue_loop, .goto => true,
        .builtin => |builtin| isTerminalBuiltin(builtin),
        else => false,
    };
}

pub fn isTerminalBuiltin(builtin: ast.Builtin) bool {
    return switch (builtin) {
        .jump, .return_from_function, .direct_goto, .tail => true,
        else => false,
    };
}

pub fn writeContinue(g: Gen, statement: *const Statement) !void {
    const loop = try findLoop(g, statement.continue_loop);
    if (loop.continue_suffix.len == 0) return error.CannotContinueBlock;
    try g.out.jump(.j, try g.localLabel(loop.continue_suffix, loop.label));
    try g.out.nop();
}

pub fn writeBreak(g: Gen, statement: *const Statement) !void {
    const transfer = statement.break_loop;
    const loop = try findLoop(g, transfer.label);
    try g.out.jump(.j, try g.localLabel(loop.break_suffix, loop.label));
    try statements_.writeConditionalDirectDelaySlot(g, transfer.delay_slot);
}

fn isContinue(_: void, statement: *const Statement) bool {
    return statement.* == .continue_loop;
}

pub fn writeDoWhile(g: Gen, statement: *const Statement) !void {
    const loop = statement.do_while_loop;
    const label = g.context.allocLabel();
    try pushLoop(g, .{ .name = loop.label, .label = label, .continue_suffix = "dowhilecond", .break_suffix = "dowhileend" });
    defer popLoop(g);
    // The condition and slot may read values declared in the body.
    const scope = g.context.pushScope();
    defer g.context.popScope(scope);
    try g.out.label(try g.localLabel("dowhile", label));
    try writeStatements(g, loop.statements);
    if (ast_walk.any(loop.statements, {}, isContinue)) try g.out.label(try g.localLabel("dowhilecond", label));
    g.advance(1);
    try writeLoopBack(g, loop.condition, label, loop.delay_slot == null);
    try statements_.writeStructuredDelaySlot(g, loop.delay_slot);
    try g.out.label(try g.localLabel("dowhileend", label));
}

/// Branches back to the loop top while `condition` holds, or always.
fn writeLoopBack(g: Gen, condition: ?ast.Condition, label: usize, emit_nop: bool) !void {
    var inverse = condition orelse {
        try g.out.jump(.j, try g.localLabel("dowhile", label));
        if (emit_nop) try g.out.nop();
        return;
    };
    inverse.op = common.invertComparison(inverse.op);
    try writeConditionBranchFalse(g, inverse, "dowhile", label, emit_nop);
}

const Block = @FieldType(Statement, "labeled_block");

/// A terminal conditional exit without its own slot may share the block's
/// exit slot.
fn canShareExit(block: Block) bool {
    if (block.exit_delay == null or block.statements.len == 0) return false;
    const last = &block.statements[block.statements.len - 1];
    return isSharableExit(last.*) and @import("ast_walk.zig").delaySlot(last) == null;
}

fn isSharableExit(statement: Statement) bool {
    return statement == .conditional_direct_goto or statement == .goto or statement == .break_loop;
}

pub fn writeLabeledBlock(g: Gen, statement: *const Statement) !void {
    const block = statement.labeled_block;
    const label = g.context.allocLabel();
    try pushLoop(g, .{ .name = block.label, .label = label, .continue_suffix = "", .break_suffix = "blockend" });
    defer popLoop(g);
    const scope = g.context.pushScope();
    defer g.context.popScope(scope);
    if (canShareExit(block)) return writeSharedExitBlock(g, block, label);
    try writeStatements(g, block.statements);
    try g.out.label(try g.localLabel("blockend", label));
    if (block.exit_delay) |delay| try writeStatements(g, delay);
}

fn writeSharedExitBlock(g: Gen, block: Block, label: usize) !void {
    const last = block.statements.len - 1;
    try writeStatements(g, block.statements[0..last]);
    const context = g.context;
    const saved = .{ context.shared_exit_label, context.shared_exit_delay, context.shared_exit_consumed };
    context.shared_exit_label = label;
    context.shared_exit_delay = block.exit_delay;
    context.shared_exit_consumed = false;
    defer {
        context.shared_exit_label = saved[0];
        context.shared_exit_delay = saved[1];
        context.shared_exit_consumed = saved[2];
    }
    try writeStatements(g, block.statements[last..]);
    if (context.shared_exit_consumed) return;
    try g.out.label(try g.localLabel("blockend", label));
    try writeStatements(g, block.exit_delay.?);
}

// -------------------------------------------------------------- if / else

const If = @FieldType(Statement, "if_statement");

pub fn writeIf(g: Gen, statement: *const Statement) !void {
    const branch = statement.if_statement;
    const label = g.context.allocLabel();
    if (try conditionalExit(g, branch)) |exit| return writeConditionalExit(g, branch, exit);
    const then_terminates = terminatesControlFlow(branch.then_statements);
    const else_terminates = if (branch.else_statements) |items| terminatesControlFlow(items) else false;
    if (branch.else_statements != null and else_terminates and !then_terminates) return writeReorderedIf(g, branch, label);
    return writeOrderedIf(g, branch, label, then_terminates);
}

/// Where `if (c) { break; }` or `if (c) { continue; }` goes, which
/// lowers to one branch.
const Exit = struct { suffix: []const u8, label: usize, delay_slot: ?[]const Statement };

fn conditionalExit(g: Gen, branch: If) !?Exit {
    if (branch.else_statements != null or branch.then_statements.len != 1) return null;
    return switch (branch.then_statements[0]) {
        .break_loop => |transfer| try breakExit(g, transfer),
        .continue_loop => |name| try continueExit(g, name),
        else => null,
    };
}

fn breakExit(g: Gen, transfer: ast.BreakTransfer) !Exit {
    const loop = try findLoop(g, transfer.label);
    return .{ .suffix = loop.break_suffix, .label = loop.label, .delay_slot = transfer.delay_slot };
}

fn continueExit(g: Gen, name: ?[]const u8) !Exit {
    const loop = try findLoop(g, name);
    if (loop.continue_suffix.len == 0) return error.CannotContinueBlock;
    return .{ .suffix = loop.continue_suffix, .label = loop.label, .delay_slot = null };
}

fn writeConditionalExit(g: Gen, branch: If, exit: Exit) !void {
    if (branch.delay_slot != null and exit.delay_slot != null) return error.MultipleDelaySlots;
    const delay_slot = branch.delay_slot orelse exit.delay_slot;
    var inverse = branch.condition;
    inverse.op = common.invertComparison(inverse.op);
    try writeConditionBranchFalse(g, inverse, exit.suffix, exit.label, delay_slot == null);
    try statements_.writeStructuredDelaySlot(g, delay_slot);
    g.advance(1);
}

/// When only the else arm terminates, it is placed first so the then arm
/// falls through to the end without a jump.
/// `if (c) { ...; tail f(); } rest` where `rest` also ends in a transfer:
/// the common path falls through into `rest` and the body is placed after
/// it, so it costs no taken branch. Not used when `rest` must fall through
/// into the next function.
pub fn isColdIf(g: Gen, statements: []const Statement, index: usize) bool {
    if (statements[index] != .if_statement) return false;
    const branch = statements[index].if_statement;
    if (branch.else_statements != null or !terminatesControlFlow(branch.then_statements)) return false;
    const rest = statements[index + 1 ..];
    if (!terminatesControlFlow(rest) or isSingleExit(branch)) return false;
    return !reachesOmittedTail(g, branch, rest);
}

fn isSingleExit(branch: If) bool {
    if (branch.then_statements.len != 1) return false;
    const only = branch.then_statements[0];
    return only == .break_loop or only == .continue_loop;
}

fn reachesOmittedTail(g: Gen, branch: If, rest: []const Statement) bool {
    if (g.context.omitted_tail_target == null) return false;
    const end = g.context.statement_position + analysis.countFlowStatements(branch.then_statements) + analysis.countFlowStatements(rest);
    return end >= g.context.omitted_tail_position;
}

pub fn writeColdIf(g: Gen, statement: *const Statement, rest: []const Statement) !void {
    const branch = statement.if_statement;
    const label = g.context.allocLabel();
    var inverse = branch.condition;
    inverse.op = common.invertComparison(inverse.op);
    try writeConditionBranchFalse(g, inverse, "ifthen", label, branch.delay_slot == null);
    try statements_.writeStructuredDelaySlot(g, branch.delay_slot);
    const source_position = g.context.statement_position;
    g.context.statement_position = source_position + analysis.countFlowStatements(branch.then_statements);
    try writeStatements(g, rest);
    const end_position = g.context.statement_position;
    try g.out.label(try g.localLabel("ifthen", label));
    g.context.statement_position = source_position;
    try writeScoped(g, branch.then_statements);
    g.context.statement_position = end_position;
}

fn writeReorderedIf(g: Gen, branch: If, label: usize) !void {
    var inverse = branch.condition;
    inverse.op = common.invertComparison(inverse.op);
    try writeConditionBranchFalse(g, inverse, "ifthen", label, branch.delay_slot == null);
    try statements_.writeStructuredDelaySlot(g, branch.delay_slot);
    const source_position = g.context.statement_position;
    const then_count = analysis.countFlowStatements(branch.then_statements);
    const else_statements = branch.else_statements.?;
    g.context.statement_position = source_position + then_count;
    try writeScoped(g, else_statements);
    try g.out.label(try g.localLabel("ifthen", label));
    g.context.statement_position = source_position;
    try writeScoped(g, branch.then_statements);
    g.context.statement_position = source_position + then_count + analysis.countFlowStatements(else_statements);
    try g.out.label(try g.localLabel("ifend", label));
}

fn writeOrderedIf(g: Gen, branch: If, label: usize, then_terminates: bool) !void {
    const false_suffix: []const u8 = if (branch.else_statements != null) "ifelse" else "ifend";
    try writeConditionBranchFalse(g, branch.condition, false_suffix, label, branch.delay_slot == null);
    try statements_.writeStructuredDelaySlot(g, branch.delay_slot);
    try writeScoped(g, branch.then_statements);
    if (branch.else_statements) |else_statements| {
        if (!then_terminates) {
            try g.out.jump(.j, try g.localLabel("ifend", label));
            try g.out.nop();
        }
        try g.out.label(try g.localLabel("ifelse", label));
        try writeScoped(g, else_statements);
    }
    try g.out.label(try g.localLabel("ifend", label));
}

test "branch selection tables invert conditions consistently" {
    try std.testing.expectEqual(ir.Op.bgez, falseZeroBranch(.lt));
    try std.testing.expectEqual(ir.Op.bltz, falseZeroBranch(.ge));
    try std.testing.expectEqual(ir.Op.bltz, trueZeroBranch(.lt));
    try std.testing.expectEqual(ir.Op.blez, trueZeroBranch(.le));
    try std.testing.expectEqual(ir.Op.bgtz, trueZeroBranch(.gt));
    try std.testing.expectEqual(ir.Op.bgez, trueZeroBranch(.ge));
    try std.testing.expectEqual(@as(?i64, null), adjustedImmediate(.gt, std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(?i64, 5), adjustedImmediate(.lt, 5));
    try std.testing.expect(!terminatesControlFlow(&.{}));
}
