const std = @import("std");
const ast = @import("../ast.zig");
const asm_writer = @import("../asm_writer.zig");
const asm_optimizer = @import("../asm_optimizer.zig");
const parser_mod = @import("../parser.zig");

const testing = std.testing;

const expectAsm = @import("support.zig").expectAsm;
const expectAsmError = @import("support.zig").expectAsmError;
const expectParseError = @import("support.zig").expectParseError;
const expectSyntaxRejected = @import("support.zig").expectSyntaxRejected;
const expectOptimizedAsm = @import("support.zig").expectOptimizedAsm;

test "optimizer fills a branch delay slot with an independent instruction" {
    try expectOptimizedAsm(
        "  addiu $t0, $zero, 1\n  addiu $t1, $zero, 2\n  bne $t0, $zero, done\n  nop\ndone:\n",
        "  addiu $t0, $zero, 1\n  bne $t0, $zero, done\n  addiu $t1, $zero, 2\ndone:\n",
    );
}

test "optimizer schedules signed scalar arithmetic" {
    try expectOptimizedAsm(
        "  lw $s0, 0($zero)\n  add $s0, $s0, $gp\n  j fetch\n  nop\nfetch:\n",
        "  lw $s0, 0($zero)\n  j fetch\n  add $s0, $s0, $gp\nfetch:\n",
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

test "exact blocks make raw assembly an optimizer barrier" {
    try expectAsm(
        \\fn test() {
        \\  exact {
        \\    asm("addiu $t0, $zero, 1");
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\# zsp exact block begin
        \\  addiu $t0, $zero, 1
        \\# zsp exact block end
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "exact blocks preserve emitted instruction order" {
    try expectAsm(
        \\fn test() {
        \\  exact {
        \\    asm("addiu $t0, $zero, 1");
        \\    asm("addiu $t1, $zero, 2");
        \\    asm("bne $t0, $zero, done");
        \\    asm("nop");
        \\  }
        \\  done:
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\# zsp exact block begin
        \\  addiu $t0, $zero, 1
        \\  addiu $t1, $zero, 2
        \\  bne $t0, $zero, done
        \\  nop
        \\# zsp exact block end
        \\LABEL_test_done_0:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "optimizer folds a literal data-label address into a memory relocation" {
    try expectOptimizedAsm(
        \\  addiu $at, $zero, %lo(mode)
        \\  lw $a0, 24($at)
        \\  addiu $at, $zero, %lo(mode)
        \\  sw $a1, -4($at)
    ,
        \\  lw $a0, %lo(mode + 24)($zero)
        \\  sw $a1, %lo(mode + -4)($zero)
    );
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

test "optimizer does not move an ra read into a jal delay slot" {
    try expectOptimizedAsm(
        \\  or $k1, $ra, $zero
        \\  jal helper
        \\  nop
    ,
        \\  or $k1, $ra, $zero
        \\  jal helper
        \\  nop
    );
}
