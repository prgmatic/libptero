//! Deterministic function order and tail fallthrough decisions, computed before
//! emission. A target can be claimed by only one predecessor; cycles terminate
//! with an explicit jump to the already placed function.
const std = @import("std");
const ast = @import("ast.zig");

pub const Plan = struct {
    order: [1024]usize = undefined,
    len: usize = 0,
    fallthrough: [1024]?usize = @splat(null),
    visited: [1024]bool = @splat(false),

    pub fn init(functions: []const ast.Function) !Plan {
        if (functions.len > 1024) return error.TooManyFunctions;
        var plan: Plan = .{};
        var targets: [1024]?usize = @splat(null);
        var claimed: [1024]bool = @splat(false);
        try resolveTargets(functions, targets[0..functions.len], &claimed);
        for (functions, 0..) |_, index| {
            if (!claimed[index]) plan.appendChain(functions, &targets, index);
        }
        for (functions, 0..) |_, index| plan.appendChain(functions, &targets, index);
        return plan;
    }

    fn appendChain(self: *Plan, functions: []const ast.Function, targets: []const ?usize, first: usize) void {
        var index = first;
        while (!self.visited[index]) {
            self.visited[index] = true;
            self.order[self.len] = index;
            self.len += 1;
            if (functions[index].external) return;
            const next = emittableTarget(functions, targets[index]) orelse return;
            if (!self.visited[next]) self.fallthrough[index] = next;
            index = next;
        }
    }
};

fn resolveTargets(functions: []const ast.Function, targets: []?usize, claimed: []bool) !void {
    for (functions, 0..) |function, index| {
        const target = terminalTail(function.statements) orelse continue;
        if (target.module != null) return error.UnresolvedModuleCall;
        const target_index = findFunctionIndex(functions, target.name) orelse return error.UnknownFunction;
        targets[index] = target_index;
        claimed[target_index] = true;
    }
}

fn emittableTarget(functions: []const ast.Function, target: ?usize) ?usize {
    const index = target orelse return null;
    if (!functions[index].emitsBody()) return null;
    return index;
}

fn terminalTail(statements: []const ast.Statement) ?ast.FunctionRef {
    if (statements.len == 0) return null;
    const builtin = switch (statements[statements.len - 1]) {
        .builtin => |builtin| builtin,
        else => return null,
    };
    return switch (builtin) {
        .tail => |tail| tail.target,
        else => null,
    };
}

fn findFunctionIndex(functions: []const ast.Function, name: []const u8) ?usize {
    for (functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, name)) return index;
    }
    return null;
}

test "placement claims shared targets once and closes cycles with jumps" {
    var diagnostic: ?@import("parser.zig").Diagnostic = null;
    var program = try @import("source.zig").Program.parse(std.testing.allocator, "fn target() noreturn { rsp.halt(); } fn first() noreturn { tail target(); } fn second() noreturn { tail target(); } fn cycle() noreturn { tail cycle(); }", &diagnostic);
    defer program.deinit();
    const plan = try Plan.init(program.functions);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2, 3 }, plan.order[0..plan.len]);
    try std.testing.expectEqual(@as(?usize, 0), plan.fallthrough[1]);
    try std.testing.expectEqual(@as(?usize, null), plan.fallthrough[2]);
    try std.testing.expectEqual(@as(?usize, null), plan.fallthrough[3]);
}

test "placement validates targets and leaves external transfers explicit" {
    var diagnostic: ?@import("parser.zig").Diagnostic = null;
    var program = try @import("source.zig").Program.parse(std.testing.allocator, "extern fn external() noreturn; fn caller() noreturn { tail external(); }", &diagnostic);
    defer program.deinit();
    const plan = try Plan.init(program.functions);
    try std.testing.expectEqual(@as(?usize, null), plan.fallthrough[1]);
    program.functions[1].statements[0].builtin.tail.target.name = "missing";
    try std.testing.expectError(error.UnknownFunction, Plan.init(program.functions));
    program.functions[1].statements[0].builtin.tail.target.module = "unlinked";
    try std.testing.expectError(error.UnresolvedModuleCall, Plan.init(program.functions));
}
