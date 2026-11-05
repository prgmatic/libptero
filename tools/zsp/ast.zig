const std = @import("std");

pub const SourceLocation = struct { line: usize, column: usize };
pub const StatementLocation = struct {
    statement: *const Statement,
    location: SourceLocation,
};

pub const Function = struct {
    source_path: []const u8 = "",
    source_locations: []const StatementLocation = &.{},
    /// Names the parser generated for this function, such as unrolled
    /// locals and register array elements.
    generated_names: []const []const u8 = &.{},
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

    /// External and inline functions have no body of their own in the output.
    pub fn emitsBody(self: Function) bool {
        return !self.external and !self.inline_call;
    }

    /// An unpinned inline parameter names its argument at each expansion
    /// rather than receiving it in a register.
    pub fn bindsArgument(self: Function, parameter: Parameter) bool {
        return self.inline_call and parameter.automatic;
    }
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
    /// Written without a register; internal functions let the compiler
    /// choose one (`param_alloc.zig`).
    automatic: bool = false,
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
    bit_cast: ValueRef,
    function_address: FunctionRef,
    code_address: struct {
        label: []const u8,
    },
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
    vch = 0b100101,
    vcl = 0b100100,
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
};

pub const Load = struct {
    data_type: DataType,
    address: ValueRef,
    offset: i64 = 0,
    label_offset: ?[]const u8 = null,
    packed_u8: bool = false,
    packed_unsigned_u8: bool = false,
    unaligned: bool = false,
};

pub const ValueRef = union(enum) {
    ident: []const u8,
    bit_cast: []const u8,
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
    /// Lanes selected from `lane` by `v[first..end]`; the parser lowers
    /// ranges of more than one lane into transfers.
    lane_count: u4 = 1,
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
    load32,
    store32,
    load64,
    store64,
    load128,
    store128,
    load_quad_lane,
    load_right,
    store_right,
    load_transpose,
    load_packed_signed,
    load_packed_unsigned,
    store_packed_signed,
    store_packed_unsigned,
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
    },
    indirect_call: struct {
        address: ValueRef,
        delay_slot: ?[]Statement,
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
    destination_lane_count: u4 = 1,
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
        address: ValueRef,
        value: ValueRef,
        offset: i64 = 0,
        label_offset: ?[]const u8 = null,
    },
    call: Call,
    builtin: Builtin,
    label: []const u8,
    exported_label: []const u8,
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
    /// `do { } while (condition);`, and every `while` loop, which the
    /// parser rotates into `if (condition) do { } while (condition)`.
    /// Without a condition the loop repeats until a transfer leaves it.
    do_while_loop: struct {
        label: ?[]const u8 = null,
        condition: ?Condition,
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
    for (functions) |function| freeFunction(allocator, function);
    allocator.free(functions);
}

fn freeFunction(allocator: std.mem.Allocator, function: Function) void {
    allocator.free(function.source_locations);
    for (function.generated_names) |name| allocator.free(name);
    allocator.free(function.generated_names);
    freeOptional(allocator, function.command_indices);
    freeOptional(allocator, function.command_sizes);
    freeOptional(allocator, function.clobber_regs);
    freeOptional(allocator, function.clobber_vector_regs);
    allocator.free(function.parameters);
    freeStatements(allocator, function.statements);
}

/// Slices that default to a static empty one are only freed when filled.
fn freeOptional(allocator: std.mem.Allocator, slice: anytype) void {
    if (slice.len != 0) allocator.free(slice);
}

fn freeStatements(allocator: std.mem.Allocator, statements: []const Statement) void {
    for (statements) |*statement| {
        owned_freers.get(std.meta.activeTag(statement.*))(allocator, statement);
        const nested = @import("ast_walk.zig").children(statement);
        for (nested.slice()) |list| freeStatements(allocator, list);
    }
    allocator.free(statements);
}

/// Frees what a statement owns besides its nested statement lists.
const OwnedFreer = *const fn (std.mem.Allocator, *const Statement) void;

const owned_freers = blk: {
    var table = std.EnumArray(std.meta.Tag(Statement), OwnedFreer).initFill(&freeNothing);
    table.set(.assignment, &freeAssignment);
    table.set(.var_decl, &freeDeclaration);
    table.set(.packed_struct_decl, &freePackedStruct);
    table.set(.data_block, &freeStorage);
    table.set(.bss_block, &freeStorage);
    table.set(.state_block, &freeStorage);
    table.set(.builtin, &freeBuiltin);
    table.set(.conditional_direct_goto, &freeConditionalDirectGoto);
    table.set(.call, &freeCall);
    break :blk table;
};

fn freeNothing(_: std.mem.Allocator, _: *const Statement) void {}

fn freeAssignment(allocator: std.mem.Allocator, statement: *const Statement) void {
    const assignment = statement.assignment;
    freeValue(allocator, assignment.lhs);
    if (assignment.rhs) |rhs| freeValue(allocator, rhs);
    for (assignment.continuation) |step| freeValue(allocator, step.rhs);
    allocator.free(assignment.continuation);
}

fn freeDeclaration(allocator: std.mem.Allocator, statement: *const Statement) void {
    if (statement.var_decl.value) |value| freeValue(allocator, value);
}

fn freePackedStruct(allocator: std.mem.Allocator, statement: *const Statement) void {
    allocator.free(statement.packed_struct_decl.fields);
}

fn freeStorage(allocator: std.mem.Allocator, statement: *const Statement) void {
    const declarations = switch (statement.*) {
        .data_block, .bss_block, .state_block => |declarations| declarations,
        else => unreachable,
    };
    for (declarations) |declaration| allocator.free(declaration.values);
    allocator.free(declarations);
}

fn freeBuiltin(allocator: std.mem.Allocator, statement: *const Statement) void {
    switch (statement.builtin) {
        .tail => |tail| allocator.free(tail.arguments),
        .direct_goto => |branch| allocator.free(branch.arguments),
        else => {},
    }
}

fn freeConditionalDirectGoto(allocator: std.mem.Allocator, statement: *const Statement) void {
    allocator.free(statement.conditional_direct_goto.arguments);
}

fn freeCall(allocator: std.mem.Allocator, statement: *const Statement) void {
    allocator.free(statement.call.arguments);
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
