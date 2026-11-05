//! Loop lowering shared by the statement parser: the continue expression
//! of `while (condition) : (step) { ... }`, and `while (true)` loops that
//! end in a conditional `break`.
const std = @import("std");
const ast = @import("ast.zig");
const ast_walk = @import("ast_walk.zig");
const Parser = @import("parser.zig").Parser;

const Statement = ast.Statement;

/// The body followed by its continue expression. A `continue` of this loop
/// must still run the step, so the body is wrapped in a block that such
/// continues leave with `break`.
pub fn appendStep(self: *Parser, label: ?[]const u8, body: []Statement, step: []Statement) ![]Statement {
    const target: Target = .{ .loop = label, .block = try self.generatedName("continue#{d}", .{self.generated_names.items.len}) };
    const wrap = redirectContinues(body, target, false);
    const head: usize = if (wrap) 1 else body.len;
    const result = try self.allocator.alloc(Statement, head + step.len);
    if (wrap) {
        result[0] = .{ .labeled_block = .{ .label = target.block, .statements = body, .exit_delay = null } };
    } else {
        @memcpy(result[0..body.len], body);
        self.allocator.free(body);
    }
    @memcpy(result[head..], step);
    self.allocator.free(step);
    return result;
}

/// `while (true) { ...; if (c) { break; } }` as `do { ... } while (!c)`,
/// so each iteration takes one branch. Loops with a `continue` keep their
/// shape, since a continue must not test the exit condition.
pub fn exitAtEnd(self: *Parser, label: ?[]const u8, body: []Statement) !Statement {
    const exit = trailingExit(label, body) orelse return whileTrue(label, body);
    if (continues(body, label, false)) return whileTrue(label, body);
    const last = body[body.len - 1].if_statement;
    self.allocator.free(last.then_statements);
    const condition: ast.Condition = .{ .lhs = exit.lhs, .op = inverted(exit.op), .rhs = exit.rhs };
    const statements = try self.allocator.realloc(body, body.len - 1);
    return .{ .do_while_loop = .{ .label = label, .condition = condition, .statements = statements, .delay_slot = null } };
}

fn whileTrue(label: ?[]const u8, body: []Statement) Statement {
    return .{ .do_while_loop = .{ .label = label, .condition = null, .statements = body, .delay_slot = null } };
}

/// The condition of a final `if (c) { break; }` that leaves this loop.
fn trailingExit(label: ?[]const u8, body: []const Statement) ?ast.Condition {
    if (body.len == 0 or body[body.len - 1] != .if_statement) return null;
    const branch = body[body.len - 1].if_statement;
    if (branch.else_statements != null or branch.delay_slot != null) return null;
    if (!isBareBreak(branch.then_statements, label)) return null;
    return branch.condition;
}

/// Exactly `break;` (or `break label;`) of this loop, without a slot.
fn isBareBreak(statements: []const Statement, label: ?[]const u8) bool {
    if (statements.len != 1 or statements[0] != .break_loop) return false;
    const transfer = statements[0].break_loop;
    return transfer.delay_slot == null and breaksTarget(transfer.label, label);
}

fn breaksTarget(named: ?[]const u8, loop: ?[]const u8) bool {
    const name = named orelse return true;
    return std.mem.eql(u8, name, loop orelse return false);
}

const inversions = std.EnumArray(ast.CompareOp, ast.CompareOp).init(.{
    .eq = .ne,
    .ne = .eq,
    .lt = .ge,
    .le = .gt,
    .gt = .le,
    .ge = .lt,
});

fn inverted(op: ast.CompareOp) ast.CompareOp {
    return inversions.get(op);
}

/// True when a `continue` in `statements` targets the loop named `label`.
fn continues(statements: []const Statement, label: ?[]const u8, nested_loop: bool) bool {
    for (statements) |*statement| if (statementContinues(statement, label, nested_loop)) return true;
    return false;
}

fn statementContinues(statement: *const Statement, label: ?[]const u8, nested_loop: bool) bool {
    const target: Target = .{ .loop = label, .block = "" };
    if (statement.* == .continue_loop) return continuesTarget(statement.continue_loop, target, nested_loop);
    const inner = nested_loop or statement.* == .do_while_loop;
    const lists = ast_walk.children(statement);
    for (lists.slice()) |list| if (continues(list, label, inner)) return true;
    return false;
}

const Target = struct { loop: ?[]const u8, block: []const u8 };

/// Rewrites the continues that target this loop; true when any did.
fn redirectContinues(statements: []Statement, target: Target, nested_loop: bool) bool {
    var found = false;
    for (statements) |*statement| found = redirectStatement(statement, target, nested_loop) or found;
    return found;
}

fn redirectStatement(statement: *Statement, target: Target, nested_loop: bool) bool {
    if (statement.* == .continue_loop and continuesTarget(statement.continue_loop, target, nested_loop)) {
        statement.* = .{ .break_loop = .{ .label = target.block, .delay_slot = null } };
        return true;
    }
    const inner = nested_loop or statement.* == .do_while_loop;
    var found = false;
    const lists = ast_walk.children(statement);
    for (lists.slice()) |list| found = redirectContinues(@constCast(list), target, inner) or found;
    return found;
}

fn continuesTarget(label: ?[]const u8, target: Target, nested_loop: bool) bool {
    const named = label orelse return !nested_loop;
    const loop = target.loop orelse return false;
    return std.mem.eql(u8, named, loop);
}
