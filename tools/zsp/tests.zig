const std = @import("std");
const ast = @import("ast.zig");
const asm_writer = @import("asm_writer.zig");
const parser_mod = @import("parser.zig");

const testing = std.testing;

fn expectAsm(source: []const u8, expected: []const u8) !void {
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);

    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try asm_writer.write(&output.writer, functions);

    const actual = try output.toOwnedSlice();
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectParseError(source: []const u8, err: parser_mod.ErrorType, line: usize, column: usize) !void {
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const result = parser.parse();
    try testing.expectError(error.ParseError, result);
    try testing.expect(parser.diagnostic != null);
    try testing.expectEqual(err, parser.diagnostic.?.err);
    try testing.expectEqual(line, parser.diagnostic.?.line);
    try testing.expectEqual(column, parser.diagnostic.?.column);
}

fn expectAsmError(source: []const u8, expected_err: anyerror) !void {
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);

    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try testing.expectError(expected_err, asm_writer.write(&output.writer, functions));
}

test "syntax numbers and scalar variables emit addiu" {
    try expectAsm(
        \\fn test() {
        \\  const initial: u32 = 0x1234;
        \\  reg($t0) a: u32 = 1234;
        \\  reg($t1) b: u32 = initial;
        \\  a += 10;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 1234
        \\  addiu $t1, $zero, 4660
        \\  addiu $t0, $t0, 10
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "scalar assignment operators support every data type" {
    const data_types = [_][]const u8{ "u8", "u16", "u32", "i8", "i16", "i32" };
    const expected =
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 14
        \\  addiu $t1, $zero, 18
        \\  addiu $t2, $zero, 0
        \\  or $t2, $zero, $t0
        \\  addu $t2, $t2, $t0
        \\  addu $t2, $t0, $t1
        \\  subu $t2, $t2, $t0
        \\  subu $t2, $t0, $t1
        \\  addiu $t2, $zero, 10
        \\  jr $ra
        \\  nop
        \\
        \\
    ;

    for (data_types) |data_type| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\fn test() {{
            \\  reg($t0) a: {s} = 14;
            \\  reg($t1) b: {s} = 18;
            \\  reg($t2) c: {s} = 0;
            \\
            \\  c = a;
            \\  c += a;
            \\  c = a + b;
            \\  c -= a;
            \\  c = a - b;
            \\  c = 10;
            \\}}
        , .{ data_type, data_type, data_type });
        defer testing.allocator.free(source);
        try expectAsm(source, expected);
    }
}

test "scalar assignment rejects mixed register data types" {
    try expectAsmError(
        \\fn test() {
        \\  reg a: u16 = 1;
        \\  reg b: i16 = 2;
        \\  a = a + b;
        \\}
    , error.RegisterTypeMismatch);
}

test "scalar math and shifts support every data type" {
    const data_types = [_][]const u8{ "u8", "u16", "u32", "i8", "i16", "i32" };

    for (data_types) |data_type| {
        const signed = data_type[0] == 'i';
        const right_shift = if (signed) "sra" else "srl";
        const variable_right_shift = if (signed) "srav" else "srlv";
        const source = try std.fmt.allocPrint(testing.allocator,
            \\fn test() {{
            \\  const factor: {s} = 4;
            \\  const shift: {s} = 2;
            \\  reg($t0) a: {s} = 16;
            \\  reg($t1) b: {s} = 2;
            \\  reg($t2) c: {s} = 0;
            \\
            \\  c = a * factor;
            \\  c *= 8;
            \\  c = a / factor;
            \\  c /= 8;
            \\  c = a << b;
            \\  c <<= shift;
            \\  c = a >> b;
            \\  c >>= shift;
            \\  c = a >>> b;
            \\  c >>>= shift;
            \\}}
        , .{ data_type, data_type, data_type, data_type, data_type });
        defer testing.allocator.free(source);

        const expected = try std.fmt.allocPrint(testing.allocator,
            \\.set noreorder
            \\.set noat
            \\.text
            \\
            \\test:
            \\  addiu $t0, $zero, 16
            \\  addiu $t1, $zero, 2
            \\  addiu $t2, $zero, 0
            \\  sll $t2, $t0, 2
            \\  sll $t2, $t2, 3
            \\  {s} $t2, $t0, 2
            \\  {s} $t2, $t2, 3
            \\  sllv $t2, $t0, $t1
            \\  sll $t2, $t2, 2
            \\  {s} $t2, $t0, $t1
            \\  {s} $t2, $t2, 2
            \\  srlv $t2, $t0, $t1
            \\  srl $t2, $t2, 2
            \\  jr $ra
            \\  nop
            \\
            \\
        , .{ right_shift, right_shift, variable_right_shift, right_shift });
        defer testing.allocator.free(expected);
        try expectAsm(source, expected);
    }
}

test "scalar math rejects unsupported multiplication and division" {
    try expectAsmError(
        \\fn test() {
        \\  reg a: u32 = 8;
        \\  reg b: u32 = 3;
        \\  a = a * b;
        \\}
    , error.PowerOfTwoConstantRequired);
    try expectAsmError(
        \\fn test() {
        \\  reg a: u32 = 8;
        \\  a /= 3;
        \\}
    , error.PowerOfTwoConstantRequired);
    try expectAsmError(
        \\fn test() {
        \\  reg a: u32 = 8;
        \\  a *= 1;
        \\}
    , error.NoOpPowerOfTwoMath);
}

test "scalar bitwise operators support every data type" {
    const data_types = [_][]const u8{ "u8", "u16", "u32", "i8", "i16", "i32" };
    const expected =
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 12
        \\  addiu $t1, $zero, 10
        \\  addiu $t2, $zero, 0
        \\  and $t2, $t0, $t1
        \\  andi $t2, $t2, 15
        \\  or $t2, $t0, $t1
        \\  ori $t2, $t2, 16
        \\  xor $t2, $t0, $t1
        \\  xori $t2, $t2, 3
        \\  nor $t2, $zero, $t0
        \\  nor $t2, $t0, $t1
        \\  nor $t2, $t2, $t0
        \\  jr $ra
        \\  nop
        \\
        \\
    ;

    for (data_types) |data_type| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\fn test() {{
            \\  reg($t0) a: {s} = 12;
            \\  reg($t1) b: {s} = 10;
            \\  reg($t2) c: {s} = 0;
            \\
            \\  c = a & b;
            \\  c &= 15;
            \\  c = a | b;
            \\  c |= 16;
            \\  c = a ^ b;
            \\  c ^= 3;
            \\  c = ~a;
            \\  c = a ~| b;
            \\  c ~|= a;
            \\}}
        , .{ data_type, data_type, data_type });
        defer testing.allocator.free(source);
        try expectAsm(source, expected);
    }
}

test "comparisons support every operator and scalar data type" {
    const data_types = [_][]const u8{ "u8", "u16", "u32", "i8", "i16", "i32" };

    for (data_types) |data_type| {
        const compare_instruction: []const u8 = if (data_type[0] == 'i') "slt" else "sltu";
        const source = try std.fmt.allocPrint(testing.allocator,
            \\fn test() {{
            \\  reg($t0) a: {s} = 1;
            \\  reg($t1) b: {s} = 2;
            \\  reg($t2) c: {s} = 0;
            \\  if (a == b) {{ c += 1; }}
            \\  if (a != b) {{ c += 2; }}
            \\  if (a < b)  {{ c += 3; }}
            \\  if (a <= b) {{ c += 4; }}
            \\  if (a > b)  {{ c += 5; }}
            \\  if (a >= b) {{ c += 6; }}
            \\}}
        , .{ data_type, data_type, data_type });
        defer testing.allocator.free(source);

        const expected = try std.fmt.allocPrint(testing.allocator,
            \\.set noreorder
            \\.set noat
            \\.text
            \\
            \\test:
            \\  addiu $t0, $zero, 1
            \\  addiu $t1, $zero, 2
            \\  addiu $t2, $zero, 0
            \\  bne $t0, $t1, LABEL_test_ifend_0
            \\  nop
            \\  addiu $t2, $t2, 1
            \\LABEL_test_ifend_0:
            \\  beq $t0, $t1, LABEL_test_ifend_1
            \\  nop
            \\  addiu $t2, $t2, 2
            \\LABEL_test_ifend_1:
            \\  {s} $at, $t0, $t1
            \\  beq $at, $zero, LABEL_test_ifend_2
            \\  nop
            \\  addiu $t2, $t2, 3
            \\LABEL_test_ifend_2:
            \\  {s} $at, $t1, $t0
            \\  bne $at, $zero, LABEL_test_ifend_3
            \\  nop
            \\  addiu $t2, $t2, 4
            \\LABEL_test_ifend_3:
            \\  {s} $at, $t1, $t0
            \\  beq $at, $zero, LABEL_test_ifend_4
            \\  nop
            \\  addiu $t2, $t2, 5
            \\LABEL_test_ifend_4:
            \\  {s} $at, $t0, $t1
            \\  bne $at, $zero, LABEL_test_ifend_5
            \\  nop
            \\  addiu $t2, $t2, 6
            \\LABEL_test_ifend_5:
            \\  jr $ra
            \\  nop
            \\
            \\
        , .{ compare_instruction, compare_instruction, compare_instruction, compare_instruction });
        defer testing.allocator.free(expected);
        try expectAsm(source, expected);
    }
}

test "comparison immediates and else blocks emit direct branches" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) a: i32 = -1;
        \\  if (a >= 0) {
        \\    a += 1;
        \\  } else {
        \\    a -= 1;
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, -1
        \\  slti $at, $t0, 0
        \\  bne $at, $zero, LABEL_test_ifelse_0
        \\  nop
        \\  addiu $t0, $t0, 1
        \\  j LABEL_test_ifend_0
        \\  nop
        \\LABEL_test_ifelse_0:
        \\  addiu $t0, $t0, -1
        \\LABEL_test_ifend_0:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "top level declarations allocate registers without label" {
    try expectAsm(
        \\reg a: u8 = 1;
        \\reg b: u16 = 2;
        \\@nop();
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\  addiu $t0, $zero, 1
        \\  addiu $t1, $zero, 2
        \\  nop
        \\
        \\
    );
}

test "store emits byte halfword and word writes" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) ptr: u32 = 0x100;
        \\  reg($t1) value: u32 = 0x55;
        \\  store(u8, ptr, value);
        \\  store(u16, ptr, 0x1234);
        \\  store(u32, 0, value);
        \\  store(i8, ptr, value);
        \\  store(i16, ptr, 0x1234);
        \\  store(i32, 0, value);
        \\  store(u32, ptr, value, 12);
        \\  store(u8, ptr, value, -4);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 256
        \\  addiu $t1, $zero, 85
        \\  sb $t1, 0($t0)
        \\  addiu $v1, $zero, 4660
        \\  sh $v1, 0($t0)
        \\  sw $t1, 0($zero)
        \\  sb $t1, 0($t0)
        \\  addiu $v1, $zero, 4660
        \\  sh $v1, 0($t0)
        \\  sw $t1, 0($zero)
        \\  sw $t1, 12($t0)
        \\  sb $t1, -4($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "load emits signed and unsigned byte halfword and word reads" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) ptr: u32 = 0x100;
        \\  reg($t1) a = load(u8, ptr);
        \\  reg($t2) b = load(i8, ptr);
        \\  reg($t3) c = load(u16, ptr);
        \\  reg($t4) d = load(i16, ptr);
        \\  reg($t5) e = load(u32, ptr, 12);
        \\  reg($t6) f = load(i32, ptr, -4);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 256
        \\  lbu $t1, 0($t0)
        \\  lb $t2, 0($t0)
        \\  lhu $t3, 0($t0)
        \\  lh $t4, 0($t0)
        \\  lw $t5, 12($t0)
        \\  lw $t6, -4($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "memory offsets must fit the instruction immediate" {
    try expectAsmError(
        \\fn test() {
        \\  reg ptr: u32 = 0x100;
        \\  reg value = load(u32, ptr, 32768);
        \\}
    , error.MemoryOffsetOutOfRange);
    try expectAsmError(
        \\fn test() {
        \\  reg ptr: u32 = 0x100;
        \\  store(u32, ptr, 1, -32769);
        \\}
    , error.MemoryOffsetOutOfRange);
}

test "load can assign an already defined register" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) ptr: u32 = 0x100;
        \\  reg($t1) value: u16 = 0;
        \\  value = load(u16, ptr);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 256
        \\  addiu $t1, $zero, 0
        \\  lhu $t1, 0($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "load destination type must match requested data type" {
    try expectAsmError(
        \\fn test() {
        \\  reg ptr: u32 = 0;
        \\  reg value: u32 = 0;
        \\  value = load(u16, ptr);
        \\}
    , error.RegisterTypeMismatch);
}

test "inline calls bind parameters and expand inside caller scope" {
    try expectAsm(
        \\inline fn write(
        \\  reg($t0) value: u32,
        \\  reg($s0) destination: u32,
        \\) {
        \\  store(u32, destination, value);
        \\}
        \\
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = 0x1234;
        \\  reg($s0) destination: u32 = 0x20;
        \\  write(value, destination);
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 4660
        \\  addiu $s0, $zero, 32
        \\  sw $t0, 0($s0)
        \\  break
        \\
        \\
    );
}

test "fixed-register parameters bind without emitting initialization" {
    try expectAsm(
        \\fn write_word(
        \\  reg($t0) value: u32,
        \\  reg($s0) destination: u32,
        \\) {
        \\  store(u32, destination, value);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\write_word:
        \\  sw $t0, 0($s0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "fixed-register parameters reject conflicting bindings" {
    try expectAsmError(
        \\fn duplicate_name(
        \\  reg($t0) value: u32,
        \\  reg($t1) value: u32,
        \\) {}
    , error.SymbolAlreadyDefined);
    try expectAsmError(
        \\fn duplicate_register(
        \\  reg($t0) first: u32,
        \\  reg($t0) second: u32,
        \\) {}
    , error.RegisterAlreadyInUse);
    try expectAsmError(
        \\fn reserved_register(reg($at) value: u32) {}
    , error.RegisterReservedForBackend);
}

test "function parameters require explicit register bindings" {
    try expectParseError(
        \\fn invalid(value: u32) {}
    , .expected_fixed_register_parameter, 1, 12);
}

test "gp can be explicitly pinned but is not automatically allocated" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($gp) command_address: u32 = 0x20;
        \\  reg automatic: u32 = 1;
        \\  command_address += automatic;
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $gp, $zero, 32
        \\  addiu $t0, $zero, 1
        \\  addu $gp, $gp, $t0
        \\  break
        \\
        \\
    );
}

test "function calls verify fixed-register arguments without moves" {
    try expectAsm(
        \\fn callee(
        \\  reg($t0) size: u32,
        \\  reg($s0) address: u32,
        \\) {}
        \\
        \\fn caller() noreturn {
        \\  reg($t0) size: u32 = 15;
        \\  reg($s0) address: u32 = 0x1000;
        \\  callee(size, address);
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\callee:
        \\  jr $ra
        \\  nop
        \\
        \\caller:
        \\  addiu $t0, $zero, 15
        \\  addiu $s0, $zero, 4096
        \\  jal callee
        \\  nop
        \\  break
        \\
        \\
    );
}

test "function calls reject arguments that do not match pinned parameters" {
    try expectAsmError(
        \\fn callee(reg($t0) value: u32) {}
        \\fn caller() {
        \\  callee();
        \\}
    , error.FunctionArgumentCountMismatch);
    try expectAsmError(
        \\fn callee(reg($t0) value: u32) {}
        \\fn caller() {
        \\  reg($t0) value: i32 = 1;
        \\  callee(value);
        \\}
    , error.FunctionArgumentTypeMismatch);
    try expectAsmError(
        \\fn callee(reg($t0) value: u32) {}
        \\fn caller() {
        \\  reg($t1) value: u32 = 1;
        \\  callee(value);
        \\}
    , error.FunctionArgumentRegisterMismatch);
}

test "function calls materialize constants and literals in pinned registers" {
    try expectAsm(
        \\fn callee(
        \\  reg($t0) size: u32,
        \\  reg($s0) address: u32,
        \\) {}
        \\
        \\fn caller() noreturn {
        \\  const address: u32 = 0x12345678;
        \\  callee(16, address);
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\callee:
        \\  jr $ra
        \\  nop
        \\
        \\caller:
        \\  addiu $t0, $zero, 16
        \\  lui $s0, 4660
        \\  ori $s0, $s0, 22136
        \\  jal callee
        \\  nop
        \\  break
        \\
        \\
    );
}

test "module imports public functions and qualified calls parse" {
    var parser = try parser_mod.Parser.init(testing.allocator,
        \\const dma = @import("dma.zsp");
        \\pub fn helper() {}
        \\export fn _start() noreturn {
        \\  dma.exec();
        \\}
    );
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    const imports = try parser.takeImports();
    defer testing.allocator.free(imports);

    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("dma", imports[0].name);
    try testing.expectEqualStrings("dma.zsp", imports[0].path);
    try testing.expect(functions[0].public);

    const call = functions[1].statements[0].call;
    try testing.expectEqualStrings("dma", call.module.?);
    try testing.expectEqualStrings("exec", call.name);
}

test "while loop emits labels branch and back edge" {
    try expectAsm(
        \\export fn _start() noreturn {
        \\  reg($t0) ptr: u16 = 0;
        \\  const end: u16 = 4;
        \\  while(ptr < end) {
        \\    store(u16, ptr, ptr);
        \\    ptr += 2;
        \\  }
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl _start
        \\_start:
        \\  addiu $t0, $zero, 0
        \\LABEL__start_while_0:
        \\  sltiu $at, $t0, 4
        \\  beq $at, $zero, LABEL__start_whileend_0
        \\  nop
        \\  sh $t0, 0($t0)
        \\  addiu $t0, $t0, 2
        \\  j LABEL__start_while_0
        \\  nop
        \\LABEL__start_whileend_0:
        \\  break
        \\
        \\
    );
}

test "syntax rejects unsupported function modifier" {
    try expectParseError(
        \\fn test() interrupt {
        \\}
    , .unsupported_function_modifier, 1, 11);
}

test "syntax rejects invalid number literal" {
    try expectParseError(
        \\fn test() {
        \\  reg($t0) a: u32 = 0xzz;
        \\}
    , .invalid_number, 2, 21);
}

test "semantic rejects function variable redefining global" {
    try expectAsmError(
        \\reg a: u8 = 0;
        \\
        \\fn test() {
        \\  reg a: u16 = 2;
        \\}
    , error.SymbolAlreadyDefined);
}

test "syntax rejects removed var keyword" {
    try expectParseError(
        \\fn test() {
        \\  var a: u16 = 0;
        \\}
    , .var_keyword_removed, 2, 3);
}
