//! Readable surface forms: contextual keywords, negation, single-statement
//! bodies, expression arguments, inline return values, and array parameters.
const support = @import("support.zig");

const expectAsm = support.expectAsm;
const expectRejectedWith = support.expectRejectedWith;

test "statement keywords are contextual names" {
    try expectAsm(
        \\fn test(reg($a0) a: u32) {
        \\  reg packed: u32 = a;
        \\  packed += 1;
        \\  reg state: u32 = packed;
        \\  state = a;
        \\  store(u32, 0x10, state);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  or $t0, $a0, $zero
        \\  addi $t0, $t0, 1
        \\  or $t1, $t0, $zero
        \\  or $t1, $a0, $zero
        \\  sw $t1, 16($zero)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "negation applies to names and expressions" {
    try expectAsm(
        \\fn test(reg($a0) a: i32, reg($a1) b: i32) {
        \\  reg y: i32 = -a;
        \\  reg w: i32 = b - -a;
        \\  reg v: i32 = -(a + b);
        \\  store(i32, 0x10, y);
        \\  store(i32, 0x14, w);
        \\  store(i32, 0x18, v);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  sub $t0, $zero, $a0
        \\  sub $t2, $zero, $a0
        \\  sub $t1, $a1, $t2
        \\  add $t2, $a0, $a1
        \\  sub $t2, $zero, $t2
        \\  sw $t0, 16($zero)
        \\  sw $t1, 20($zero)
        \\  sw $t2, 24($zero)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "if and else take a single statement" {
    try expectAsm(
        \\fn test(reg($a0) a: u32, reg($a1) b: u32) {
        \\  if (a == 0) return;
        \\  if (b == 1) store(u32, 0x14, b); else if (b == 2) store(u32, 0x18, b); else b += 3;
        \\  store(u32, 0x10, b);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  bne $a0, $zero, LABEL_test_ifend_0
        \\  nop
        \\  jr $ra
        \\  nop
        \\LABEL_test_ifend_0:
        \\  addiu $v1, $zero, 1
        \\  bne $a1, $v1, LABEL_test_ifelse_1
        \\  nop
        \\  sw $a1, 20($zero)
        \\  j LABEL_test_ifend_1
        \\  nop
        \\LABEL_test_ifelse_1:
        \\  addiu $v1, $zero, 2
        \\  bne $a1, $v1, LABEL_test_ifelse_2
        \\  nop
        \\  sw $a1, 24($zero)
        \\  j LABEL_test_ifend_2
        \\  nop
        \\LABEL_test_ifelse_2:
        \\  addi $a1, $a1, 3
        \\LABEL_test_ifend_2:
        \\LABEL_test_ifend_1:
        \\  sw $a1, 16($zero)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "expression arguments are evaluated before the call" {
    try expectAsm(
        \\fn helper(a: u32, b: u32) {
        \\  store(u32, 0x10, a);
        \\  store(u32, 0x14, b);
        \\}
        \\fn test(reg($a0) a: u32) {
        \\  helper(a + 4, (a << 2) | 1);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\helper:
        \\  sw $a0, 16($zero)
        \\  sw $a1, 20($zero)
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  addi $t0, $a0, 4
        \\  sll $a1, $a0, 2
        \\  ori $a1, $a1, 1
        \\  or $a0, $t0, $zero
        \\  jal helper
        \\  nop
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "inline functions return values into the caller's register" {
    try expectAsm(
        \\inline fn twice(x: u32) u32 {
        \\  return x + x;
        \\}
        \\inline fn clamp(x: i32, limit: i32) i32 {
        \\  reg result: i32 = x;
        \\  if (x > limit) result = limit;
        \\  return result;
        \\}
        \\fn test(reg($a0) a: u32, reg($a1) b: i32) {
        \\  reg y: u32 = twice(a);
        \\  y = twice(y);
        \\  store(u32, 0x10, y);
        \\  reg c: i32 = clamp(b, 100);
        \\  store(i32, 0x14, c);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  add $t0, $a0, $a0
        \\  add $t0, $t0, $t0
        \\  sw $t0, 16($zero)
        \\  or $t0, $a1, $zero
        \\  slti $at, $a1, 101
        \\  bne $at, $zero, LABEL_test_ifend_0
        \\  nop
        \\  addiu $t0, $zero, 100
        \\LABEL_test_ifend_0:
        \\  or $t1, $t0, $zero
        \\  sw $t1, 20($zero)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "register arrays pass by name to array parameters" {
    try expectAsm(
        \\inline fn sum(rows: [2]vec16) {
        \\  rows[0] = rows[0] + rows[1];
        \\}
        \\fn rowsOut(reg($v04) rows: [2]vec16) {
        \\  store(vec16, 0x100, rows[0]);
        \\  store(vec16, 0x110, rows[1]);
        \\}
        \\fn test() {
        \\  reg m: [2]vec16 = undefined;
        \\  m[0] = load(vec16, 0x200);
        \\  m[1] = load(vec16, 0x210);
        \\  sum(m);
        \\  rowsOut(m);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\rowsOut:
        \\  addiu $at, $zero, 256
        \\  .word 0xe8242000 # sqv $v04, 0($at)
        \\  addiu $at, $zero, 272
        \\  .word 0xe8252000 # sqv $v05, 0($at)
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  addiu $at, $zero, 512
        \\  .word 0xc8242000 # lqv $v04, 0($at)
        \\  addiu $at, $zero, 528
        \\  .word 0xc8252000 # lqv $v05, 0($at)
        \\  .word 0x4a052114 # vaddc $v04, $v04, $v05
        \\  jal rowsOut
        \\  nop
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "return values need an inline function and a final return" {
    try expectRejectedWith("fn f(x: u32) u32 { return x; }", .return_value_requires_inline);
    try expectRejectedWith("fn f(x: u32) { return x; }", .return_value_requires_inline);
    try expectRejectedWith("inline fn f(x: u32) u32 { if (x == 0) { return x; } return x; }", .return_value_not_last);
    try expectRejectedWith("inline fn f(x: u32) u32 { return x; x += 1; }", .return_value_not_last);
    try expectRejectedWith("inline fn f(x: u32) u32 { x += 1; }", .missing_return_value);
}

test "array parameters need a valid length and a vector register to pin" {
    try expectRejectedWith("fn f(rows: [0]vec16) {}", .invalid_array_length);
    try expectRejectedWith("fn f(reg($t0) rows: [2]u32) {}", .expected_vector_register);
}
