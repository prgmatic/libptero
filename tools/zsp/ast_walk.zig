//! Uniform access to the statement lists nested inside a statement, so
//! recursive queries need not repeat the statement grammar.
const std = @import("std");
const ast = @import("ast.zig");

const Statement = ast.Statement;
const Tag = std.meta.Tag(Statement);
const BuiltinTag = std.meta.Tag(ast.Builtin);

/// Up to three nested lists, in source order.
pub const Children = struct {
    lists: [3][]const Statement = .{ &.{}, &.{}, &.{} },
    len: usize = 0,

    fn add(self: *Children, list: ?[]const Statement) void {
        const items = list orelse return;
        self.lists[self.len] = items;
        self.len += 1;
    }

    pub fn slice(self: *const Children) []const []const Statement {
        return self.lists[0..self.len];
    }
};

/// Every nested list: structured bodies and transfer delay slots.
pub fn children(statement: *const Statement) Children {
    var result: Children = .{};
    child_readers.get(std.meta.activeTag(statement.*))(statement, &result);
    return result;
}

/// Calls `visit` on each statement and, depth-first, on nested statements.
/// Stops at the first `true` and returns it.
pub fn any(statements: []const Statement, context: anytype, comptime visit: fn (@TypeOf(context), *const Statement) bool) bool {
    for (statements) |*statement| {
        if (visit(context, statement)) return true;
        const nested = children(statement);
        for (nested.slice()) |list| if (any(list, context, visit)) return true;
    }
    return false;
}

/// The delay slot written on a transfer statement, if any.
pub fn delaySlot(statement: *const Statement) ?[]const Statement {
    return delay_readers.get(std.meta.activeTag(statement.*))(statement);
}

const DelayReader = *const fn (*const Statement) ?[]const Statement;

const delay_readers = blk: {
    var table = std.EnumArray(Tag, DelayReader).initFill(&noDelay);
    table.set(.call, &callDelay);
    table.set(.goto, &gotoDelay);
    table.set(.conditional_goto, &conditionalGotoDelay);
    table.set(.conditional_direct_goto, &conditionalDirectDelay);
    table.set(.break_loop, &breakDelay);
    table.set(.builtin, &builtinDelay);
    break :blk table;
};

fn noDelay(_: *const Statement) ?[]const Statement {
    return null;
}

fn callDelay(statement: *const Statement) ?[]const Statement {
    return statement.call.delay_slot;
}

fn gotoDelay(statement: *const Statement) ?[]const Statement {
    return statement.goto.delay_slot;
}

fn conditionalGotoDelay(statement: *const Statement) ?[]const Statement {
    return statement.conditional_goto.delay_slot;
}

fn conditionalDirectDelay(statement: *const Statement) ?[]const Statement {
    return statement.conditional_direct_goto.delay_slot;
}

fn breakDelay(statement: *const Statement) ?[]const Statement {
    return statement.break_loop.delay_slot;
}

fn builtinDelay(statement: *const Statement) ?[]const Statement {
    return builtinDelaySlot(&statement.builtin);
}

/// The delay slot of a transfer builtin, if any.
pub fn builtinDelaySlot(builtin: *const ast.Builtin) ?[]const Statement {
    return switch (builtin.*) {
        .jump => |jump| jump.delay_slot,
        .indirect_call => |call| call.delay_slot,
        .direct_goto => |branch| branch.delay_slot,
        .tail => |tail| tail.delay_slot,
        else => builtinReturnDelay(builtin),
    };
}

fn builtinReturnDelay(builtin: *const ast.Builtin) ?[]const Statement {
    return if (builtin.* == .return_from_function) builtin.return_from_function else null;
}

const Reader = *const fn (*const Statement, *Children) void;

const child_readers = blk: {
    var table = std.EnumArray(Tag, Reader).initFill(&delayOnly);
    table.set(.while_loop, &whileChildren);
    table.set(.do_while_loop, &doWhileChildren);
    table.set(.if_statement, &ifChildren);
    table.set(.labeled_block, &blockChildren);
    table.set(.ordered_block, &orderedChildren);
    break :blk table;
};

fn delayOnly(statement: *const Statement, result: *Children) void {
    result.add(delaySlot(statement));
}

fn whileChildren(statement: *const Statement, result: *Children) void {
    result.add(statement.while_loop.statements);
}

fn doWhileChildren(statement: *const Statement, result: *Children) void {
    result.add(statement.do_while_loop.statements);
    result.add(statement.do_while_loop.delay_slot);
}

fn ifChildren(statement: *const Statement, result: *Children) void {
    const branch = statement.if_statement;
    result.add(branch.delay_slot);
    result.add(branch.then_statements);
    result.add(branch.else_statements);
}

fn blockChildren(statement: *const Statement, result: *Children) void {
    result.add(statement.labeled_block.statements);
    result.add(statement.labeled_block.exit_delay);
}

fn orderedChildren(statement: *const Statement, result: *Children) void {
    result.add(statement.ordered_block);
}

/// The transfers that carry a delay slot.
pub const DelayKind = enum {
    call,
    goto,
    conditional_goto,
    conditional_direct_goto,
    break_loop,
    jump,
    indirect_call,
    return_from_function,
    direct_goto,
    tail,
};

pub const DelaySet = std.EnumSet(DelayKind);

pub fn delayKind(statement: *const Statement) ?DelayKind {
    return switch (statement.*) {
        .builtin => |builtin| builtinDelayKind(builtin),
        else => std.meta.stringToEnum(DelayKind, @tagName(statement.*)),
    };
}

fn builtinDelayKind(builtin: ast.Builtin) ?DelayKind {
    return std.meta.stringToEnum(DelayKind, @tagName(builtin));
}

/// Structured bodies only: loops, branches, labeled blocks, and exact
/// blocks, with their own slots but not the slots of transfers.
pub fn structuredChildren(statement: *const Statement) Children {
    var result: Children = .{};
    if (delayKind(statement) == null) child_readers.get(std.meta.activeTag(statement.*))(statement, &result);
    return result;
}

/// Structured children plus the delay slots of the given transfer kinds.
pub fn childrenWith(statement: *const Statement, delays: DelaySet) Children {
    var result = structuredChildren(statement);
    const kind = delayKind(statement) orelse return result;
    if (delays.contains(kind)) result.add(delaySlot(statement));
    return result;
}

/// Like `any`, following only structured bodies and the chosen slots.
pub fn anyWith(statements: []const Statement, delays: DelaySet, context: anytype, comptime visit: fn (@TypeOf(context), *const Statement) bool) bool {
    for (statements) |*statement| {
        if (visit(context, statement)) return true;
        const nested = childrenWith(statement, delays);
        for (nested.slice()) |list| if (anyWith(list, delays, context, visit)) return true;
    }
    return false;
}

/// Calls `visit` on every statement reachable through the chosen lists.
pub fn each(statements: []const Statement, delays: DelaySet, context: anytype, comptime visit: fn (@TypeOf(context), *const Statement) void) void {
    for (statements) |*statement| {
        visit(context, statement);
        const nested = childrenWith(statement, delays);
        for (nested.slice()) |list| each(list, delays, context, visit);
    }
}

const testing = std.testing;

test "delay kinds name transfers and structured children skip their slots" {
    var delay = [_]Statement{.{ .builtin = .nop }};
    const call: Statement = .{ .call = .{ .module = null, .name = "f", .arguments = &.{}, .delay_slot = &delay } };
    try testing.expectEqual(@as(?DelayKind, .call), delayKind(&call));
    try testing.expectEqual(@as(usize, 0), structuredChildren(&call).len);
    try testing.expectEqual(@as(usize, 1), childrenWith(&call, DelaySet.initOne(.call)).len);
    try testing.expectEqual(@as(usize, 0), childrenWith(&call, DelaySet.initOne(.goto)).len);
    const tail: Statement = .{ .builtin = .{ .tail = .{ .target = .{ .name = "f" }, .arguments = &.{} } } };
    try testing.expectEqual(@as(?DelayKind, .tail), delayKind(&tail));
    try testing.expectEqual(@as(?DelayKind, null), delayKind(&delay[0]));
    var visited: usize = 0;
    each(&.{call}, DelaySet.initOne(.call), &visited, struct {
        fn visit(count: *usize, _: *const Statement) void {
            count.* += 1;
        }
    }.visit);
    try testing.expectEqual(@as(usize, 2), visited);
    try testing.expect(!anyWith(&.{call}, .{}, {}, isContinue));
}

fn isContinue(_: void, statement: *const Statement) bool {
    return statement.* == .continue_loop;
}

test "nested statements are visited through every list" {
    var delay = [_]Statement{.{ .continue_loop = null }};
    var body = [_]Statement{.{ .builtin = .nop }};
    var statements = [_]Statement{
        .{ .if_statement = .{
            .condition = .{ .lhs = "x", .op = .eq, .rhs = .{ .number = 0 } },
            .delay_slot = null,
            .then_statements = &body,
            .else_statements = &delay,
        } },
    };
    try testing.expect(any(&statements, {}, isContinue));
    try testing.expect(!any(&body, {}, isContinue));
    try testing.expectEqual(@as(usize, 2), children(&statements[0]).len);
    const loop: Statement = .{ .do_while_loop = .{ .condition = statements[0].if_statement.condition, .statements = &body, .delay_slot = &delay } };
    try testing.expectEqual(@as(usize, 2), children(&loop).len);
    const tail: Statement = .{ .builtin = .{ .tail = .{ .target = .{ .name = "f" }, .arguments = &.{}, .delay_slot = &delay } } };
    try testing.expectEqual(@as(usize, 1), delaySlot(&tail).?.len);
    try testing.expectEqual(@as(?[]const Statement, null), delaySlot(&body[0]));
    const returned: Statement = .{ .builtin = .{ .return_from_function = &delay } };
    try testing.expectEqual(@as(usize, 1), delaySlot(&returned).?.len);
    for ([_]Statement{
        .{ .call = .{ .module = null, .name = "f", .arguments = &.{}, .delay_slot = &delay } },
        .{ .goto = .{ .target = "l", .delay_slot = &delay } },
        .{ .conditional_goto = .{ .condition = statements[0].if_statement.condition, .target = "l", .delay_slot = &delay } },
        .{ .conditional_direct_goto = .{ .condition = statements[0].if_statement.condition, .target = .{ .name = "f" }, .delay_slot = &delay } },
        .{ .break_loop = .{ .label = null, .delay_slot = &delay } },
        .{ .builtin = .{ .jump = .{ .address = .{ .number = 0 }, .delay_slot = &delay } } },
        .{ .builtin = .{ .indirect_call = .{ .address = .{ .number = 0 }, .delay_slot = &delay } } },
        .{ .builtin = .{ .direct_goto = .{ .target = .{ .name = "f" }, .delay_slot = &delay } } },
    }) |transfer| try testing.expectEqual(@as(usize, 1), delaySlot(&transfer).?.len);
    const block: Statement = .{ .labeled_block = .{ .label = "b", .statements = &body, .exit_delay = null } };
    try testing.expectEqual(@as(usize, 1), children(&block).len);
    const ordered: Statement = .{ .ordered_block = &body };
    try testing.expectEqual(@as(usize, 1), children(&ordered).len);
    const loop2: Statement = .{ .while_loop = .{ .condition = statements[0].if_statement.condition, .statements = &body } };
    try testing.expectEqual(@as(usize, 1), children(&loop2).len);
}
