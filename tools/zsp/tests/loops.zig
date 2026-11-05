//! Structured loops: rotated `while`, `while (true)`, continue
//! expressions, and single-branch conditional exits.
const support = @import("support.zig");

const expectAsm = support.expectAsm;

test "while loops test their condition before and after each iteration" {
    try expectAsm(
        \\fn test(reg($a0) count: u32) {
        \\  reg i: u32 = 0;
        \\  while (i != count) : (i += 1) {
        \\    if (i == 3) {
        \\      continue;
        \\    }
        \\    rsp.cp0.setSpStatus(i);
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  beq $t0, $a0, LABEL_test_ifend_0
        \\  nop
        \\LABEL_test_dowhile_1:
        \\  addiu $v1, $zero, 3
        \\  beq $t0, $v1, LABEL_test_blockend_2
        \\  nop
        \\  mtc0 $t0, $4
        \\LABEL_test_blockend_2:
        \\  addi $t0, $t0, 1
        \\  bne $t0, $a0, LABEL_test_dowhile_1
        \\  nop
        \\LABEL_test_dowhileend_1:
        \\LABEL_test_ifend_0:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "continue expressions run before labeled and unlabeled continues" {
    try expectAsm(
        \\fn test(reg($a0) count: u32) {
        \\  outer: while (count != 0) : (count -= 1) {
        \\    reg($t1) inner: u32 = count;
        \\    while (inner != 0) : (inner -= 1) {
        \\      if (inner == 2) {
        \\        continue outer;
        \\      }
        \\      if (inner == 5) {
        \\        continue;
        \\      }
        \\    }
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  beq $a0, $zero, LABEL_test_ifend_0
        \\  nop
        \\LABEL_test_dowhile_1:
        \\  or $t1, $a0, $zero
        \\  beq $t1, $zero, LABEL_test_ifend_3
        \\  nop
        \\LABEL_test_dowhile_4:
        \\  addiu $v1, $zero, 2
        \\  beq $t1, $v1, LABEL_test_blockend_2
        \\  nop
        \\  addiu $v1, $zero, 5
        \\  beq $t1, $v1, LABEL_test_blockend_5
        \\  nop
        \\LABEL_test_blockend_5:
        \\  addi $t1, $t1, -1
        \\  bne $t1, $zero, LABEL_test_dowhile_4
        \\  nop
        \\LABEL_test_dowhileend_4:
        \\LABEL_test_ifend_3:
        \\LABEL_test_blockend_2:
        \\  addi $a0, $a0, -1
        \\  bne $a0, $zero, LABEL_test_dowhile_1
        \\  nop
        \\LABEL_test_dowhileend_1:
        \\LABEL_test_ifend_0:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "while true ending in a break tests its exit on the back edge" {
    try expectAsm(
        \\fn test(reg($a0) count: u32) {
        \\  while (true) {
        \\    count -= 1;
        \\    if (count == 0) {
        \\      break;
        \\    }
        \\  }
        \\  do {
        \\    done: block {
        \\      if (count == 4) {
        \\        break;
        \\      }
        \\      break done;
        \\    }
        \\    count += 1;
        \\  } while (true) slot {
        \\    count += 2;
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\LABEL_test_dowhile_0:
        \\  addi $a0, $a0, -1
        \\  bne $a0, $zero, LABEL_test_dowhile_0
        \\  nop
        \\LABEL_test_dowhileend_0:
        \\LABEL_test_dowhile_1:
        \\  addiu $v1, $zero, 4
        \\  beq $a0, $v1, LABEL_test_dowhileend_1
        \\  nop
        \\  j LABEL_test_blockend_2
        \\  nop
        \\LABEL_test_blockend_2:
        \\  addi $a0, $a0, 1
        \\  j LABEL_test_dowhile_1
        \\  addi $a0, $a0, 2
        \\LABEL_test_dowhileend_1:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "expression initializers declare then assign" {
    try expectAsm(
        \\fn test(reg($a0) a: u32, reg($a1) b: u32) {
        \\  reg sum: u32 = a + b << 2;
        \\  rsp.cp0.setSpStatus(sum);
        \\  reg($v01) left: vec32 = undefined;
        \\  reg($v03) total: vec32 = left + left.yyyyYYYY;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  add $t0, $a0, $a1
        \\  sll $t0, $t0, 2
        \\  mtc0 $t0, $4
        \\  .word 0x4aa21114 # vaddc $v04, $v02, $v02
        \\  .word 0x4aa108d0 # vadd $v03, $v01, $v01
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "while true keeps its jump when the break is mid-body or a continue tests nothing" {
    try expectAsm(
        \\fn test(reg($a0) count: u32) {
        \\  while (true) {
        \\    count -= 1;
        \\    if (count == 0) {
        \\      break;
        \\    }
        \\    count -= 2;
        \\  }
        \\  while (true) {
        \\    count += 1;
        \\    if (count == 4) {
        \\      continue;
        \\    }
        \\    if (count == 9) {
        \\      break;
        \\    }
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\LABEL_test_dowhile_0:
        \\  addi $a0, $a0, -1
        \\  beq $a0, $zero, LABEL_test_dowhileend_0
        \\  nop
        \\  addi $a0, $a0, -2
        \\  j LABEL_test_dowhile_0
        \\  nop
        \\LABEL_test_dowhileend_0:
        \\LABEL_test_dowhile_2:
        \\  addi $a0, $a0, 1
        \\  addiu $v1, $zero, 4
        \\  beq $a0, $v1, LABEL_test_dowhilecond_2
        \\  nop
        \\  addiu $v1, $zero, 9
        \\  beq $a0, $v1, LABEL_test_dowhileend_2
        \\  nop
        \\LABEL_test_dowhilecond_2:
        \\  j LABEL_test_dowhile_2
        \\  nop
        \\LABEL_test_dowhileend_2:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "cold if bodies are placed after the function and jump back" {
    try expectAsm(
        \\fn test(reg($a0) count: u32, reg($a1) flag: u32) {
        \\  count += 1;
        \\  if (flag != 0) {
        \\    @branchHint(.cold);
        \\    count = 0;
        \\  }
        \\  while (count == 3) {
        \\    @branchHint(.cold);
        \\    count = rsp.cp0.spStatus();
        \\  }
        \\  rsp.cp0.setSpStatus(count);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addi $a0, $a0, 1
        \\  bne $a1, $zero, LABEL_test_ifcold_0
        \\  nop
        \\LABEL_test_ifend_0:
        \\  addiu $v1, $zero, 3
        \\  beq $a0, $v1, LABEL_test_ifcold_1
        \\  nop
        \\LABEL_test_ifend_1:
        \\  mtc0 $a0, $4
        \\  jr $ra
        \\  nop
        \\LABEL_test_ifcold_0:
        \\  addiu $a0, $zero, 0
        \\  j LABEL_test_ifend_0
        \\  nop
        \\LABEL_test_ifcold_1:
        \\LABEL_test_dowhile_2:
        \\  mfc0 $a0, $4
        \\  addiu $v1, $zero, 3
        \\  beq $a0, $v1, LABEL_test_dowhile_2
        \\  nop
        \\LABEL_test_dowhileend_2:
        \\  j LABEL_test_ifend_1
        \\  nop
        \\
        \\
    );
}

test "cold bodies stay inline inside loops" {
    try expectAsm(
        \\fn test(reg($a0) count: u32) {
        \\  while (count != 0) {
        \\    if (count == 2) {
        \\      @branchHint(.cold);
        \\      count = 9;
        \\    }
        \\    count -= 1;
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  beq $a0, $zero, LABEL_test_ifend_0
        \\  nop
        \\LABEL_test_dowhile_1:
        \\  addiu $v1, $zero, 2
        \\  bne $a0, $v1, LABEL_test_ifend_2
        \\  nop
        \\  addiu $a0, $zero, 9
        \\LABEL_test_ifend_2:
        \\  addi $a0, $a0, -1
        \\  bne $a0, $zero, LABEL_test_dowhile_1
        \\  nop
        \\LABEL_test_dowhileend_1:
        \\LABEL_test_ifend_0:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}
