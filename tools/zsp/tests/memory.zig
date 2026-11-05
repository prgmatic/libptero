const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const optimizer = @import("../optimizer.zig");
const parser_mod = @import("../parser.zig");

const testing = std.testing;

const expectAsm = @import("support.zig").expectAsm;
const expectAsmError = @import("support.zig").expectAsmError;
const expectParseError = @import("support.zig").expectParseError;
const expectSyntaxRejected = @import("support.zig").expectSyntaxRejected;
const expectOptimizedAsm = @import("support.zig").expectOptimizedAsm;

test "narrow scalar arithmetic stays 32 bit until an explicit narrow store" {
    try expectAsm(
        \\fn test(reg($t0) value: u8, reg($t1) amount: u8, reg($a0) address: dmem) noreturn {
        \\  value += amount;
        \\  value >>= 1;
        \\  store(u8, address, value);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  add $t0, $t0, $t1
        \\  srl $t0, $t0, 1
        \\  sb $t0, 0($a0)
        \\  break
        \\
        \\
    );
}

test "ordinary scalar arithmetic emits trapping instructions" {
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
        \\  addi $t0, $t0, 10
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
        \\  rsp.halt();
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
        \\  lw $t2, %lo(overlay_data_rdram)($zero)
        \\  break
        \\
        \\
    );
}

test "scalar label loads and stores fold literal offsets into the instruction" {
    try expectAsm(
        \\bss { words: [2]u32; }
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = load(u32, words, 4);
        \\  store(u32, words, value, 4);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 4
        \\words:
        \\  .space 8
        \\
        \\.text
        \\
        \\
        \\test:
        \\  lw $t0, %lo(words + 4)($zero)
        \\  sw $t0, %lo(words + 4)($zero)
        \\
        \\
    );
}

test "scalar memory operations use zero-based absolute DMEM offsets" {
    try expectAsm(
        \\fn test(reg($t0) value: u32) noreturn {
        \\  store(u16, 0x92, value);
        \\  value = load(u16, 0x94);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  sh $t0, 146($zero)
        \\  lhu $t0, 148($zero)
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

test "public and external storage labels form a linker ABI" {
    try expectAsm(
        \\bss {
        \\  pub resident_value: u32;
        \\  extern imported_value: u32;
        \\}
        \\export fn _start() noreturn {
        \\  reg($t0) value: u32 = load(u32, imported_value);
        \\  store(u32, resident_value, value);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 4
        \\.globl resident_value
        \\resident_value:
        \\  .space 4
        \\
        \\.text
        \\
        \\
        \\.globl _start
        \\_start:
        \\  lw $t0, %lo(imported_value)($zero)
        \\  sw $t0, %lo(resident_value)($zero)
        \\  break
        \\
        \\
    );
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
        \\  reg($t0) address: dmem = header;
        \\  rsp.halt();
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

test "packed struct field offsets are compile-time memory offsets" {
    try expectAsm(
        \\packed struct Header {
        \\  opcode: u8;
        \\  flags: u16;
        \\  address: u32;
        \\}
        \\fn test(reg($t0) ptr: dmem, reg($t1) value: u32) noreturn {
        \\  value = load(u32, ptr, offsetOf(Header, address));
        \\  store(u16, ptr, value, offsetOf(Header, flags));
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\
        \\test:
        \\  lw $t1, 3($t0)
        \\  sh $t1, 1($t0)
        \\  break
        \\
        \\
    );
}

test "packed struct fields provide typed load and store operands" {
    try expectAsm(
        \\packed struct Header {
        \\  opcode: u8;
        \\  flags: u16;
        \\  address: u32;
        \\}
        \\fn test(reg($t0) ptr: dmem, reg($t1) value: u32) noreturn {
        \\  reg($t2) opcode = load(Header.opcode, ptr);
        \\  value = load(Header.address, ptr);
        \\  store(Header.flags, ptr, value);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\
        \\test:
        \\  lbu $t2, 0($t0)
        \\  lw $t1, 3($t0)
        \\  sh $t1, 1($t0)
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

test "state blocks reserve addressable DMA-aligned storage" {
    try expectAsm(
        \\state {
        \\  counter: u32;
        \\  flags: [3]u8;
        \\}
        \\export fn _start() noreturn {
        \\  reg($t0) address: dmem = counter;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.section .state,"aw",@progbits
        \\.balign 4
        \\counter:
        \\  .space 4
        \\flags:
        \\  .space 3
        \\.balign 8
        \\
        \\.text
        \\
        \\
        \\.globl _start
        \\_start:
        \\  addiu $t0, $zero, %lo(counter)
        \\  break
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
        \\  or $t2, $t0, $zero
        \\  add $t2, $t2, $t0
        \\  add $t2, $t0, $t1
        \\  sub $t2, $t2, $t0
        \\  sub $t2, $t0, $t1
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
        \\  nor $t2, $t0, $zero
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
            \\  addi $t2, $t2, 1
            \\LABEL_test_ifend_0:
            \\  beq $t0, $t1, LABEL_test_ifend_1
            \\  nop
            \\  addi $t2, $t2, 2
            \\LABEL_test_ifend_1:
            \\  {s} $at, $t0, $t1
            \\  beq $at, $zero, LABEL_test_ifend_2
            \\  nop
            \\  addi $t2, $t2, 3
            \\LABEL_test_ifend_2:
            \\  {s} $at, $t1, $t0
            \\  bne $at, $zero, LABEL_test_ifend_3
            \\  nop
            \\  addi $t2, $t2, 4
            \\LABEL_test_ifend_3:
            \\  {s} $at, $t1, $t0
            \\  beq $at, $zero, LABEL_test_ifend_4
            \\  nop
            \\  addi $t2, $t2, 5
            \\LABEL_test_ifend_4:
            \\  {s} $at, $t0, $t1
            \\  bne $at, $zero, LABEL_test_ifend_5
            \\  nop
            \\  addi $t2, $t2, 6
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

test "scalar unary negation preserves signed instruction selection" {
    try expectAsm(
        \\fn test(reg($t0) signed: i32, reg($t1) unsigned: u32) noreturn {
        \\  signed = -signed;
        \\  unsigned = -unsigned;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  sub $t0, $zero, $t0
        \\  subu $t1, $zero, $t1
        \\  break
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

test "store emits byte halfword and word writes" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) ptr: dmem = 0x100;
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
        \\  reg($t0) ptr: dmem = 0x100;
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
        \\  reg ptr: dmem = 0x100;
        \\  reg value = load(u32, ptr, 32768);
        \\}
    , error.MemoryOffsetOutOfRange);
    try expectAsmError(
        \\fn test() {
        \\  reg ptr: dmem = 0x100;
        \\  store(u32, ptr, 1, -32769);
        \\}
    , error.MemoryOffsetOutOfRange);
}

test "load can assign an already defined register" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) ptr: dmem = 0x100;
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

test "signed narrow loads can widen into u32 registers" {
    try expectAsm(
        \\fn test() {
        \\  reg ptr: dmem = 0;
        \\  reg value: u32 = 0;
        \\  value = load(i16, ptr);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  addiu $t1, $zero, 0
        \\  lh $t1, 0($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "function address values can materialize a return target" {
    try expectAsm(
        \\fn loop() noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch(reg($t0) handler: u32) noreturn {
        \\  reg($ra) continuation: fn() = &loop;
        \\  jump(handler);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\loop:
        \\  break
        \\
        \\dispatch:
        \\  addiu $ra, $zero, %lo(loop)
        \\  jr $t0
        \\  nop
        \\
        \\
    );
}

test "function address initialization materializes a typed function label" {
    try expectAsm(
        \\fn append(reg($a0) value: u32) noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch() noreturn {
        \\  reg($t5) next: fn(u32) = &append;
        \\  jump(next);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\append:
        \\  break
        \\
        \\dispatch:
        \\  addiu $t5, $zero, %lo(append)
        \\  jr $t5
        \\  nop
        \\
        \\
    );
}

test "code addresses materialize local continuations with selectable signedness" {
    try expectAsm(
        \\fn dispatch(reg($t0) handler: u32) noreturn {
        \\  reg($ra) continuation: fn() = code.addressOfUnsigned(done);
        \\  jump(handler);
        \\done:
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\  ori $ra, $zero, %lo(LABEL_dispatch_done_0)
        \\  jr $t0
        \\  nop
        \\LABEL_dispatch_done_0:
        \\  break
        \\
        \\
    );
}

test "dmem address values materialize a data label with an offset" {
    try expectAsm(
        \\bss { cached: [2]u32; }
        \\fn send() noreturn {
        \\  reg($s3) end: dmem = dmem.addressOf(cached, 8);
        \\  reg($s4) unsigned_end: dmem = dmem.addressOfUnsigned(cached, 8);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 4
        \\cached:
        \\  .space 8
        \\
        \\.text
        \\
        \\
        \\send:
        \\  addiu $s3, $zero, %lo(cached + 8)
        \\  ori $s4, $zero, %lo(cached + 8)
        \\  break
        \\
        \\
    );
}

test "RSP memory operations require dmem addresses" {
    try expectAsmError(
        \\fn test(reg($t0) address: u32, reg($t1) value: u32) noreturn {
        \\  value = load(u32, address);
        \\  rsp.halt();
        \\}
    , error.ExpectedDmemAddress);

    try expectAsmError(
        \\fn test(reg($t0) value: u32) noreturn {
        \\  value = load(u32, 4096);
        \\  rsp.halt();
        \\}
    , error.DmemAddressOutOfRange);
}

test "named CP0 DMA memory address operations use dmem" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) address = rsp.cp0.dmaMemoryAddress();
        \\  rsp.cp0.setDmaMemoryAddress(address);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  mfc0 $t0, $0
        \\  mtc0 $t0, $0
        \\  break
        \\
        \\
    );

    try expectAsmError(
        \\fn test(reg($t0) address: u32) noreturn {
        \\  rsp.cp0.setDmaMemoryAddress(address);
        \\  rsp.halt();
        \\}
    , error.ExpectedDmemAddress);

    try expectAsmError(
        \\fn test(reg($t0) address: u32) noreturn {
        \\  address = rsp.cp0.dmaMemoryAddress();
        \\  rsp.halt();
        \\}
    , error.ExpectedDmemAddress);
}

test "narrow unsigned loads zero extend into u32 registers" {
    try expectAsm(
        \\fn test(reg($a0) address: dmem) {
        \\  reg($t0) byte: u32 = load(u8, address);
        \\  reg($t1) half: u32 = 0;
        \\  half = load(u16, address, 2);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  lbu $t0, 0($a0)
        \\  addiu $t1, $zero, 0
        \\  lhu $t1, 2($a0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "scalar loads support symbolic offsets from an index register" {
    try expectAsm(
        \\bss {
        \\  table: [16]u16;
        \\}
        \\fn test(reg($t0) index: u32) {
        \\  reg($t1) value: u32 = load(u16, index, table);
        \\  value = load(u16, table + index, 6);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 2
        \\table:
        \\  .space 32
        \\
        \\.text
        \\
        \\
        \\test:
        \\  lhu $t1, %lo(table)($t0)
        \\  lhu $t1, %lo(table + 6)($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "scalar stores support symbolic offsets from an index register" {
    try expectAsm(
        \\bss {
        \\  table: [16]u32;
        \\}
        \\fn test(reg($t0) index: u32, reg($t1) value: u32) {
        \\  store(u32, index, value, table);
        \\  store(u32, table + index, value, 12);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 4
        \\table:
        \\  .space 64
        \\
        \\.text
        \\
        \\
        \\test:
        \\  sw $t1, %lo(table)($t0)
        \\  sw $t1, %lo(table + 12)($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "undefined register declarations emit no instruction" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) scratch: u32 = undefined;
        \\  scratch = 7;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 7
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "data addresses can initialize signed pointer registers" {
    try expectAsm(
        \\bss { storage: u32; }
        \\fn test() {
        \\  reg($t0) pointer: i32 = storage;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 4
        \\storage:
        \\  .space 4
        \\
        \\.text
        \\
        \\
        \\test:
        \\  addiu $t0, $zero, %lo(storage)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "resident instruction forms are expressible without inline assembly" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($gp) address: dmem = undefined;
        \\  reg($t7) size: u32 = undefined;
        \\  reg($t0) next: dmem = undefined;
        \\  reg($t1) limit: dmem = undefined;
        \\  reg($at) comparison: u32 = undefined;
        \\  reg($v31) packed_vector: vec16 = undefined;
        \\  reg($v30) shifted: vec16 = undefined;
        \\  next = address +% size;
        \\  comparison = signedLessThan(next, limit);
        \\  packed_vector = loadVectorBytes(0);
        \\  shifted = packed_vector >>> 8;
        \\  goto done, .branch slot {
        \\done:
        \\    rsp.halt(0xba);
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addu $t0, $gp, $t7
        \\  slt $at, $t0, $t1
        \\  .word 0xc81f3000 # lpv $v31, 0($zero)
        \\  .word 0x4bffff84 # vsrl $v30, $v31, $v31
        \\  b LABEL_test_done_0
        \\LABEL_test_done_0:
        \\  break 0xba
        \\
        \\
    );
}

test "symbolic address addition distinguishes trapping and wrapping operators" {
    var parser = try parser_mod.Parser.init(testing.allocator,
        \\data { target: [8]u8; }
        \\fn test() noreturn {
        \\    reg($t0) address: u32 = 0;
        \\    address = address + target;
        \\    address = address +% target;
        \\    rsp.halt();
        \\}
    );
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try codegen.write(testing.allocator, &output.writer, functions);
    const bytes = output.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, bytes, "addi $t0, $t0, %lo(target)") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "addiu $t0, $t0, %lo(target)") != null);
}

test "bit-cast addresses use the source register directly" {
    try @import("support.zig").expectAsmContains(
        \\fn entry() {
        \\  reg($t0) address: u32 = 64;
        \\  reg($t1) value: u32 = 1;
        \\  store(u32, bitCast(address), value);
        \\  rsp.cp0.setDmaRdramAddress(bitCast(address));
        \\}
    , &.{ "  sw $t1, 0($t0)\n", "  mtc0 $t0, $1\n" });
    try expectAsmError(
        \\fn entry() {
        \\  reg($v01) vector: vec16 = 0;
        \\  rsp.cp0.setDmaRdramAddress(bitCast(vector));
        \\}
    , error.AddressMustBeRegister);
}
