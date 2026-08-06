const std = @import("std");
const ast = @import("ast.zig");
const asm_writer = @import("asm_writer.zig");
const asm_optimizer = @import("asm_optimizer.zig");
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

fn expectOptimizedAsm(input: []const u8, expected: []const u8) !void {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try asm_optimizer.writeOptimized(testing.allocator, &output.writer, input);
    const actual = try output.toOwnedSlice();
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "optimizer fills a branch delay slot with an independent instruction" {
    try expectOptimizedAsm(
        "  addiu $t0, $zero, 1\n  addiu $t1, $zero, 2\n  bne $t0, $zero, done\n  nop\ndone:\n",
        "  addiu $t0, $zero, 1\n  bne $t0, $zero, done\n  addiu $t1, $zero, 2\ndone:\n",
    );
}

test "optimizer does not move a branch dependency into its delay slot" {
    const assembly = "  addiu $t0, $zero, 1\n  bne $t0, $zero, done\n  nop\ndone:\n";
    try expectOptimizedAsm(assembly, assembly);
}

test "optimizer never steals an already filled delay slot" {
    try expectOptimizedAsm(
        "  addiu $t0, $zero, 1\n  addiu $t1, $zero, 2\n  bne $t0, $zero, first\n  nop\n  jal helper\n  nop\nfirst:\n",
        "  addiu $t0, $zero, 1\n  bne $t0, $zero, first\n  addiu $t1, $zero, 2\n  jal helper\n  nop\nfirst:\n",
    );
}

test "optimizer hides scalar load latency with independent work" {
    try expectOptimizedAsm(
        "  lw $t0, 0($a0)\n  addu $t1, $t0, $a1\n  addiu $t2, $zero, 1\n  addiu $t3, $zero, 2\n",
        "  lw $t0, 0($a0)\n  addiu $t2, $zero, 1\n  addiu $t3, $zero, 2\n  addu $t1, $t0, $a1\n",
    );
}

test "optimizer pairs independent scalar and vector pipeline instructions" {
    try expectOptimizedAsm(
        "  addiu $t0, $zero, 1\n  addiu $t1, $zero, 2\n  .word 0x4a0208d0 # vadd $v03, $v01, $v02\n",
        "  addiu $t0, $zero, 1\n  .word 0x4a0208d0 # vadd $v03, $v01, $v02\n  addiu $t1, $zero, 2\n",
    );
}

test "optimizer preserves memory order and treats unknown asm as a barrier" {
    const assembly = "  lw $t0, 0($a0)\n  sw $t1, 0($a1)\n  custom $t2, $t3\n  bne $t0, $zero, done\n  nop\ndone:\n";
    try expectOptimizedAsm(assembly, assembly);
}

test "optimizer folds a CP0 polling while loop into a conditional back edge" {
    try expectOptimizedAsm(
        "  addiu $t3, $zero, 0\n  mfc0 $t3, $5\nloop:\n  beq $t3, $zero, end\n  nop\n  mfc0 $t3, $5\n  j loop\n  nop\nend:\n  andi $t3, $t0, 4095\n",
        "loop:\n  mfc0 $t3, $5\n  bne $t3, $zero, loop\n  andi $t3, $t0, 4095\nend:\n",
    );
}

test "optimizer rotates a two-operation CP0 polling recurrence" {
    try expectOptimizedAsm(
        "  mfc0 $t3, $4\n  and $t3, $t3, $t2\nloop:\n  beq $t3, $zero, end\n  nop\n  mfc0 $t3, $4\n  and $t3, $t3, $t2\n  j loop\n  nop\nend:\n  jr $ra\n  nop\n",
        "  mfc0 $t3, $4\nloop:\n  and $t3, $t3, $t2\n  bne $t3, $zero, loop\n  mfc0 $t3, $4\nend:\n  jr $ra\n  nop\n",
    );
}

test "unsigned high-bit comparison emits a signed zero branch" {
    try expectAsm(
        \\fn test(reg($t2) flags: u32) {
        \\  if(flags < 0x80000000) { @nop(); }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  bltz $t2, LABEL_test_ifend_0
        \\  nop
        \\  nop
        \\LABEL_test_ifend_0:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
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

test "data blocks emit scalar arrays and expose DMEM addresses" {
    try expectAsm(
        \\data {
        \\  shift_constants: [8]u8 = .{ 0x80, 0x40, 0x20, 0x10, 8, 4, 2, 1 };
        \\  queue_address: u32 = 0x12345678;
        \\}
        \\bss {
        \\  overlay_data_rdram: [16]u32;
        \\  overlay_idmap: [16]u8;
        \\  status: u32;
        \\}
        \\export fn _start() noreturn {
        \\  reg($t0) table: u32 = overlay_data_rdram;
        \\  reg($t1) idmap: u32 = overlay_idmap;
        \\  reg($t2) first: u32 = load(u32, overlay_data_rdram);
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.data
        \\shift_constants:
        \\  .byte 128
        \\  .byte 64
        \\  .byte 32
        \\  .byte 16
        \\  .byte 8
        \\  .byte 4
        \\  .byte 2
        \\  .byte 1
        \\.balign 4
        \\queue_address:
        \\  .word 305419896
        \\
        \\.bss
        \\.balign 4
        \\overlay_data_rdram:
        \\  .space 64
        \\overlay_idmap:
        \\  .space 16
        \\.balign 4
        \\status:
        \\  .space 4
        \\
        \\.text
        \\
        \\
        \\.globl _start
        \\_start:
        \\  addiu $t0, $zero, %lo(overlay_data_rdram)
        \\  addiu $t1, $zero, %lo(overlay_idmap)
        \\  addiu $at, $zero, %lo(overlay_data_rdram)
        \\  lw $t2, 0($at)
        \\  break
        \\
        \\
    );
}

test "initialized data arrays require every element" {
    try expectParseError(
        \\data {
        \\  values: [2]u32 = .{ 1 };
        \\}
    , .incorrect_array_initializer_count, 2, 3);
}

test "packed structs emit fields without padding" {
    try expectAsm(
        \\packed struct Header {
        \\  state_start: u16;
        \\  state_rdram: u32;
        \\  marker: i8;
        \\}
        \\data {
        \\  header: Header = .{ 8, 0x12345678, -1 };
        \\}
        \\bss {
        \\  scratch: Header;
        \\  headers: [2]Header;
        \\}
        \\export fn _start() noreturn {
        \\  reg($t0) address: u32 = header;
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.data
        \\header:
        \\  .short 8
        \\  .word 305419896
        \\  .byte -1
        \\
        \\.bss
        \\scratch:
        \\  .space 7
        \\headers:
        \\  .space 14
        \\
        \\.text
        \\
        \\
        \\.globl _start
        \\_start:
        \\  addiu $t0, $zero, %lo(header)
        \\  break
        \\
        \\
    );
}

test "data blocks reject undefined storage" {
    try expectParseError(
        \\data {
        \\  scratch: u32 = undefined;
        \\}
    , .undefined_data_initializer, 2, 18);
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

test "vec16 and vec32 operations emit encoded RSP vector instructions" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) ptr: u32 = 0;
        \\  reg($v01) a: vec16 = load(vec16, ptr);
        \\  reg($v02) b: vec16 = load(vec16, ptr, 16);
        \\  reg($v03) c: vec16 = 0;
        \\  c = a + b;
        \\  store(vec16, ptr, c, 128);
        \\  reg($v04) x: vec32 = load(vec32, ptr, 32);
        \\  reg($v06) y: vec32 = load(vec32, ptr, 64);
        \\  reg($v08) z: vec32 = 0;
        \\  z = x ^ y;
        \\  store(vec32, ptr, z, 96);
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  .word 0xc9012000 # lqv $v01, 0($t0)
        \\  .word 0xc9022001 # lqv $v02, 16($t0)
        \\  .word 0x4a0318ec # vxor $v03, $v03, $v03
        \\  .word 0x4a0208d4 # vaddc $v03, $v01, $v02
        \\  .word 0xe9032008 # sqv $v03, 128($t0)
        \\  .word 0xc9042002 # lqv $v04, 32($t0)
        \\  .word 0xc9052003 # lqv $v05, 48($t0)
        \\  .word 0xc9062004 # lqv $v06, 64($t0)
        \\  .word 0xc9072005 # lqv $v07, 80($t0)
        \\  .word 0x4a08422c # vxor $v08, $v08, $v08
        \\  .word 0x4a094a6c # vxor $v09, $v09, $v09
        \\  .word 0x4a06222c # vxor $v08, $v04, $v06
        \\  .word 0x4a072a6c # vxor $v09, $v05, $v07
        \\  .word 0xe9082006 # sqv $v08, 96($t0)
        \\  .word 0xe9092007 # sqv $v09, 112($t0)
        \\  break
        \\
        \\
    );
}

test "vector compound assignments use the destination as the left operand" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) a: vec16 = 0;
        \\  reg($v02) b: vec16 = 0;
        \\  a += b;
        \\  a -= b;
        \\  a &= b;
        \\  a |= b;
        \\  a ^= b;
        \\  a ~|= b;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x4a020854 # vaddc $v01, $v01, $v02
        \\  .word 0x4a020855 # vsubc $v01, $v01, $v02
        \\  .word 0x4a020868 # vand $v01, $v01, $v02
        \\  .word 0x4a02086a # vor $v01, $v01, $v02
        \\  .word 0x4a02086c # vxor $v01, $v01, $v02
        \\  .word 0x4a02086b # vnor $v01, $v01, $v02
        \\
        \\
    );
}

test "fixed vector parameters bind and inline with exact registers" {
    try expectAsm(
        \\inline fn accumulate(
        \\  reg($v01) value: vec16,
        \\  reg($v02) addend: vec16,
        \\) {
        \\  value += addend;
        \\}
        \\fn test() noreturn {
        \\  reg($t0) ptr: u32 = 0;
        \\  reg($v01) a: vec16 = load(vec16, ptr);
        \\  reg($v02) b: vec16 = load(vec16, ptr, 16);
        \\  accumulate(a, b);
        \\  @break();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  .word 0xc9012000 # lqv $v01, 0($t0)
        \\  .word 0xc9022001 # lqv $v02, 16($t0)
        \\  .word 0x4a020854 # vaddc $v01, $v01, $v02
        \\  break
        \\
        \\
    );
}

test "vector calls require matching types and fixed registers" {
    try expectAsmError(
        \\fn consume(reg($v01) value: vec16) {}
        \\fn test() {
        \\  reg($v02) value: vec16 = 0;
        \\  consume(value);
        \\}
    , error.FunctionArgumentRegisterMismatch);
    try expectAsmError(
        \\fn consume(reg($v01) value: vec16) {}
        \\fn test() {
        \\  consume(0);
        \\}
    , error.VectorArgumentMustBeRegister);
    try expectAsmError(
        \\fn consume(reg($v01) value: vec16) {}
        \\fn test() {
        \\  reg($v01) value: vec32 = 0;
        \\  consume(value);
        \\}
    , error.FunctionArgumentTypeMismatch);
    try expectAsmError(
        \\fn consume(
        \\  reg($v01) wide: vec32,
        \\  reg($v02) overlap: vec16,
        \\) {}
    , error.RegisterAlreadyInUse);
}

test "vector declarations validate fixed registers and register pairs" {
    try expectParseError(
        \\fn test() {
        \\  reg($v1) value: vec16 = 0;
        \\}
    , .expected_vector_register, 2, 7);
    try expectAsmError(
        \\fn test() {
        \\  reg($v28) value: vec32 = 0;
        \\}
    , error.VectorRegisterReservedForBackend);
    try expectAsmError(
        \\fn test() {
        \\  reg($v01) a: vec32 = 0;
        \\  reg($v02) b: vec16 = 0;
        \\}
    , error.RegisterAlreadyInUse);
}

test "automatic vector allocation keeps vec32 register pairs contiguous" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg a: vec16 = 0;
        \\  reg b: vec32 = 0;
        \\  reg c: vec16 = 0;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x4a0318ec # vxor $v03, $v03, $v03
        \\  .word 0x4a04212c # vxor $v04, $v04, $v04
        \\
        \\
    );
}

test "automatic vector allocation reports exhaustion" {
    var source_writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer source_writer.deinit();
    try source_writer.writer.writeAll("fn test() {\n");
    for (0..29) |index| {
        try source_writer.writer.print("  reg value_{d}: vec16 = 0;\n", .{index});
    }
    try source_writer.writer.writeAll("}\n");
    const source = try source_writer.toOwnedSlice();
    defer testing.allocator.free(source);

    try expectAsmError(source, error.OutOfFreeVectorRegisters);
}

test "vector operations reject mixed types, immediates, and invalid memory offsets" {
    try expectAsmError(
        \\fn test() {
        \\  reg($v01) narrow: vec16 = 0;
        \\  reg($v02) wide: vec32 = 0;
        \\  narrow += wide;
        \\}
    , error.RegisterTypeMismatch);
    try expectAsmError(
        \\fn test() {
        \\  reg($v01) value: vec16 = 0;
        \\  value += 1;
        \\}
    , error.VectorImmediateUnsupported);
    try expectAsmError(
        \\fn test() {
        \\  reg ptr: u32 = 0;
        \\  reg($v01) value: vec16 = load(vec16, ptr, 1);
        \\}
    , error.VectorMemoryOffsetUnaligned);
    try expectAsmError(
        \\fn test() {
        \\  reg ptr: u32 = 0;
        \\  reg($v01) value: vec16 = load(vec16, ptr, 1024);
        \\}
    , error.VectorMemoryOffsetOutOfRange);
}

test "vector swizzles views and indexed lane transfers lower to COP2 encodings" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) scalar: u32 = 0x1234;
        \\  reg($v01) source: vec16 = 0;
        \\  reg($v02) result: vec16 = 0;
        \\  source[2] = scalar;
        \\  scalar = source[2];
        \\  result = source + source.xxxxxxxx;
        \\  reg($v04) wide: vec32 = 0;
        \\  reg($v06) half: vec16 = 0;
        \\  half = wide.sfract ^ half;
        \\  wide.sint = half;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 4660
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x48880a00 # mtc2 $t0, $v01[2]
        \\  .word 0x48080a00 # mfc2 $t0, $v01[2]
        \\  andi $t0, $t0, 65535
        \\  .word 0x4b010894 # vaddc $v02, $v01, $v01
        \\  .word 0x4a04212c # vxor $v04, $v04, $v04
        \\  .word 0x4a05296c # vxor $v05, $v05, $v05
        \\  .word 0x4a0631ac # vxor $v06, $v06, $v06
        \\  .word 0x4a0629ac # vxor $v06, $v05, $v06
        \\  .word 0x4a06312a # vor $v04, $v06, $v06
        \\
        \\
    );
}

test "fractional multiply and accumulate expressions emit VU instructions" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) source: vec16 = 0;
        \\  reg($v02) factor: vec16 = 0;
        \\  reg($v03) result: vec16 = 0;
        \\  result.sfract = vmulf(source.sfract, factor.x);
        \\  result.ufract = vmulu(source.ufract, factor);
        \\  result.sfract = vmacf(source.sfract, factor.yyyyyyyy);
        \\  result.ufract = vmacu(source.ufract, factor);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x4a0318ec # vxor $v03, $v03, $v03
        \\  .word 0x4b0208c0 # vmulf $v03, $v01, $v02
        \\  .word 0x4a0208c1 # vmulu $v03, $v01, $v02
        \\  .word 0x4b2208c8 # vmacf $v03, $v01, $v02
        \\  .word 0x4a0208c9 # vmacu $v03, $v01, $v02
        \\
        \\
    );
}

test "fractional multiply validates operand widths and swizzle placement" {
    try expectAsmError(
        \\fn test() {
        \\  reg($v01) wide: vec32 = 0;
        \\  reg($v03) factor: vec16 = 0;
        \\  reg($v04) result: vec16 = 0;
        \\  result = vmulf(wide, factor);
        \\}
    , error.VectorMultiplyRequiresVec16Operands);
    try expectAsmError(
        \\fn test() {
        \\  reg($v01) source: vec16 = 0;
        \\  reg($v02) factor: vec16 = 0;
        \\  reg($v03) result: vec16 = 0;
        \\  result = vmulf(source.x, factor);
        \\}
    , error.VectorSwizzleOnlyAllowedOnRhs);
}

test "partial-product multiply and accumulate families emit their function codes" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) left: vec16 = 0;
        \\  reg($v02) right: vec16 = 0;
        \\  reg($v03) result: vec16 = 0;
        \\  result = vmudl(left, right);
        \\  result = vmudm(left, right);
        \\  result = vmudn(left, right);
        \\  result = vmudh(left, right);
        \\  result = vmadl(left, right);
        \\  result = vmadm(left, right);
        \\  result = vmadn(left, right);
        \\  result = vmadh(left, right);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x4a0318ec # vxor $v03, $v03, $v03
        \\  .word 0x4a0208c4 # vmudl $v03, $v01, $v02
        \\  .word 0x4a0208c5 # vmudm $v03, $v01, $v02
        \\  .word 0x4a0208c6 # vmudn $v03, $v01, $v02
        \\  .word 0x4a0208c7 # vmudh $v03, $v01, $v02
        \\  .word 0x4a0208cc # vmadl $v03, $v01, $v02
        \\  .word 0x4a0208cd # vmadm $v03, $v01, $v02
        \\  .word 0x4a0208ce # vmadn $v03, $v01, $v02
        \\  .word 0x4a0208cf # vmadh $v03, $v01, $v02
        \\
        \\
    );
}

test "accumulator reads select high middle and low portions" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) high: vec16 = accumulator(.high);
        \\  reg($v02) middle: vec16 = accumulator(.middle);
        \\  reg($v03) low: vec16 = 0;
        \\  low = accumulator(.low);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4b00005d # vsar $v01, $v00, $v00
        \\  .word 0x4b20009d # vsar $v02, $v00, $v00
        \\  .word 0x4a0318ec # vxor $v03, $v03, $v03
        \\  .word 0x4b4000dd # vsar $v03, $v00, $v00
        \\
        \\
    );
}

test "indexed vector lanes support halfword memory transfers" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) ptr: u32 = 0;
        \\  reg($v01) value: vec16 = 0;
        \\  value[2] = load(vec16, ptr, 6);
        \\  store(vec16, ptr, value[5], -4);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0xc9010a03 # lsv $v01[2], 6($t0)
        \\  .word 0xe9010d7e # ssv $v01[5], -4($t0)
        \\
        \\
    );
}

test "vector comparison and merge instructions expose VCC-backed primitives" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) left: vec16 = 0;
        \\  reg($v02) right: vec16 = 0;
        \\  reg($v03) result: vec16 = 0;
        \\  result = vlt(left, right);
        \\  result = veq(left, right);
        \\  result = vne(left, right);
        \\  result = vge(left, right);
        \\  result = vmrg(left, right);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x4a0318ec # vxor $v03, $v03, $v03
        \\  .word 0x4a0208e0 # vlt $v03, $v01, $v02
        \\  .word 0x4a0208e1 # veq $v03, $v01, $v02
        \\  .word 0x4a0208e2 # vne $v03, $v01, $v02
        \\  .word 0x4a0208e3 # vge $v03, $v01, $v02
        \\  .word 0x4a0208e7 # vmrg $v03, $v01, $v02
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

test "jump transfers control through a scalar register" {
    try expectAsm(
        \\fn dispatch(reg($t0) handler: u32) noreturn {
        \\  @jump(handler);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\  jr $t0
        \\  nop
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
