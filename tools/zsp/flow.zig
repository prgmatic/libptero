//! The statement-position flow graph used by liveness queries. Each
//! position has at most two successors; position 0 is the function exit.
const std = @import("std");
const ast = @import("ast.zig");
const ast_walk = @import("ast_walk.zig");
const lifetimes_ = @import("lifetimes.zig");

const Lifetimes = lifetimes_.Lifetimes;
const Statement = ast.Statement;
const Tag = std.meta.Tag(Statement);

/// Delay slots that occupy flow positions.
const flow_delays = ast_walk.DelaySet.initMany(&.{
    .call, .goto, .conditional_goto, .conditional_direct_goto, .break_loop, .jump, .return_from_function,
});

/// Positions occupied by `statements` and everything nested in them.
pub fn countFlowStatements(statements: []const Statement) usize {
    var count = statements.len;
    for (statements) |*statement| count += nestedFlowCount(statement);
    return count;
}

/// Positions nested inside one statement; a `do`/`while` condition has its own.
pub fn nestedFlowCount(statement: *const Statement) usize {
    var count: usize = @intFromBool(statement.* == .do_while_loop);
    const nested = ast_walk.childrenWith(statement, flow_delays);
    for (nested.slice()) |list| count += countFlowStatements(list);
    return count;
}

const Step = struct { current: usize, nested: usize, next: usize };

pub const Builder = struct {
    lifetimes: *Lifetimes,
    position: usize = 0,

    pub fn init(lifetimes: *Lifetimes, statement_count: usize) !Builder {
        lifetimes.flow_statement_count = statement_count;
        try lifetimes.successors.appendNTimes(lifetimes.allocator, .{ 0, 0 }, statement_count + 1);
        try lifetimes.successor_counts.appendNTimes(lifetimes.allocator, 0, statement_count + 1);
        return .{ .lifetimes = lifetimes };
    }

    pub fn build(self: *Builder, statements: []const Statement, continuation: usize) anyerror!void {
        for (statements, 0..) |*statement, index| {
            self.position += 1;
            const current = self.position;
            const nested = nestedFlowCount(statement);
            const next = if (index + 1 < statements.len) current + nested + 1 else continuation;
            const step: Step = .{ .current = current, .nested = nested, .next = next };
            try builders.get(std.meta.activeTag(statement.*))(self, statement, step);
        }
    }

    fn optional(self: *Builder, list: ?[]const Statement, continuation: usize) !void {
        try self.build(list orelse return, continuation);
    }

    pub fn add(self: *Builder, position: usize, successor: usize) !void {
        if (position == 0 or successor == 0) return;
        try self.ensure(position);
        const lifetimes = self.lifetimes;
        const count = lifetimes.successor_counts.items[position];
        const existing = lifetimes.successors.items[position][0..count];
        if (std.mem.indexOfScalar(usize, existing, successor) != null) return;
        if (count == 2) return error.AnalysisCapacityExceeded;
        lifetimes.successors.items[position][count] = successor;
        lifetimes.successor_counts.items[position] += 1;
    }

    /// Positions past the counted statements come from slots the count
    /// does not include; give them storage rather than dropping edges.
    fn ensure(self: *Builder, position: usize) !void {
        const lifetimes = self.lifetimes;
        const missing = (position + 1) -| lifetimes.successors.items.len;
        try lifetimes.successors.appendNTimes(lifetimes.allocator, .{ 0, 0 }, missing);
        try lifetimes.successor_counts.appendNTimes(lifetimes.allocator, 0, missing);
    }

    /// Flows into an explicit slot, or straight to `target` without one.
    fn throughSlot(self: *Builder, step: Step, slot: ?[]const Statement, target: usize) !void {
        const statements = slot orelse return self.add(step.current, target);
        try self.add(step.current, step.current + 1);
        try self.build(statements, target);
    }

    /// Enters nested positions when there are any, else continues.
    fn intoNested(self: *Builder, step: Step) !void {
        try self.add(step.current, if (step.nested != 0) step.current + 1 else step.next);
    }

    fn pushLoop(self: *Builder, loop: lifetimes_.FlowLoop) !void {
        try self.lifetimes.flow_loops.append(self.lifetimes.allocator, loop);
    }

    fn popLoop(self: *Builder) void {
        _ = self.lifetimes.flow_loops.pop();
    }

    /// An unknown loop name disables lifetime reuse for the function.
    fn loopTarget(self: *Builder, name: ?[]const u8, want_continue: bool) usize {
        var index = self.lifetimes.flow_loops.items.len;
        while (index > 0) {
            index -= 1;
            const loop = self.lifetimes.flow_loops.items[index];
            if (!loopMatches(loop, name)) continue;
            return if (want_continue) loop.continue_position else loop.break_position;
        }
        self.lifetimes.reuse = false;
        return 0;
    }
};

/// An unlabeled `break` or `continue` names the innermost loop; blocks
/// need their label.
fn loopMatches(loop: lifetimes_.FlowLoop, name: ?[]const u8) bool {
    const requested = name orelse return loop.continue_position != 0;
    const actual = loop.name orelse return false;
    return std.mem.eql(u8, requested, actual);
}

const Handler = *const fn (*Builder, *const Statement, Step) anyerror!void;

const builders = blk: {
    var table = std.EnumArray(Tag, Handler).initFill(&sequential);
    table.set(.call, &call);
    table.set(.goto, &goto);
    table.set(.conditional_goto, &conditionalGoto);
    table.set(.conditional_direct_goto, &conditionalDirectGoto);
    table.set(.do_while_loop, &doWhileLoop);
    table.set(.break_loop, &breakLoop);
    table.set(.continue_loop, &continueLoop);
    table.set(.if_statement, &ifStatement);
    table.set(.labeled_block, &labeledBlock);
    table.set(.ordered_block, &orderedBlock);
    table.set(.builtin, &builtin);
    break :blk table;
};

fn sequential(builder: *Builder, _: *const Statement, step: Step) !void {
    try builder.add(step.current, step.next);
}

fn call(builder: *Builder, statement: *const Statement, step: Step) !void {
    try builder.throughSlot(step, statement.call.delay_slot, step.next);
}

fn goto(builder: *Builder, statement: *const Statement, step: Step) !void {
    const target = builder.lifetimes.labelPosition(statement.goto.target);
    try builder.throughSlot(step, statement.goto.delay_slot, target);
}

/// A conditional branch continues and branches; with a slot, the branch
/// edge leaves from the slot's last position.
fn conditionalGoto(builder: *Builder, statement: *const Statement, step: Step) !void {
    const branch = statement.conditional_goto;
    const target = builder.lifetimes.labelPosition(branch.target);
    if (branch.delay_slot) |delay| {
        try builder.throughSlot(step, delay, step.next);
        return builder.add(step.current + step.nested, target);
    }
    try builder.add(step.current, step.next);
    try builder.add(step.current, target);
}

fn conditionalDirectGoto(builder: *Builder, statement: *const Statement, step: Step) !void {
    try builder.throughSlot(step, statement.conditional_direct_goto.delay_slot, step.next);
}

fn doWhileLoop(builder: *Builder, statement: *const Statement, step: Step) !void {
    const loop = statement.do_while_loop;
    const body_start = step.current + 1;
    const condition = step.current + countFlowStatements(loop.statements) + 1;
    try builder.add(step.current, if (loop.statements.len == 0) condition else body_start);
    try builder.pushLoop(.{ .name = loop.label, .continue_position = condition, .break_position = step.next });
    try builder.build(loop.statements, condition);
    builder.popLoop();
    builder.position += 1;
    const back: Back = .{ .condition = condition, .body_start = body_start, .exits = loop.condition != null };
    try loopBack(builder, step, loop.delay_slot, back);
}

/// The edges of a loop's condition position.
const Back = struct { condition: usize, body_start: usize, exits: bool };

/// The condition repeats the body; a slot runs before either edge. A
/// loop without a condition never exits there.
fn loopBack(builder: *Builder, step: Step, slot: ?[]const Statement, back: Back) !void {
    if (slot) |delay| {
        try builder.add(back.condition, back.condition + 1);
        try builder.build(delay, if (back.exits) step.next else back.body_start);
        return builder.add(step.current + step.nested, back.body_start);
    }
    try builder.add(back.condition, back.body_start);
    if (back.exits) try builder.add(back.condition, step.next);
}

fn breakLoop(builder: *Builder, statement: *const Statement, step: Step) !void {
    const transfer = statement.break_loop;
    try builder.throughSlot(step, transfer.delay_slot, builder.loopTarget(transfer.label, false));
}

fn continueLoop(builder: *Builder, statement: *const Statement, step: Step) !void {
    try builder.add(step.current, builder.loopTarget(statement.continue_loop, true));
}

fn optionalCount(list: ?[]const Statement) usize {
    return countFlowStatements(list orelse return 0);
}

fn ifStatement(builder: *Builder, statement: *const Statement, step: Step) !void {
    const branch = statement.if_statement;
    const delay_count = optionalCount(branch.delay_slot);
    const then_count = countFlowStatements(branch.then_statements);
    const then_start = step.current + delay_count + 1;
    try builder.throughSlot(step, branch.delay_slot, if (then_count != 0) then_start else step.next);
    try builder.build(branch.then_statements, step.next);
    // The false edge leaves from the branch, after any slot.
    const branch_position = if (delay_count != 0) step.current + delay_count else step.current;
    try elseEdge(builder, branch.else_statements, branch_position, then_start + then_count, step.next);
}

fn elseEdge(builder: *Builder, else_statements: ?[]const Statement, branch_position: usize, else_start: usize, next: usize) !void {
    const statements = else_statements orelse return builder.add(branch_position, next);
    try builder.add(branch_position, if (statements.len != 0) else_start else next);
    try builder.build(statements, next);
}

fn labeledBlock(builder: *Builder, statement: *const Statement, step: Step) !void {
    const block = statement.labeled_block;
    const exit_count = optionalCount(block.exit_delay);
    const exit_start = if (exit_count != 0) step.current + countFlowStatements(block.statements) + 1 else step.next;
    try builder.intoNested(step);
    try builder.pushLoop(.{ .name = block.label, .continue_position = 0, .break_position = exit_start });
    try builder.build(block.statements, exit_start);
    builder.popLoop();
    try builder.optional(block.exit_delay, step.next);
}

fn orderedBlock(builder: *Builder, statement: *const Statement, step: Step) !void {
    try builder.intoNested(step);
    try builder.build(statement.ordered_block, step.next);
}

/// Jumps and returns leave the function; their slots run first.
fn builtin(builder: *Builder, statement: *const Statement, step: Step) !void {
    switch (statement.builtin) {
        .jump, .return_from_function => try leaveThroughSlot(builder, step, ast_walk.builtinDelaySlot(&statement.builtin)),
        .indirect_call => |item| try indirectCall(builder, step, item.delay_slot),
        .direct_goto, .tail => {},
        else => try builder.add(step.current, step.next),
    }
}

fn leaveThroughSlot(builder: *Builder, step: Step, slot: ?[]const Statement) !void {
    const statements = slot orelse return;
    try builder.add(step.current, step.current + 1);
    try builder.build(statements, 0);
}

fn indirectCall(builder: *Builder, step: Step, slot: ?[]const Statement) !void {
    try builder.add(step.current, step.next);
    try builder.optional(slot, step.next);
}

const testing = std.testing;

test "flow counts include slots and do-while conditions" {
    var body = [_]Statement{.{ .builtin = .nop }};
    var statements = [_]Statement{
        .{ .do_while_loop = .{ .condition = .{ .lhs = "x", .op = .ne, .rhs = .{ .number = 0 } }, .statements = &body, .delay_slot = &body } },
        .{ .builtin = .{ .tail = .{ .target = .{ .name = "f" }, .arguments = &.{}, .delay_slot = &body } } },
    };
    try testing.expectEqual(@as(usize, 5), countFlowStatements(&statements));
}

test "successors are deduplicated and capped at two" {
    var lifetimes = Lifetimes.init(testing.allocator);
    defer lifetimes.deinit();
    var builder = try Builder.init(&lifetimes, 2);
    try builder.add(1, 2);
    try builder.add(1, 2);
    try builder.add(1, 3);
    try testing.expectError(error.AnalysisCapacityExceeded, builder.add(1, 4));
    try builder.add(5, 1);
    try builder.add(0, 1);
    try testing.expectEqual(@as(usize, 2), lifetimes.successorsOf(1).len);
    try testing.expectEqual(@as(usize, 0), builder.loopTarget("missing", false));
    try testing.expect(!lifetimes.reuse);
}
