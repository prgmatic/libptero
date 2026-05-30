const std = @import("std");

pub const Function = struct {
    name: []const u8,
    export_symbol: bool,
    inline_call: bool,
    no_return: bool,
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

pub const Register = enum {
    zero,
    at,
    v0,
    v1,
    a0,
    a1,
    a2,
    a3,
    t0,
    t1,
    t2,
    t3,
    t4,
    t5,
    t6,
    t7,
    s0,
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    t8,
    t9,
    k0,
    k1,
    gp,
    sp,
    fp,
    ra,
};

pub const VarDecl = struct {
    is_const: bool,
    data_type: []const u8,
    reg: ?Register,
    name: []const u8,
    value: Value,
};

pub const Builtin = enum {
    nop,
    breakpoint,
};

pub const Statement = union(enum) {
    var_decl: VarDecl,
    add_assign: struct {
        name: []const u8,
        value: i64,
    },
    store: struct {
        data_type: []const u8,
        address: Value,
        value: Value,
    },
    call: []const u8,
    builtin: Builtin,
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
