//! Loop lowering shared by the statement parser: the continue expression
//! of `while (condition) : (step) { ... }`.
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
