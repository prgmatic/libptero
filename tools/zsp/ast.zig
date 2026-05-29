const std = @import("std");

pub const Function = struct {
    name: []const u8,
    export_symbol: bool,
    statements: []const Statement,
};

pub const Value = union(enum) {
    ident: []const u8,
    number: i64,
};

pub const Condition = struct {
    lhs: []const u8,
    op: enum { lt },
    rhs: Value,
};

pub const VarDecl = struct {
    is_const: bool,
    data_type: []const u8,
    reg: ?[]const u8,
    name: []const u8,
    value: Value,
};

pub const Statement = union(enum) {
    var_decl: VarDecl,
    add_assign: struct {
        name: []const u8,
        value: i64,
    },
    store: struct {
        data_type: []const u8,
        address: []const u8,
        value: []const u8,
    },
    while_loop: struct {
        condition: Condition,
        statements: []const Statement,
    },
    asm_line: []const u8,
};

pub fn freeFunctions(allocator: std.mem.Allocator, functions: []const Function) void {
    for (functions) |function| freeStatements(allocator, function.statements);
    allocator.free(functions);
}

fn freeStatements(allocator: std.mem.Allocator, statements: []const Statement) void {
    for (statements) |statement| {
        switch (statement) {
            .while_loop => |loop| freeStatements(allocator, loop.statements),
            else => {},
        }
    }
    allocator.free(statements);
}
