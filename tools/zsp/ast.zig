const std = @import("std");

pub const Function = struct {
    name: []const u8,
    source_name: []const u8,
    emit_label: bool = true,
    export_symbol: bool,
    public: bool,
    inline_call: bool,
    no_return: bool,
    command_index: ?u8 = null,
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
    reg: ?Register = null,
    vector_reg: ?VectorRegister = null,
};

pub const Value = union(enum) {
    ident: []const u8,
    vector_access: VectorAccess,
    vector_operation: VectorOperation,
    accumulator_read: AccumulatorPart,
    number: i64,
    load: Load,
};

pub const AccumulatorPart = enum(u4) {
    high = 8,
    middle = 9,
    low = 10,
};

pub const VectorOp = enum(u6) {
    vmulf = 0b000000,
    vmulu = 0b000001,
    vmudl = 0b000100,
    vmudm = 0b000101,
    vmudn = 0b000110,
    vmudh = 0b000111,
    vmacf = 0b001000,
    vmacu = 0b001001,
    vmadl = 0b001100,
    vmadm = 0b001101,
    vmadn = 0b001110,
    vmadh = 0b001111,
    vlt = 0b100000,
    veq = 0b100001,
    vne = 0b100010,
    vge = 0b100011,
    vmrg = 0b100111,
};

pub const VectorOperation = struct {
    op: VectorOp,
    lhs: VectorAccess,
    rhs: VectorAccess,
};

pub const Load = struct {
    data_type: DataType,
    address: ValueRef,
    offset: i64 = 0,
};

pub const ValueRef = union(enum) {
    ident: []const u8,
    vector_access: VectorAccess,
    number: i64,
};

pub const VectorView = enum {
    sint,
    uint,
    sfract,
    ufract,
};

pub const VectorAccess = struct {
    name: []const u8,
    element: u4 = 0,
    lane: ?u3 = null,
    view: ?VectorView = null,
};

pub const DataType = enum {
    u8,
    u16,
    u32,
    i8,
    i16,
    i32,
    vec16,
    vec32,
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

pub const VectorRegister = enum(u5) {
    v00,
    v01,
    v02,
    v03,
    v04,
    v05,
    v06,
    v07,
    v08,
    v09,
    v10,
    v11,
    v12,
    v13,
    v14,
    v15,
    v16,
    v17,
    v18,
    v19,
    v20,
    v21,
    v22,
    v23,
    v24,
    v25,
    v26,
    v27,
    v28,
    v29,
    v30,
    v31,
};

pub const VarDecl = struct {
    is_const: bool,
    data_type: DataType,
    reg: ?Register,
    vector_reg: ?VectorRegister = null,
    name: []const u8,
    value: Value,
};

pub const DataDecl = struct {
    name: []const u8,
    storage_type: DataStorageType,
    array_len: usize,
    is_array: bool,
    values: []const i64,
    initialized: bool,
};

pub const DataStorageType = union(enum) {
    scalar: DataType,
    packed_struct: []const u8,
};

pub const PackedStructDecl = struct {
    name: []const u8,
    fields: []const PackedStructField,
};

pub const PackedStructField = struct {
    name: []const u8,
    data_type: DataType,
};

pub const Builtin = union(enum) {
    nop,
    breakpoint,
    jump: ValueRef,
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
    destination_lane: ?u3 = null,
    destination_view: ?VectorView = null,
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
    packed_struct_decl: PackedStructDecl,
    data_block: []const DataDecl,
    bss_block: []const DataDecl,
    state_block: []const DataDecl,
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
            .packed_struct_decl => |declaration| allocator.free(declaration.fields),
            .data_block, .bss_block, .state_block => |declarations| {
                for (declarations) |declaration| allocator.free(declaration.values);
                allocator.free(declarations);
            },
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
