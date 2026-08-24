const std = @import("std");

pub const Function = struct {
    name: []const u8,
    source_name: []const u8,
    emit_label: bool = true,
    export_symbol: bool,
    public: bool,
    inline_call: bool,
    external: bool = false,
    no_return: bool,
    command_indices: []const u8 = &.{},
    command_sizes: []const u8 = &.{},
    has_clobber_contract: bool = false,
    clobber_regs: []const Register = &.{},
    clobber_vector_regs: []const VectorRegister = &.{},
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

pub const FunctionType = struct {
    parameters: [16]FunctionParameterType = undefined,
    parameter_count: u8 = 0,

    pub fn parameterSlice(self: *const FunctionType) []const FunctionParameterType {
        return self.parameters[0..self.parameter_count];
    }
};

pub const FunctionParameterType = struct {
    data_type: DataType,
    reg: ?Register = null,
    vector_reg: ?VectorRegister = null,
};

pub const Value = union(enum) {
    ident: []const u8,
    vector_access: VectorAccess,
    vector_operation: VectorOperation,
    vector_shift: VectorShift,
    accumulator_read: AccumulatorPart,
    vector_control_read: VectorControlRegister,
    hardware_read: struct {
        register: u4,
        returns_dmem: bool = false,
    },
    scalar_comparison: ScalarComparison,
    signed_less_than: struct { lhs: ValueRef, rhs: ValueRef },
    number: i64,
    load: Load,
    scalar_expression: *ScalarExpression,
    function_address: FunctionRef,
    data_address: struct {
        label: []const u8,
        offset: i64 = 0,
    },
};

pub const ScalarExpression = struct {
    lhs: Value,
    op: AssignOp,
    rhs: Value,
};

pub const VectorShift = struct {
    kind: enum { left_8, right_arithmetic, right_logical },
    source: VectorAccess,
    amount: u4,
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
    vadd = 0b010000,
    vsub = 0b010001,
    vaddc = 0b010100,
    vsubc = 0b010101,
    vlt = 0b100000,
    veq = 0b100001,
    vne = 0b100010,
    vge = 0b100011,
    vmrg = 0b100111,
    vrcp = 0b110000,
    vrcpl = 0b110001,
    vrcph = 0b110010,
    vmov = 0b110011,
    vrsq = 0b110100,
    vrsql = 0b110101,
    vrsqh = 0b110110,
};

pub const VectorOperation = struct {
    op: VectorOp,
    lhs: VectorAccess,
    rhs: VectorAccess,
    explicit_lane_encoding: bool = false,
};

pub const Load = struct {
    data_type: DataType,
    address: ValueRef,
    offset: i64 = 0,
    label_offset: ?[]const u8 = null,
    packed_u8: bool = false,
    packed_unsigned_u8: bool = false,
    partial_u32_lane: ?u3 = null,
    unaligned: bool = false,
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
    dmem,
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

pub const ScalarComparison = struct {
    lhs: ValueRef,
    op: CompareOp,
    rhs: ValueRef,
};

pub const VectorControlRegister = enum(u2) {
    carry_out = 0,
    compare_code = 1,
    compare_extension = 2,
};

pub const VectorMemoryOperation = enum {
    load16,
    store16,
    load32,
    store32,
    load64,
    store64,
    load128,
    store128,
    load_packed_signed,
    load_packed_unsigned,
};

pub const HardwareWriteOperation = union(enum) {
    cp0: u4,
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
    is_reserved: bool = false,
    allow_undefined_read: bool = false,
    data_type: DataType,
    reg: ?Register,
    vector_reg: ?VectorRegister = null,
    function_type: ?FunctionType = null,
    name: []const u8,
    value: ?Value,
};

pub const DataDecl = struct {
    name: []const u8,
    storage_type: DataStorageType,
    array_len: usize,
    is_array: bool,
    values: []const i64,
    initialized: bool,
    public: bool = false,
    external: bool = false,
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
    breakpoint: u20,
    jump: struct {
        address: ValueRef,
        delay_slot: ?[]Statement,
        typed: bool = false,
    },
    return_from_function: ?[]Statement,
    direct_goto: struct {
        target: FunctionRef,
        arguments: []const ValueRef = &.{},
        typed: bool = false,
        encoding: DirectGotoEncoding = .jump,
        delay_slot: ?[]Statement,
    },
    tail: struct {
        target: FunctionRef,
        arguments: []const ValueRef,
        delay_slot: ?[]Statement = null,
    },
    write_vector_control: struct {
        register: VectorControlRegister,
        value: ValueRef,
    },
    vector_memory: struct {
        operation: VectorMemoryOperation,
        vector: VectorAccess,
        lane: u3 = 0,
        address: ValueRef,
        offset: i64 = 0,
    },
    hardware_write: struct {
        operation: HardwareWriteOperation,
        value: ValueRef,
        requires_dmem: bool = false,
    },
    hardware_read_register: struct {
        hardware_register: u4,
        destination: Register,
    },
    hardware_write_register: struct {
        hardware_register: u4,
        source: Register,
    },
};

pub const DirectGotoEncoding = enum {
    jump,
    branch,
};

pub const FunctionRef = struct {
    module: ?[]const u8 = null,
    name: []const u8,
};

pub const AssignOp = enum {
    set,
    add,
    add_wrap,
    sub,
    sub_wrap,
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
    negate,
};

pub const Assignment = struct {
    destination: []const u8,
    destination_lane: ?u3 = null,
    destination_view: ?VectorView = null,
    lhs: Value,
    op: AssignOp,
    rhs: ?Value,
    continuation: []const BinaryStep = &.{},
};

pub const BinaryStep = struct {
    op: AssignOp,
    rhs: Value,
};

pub const Call = struct {
    module: ?[]const u8,
    name: []const u8,
    arguments: []const ValueRef,
    delay_slot: ?[]Statement = null,
};

pub const BreakTransfer = struct {
    label: ?[]const u8,
    delay_slot: ?[]Statement,
};

pub const Statement = union(enum) {
    packed_struct_decl: PackedStructDecl,
    command_table_decl: []const u8,
    data_block: []const DataDecl,
    bss_block: []const DataDecl,
    state_block: []const DataDecl,
    var_decl: VarDecl,
    assignment: Assignment,
    store: struct {
        data_type: DataType,
        half_vector: bool = false,
        quarter_vector: bool = false,
        address: ValueRef,
        value: ValueRef,
        offset: i64 = 0,
        label_offset: ?[]const u8 = null,
    },
    call: Call,
    builtin: Builtin,
    label: []const u8,
    goto: struct {
        target: []const u8,
        encoding: DirectGotoEncoding = .jump,
        delay_slot: ?[]Statement,
    },
    conditional_goto: struct {
        condition: Condition,
        target: []const u8,
        delay_slot: ?[]Statement,
    },
    conditional_direct_goto: struct {
        condition: Condition,
        target: FunctionRef,
        arguments: []const ValueRef = &.{},
        typed: bool = false,
        delay_slot: ?[]Statement,
    },
    while_loop: struct {
        label: ?[]const u8 = null,
        condition: Condition,
        statements: []Statement,
    },
    do_while_loop: struct {
        label: ?[]const u8 = null,
        condition: Condition,
        statements: []Statement,
        delay_slot: ?[]Statement,
    },
    labeled_block: struct {
        label: []const u8,
        statements: []Statement,
        exit_delay: ?[]Statement,
    },
    break_loop: BreakTransfer,
    continue_loop: ?[]const u8,
    if_statement: struct {
        condition: Condition,
        delay_slot: ?[]Statement,
        then_statements: []Statement,
        else_statements: ?[]Statement,
    },
    ordered_block: []Statement,
    asm_line: []const u8,
};

pub fn freeFunctions(allocator: std.mem.Allocator, functions: []const Function) void {
    for (functions) |function| {
        if (function.command_indices.len != 0) allocator.free(function.command_indices);
        if (function.command_sizes.len != 0) allocator.free(function.command_sizes);
        if (function.clobber_regs.len != 0) allocator.free(function.clobber_regs);
        if (function.clobber_vector_regs.len != 0) allocator.free(function.clobber_vector_regs);
        allocator.free(function.parameters);
        freeStatements(allocator, function.statements);
    }
    allocator.free(functions);
}

fn freeStatements(allocator: std.mem.Allocator, statements: []Statement) void {
    for (statements) |statement| {
        switch (statement) {
            .assignment => |assignment| {
                freeValue(allocator, assignment.lhs);
                if (assignment.rhs) |rhs| freeValue(allocator, rhs);
                for (assignment.continuation) |step| freeValue(allocator, step.rhs);
                if (assignment.continuation.len != 0) allocator.free(assignment.continuation);
            },
            .var_decl => |declaration| if (declaration.value) |value| freeValue(allocator, value),
            .packed_struct_decl => |declaration| allocator.free(declaration.fields),
            .data_block, .bss_block, .state_block => |declarations| {
                for (declarations) |declaration| allocator.free(declaration.values);
                allocator.free(declarations);
            },
            .while_loop => |loop| freeStatements(allocator, loop.statements),
            .do_while_loop => |loop| {
                freeStatements(allocator, loop.statements);
                if (loop.delay_slot) |delay| freeStatements(allocator, delay);
            },
            .break_loop => |transfer| if (transfer.delay_slot) |delay| freeStatements(allocator, delay),
            .labeled_block => |block| {
                freeStatements(allocator, block.statements);
                if (block.exit_delay) |delay| freeStatements(allocator, delay);
            },
            .ordered_block => |ordered| freeStatements(allocator, ordered),
            .builtin => |builtin| switch (builtin) {
                .tail => |tail| {
                    allocator.free(tail.arguments);
                    if (tail.delay_slot) |delay_slot| freeStatements(allocator, delay_slot);
                },
                .jump => |jump| if (jump.delay_slot) |delay_slot| freeStatements(allocator, delay_slot),
                .direct_goto => |branch| {
                    if (branch.arguments.len != 0) allocator.free(branch.arguments);
                    if (branch.delay_slot) |delay_slot| freeStatements(allocator, delay_slot);
                },
                .return_from_function => |delay_slot| if (delay_slot) |return_statements| freeStatements(allocator, return_statements),
                else => {},
            },
            .goto => |branch| if (branch.delay_slot) |delay_slot| freeStatements(allocator, delay_slot),
            .conditional_goto => |branch| if (branch.delay_slot) |delay_slot| freeStatements(allocator, delay_slot),
            .conditional_direct_goto => |branch| {
                if (branch.arguments.len != 0) allocator.free(branch.arguments);
                if (branch.delay_slot) |delay_slot| freeStatements(allocator, delay_slot);
            },
            .if_statement => |if_statement| {
                if (if_statement.delay_slot) |delay_slot| freeStatements(allocator, delay_slot);
                freeStatements(allocator, if_statement.then_statements);
                if (if_statement.else_statements) |else_statements| freeStatements(allocator, else_statements);
            },
            .call => |call| {
                allocator.free(call.arguments);
                if (call.delay_slot) |delay_slot| freeStatements(allocator, delay_slot);
            },
            else => {},
        }
    }
    allocator.free(statements);
}

fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .scalar_expression => |expression| {
            freeValue(allocator, expression.lhs);
            freeValue(allocator, expression.rhs);
            allocator.destroy(expression);
        },
        else => {},
    }
}
