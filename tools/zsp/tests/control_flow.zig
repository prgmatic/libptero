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

test "DMA and RDP operations compose with an explicit return delay slot" {
    try expectAsm(
        \\fn test() {
        \\  reg($t1) busy: u32 = rsp.cp0.dmaBusy();
        \\  reg($s3) memory: dmem = undefined;
        \\  reg($a0) rdram: u32 = undefined;
        \\  reg($t3) length: u32 = undefined;
        \\  rsp.cp0.setDmaMemoryAddress(memory);
        \\  rsp.cp0.setDmaRdramAddress(rdram);
        \\  rsp.cp0.setRdpCommandEnd(rdram);
        \\  return slot {
        \\    rsp.cp0.startDmaWrite(length);
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  mfc0 $t1, $6
        \\  mtc0 $s3, $0
        \\  mtc0 $a0, $1
        \\  mtc0 $a0, $9
        \\  jr $ra
        \\  mtc0 $t3, $3
        \\
        \\
    );
}

test "unsigned high-bit comparison emits a signed zero branch" {
    try expectAsm(
        \\fn test(reg($t2) flags: u32) {
        \\  if(flags < 0x80000000) { rsp.nop(); }
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
        \\  bltz $t0, LABEL_test_ifelse_0
        \\  nop
        \\  addi $t0, $t0, 1
        \\  j LABEL_test_ifend_0
        \\  nop
        \\LABEL_test_ifelse_0:
        \\  addi $t0, $t0, -1
        \\LABEL_test_ifend_0:
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "branch delay slots can reuse a condition's pinned register" {
    try expectAsm(
        \\fn target() noreturn { rsp.halt(); }
        \\fn test() noreturn {
        \\  reg($t0) dma_full: u32 = 0;
        \\  if(dma_full == 0) jump target() slot {
        \\    reg($t0) transfer_descriptor: u32 = 7;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\  break
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  beqz $t0, target
        \\  addiu $t0, $zero, 7
        \\  break
        \\
        \\
    );
}

test "jump transfers control through a scalar register" {
    try expectAsm(
        \\fn dispatch(reg($t0) handler: u32) noreturn {
        \\  jump(handler);
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

test "raw jump transfers control directly to a function" {
    try expectAsm(
        \\fn target() noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch() noreturn {
        \\  jump target();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\  break
        \\
        \\dispatch:
        \\  j target
        \\  nop
        \\
        \\
    );
}

test "raw direct jump accepts a typed delay slot" {
    try expectAsm(
        \\fn target() noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch(reg($t0) value: u32) noreturn {
        \\  jump target() slot {
        \\    value = 7;
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\  break
        \\
        \\dispatch:
        \\  j target
        \\  addiu $t0, $zero, 7
        \\
        \\
    );
}

test "conditional function goto supports nonzero equality immediates" {
    try expectAsm(
        \\fn target() noreturn { rsp.halt(); }
        \\fn dispatch(reg($t0) value: u32) noreturn {
        \\  if(value == 3) jump target() slot {
        \\    value = 7;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\  break
        \\
        \\dispatch:
        \\  addiu $at, $zero, 3
        \\  beq $t0, $at, target
        \\  addiu $t0, $zero, 7
        \\  break
        \\
        \\
    );
}

test "conditional gotos may branch to exported labels with register comparisons" {
    try expectAsm(
        \\fn target() noreturn {
        \\  export sharedEntry:
        \\  rsp.halt();
        \\}
        \\fn dispatch(reg($t0) actual: u32, reg($t1) expected: u32) noreturn {
        \\  if(actual != expected) goto sharedEntry slot {
        \\    actual = 7;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\.globl sharedEntry
        \\sharedEntry:
        \\  break
        \\
        \\dispatch:
        \\  bne $t0, $t1, sharedEntry
        \\  addiu $t0, $zero, 7
        \\  break
        \\
        \\
    );
}

test "conditional gotos use public names for same-function exported labels" {
    try expectAsm(
        \\fn dispatch(reg($t0) condition: u32) noreturn {
        \\  if(condition != 0) goto sharedEntry;
        \\  rsp.halt();
        \\  export sharedEntry:
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\  bne $t0, $zero, sharedEntry
        \\  nop
        \\  break
        \\.globl sharedEntry
        \\sharedEntry:
        \\  break
        \\
        \\
    );
}

test "conditional direct goto supports signed register comparisons" {
    try expectAsm(
        \\fn failed() noreturn {
        \\  rsp.halt();
        \\}
        \\fn check(reg($s3) end: i32, reg($s4) start: i32) noreturn {
        \\  if(end < start) jump failed() slot {
        \\    reg($at) code: u32 = 0xc0060000;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\failed:
        \\  break
        \\
        \\check:
        \\  slt $at, $s3, $s4
        \\  bnez $at, failed
        \\  lui $at, 49158
        \\  break
        \\
        \\
    );
}

test "conditional direct goto lowers signed zero tests directly" {
    try expectAsm(
        \\fn failed() noreturn { rsp.halt(); }
        \\fn check(reg($t0) value: i32) noreturn {
        \\  if(value < 0) jump failed() slot {
        \\    reg($at) code: u32 = 0xc0080000;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\failed:
        \\  break
        \\
        \\check:
        \\  bltz $t0, failed
        \\  lui $at, 49160
        \\  break
        \\
        \\
    );
}

test "conditional direct goto accepts a register rhs" {
    try expectAsm(
        \\fn target() noreturn { rsp.halt(); }
        \\fn check(reg($t1) value: u32, reg($t0) expected: u32) noreturn {
        \\  if(value == expected) jump target() slot {
        \\    expected = 6;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\  break
        \\
        \\check:
        \\  beq $t1, $t0, target
        \\  addiu $t0, $zero, 6
        \\  break
        \\
        \\
    );
}

test "jump accepts a typed slot" {
    try expectAsm(
        \\fn loop() noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch(reg($t0) handler: u32) noreturn {
        \\  jump(handler) slot {
        \\    reg($ra) continuation: fn() = &loop;
        \\  }
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
        \\  jr $t0
        \\  addiu $ra, $zero, %lo(loop)
        \\
        \\
    );
}

test "tail transfers place their target adjacent and emit no transfer instruction" {
    try expectAsm(
        \\fn first() noreturn {
        \\  reg value: u32 = 7;
        \\  tail last(value);
        \\}
        \\fn middle() noreturn {
        \\  rsp.halt(2);
        \\}
        \\fn last(reg($t3) value: u32) noreturn {
        \\  value += 1;
        \\  rsp.halt(1);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\first:
        \\  addiu $t3, $zero, 7
        \\
        \\last:
        \\  addi $t3, $t3, 1
        \\  break 0x1
        \\
        \\middle:
        \\  break 0x2
        \\
        \\
    );
}

test "conflicting tail placement emits a jump for the non-adjacent edge" {
    try expectAsm(
        \\fn first() noreturn { tail target(); }
        \\fn second() noreturn { tail target(); }
        \\fn target() noreturn { rsp.halt(); }
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\first:
        \\
        \\target:
        \\  break
        \\
        \\second:
        \\  j target
        \\  nop
        \\
        \\
    );
}

test "tail transfers to external functions emit a jump" {
    try expectAsm(
        \\extern fn target() writes() noreturn;
        \\fn first() noreturn { tail target(); }
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\first:
        \\  j target
        \\  nop
        \\
        \\
    );
}

test "non-terminal tail transfers emit an explicit jump" {
    try expectAsm(
        \\fn first(reg($a0) flag: u32) noreturn {
        \\  if(flag != 0) {
        \\    tail target();
        \\  }
        \\  rsp.halt();
        \\}
        \\fn target() noreturn { rsp.halt(1); }
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\first:
        \\  beq $a0, $zero, LABEL_first_ifend_0
        \\  nop
        \\  j target
        \\  nop
        \\LABEL_first_ifend_0:
        \\  break
        \\
        \\target:
        \\  break 0x1
        \\
        \\
    );
}

test "local labels support direct and conditional goto" {
    try expectAsm(
        \\fn dispatch(reg($t0) value: u32) noreturn {
        \\start:
        \\  if(value == 0) goto done;
        \\  goto start;
        \\done:
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\LABEL_dispatch_start_0:
        \\  beq $t0, $zero, LABEL_dispatch_done_0
        \\  nop
        \\  j LABEL_dispatch_start_0
        \\  nop
        \\LABEL_dispatch_done_0:
        \\  break
        \\
        \\
    );
}

test "local goto slot blocks emit typed transfer-slot statements" {
    try expectAsm(
        \\fn dispatch(reg($t0) value: u32, reg($t1) next: u32) noreturn {
        \\  if(value == 0) goto done slot {
        \\    next += 1;
        \\  }
        \\  goto done slot {
        \\    value = next;
        \\  }
        \\done:
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\  beq $t0, $zero, LABEL_dispatch_done_0
        \\  addi $t1, $t1, 1
        \\  j LABEL_dispatch_done_0
        \\  or $t0, $t1, $zero
        \\LABEL_dispatch_done_0:
        \\  break
        \\
        \\
    );
}

test "conditional direct goto emits a tail branch and delay slot" {
    try expectAsm(
        \\fn target() noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch(reg($t0) value: u32) noreturn {
        \\  if(value == 0) jump target();
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\  break
        \\
        \\dispatch:
        \\  beqz $t0, target
        \\  nop
        \\  break
        \\
        \\
    );
}

test "tail slot becomes the final instruction before zero-byte fallthrough" {
    try expectAsm(
        \\fn target(reg($a0) value: u32) noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch(reg($a0) value: u32) noreturn {
        \\  tail target(value) slot {
        \\    value += 1;
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\  addi $a0, $a0, 1
        \\
        \\target:
        \\  break
        \\
        \\
    );
}

test "slot blocks reject multiple source statements" {
    try expectAsmError(
        \\fn dispatch(reg($t0) value: u32) noreturn {
        \\  goto done slot {
        \\    value += 1;
        \\    value += 2;
        \\  }
        \\done:
        \\  rsp.halt();
        \\}
    , error.InvalidSlot);
}

test "slot blocks reject semantic no-ops" {
    try expectAsmError(
        \\fn dispatch() noreturn {
        \\  jump dispatch() slot {
        \\    rsp.nop();
        \\  }
        \\}
    , error.UnnecessarySlot);
}

test "while loop emits labels branch and back edge" {
    try expectAsm(
        \\export fn _start() noreturn {
        \\  reg($t0) ptr: dmem = 0;
        \\  const end: dmem = 4;
        \\  while(ptr < end) {
        \\    store(u16, ptr, ptr);
        \\    ptr += 2;
        \\  }
        \\  rsp.halt();
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
        \\  addi $t0, $t0, 2
        \\  j LABEL__start_while_0
        \\  nop
        \\LABEL__start_whileend_0:
        \\  break
        \\
        \\
    );
}

test "labeled break and continue target the requested loop" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) outer_value: u32 = 0;
        \\  reg($t1) inner_value: u32 = 0;
        \\outer: while(outer_value < 2) {
        \\  inner: while(inner_value < 2) {
        \\    break outer;
        \\  }
        \\  continue outer;
        \\}
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\  addiu $t1, $zero, 0
        \\LABEL_test_while_0:
        \\  sltiu $at, $t0, 2
        \\  beq $at, $zero, LABEL_test_whileend_0
        \\  nop
        \\LABEL_test_while_1:
        \\  sltiu $at, $t1, 2
        \\  beq $at, $zero, LABEL_test_whileend_1
        \\  nop
        \\  j LABEL_test_whileend_0
        \\  nop
        \\LABEL_test_whileend_1:
        \\  j LABEL_test_while_0
        \\  nop
        \\LABEL_test_whileend_0:
        \\  break
        \\
        \\
    );
}

test "do while loops branch after executing their body" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = 0;
        \\again: do {
        \\  value += 1;
        \\} while(value < 3);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 0
        \\LABEL_test_dowhile_0:
        \\  addi $t0, $t0, 1
        \\  sltiu $at, $t0, 3
        \\  bne $at, $zero, LABEL_test_dowhile_0
        \\  nop
        \\LABEL_test_dowhileend_0:
        \\  break
        \\
        \\
    );
}

test "structured if supports an explicit branch slot" {
    try expectAsm(
        \\fn test(reg($t0) value: u32) noreturn {
        \\  if(value != 0) slot {
        \\    value = 7;
        \\  } {
        \\    rsp.halt(1);
        \\  }
        \\  rsp.halt(2);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  beq $t0, $zero, LABEL_test_ifend_0
        \\  addiu $t0, $zero, 7
        \\  break 0x1
        \\LABEL_test_ifend_0:
        \\  break 0x2
        \\
        \\
    );
}

test "structured if preserves a load in an explicit branch slot" {
    try expectAsm(
        \\bss {
        \\  delay_value: u16;
        \\  arm_value: u8;
        \\}
        \\fn test(reg($a0) flag: i32) noreturn {
        \\  reg($t0) value: u32 = undefined;
        \\  if(flag < 0) slot {
        \\    value = load(u16, delay_value);
        \\  } {
        \\    value = load(u8, arm_value);
        \\    rsp.halt(1);
        \\  }
        \\  rsp.halt(2);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 2
        \\delay_value:
        \\  .space 2
        \\arm_value:
        \\  .space 1
        \\
        \\.text
        \\
        \\
        \\test:
        \\  bgez $a0, LABEL_test_ifend_0
        \\  lhu $t0, %lo(delay_value)($zero)
        \\  lbu $t0, %lo(arm_value)($zero)
        \\  break 0x1
        \\LABEL_test_ifend_0:
        \\  break 0x2
        \\
        \\
    );
}

test "if block placement avoids a jump when the else arm terminates" {
    try expectAsm(
        \\fn test(reg($a0) flag: u32, reg($t0) value: u32) noreturn {
        \\  if(flag != 0) {
        \\    value += 1;
        \\  } else {
        \\    return;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  bne $a0, $zero, LABEL_test_ifthen_0
        \\  nop
        \\  jr $ra
        \\  nop
        \\LABEL_test_ifthen_0:
        \\  addi $t0, $t0, 1
        \\LABEL_test_ifend_0:
        \\  break
        \\
        \\
    );
}

test "conditional labeled block breaks branch directly to the block exit" {
    try expectAsm(
        \\fn test(reg($t0) value: u32) noreturn {
        \\  done: block {
        \\    if(value == 0) {
        \\      break done slot {
        \\        value = 1;
        \\      }
        \\    }
        \\    value = 2;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  beq $t0, $zero, LABEL_test_blockend_0
        \\  addiu $t0, $zero, 1
        \\  addiu $t0, $zero, 2
        \\LABEL_test_blockend_0:
        \\  break
        \\
        \\
    );
}

test "labeled block exit slot is shared with a terminal conditional transfer" {
    try expectAsm(
        \\fn target() noreturn { rsp.halt(1); }
        \\fn test(reg($t0) value: u32) noreturn {
        \\  done: block {
        \\    if(value == 0) {
        \\      break done;
        \\    }
        \\    if(value != 1) jump target();
        \\  } exit slot {
        \\    value = 7;
        \\  }
        \\  rsp.halt(2);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\target:
        \\  break 0x1
        \\
        \\test:
        \\  beq $t0, $zero, LABEL_test_blockend_0
        \\  nop
        \\  addiu $at, $zero, 1
        \\  bne $t0, $at, target
        \\LABEL_test_blockend_0:
        \\  addiu $t0, $zero, 7
        \\  break 0x2
        \\
        \\
    );
}

test "loop control outside a matching loop is rejected" {
    try expectAsmError(
        \\fn test() noreturn {
        \\  continue missing;
        \\}
    , error.UnknownLoopLabel);
}

test "exact terminal return does not append a second return" {
    var parser = try parser_mod.Parser.init(testing.allocator,
        \\fn test() {
        \\    exact {
        \\        return;
        \\    }
        \\}
    );
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try asm_writer.write(&output.writer, functions);
    const bytes = output.writer.buffered();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "jr $ra"));
}
