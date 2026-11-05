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

test "named exports generate structural external interfaces" {
    const source =
        \\pub export fn increment(value: u32) noreturn {
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ;
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);

    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try @import("../interface.zig").writeInterface(testing.allocator, &output.writer, functions, null);
    try testing.expectEqualStrings(
        "// @zsp-symbol increment increment\n" ++
            "pub extern fn increment(reg($a0) value: u32) writes($a0) noreturn;\n\n",
        output.written(),
    );
}

test "call followed by tail uses a fallthrough continuation when available" {
    try expectAsm(
        \\fn append() {}
        \\fn finish() noreturn { rsp.halt(); }
        \\fn test() noreturn {
        \\  append();
        \\  tail finish();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\append:
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  jal append
        \\  nop
        \\
        \\finish:
        \\  break
        \\
        \\
    );
}

test "call followed by tail emits a stackless continuation when placement is claimed" {
    try expectAsm(
        \\fn append() {}
        \\fn finish() noreturn { rsp.halt(); }
        \\fn first() noreturn {
        \\  append();
        \\  tail finish();
        \\}
        \\fn second() noreturn {
        \\  append();
        \\  tail finish();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\append:
        \\  jr $ra
        \\  nop
        \\
        \\first:
        \\  jal append
        \\  nop
        \\
        \\finish:
        \\  break
        \\
        \\second:
        \\  j append
        \\  addiu $ra, $zero, %lo(finish)
        \\
        \\
    );
}

test "function call accepts one explicit slot statement" {
    try expectAsm(
        \\fn helper(reg($a0) value: u32) {}
        \\@rspq.command(1) fn test(reg($a0) value: u32) {
        \\  reg($t3) opcode: u32 = undefined;
        \\  helper(value) slot { opcode = 0xf0000000; }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\helper:
        \\  jr $ra
        \\  nop
        \\
        \\.globl test
        \\test:
        \\  or $k1, $ra, $zero
        \\  jal helper
        \\  lui $t3, 61440
        \\  jr $k1
        \\  nop
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word test
        \\  .byte 1
        \\  .byte 4
        \\  .short 0
        \\
        \\
    );
}

test "inline calls bind parameters and expand inside caller scope" {
    try expectAsm(
        \\inline fn write(
        \\  reg($t0) value: u32,
        \\  reg($s0) destination: dmem,
        \\) {
        \\  store(u32, destination, value);
        \\}
        \\
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = 0x1234;
        \\  reg($s0) destination: dmem = 0x20;
        \\  write(value, destination);
        \\  rsp.halt();
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

test "unpinned inline parameters name their arguments in place" {
    try expectAsm(
        \\bss { stage: [4]u32; end: u32; }
        \\fn send(reg($s4) first: dmem, reg($s3) last: dmem) {
        \\  last &= 0x0fff;
        \\  store(u32, first, last);
        \\}
        \\inline fn take(begin: dmem, finish: dmem, step: u32) {
        \\  begin = stage;
        \\  finish = load(u32, end);
        \\  finish += step;
        \\}
        \\fn test() {
        \\  reg low: dmem;
        \\  reg high: dmem;
        \\  take(low, high, 8);
        \\  send(low, high);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\.balign 4
        \\stage:
        \\  .space 16
        \\.balign 4
        \\end:
        \\  .space 4
        \\
        \\.text
        \\
        \\
        \\send:
        \\  andi $s3, $s3, 4095
        \\  sw $s3, 0($s4)
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  addiu $s4, $zero, %lo(stage)
        \\  lw $s3, %lo(end)($zero)
        \\  addi $s3, $s3, 8
        \\  jal send
        \\  nop
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "default function parameters use argument registers" {
    try expectAsm(
        \\fn add(first: u32, second: u32) noreturn {
        \\  first += second;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\add:
        \\  add $a0, $a0, $a1
        \\  break
        \\
        \\
    );
}

test "default argument registers are reusable across functions" {
    try expectAsm(
        \\fn first(value: u32) noreturn {
        \\  value += 1;
        \\  rsp.halt();
        \\}
        \\fn second(value: u32, mask: u32) noreturn {
        \\  value &= mask;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\first:
        \\  addi $a0, $a0, 1
        \\  break
        \\
        \\second:
        \\  and $a0, $a0, $a1
        \\  break
        \\
        \\
    );
}

test "typed function pointers validate addresses and support indirect jumps" {
    try expectAsm(
        \\fn first() noreturn { rsp.halt(); }
        \\fn second() noreturn { rsp.halt(); }
        \\fn dispatch() noreturn {
        \\  reg($t0) next: fn() = &first;
        \\  next = &second;
        \\  jump(next);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\first:
        \\  break
        \\
        \\second:
        \\  break
        \\
        \\dispatch:
        \\  addiu $t0, $zero, %lo(first)
        \\  addiu $t0, $zero, %lo(second)
        \\  jr $t0
        \\  nop
        \\
        \\
    );
}

test "scalar code addresses support indirect calls with a delay slot" {
    try expectAsm(
        \\fn dispatch(reg($t9) handler: u32, reg($t0) value: u32) noreturn {
        \\  call(handler) slot {
        \\    value = 7;
        \\  }
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\dispatch:
        \\  jal $t9
        \\  addiu $t0, $zero, 7
        \\  break
        \\
        \\
    );
}

test "typed function pointer assignments reject incompatible structural signatures" {
    try expectAsmError(
        \\fn target(reg($t0) value: u32) noreturn { rsp.halt(); }
        \\fn dispatch() noreturn {
        \\  reg next: fn(u32) = &target;
        \\  jump(next);
        \\}
    , error.FunctionTypeMismatch);
}

test "gp can be explicitly pinned but is not automatically allocated" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($gp) command_address: u32 = 0x20;
        \\  reg automatic: u32 = 1;
        \\  command_address += automatic;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $gp, $zero, 32
        \\  addiu $t0, $zero, 1
        \\  add $gp, $gp, $t0
        \\  break
        \\
        \\
    );
}

test "conditional tail validates arguments and preserves direct branch lowering" {
    try expectAsm(
        \\fn target(reg($a0) value: u32) noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch(reg($t0) condition: u32) noreturn {
        \\  reg value: u32 = 7;
        \\  if(condition == 0) tail target(value);
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
        \\  addiu $a0, $zero, 7
        \\  beqz $t0, target
        \\  nop
        \\  break
        \\
        \\
    );
}

test "typed direct jump validates arguments without changing function layout" {
    try expectAsm(
        \\fn target(reg($a0) value: u32) noreturn {
        \\  rsp.halt();
        \\}
        \\fn dispatch() noreturn {
        \\  reg value: u32 = 7;
        \\  jump target(value);
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
        \\  addiu $a0, $zero, 7
        \\  j target
        \\  nop
        \\
        \\
    );
}

test "automatic call arguments coalesce into fixed ABI registers" {
    try expectAsm(
        \\fn consume(reg($t3) value: u32) noreturn {
        \\  rsp.halt();
        \\}
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume(value);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\consume:
        \\  break
        \\
        \\test:
        \\  addiu $t3, $zero, 7
        \\  jal consume
        \\  nop
        \\  break
        \\
        \\
    );
}

test "read-only automatic arguments remain live in their ABI registers" {
    try expectAsm(
        \\fn consume(reg($t0) input: u32) {
        \\}
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume(value);
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\consume:
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  addiu $t0, $zero, 7
        \\  jal consume
        \\  nop
        \\  addi $t0, $t0, 1
        \\  break
        \\
        \\
    );
}

test "literal argument setup rejects conflicting pinned live values" {
    try expectAsmError(
        \\fn consume(reg($t0) input: u32) {
        \\}
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = 7;
        \\  consume(3);
        \\  value += 1;
        \\  rsp.halt();
        \\}
    , error.PinnedRegisterOverwrittenByCallArgument);
}

test "transitive literal argument setup rejects conflicting pinned live values" {
    try expectAsmError(
        \\fn consume(reg($t0) input: u32) {
        \\}
        \\fn middle() {
        \\  consume(3);
        \\}
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = 7;
        \\  middle();
        \\  value += 1;
        \\  rsp.halt();
        \\}
    , error.PinnedRegisterClobberedByCall);
}

test "calls may define automatic output arguments in fixed registers" {
    try expectAsm(
        \\inline fn readStatus(reg($t2) value: u32) {
        \\  value = rsp.cp0.read(11);
        \\}
        \\fn test() noreturn {
        \\  reg value: u32;
        \\  readStatus(value);
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  mfc0 $t2, $11
        \\  addi $t2, $t2, 1
        \\  break
        \\
        \\
    );
}

test "function calls verify fixed-register arguments without moves" {
    try expectAsm(
        \\fn callee(
        \\  reg($t0) size: u32,
        \\  reg($s0) address: dmem,
        \\) {}
        \\
        \\fn caller() noreturn {
        \\  reg($t0) size: u32 = 15;
        \\  reg($s0) address: dmem = 0x1000;
        \\  callee(size, address);
        \\  rsp.halt();
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

test "function calls move scalar arguments that do not match pinned parameters" {
    try expectAsmError(
        \\fn callee(reg($t0) value: u32) {}
        \\fn caller() {
        \\  callee();
        \\}
    , error.FunctionArgumentCountMismatch);
    try expectAsm(
        \\fn callee(reg($t0) value: u32) {}
        \\fn caller() {
        \\  reg($t0) value: i32 = 1;
        \\  callee(value);
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
        \\  addiu $t0, $zero, 1
        \\  jal callee
        \\  nop
        \\  jr $ra
        \\  nop
        \\
        \\
    );
    try expectAsm(
        \\fn callee(reg($t0) value: u32) {}
        \\fn caller() {
        \\  reg($t1) value: u32 = 1;
        \\  callee(value);
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
        \\  addiu $t1, $zero, 1
        \\  or $t0, $t1, $zero
        \\  jal callee
        \\  nop
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "function calls order argument moves before destructive setup" {
    try expectAsm(
        \\fn callee(reg($t0) first: u32, reg($t1) second: u32) {}
        \\fn caller() {
        \\  reg($t0) second: u32 = 9;
        \\  callee(3, second);
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
        \\  addiu $t0, $zero, 9
        \\  or $t1, $t0, $zero
        \\  addiu $t0, $zero, 3
        \\  jal callee
        \\  nop
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "function calls break scalar argument move cycles through a scratch register" {
    try @import("support.zig").expectAsmContains(
        \\fn callee(reg($t0) first: u32, reg($t1) second: u32) {}
        \\fn caller() {
        \\  reg($t0) second: u32 = 1;
        \\  reg($t1) first: u32 = 2;
        \\  callee(first, second);
        \\}
    , &.{"  or $at, $t0, $zero\n  or $t0, $t1, $zero\n  or $t1, $at, $zero\n  jal callee\n"});
    try @import("support.zig").expectAsmContains(
        \\fn callee(reg($t0) a: u32, reg($t1) b: u32, reg($at) c: u32) {}
        \\fn caller() {
        \\  reg($t1) x: u32 = 1;
        \\  reg($t0) y: u32 = 2;
        \\  reg($t2) z: u32 = 3;
        \\  callee(x, y, z);
        \\}
    , &.{"  or $v1, $t0, $zero\n"});
}

test "function calls require matching registers for written scalar arguments" {
    try expectAsmError(
        \\fn update(reg($t0) value: u32) {
        \\  value = 2;
        \\}
        \\fn caller() {
        \\  reg($t1) value: u32 = 1;
        \\  update(value);
        \\}
    , error.FunctionArgumentRegisterMismatch);
}

test "function calls materialize constants and literals in pinned registers" {
    try expectAsm(
        \\fn callee(
        \\  reg($t0) size: u32,
        \\  reg($s0) address: dmem,
        \\) {}
        \\
        \\fn caller() noreturn {
        \\  const address: dmem = 0x12345678;
        \\  callee(16, address);
        \\  rsp.halt();
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

test "read-only pinned ABI bindings do not claim hardware writes" {
    const source =
        \\fn observe() {
        \\    reg($t3) counter: u32 = undefined;
        \\    reg($v13) volume: vec16 = undefined;
        \\    store(u32, 128, counter);
        \\    store(vec16, 144, volume);
        \\}
        \\fn test() noreturn {
        \\    reg($t3) counter: u32 = 8;
        \\    reg($v13) volume: vec16 = undefined;
        \\    observe();
        \\    counter += 1;
        \\    store(vec16, 160, volume);
        \\    rsp.halt();
        \\}
    ;
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try codegen.write(testing.allocator, &output.writer, functions);
}

test "bit-cast arguments move into the parameter register" {
    try @import("support.zig").expectAsmContains(
        \\fn callee(reg($a0) value: u32) { rsp.nop(); }
        \\fn entry() {
        \\  reg($t0) signed: i32 = -1;
        \\  callee(bitCast(signed));
        \\}
    , &.{ "  or $a0, $zero, $t0\n", "  jal callee\n" });
    try expectAsmError(
        \\fn callee(reg($a0) value: u32) { rsp.nop(); }
        \\fn entry() {
        \\  reg($v01) vector: vec16 = 0;
        \\  callee(bitCast(vector));
        \\}
    , error.FunctionArgumentTypeMismatch);
}
