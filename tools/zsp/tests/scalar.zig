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

test "assembly emission is deterministic" {
    const source =
        \\fn second() noreturn { rsp.halt(2); }
        \\fn first() noreturn { tail second(); }
    ;
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);

    var first = std.Io.Writer.Allocating.init(testing.allocator);
    defer first.deinit();
    var second = std.Io.Writer.Allocating.init(testing.allocator);
    defer second.deinit();
    try codegen.write(testing.allocator, &first.writer, functions);
    try codegen.write(testing.allocator, &second.writer, functions);
    try testing.expectEqualStrings(first.written(), second.written());
}

test "reserved scalar declarations claim the backend scratch register" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) left: u32 = undefined;
        \\  reg($t1) right: u32 = undefined;
        \\  reserved reg($v1) temporary: u32 = undefined;
        \\  temporary = left | right;
        \\  left |= temporary;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  or $v1, $t0, $t1
        \\  or $t0, $t0, $v1
        \\  break
        \\
        \\
    );

    try expectAsmError(
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = undefined;
        \\  reserved reg($v1) temporary: u32 = undefined;
        \\  value +%= 0x12345678;
        \\  rsp.halt();
        \\}
    , error.BackendScratchRegisterUnavailable);
}

test "CP0 intrinsics support values and explicit fixed registers" {
    try expectAsm(
        \\fn test(reg($t0) value: u32) noreturn {
        \\  value = rsp.cp0.read(4);
        \\  rsp.cp0.write(9, value);
        \\  rsp.cp0.readRegister(5, $at);
        \\  rsp.cp0.writeRegister(2, $at);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  mfc0 $t0, $4
        \\  mtc0 $t0, $9
        \\  mfc0 $at, $5
        \\  mtc0 $at, $2
        \\  break
        \\
        \\
    );
}

test "named CP0 operations return values and accept arbitrary scalar registers" {
    try expectAsm(
        \\fn test(reg($t0) value: u32) noreturn {
        \\  value = rsp.cp0.spStatus();
        \\  rsp.cp0.setRdpCommandEnd(value);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  mfc0 $t0, $4
        \\  mtc0 $t0, $9
        \\  break
        \\
        \\
    );
}

test "scalar comparison expressions produce normalized register results" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) left: i32 = undefined;
        \\  reg($t1) right: i32 = undefined;
        \\  reg($t2) result: u32 = undefined;
        \\  result = left < right;
        \\  result = left <= right;
        \\  result = left > right;
        \\  result = left >= right;
        \\  result = left == right;
        \\  result = left != right;
        \\  result = right != 0;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  slt $t2, $t0, $t1
        \\  slt $t2, $t1, $t0
        \\  xori $t2, $t2, 1
        \\  slt $t2, $t1, $t0
        \\  slt $t2, $t0, $t1
        \\  xori $t2, $t2, 1
        \\  xor $t2, $t0, $t1
        \\  sltiu $t2, $t2, 1
        \\  xor $t2, $t0, $t1
        \\  sltu $t2, $zero, $t2
        \\  sltu $t2, $zero, $t1
        \\  break
        \\
        \\
    );
}

test "functions emit in source order" {
    try expectAsm(
        \\fn second() {}
        \\fn first() {}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\second:
        \\  jr $ra
        \\  nop
        \\
        \\first:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "parenthesized scalar expression chains reuse the destination register" {
    try expectAsm(
        \\fn test(reg($t0) a: u32, reg($t1) b: u32, reg($t2) c: u32, reg($t3) result: u32) noreturn {
        \\  result = (a & b | c);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  and $t3, $t0, $t1
        \\  or $t3, $t3, $t2
        \\  break
        \\
        \\
    );
}

test "nested scalar expressions honor precedence and allocate predictable temporaries" {
    try expectAsm(
        \\fn test(
        \\  reg($a0) a: u32,
        \\  reg($a1) b: u32,
        \\  reg($a2) c: u32,
        \\  reg($t0) result: u32,
        \\) noreturn {
        \\  result = a | b & c;
        \\  result = (a + b) & c;
        \\  result = a + (b - c);
        \\  result = (a + b) + result;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  and $t1, $a1, $a2
        \\  or $t0, $a0, $t1
        \\  add $t0, $a0, $a1
        \\  and $t0, $t0, $a2
        \\  sub $t1, $a1, $a2
        \\  add $t0, $a0, $t1
        \\  or $t1, $t0, $zero
        \\  add $t0, $a0, $a1
        \\  add $t0, $t0, $t1
        \\  break
        \\
        \\
    );
}

test "addition binds more tightly than shifts and multiplication binds more tightly than addition" {
    try expectAsm(
        \\fn test(reg($a0) a: u32, reg($a1) b: u32, reg($t0) result: u32) noreturn {
        \\  result = a + b << 2;
        \\  result = a + b * 4;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  add $t0, $a0, $a1
        \\  sll $t0, $t0, 2
        \\  sll $t1, $a1, 2
        \\  add $t0, $a0, $t1
        \\  break
        \\
        \\
    );
}

test "nested scalar expressions reject side effects" {
    try expectAsmError(
        \\fn test(reg($a0) address: dmem, reg($t0) result: u32) noreturn {
        \\  result = result + load(u32, address);
        \\  rsp.halt();
        \\}
    , error.SideEffectsNotAllowedInScalarExpression);
}

test "compile-time enums and flags lower to qualified immediates" {
    try expectAsm(
        \\enum CycleType: u32 {
        \\  one = 1;
        \\  copy;
        \\}
        \\flags RenderFlags: u32 {
        \\  antialias;
        \\  z_compare;
        \\  force_blend = 8;
        \\  alpha_compare;
        \\}
        \\data {
        \\  default_cycle: u32 = CycleType.copy;
        \\}
        \\fn test() noreturn {
        \\  reg($t0) cycle: u32 = CycleType.copy;
        \\  reg($t1) flags: u32;
        \\  flags = RenderFlags.antialias | RenderFlags.force_blend | RenderFlags.alpha_compare;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.data
        \\.balign 4
        \\default_cycle:
        \\  .word 2
        \\
        \\.text
        \\
        \\
        \\test:
        \\  addiu $t0, $zero, 2
        \\  addiu $t1, $zero, 25
        \\  break
        \\
        \\
    );
}

test "state blocks preserve initialized persistent bytes" {
    try expectAsm(
        \\state {
        \\  fog: [4]i16 = .{ 0, 0, 32767, 0 };
        \\  clipping_planes: [8]i8 = .{ 1, 0, 0, 1, 1, 0, 0, -1 };
        \\  scratch: [4]u8;
        \\}
        \\export fn _start() noreturn {
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.section .state,"aw",@progbits
        \\.balign 2
        \\fog:
        \\  .short 0
        \\  .short 0
        \\  .short 32767
        \\  .short 0
        \\clipping_planes:
        \\  .byte 1
        \\  .byte 0
        \\  .byte 0
        \\  .byte 1
        \\  .byte 1
        \\  .byte 0
        \\  .byte 0
        \\  .byte -1
        \\scratch:
        \\  .space 4
        \\.balign 8
        \\
        \\.text
        \\
        \\
        \\.globl _start
        \\_start:
        \\  break
        \\
        \\
    );
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

test "top level declarations allocate registers without label" {
    try expectAsm(
        \\reg a: u8 = 1;
        \\reg b: u16 = 2;
        \\rsp.nop();
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

test "register declarations infer intrinsic initializer types" {
    try expectAsm(
        \\fn test(reg($a0) left: u32, reg($a1) right: u32) noreturn {
        \\  reg($t0) mask = 255;
        \\  reg($t1) status = rsp.cp0.read(4);
        \\  reg($t2) ordered = signedLessThan(left, right);
        \\  reg($v01) accumulator = readVectorAccumulatorHigh();
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 255
        \\  mfc0 $t1, $4
        \\  slt $t2, $a0, $a1
        \\  .word 0x4b00005d # vsar $v01, $v00, $v00
        \\  break
        \\
        \\
    );
}

test "register declarations infer types from visible identifiers" {
    try expectAsm(
        \\fn test(reg($a0) signed_value: i32) noreturn {
        \\  reg copy = signed_value;
        \\  copy >>= 1;
        \\  reg($v01) vector: vec16 = 0;
        \\  reg vector_copy = vector;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  or $t0, $a0, $zero
        \\  sra $t0, $t0, 1
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0108aa # vor $v02, $v01, $v01
        \\  break
        \\
        \\
    );
}

test "fixed-register parameters bind without emitting initialization" {
    try expectAsm(
        \\fn write_word(
        \\  reg($t0) value: u32,
        \\  reg($s0) destination: dmem,
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
    try expectAsm(
        \\fn scratch(reg($at) value: u32) {}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\scratch:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "pinned registers can be reused after their last use" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) dma_full: u32 = 1;
        \\  dma_full += 1;
        \\  reg($t0) transfer_descriptor: u32 = 2;
        \\  transfer_descriptor += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 1
        \\  addi $t0, $t0, 1
        \\  addiu $t0, $zero, 2
        \\  addi $t0, $t0, 1
        \\  break
        \\
        \\
    );
}

test "boundary parameters outside the default scalar convention require explicit registers" {
    try expectParseError(
        \\export fn invalid(a: u32, b: u32, c: u32, d: u32, value: u32) {}
    , .expected_fixed_register_parameter, 1, 19);
    try expectParseError(
        \\export fn invalid(value: vec16) {}
    , .expected_fixed_register_parameter, 1, 19);
}

test "internal functions let the compiler choose parameter registers" {
    try @import("support.zig").expectAsmContains(
        \\fn scale(a: u32, b: u32, c: u32, d: u32, value: u32, vector: vec16) {
        \\  value += a;
        \\  vector += vector;
        \\  rsp.cp0.setSpStatus(value);
        \\}
        \\export fn entry() noreturn {
        \\  reg($t6) count: u32 = 1;
        \\  reg($v09) data: vec16 = 0;
        \\  scale(1, 2, 3, 4, count, data);
        \\  rsp.halt();
        \\}
    , &.{ "  add $t6, $t6, $a0\n", "# vaddc $v09, $v09, $v09\n", "  jal scale\n" });
}

test "automatic scalar allocation reuses a register after its final use" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg first: u32 = 1;
        \\  first += 1;
        \\  reg second: u32 = 2;
        \\  second += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 1
        \\  addi $t0, $t0, 1
        \\  addiu $t0, $zero, 2
        \\  addi $t0, $t0, 1
        \\  break
        \\
        \\
    );
}

test "automatic allocation preserves values across backward label edges" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg sum: u32 = 0;
        \\  reg count: u32 = 2;
        \\loop:
        \\  sum += count;
        \\  reg scratch: u32 = 1;
        \\  count -= scratch;
        \\  if(count != 0) goto loop;
        \\  reg result: u32 = 3;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  addiu $t1, $zero, 2
        \\LABEL_test_loop_0:
        \\  add $t0, $t0, $t1
        \\  addiu $t2, $zero, 1
        \\  sub $t1, $t1, $t2
        \\  bne $t1, $zero, LABEL_test_loop_0
        \\  nop
        \\  addiu $t0, $zero, 3
        \\  break
        \\
        \\
    );
}

test "functions may expose interior entry labels" {
    try expectAsm(
        \\fn dispatch() noreturn {
        \\  export sharedEntry:
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\.globl sharedEntry
        \\sharedEntry:
        \\  break
        \\
        \\
    );
}

test "bitCast reinterprets scalar register values without conversion" {
    try expectAsm(
        \\fn test(reg($s5) signed: i32) noreturn {
        \\  reg($a1) address: u32 = bitCast(signed);
        \\  reg($a0) same_bits: dmem = bitCast(address);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  or $a1, $s5, $zero
        \\  or $a0, $a1, $zero
        \\  break
        \\
        \\
    );
}

test "raw CP0 access remains an untyped escape hatch" {
    try expectAsm(
        \\fn test(reg($t0) value: u32) noreturn {
        \\  value = rsp.cp0.read(0);
        \\  rsp.cp0.write(0, value);
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
}

test "assignment copies between explicit scalar registers" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($sp) saved_return: u32 = undefined;
        \\  reg($ra) return_address: u32 = undefined;
        \\  saved_return = return_address;
        \\  return_address = saved_return;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  or $sp, $ra, $zero
        \\  or $ra, $sp, $zero
        \\  break
        \\
        \\
    );
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

test "bit-cast operands reinterpret registers in arithmetic and comparisons" {
    try @import("support.zig").expectAsmContains(
        \\fn entry() {
        \\  reg($t1) total: u32 = 1;
        \\  reg($t0) signed: i32 = 2;
        \\  total +%= bitCast(signed);
        \\  reg($t2) below: u32 = 0;
        \\  below = total < bitCast(signed);
        \\  rsp.cp0.setSpStatus(below);
        \\}
    , &.{ "  addu $t1, $t1, $t0\n", "  sltu $t2, $t1, $t0\n" });
    try expectAsmError(
        \\fn entry() {
        \\  reg($t1) total: u32 = 1;
        \\  reg($v01) vector: vec16 = 0;
        \\  total +%= bitCast(vector);
        \\}
    , error.ArithmeticRhsMustBeRegisterOrNumber);
    try expectAsmError(
        \\fn entry() {
        \\  reg($t1) total: u32 = 1;
        \\  reg($v01) vector: vec16 = 0;
        \\  reg($t2) below: u32 = 0;
        \\  below = total < bitCast(vector);
        \\}
    , error.ExpectedScalarType);
}
