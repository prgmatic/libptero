const std = @import("std");

pub const Function = struct {
    name: []const u8,
    source_name: []const u8,
    emit_label: bool = true,
    export_symbol: bool,
    public: bool,
    inline_call: bool,
    no_return: bool,
    parameters: []const Parameter,
    statements: []Statement,
};

pub const Import = struct {
    name: []const u8,
    path: []const u8,
};

pub const Parameter = struct {
    name: []const u8,
    data_type: DataType,
    reg: Register,
};

pub const Value = union(enum) {
    ident: []const u8,
    number: i64,
    load: Load,
};

pub const Load = struct {
    data_type: DataType,
    address: ValueRef,
    offset: i64 = 0,
};

pub const ValueRef = union(enum) {
    ident: []const u8,
    number: i64,
};

pub const DataType = enum {
    u8,
    u16,
    u32,
    i8,
    i16,
    i32,
};

pub const Condition = struct {
    lhs: []const u8,
    op: CompareOp,
    rhs: Value,
};

pub const CompareOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

pub const Register = enum {
    zero,
    at, v0, v1, a0, a1, a2, a3, 
    t0, t1, t2, t3, t4, t5, t6, t7,
    s0, s1, s2, s3, s4, s5, s6, s7,
    t8, t9, k0, k1, gp, sp, fp, ra,
};

pub const VarDecl = struct {
    is_const: bool,
    data_type: DataType,
    reg: ?Register,
    name: []const u8,
    value: Value,
};

pub const Builtin = enum {
    nop,
    breakpoint,
};

pub const AssignOp = enum {
    set,
    add,
    sub,
    mul,
    div,
    shift_left,
    shift_right,
    logical_shift_right,
    bit_and,
    bit_or,
    bit_xor,
    bit_nor,
    bit_not,
};

pub const Assignment = struct {
    destination: []const u8,
    lhs: Value,
    op: AssignOp,
    rhs: ?Value,
};

pub const Call = struct {
    module: ?[]const u8,
    name: []const u8,
    arguments: []const ValueRef,
};

pub const Statement = union(enum) {
    var_decl: VarDecl,
    assignment: Assignment,
    store: struct {
        data_type: DataType,
        address: ValueRef,
        value: ValueRef,
        offset: i64 = 0,
    },
    call: Call,
    builtin: Builtin,
    while_loop: struct {
        condition: Condition,
        statements: []Statement,
    },
    if_statement: struct {
        condition: Condition,
        then_statements: []Statement,
        else_statements: ?[]Statement,
    },
    asm_line: []const u8,
};

pub fn freeFunctions(allocator: std.mem.Allocator, functions: []const Function) void {
    for (functions) |function| {
        allocator.free(function.parameters);
        freeStatements(allocator, function.statements);
    }
    allocator.free(functions);
}

fn freeStatements(allocator: std.mem.Allocator, statements: []Statement) void {
    for (statements) |statement| {
        switch (statement) {
            .while_loop => |loop| freeStatements(allocator, loop.statements),
            .if_statement => |if_statement| {
                freeStatements(allocator, if_statement.then_statements);
                if (if_statement.else_statements) |else_statements| freeStatements(allocator, else_statements);
            },
            .call => |call| allocator.free(call.arguments),
            else => {},
        }
    }
    allocator.free(statements);
}
