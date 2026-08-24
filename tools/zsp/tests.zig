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
    try asm_writer.write(&first.writer, functions);
    try asm_writer.write(&second.writer, functions);
    try testing.expectEqualStrings(first.written(), second.written());
}

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
    try asm_writer.writeInterface(&output.writer, functions, null);
    try testing.expectEqualStrings(
        "// @zsp-symbol increment increment\n" ++
            "pub extern fn increment(reg($a0) value: u32) writes($a0) noreturn;\n\n",
        output.written(),
    );
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

fn expectSyntaxRejected(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try parser_mod.Parser.init(arena.allocator(), source);
    const functions = parser.parse() catch return;
    _ = functions;
    return error.ExpectedSyntaxError;
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

test "vector control registers use explicit read and write builtins" {
    try expectAsm(
        \\fn test() {
        \\  reg($t0) carry: u32 = rsp.vector.getCarryOut();
        \\  reg($t1) compare: u32 = rsp.vector.getCompareCode();
        \\  reg($t2) extension: u32 = rsp.vector.getCompareExtension();
        \\  rsp.vector.setCarryOut(carry);
        \\  rsp.vector.setCompareCode(compare);
        \\  rsp.vector.setCompareExtension(extension);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x48480000 # cfc2 $t0, $0
        \\  .word 0x48490800 # cfc2 $t1, $1
        \\  .word 0x484a1000 # cfc2 $t2, $2
        \\  .word 0x48c80000 # ctc2 $t0, $0
        \\  .word 0x48c90800 # ctc2 $t1, $1
        \\  .word 0x48ca1000 # ctc2 $t2, $2
        \\  jr $ra
        \\  nop
        \\
        \\
    );
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

test "nested scalar expressions reject side effects" {
    try expectAsmError(
        \\fn test(reg($a0) address: dmem, reg($t0) result: u32) noreturn {
        \\  result = result + load(u32, address);
        \\  rsp.halt();
        \\}
    , error.SideEffectsNotAllowedInScalarExpression);
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
        \\  addiu $t1, $zero, 1
        \\  ori $t1, $t1, 8
        \\  ori $t1, $t1, 16
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

test "vec16 and vec32 operations emit encoded RSP vector instructions" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) ptr: dmem = 0;
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
        \\  rsp.halt();
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

test "unaligned vector loads emit paired lqv and lrv instructions" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) ptr: dmem = 8;
        \\  reg($v01) narrow: vec16 = loadUnaligned(vec16, ptr);
        \\  reg($v02) wide: vec32 = loadUnaligned(vec32, ptr, 16);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 8
        \\  .word 0xc9012000 # lqv $v01, 0($t0)
        \\  .word 0xc9012801 # lrv $v01, 16($t0)
        \\  .word 0xc9022001 # lqv $v02, 16($t0)
        \\  .word 0xc9022802 # lrv $v02, 32($t0)
        \\  .word 0xc9032002 # lqv $v03, 32($t0)
        \\  .word 0xc9032803 # lrv $v03, 48($t0)
        \\  break
        \\
        \\
    );
}

test "triangle packed and partial vector loads emit exact RSP encodings" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) ptr: dmem = 8;
        \\  reg($v01) unsigned_bytes: vec16 = loadVectorBytesUnsigned(ptr, 8);
        \\  reg($v02) signed_bytes: vec16 = loadVectorBytes(ptr, 8);
        \\  reg($v03) words: vec16 = loadVectorWords(ptr, 4);
        \\  words = loadVectorWords(ptr, 8, 4);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 8
        \\  .word 0xc9013801 # luv $v01, 8($t0)
        \\  .word 0xc9023001 # lpv $v02, 8($t0)
        \\  .word 0xc9031001 # llv $v03[0], 4($t0)
        \\  .word 0xc9031402 # llv $v03[4], 8($t0)
        \\  break
        \\
        \\
    );
}

test "explicit vector memory builtins emit each transfer width" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) ptr: dmem = 8;
        \\  reg($v01) value: vec16 = undefined;
        \\  rsp.vector.load16(value, 2, ptr, 4);
        \\  rsp.vector.store16(value, 2, ptr, 4);
        \\  rsp.vector.load32(value, 2, ptr, 4);
        \\  rsp.vector.store32(value, 2, ptr, 4);
        \\  rsp.vector.load64(value, 2, ptr, 8);
        \\  rsp.vector.store64(value, 2, ptr, 8);
        \\  rsp.vector.load128(value, ptr, 16);
        \\  rsp.vector.store128(value, ptr, 16);
        \\  rsp.vector.loadPackedSigned(value, ptr, 8);
        \\  rsp.vector.loadPackedUnsigned(value, ptr, 8);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 8
        \\  .word 0xc9010a02 # lsv $v01[2], 4($t0)
        \\  .word 0xe9010a02 # ssv $v01[2], 4($t0)
        \\  .word 0xc9011201 # llv $v01[2], 4($t0)
        \\  .word 0xe9011201 # slv $v01[2], 4($t0)
        \\  .word 0xc9011a01 # ldv $v01[2], 8($t0)
        \\  .word 0xe9011a01 # sdv $v01[2], 8($t0)
        \\  .word 0xc9012001 # lqv $v01, 16($t0)
        \\  .word 0xe9012001 # sqv $v01, 16($t0)
        \\  .word 0xc9013001 # lpv $v01, 8($t0)
        \\  .word 0xc9013801 # luv $v01, 8($t0)
        \\  break
        \\
        \\
    );
}

test "triangle vector shifts use the resident shift constant vector" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) source: vec16 = undefined;
        \\  reg($v02) left: vec16 = undefined;
        \\  reg($v03) arithmetic: vec16 = undefined;
        \\  reg($v04) logical: vec16 = undefined;
        \\  left = source << 14;
        \\  arithmetic = source >> 2;
        \\  logical = source >>> 7;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4b3f0886 # vsll8 $v02, $v01, $v31
        \\  .word 0x4b3f08c5 # vsra $v03, $v01, $v31
        \\  .word 0x4bdf0904 # vsrl $v04, $v01, $v31
        \\  break
        \\
        \\
    );
}

test "explicit vector shift names preserve vec32 views" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v06) source: vec16 = undefined;
        \\  reg($v25) shifted: vec32 = undefined;
        \\  shifted.sfract = vectorShiftLeft8(source, 14);
        \\  shifted.sint = vectorShiftRightArithmetic(source, 2);
        \\  source = vectorShiftRightLogical(source, 7);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4b3f3686 # vsll8 $v26, $v06, $v31
        \\  .word 0x4b3f3645 # vsra $v25, $v06, $v31
        \\  .word 0x4bdf3184 # vsrl $v06, $v06, $v31
        \\  break
        \\
        \\
    );
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

test "explicit vector operation names preserve RSP encodings" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) left: vec16 = undefined;
        \\  reg($v02) right: vec16 = undefined;
        \\  reg($v03) result: vec16 = undefined;
        \\  result = vectorAdd(left, right);
        \\  result = vectorSubtract(left, right);
        \\  result = vectorAddCarry(left, right);
        \\  result = vectorSubtractCarry(left, right);
        \\  result = vectorCompareLessThan(left, right);
        \\  result = vectorCompareEqual(left, right);
        \\  result = vectorCompareNotEqual(left, right);
        \\  result = vectorCompareGreaterOrEqual(left, right);
        \\  result = vectorSelectByCompareCode(left, right);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a0208d0 # vadd $v03, $v01, $v02
        \\  .word 0x4a0208d1 # vsub $v03, $v01, $v02
        \\  .word 0x4a0208d4 # vaddc $v03, $v01, $v02
        \\  .word 0x4a0208d5 # vsubc $v03, $v01, $v02
        \\  .word 0x4a0208e0 # vlt $v03, $v01, $v02
        \\  .word 0x4a0208e1 # veq $v03, $v01, $v02
        \\  .word 0x4a0208e2 # vne $v03, $v01, $v02
        \\  .word 0x4a0208e3 # vge $v03, $v01, $v02
        \\  .word 0x4a0208e7 # vmrg $v03, $v01, $v02
        \\  break
        \\
        \\
    );
}

test "explicit accumulator and reciprocal names preserve RSP encodings" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v18) high: vec16 = readVectorAccumulatorHigh();
        \\  reg($v19) middle: vec16 = readVectorAccumulatorMiddle();
        \\  reg($v20) reciprocal_high: vec16 = undefined;
        \\  reg($v21) reciprocal_low: vec16 = undefined;
        \\  reg($v24) source: vec16 = undefined;
        \\  reciprocal_high[7] = vectorReciprocalHigh(high[0]);
        \\  reciprocal_low[7] = vectorReciprocalLow(middle[0]);
        \\  reciprocal_low[0] = vectorReciprocal(source[1]);
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4b00049d # vsar $v18, $v00, $v00
        \\  .word 0x4b2004dd # vsar $v19, $v00, $v00
        \\  .word 0x4b127d32 # vrcph $v20[7], $v18[0]
        \\  .word 0x4b137d71 # vrcpl $v21[7], $v19[0]
        \\  .word 0x4b384570 # vrcp $v21[0], $v24[1]
        \\  break
        \\
        \\
    );
}

test "command tail jumps omit unreachable command return scaffolding" {
    try expectAsm(
        \\@rspq.command(1) fn commandTail(reg($a0) value: u32) {
        \\  jump target(value);
        \\}
        \\fn target(reg($a0) value: u32) noreturn {
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl commandTail
        \\commandTail:
        \\  j target
        \\  nop
        \\
        \\target:
        \\  break
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word commandTail
        \\  .byte 1
        \\  .byte 4
        \\  .short 0
        \\
        \\
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

test "vector lane moves and reciprocal operations emit exact RSP encodings" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) destination: vec16 = 0;
        \\  reg($v02) source: vec16 = 0;
        \\  reg($v03) reciprocal: vec16 = 0;
        \\  reg($v04) input: vec16 = 0;
        \\  destination[3] = source[6];
        \\  destination[0] = vectorMove(source[0]);
        \\  reciprocal[0] = vrcph(input[5]);
        \\  reciprocal[1] = vrcpl(input[4]);
        \\  reciprocal[2] = vrcp(input[3]);
        \\  rsp.halt();
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
        \\  .word 0x4bc21873 # vmov $v01[3], $v02[6]
        \\  .word 0x4b024073 # vmov $v01[0], $v02[0]
        \\  .word 0x4ba400f2 # vrcph $v03[0], $v04[5]
        \\  .word 0x4b8408f1 # vrcpl $v03[1], $v04[4]
        \\  .word 0x4b6410f0 # vrcp $v03[2], $v04[3]
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
        \\  reg($t0) ptr: dmem = 0;
        \\  reg($v01) a: vec16 = load(vec16, ptr);
        \\  reg($v02) b: vec16 = load(vec16, ptr, 16);
        \\  accumulate(a, b);
        \\  rsp.halt();
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
    try expectAsm(
        \\fn test() {
        \\  reg($v28) value: vec32 = 0;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a1ce72c # vxor $v28, $v28, $v28
        \\  .word 0x4a1def6c # vxor $v29, $v29, $v29
        \\  jr $ra
        \\  nop
        \\
        \\
    );
    try expectAsmError(
        \\fn test() {
        \\  reg($v01) a: vec32 = 0;
        \\  reg($v02) b: vec16 = 0;
        \\  a = 0;
        \\}
    , error.RegisterAlreadyInUse);
}

test "automatic vector allocation reuses dead registers and keeps vec32 pairs contiguous" {
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
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
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
    for (1..29) |index| {
        try source_writer.writer.print("  value_0 += value_{d};\n", .{index});
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
        \\  reg ptr: dmem = 0;
        \\  reg($v01) value: vec16 = load(vec16, ptr, 1);
        \\}
    , error.VectorMemoryOffsetUnaligned);
    try expectAsmError(
        \\fn test() {
        \\  reg ptr: dmem = 0;
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

test "signed vector lane extraction preserves MFC2 sign extension" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) source: vec16 = 0;
        \\  reg($t0) signed: i32 = undefined;
        \\  signed = source[0];
        \\  signed = signedLessThan(signed, 0);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x48080800 # mfc2 $t0, $v01[0]
        \\  slt $t0, $t0, $zero
        \\
        \\
    );
}

test "vec32 views compose with lane and swizzle selection" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) wide: vec32 = 0;
        \\  reg($t0) scalar: i32 = undefined;
        \\  reg($t1) base: dmem = 0;
        \\  scalar = wide.sint[2];
        \\  wide.sfract[3] = vrcp(wide.sint[2]);
        \\  wide.sfract = wide.sfract.XXXXXXXX;
        \\  store(vec16, base, wide.sfract[3]);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  addiu $t1, $zero, 0
        \\  .word 0x48080a00 # mfc2 $t0, $v01[2]
        \\  .word 0x4b4118b0 # vrcp $v02[3], $v01[2]
        \\  .word 0x4b8200aa # vor $v02, $v00, $v02
        \\  .word 0xe9220b00 # ssv $v02[3], 0($t1)
        \\
        \\
    );
}

test "reciprocal square root lane operations emit exact RSP encodings" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) high: vec16 = undefined;
        \\  reg($v02) low: vec16 = undefined;
        \\  high[3] = vectorReciprocalSquareRootHigh(high[0]);
        \\  low[3] = vectorReciprocalSquareRootLow(low[0]);
        \\  high[3] = vectorReciprocalSquareRoot(high[0]);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4b015876 # vrsqh $v01[3], $v01[0]
        \\  .word 0x4b0258b5 # vrsql $v02[3], $v02[0]
        \\  .word 0x4b015874 # vrsq $v01[3], $v01[0]
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

test "explicit saturated vector add and subtract emit VADD and VSUB" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($v01) lhs: vec16 = 0;
        \\  reg($v02) rhs: vec16 = 0;
        \\  reg($v03) result: vec16 = vadd(lhs, rhs.xxxxxxxx);
        \\  result = vsub(lhs, rhs);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  .word 0x4b0208d0 # vadd $v03, $v01, $v02
        \\  .word 0x4a0208d1 # vsub $v03, $v01, $v02
        \\
        \\
    );
}

test "half-vector stores emit SDV with exact lane and offset fields" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t4) ptr: dmem = undefined;
        \\  reg($v04) values: vec16 = undefined;
        \\  store(vec64, ptr, values, 24);
        \\  store(vec64, ptr, values[4], 56);
        \\  store(vec32lane, ptr, values[6], 12);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0xe9841803 # sdv $v04[0], 24($t4)
        \\  .word 0xe9841c07 # sdv $v04[4], 56($t4)
        \\  .word 0xe9841603 # slv $v04[6], 12($t4)
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
        \\  reg($t0) ptr: dmem = 0;
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

test "parameters outside the default scalar convention require explicit registers" {
    try expectParseError(
        \\fn invalid(a: u32, b: u32, c: u32, d: u32, value: u32) {}
    , .expected_fixed_register_parameter, 1, 12);
    try expectParseError(
        \\fn invalid(value: vec16) {}
    , .expected_fixed_register_parameter, 1, 12);
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

test "dmem address values materialize a data label with an offset" {
    try expectAsm(
        \\bss { cached: [2]u32; }
        \\fn send() noreturn {
        \\  reg($s3) end: dmem = dmem.addressOf(cached, 8);
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

test "automatic values live across calls avoid inferred clobbers" {
    try expectAsm(
        \\fn consume(reg($t0) input: u32) {
        \\  input += 1;
        \\}
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume(3);
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\consume:
        \\  addi $t0, $t0, 1
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  addiu $t1, $zero, 7
        \\  addiu $t0, $zero, 3
        \\  jal consume
        \\  nop
        \\  addi $t1, $t1, 1
        \\  break
        \\
        \\
    );
}

test "literal argument setup avoids unrelated automatic values live across calls" {
    try expectAsm(
        \\fn consume(reg($t0) input: u32) {
        \\}
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume(3);
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
        \\  addiu $t1, $zero, 7
        \\  addiu $t0, $zero, 3
        \\  jal consume
        \\  nop
        \\  addi $t1, $t1, 1
        \\  break
        \\
        \\
    );
}

test "constant argument setup avoids unrelated automatic values live across calls" {
    try expectAsm(
        \\fn consume(reg($t0) input: u32) {
        \\}
        \\fn test() noreturn {
        \\  const input: u32 = 3;
        \\  reg value: u32 = 7;
        \\  consume(input);
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
        \\  addiu $t1, $zero, 7
        \\  addiu $t0, $zero, 3
        \\  jal consume
        \\  nop
        \\  addi $t1, $t1, 1
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

test "call clobber inference includes callee automatic registers" {
    try expectAsm(
        \\fn consume() {
        \\  reg scratch: u32 = 1;
        \\  scratch += 1;
        \\}
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume();
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\consume:
        \\  addiu $t0, $zero, 1
        \\  addi $t0, $t0, 1
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  addiu $t1, $zero, 7
        \\  jal consume
        \\  nop
        \\  addi $t1, $t1, 1
        \\  break
        \\
        \\
    );
}

test "automatic callees preserve pinned caller locals live across calls" {
    try expectAsm(
        \\fn consume() {
        \\  reg scratch: u32 = 1;
        \\  scratch += 1;
        \\}
        \\fn test() noreturn {
        \\  reg($t0) preserved: u32 = 7;
        \\  consume();
        \\  preserved += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\consume:
        \\  addiu $t1, $zero, 1
        \\  addi $t1, $t1, 1
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

test "fixed callee clobbers reject conflicting pinned caller locals" {
    try expectAsmError(
        \\fn consume() {
        \\  reg($t0) scratch: u32 = 1;
        \\}
        \\fn test() noreturn {
        \\  reg($t0) preserved: u32 = 7;
        \\  consume();
        \\  preserved += 1;
        \\  rsp.halt();
        \\}
    , error.PinnedRegisterClobberedByCall);
}

test "transitive fixed clobbers reject conflicting pinned caller locals" {
    try expectAsmError(
        \\fn inner() {
        \\  reg($t0) scratch: u32 = 1;
        \\}
        \\fn middle() {
        \\  inner();
        \\}
        \\fn test() noreturn {
        \\  reg($t0) preserved: u32 = 7;
        \\  middle();
        \\  preserved += 1;
        \\  rsp.halt();
        \\}
    , error.PinnedRegisterClobberedByCall);
}

test "automatic values overwritten after calls may use callee clobbers" {
    try expectAsm(
        \\fn consume(reg($t0) input: u32) {
        \\  input += 1;
        \\}
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume(3);
        \\  value = 9;
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\consume:
        \\  addi $t0, $t0, 1
        \\  jr $ra
        \\  nop
        \\
        \\test:
        \\  addiu $t0, $zero, 7
        \\  addiu $t0, $zero, 3
        \\  jal consume
        \\  nop
        \\  addiu $t0, $zero, 9
        \\  addi $t0, $t0, 1
        \\  break
        \\
        \\
    );
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

test "uninitialized registers require assignment before reads" {
    try expectAsmError(
        \\fn test() noreturn {
        \\  reg value: u32;
        \\  value += 1;
        \\  rsp.halt();
        \\}
    , error.RegisterReadBeforeAssignment);

    try expectAsmError(
        \\fn test(reg($a0) flag: u32) noreturn {
        \\  reg value: u32;
        \\  if(flag != 0) {
        \\    value = 1;
        \\  }
        \\  value += 1;
        \\  rsp.halt();
        \\}
    , error.RegisterReadBeforeAssignment);
}

test "definite assignment accepts all-path and slot definitions" {
    try expectAsm(
        \\fn test(reg($a0) flag: u32) noreturn {
        \\  reg value: u32;
        \\  if(flag != 0) slot {
        \\    value = 3;
        \\  } {
        \\    value = 1;
        \\  } else {
        \\    value = 2;
        \\  }
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  beq $a0, $zero, LABEL_test_ifelse_0
        \\  addiu $t0, $zero, 3
        \\  addiu $t0, $zero, 1
        \\  j LABEL_test_ifend_0
        \\  nop
        \\LABEL_test_ifelse_0:
        \\  addiu $t0, $zero, 2
        \\LABEL_test_ifend_0:
        \\  addi $t0, $t0, 1
        \\  break
        \\
        \\
    );
}

test "explicit undefined preserves unchecked register reads" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg value: u32 = undefined;
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addi $t0, $t0, 1
        \\  break
        \\
        \\
    );
}

test "extern clobber contracts constrain automatic values live across calls" {
    try expectAsm(
        \\extern fn consume() writes($t0);
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume();
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t1, $zero, 7
        \\  jal consume
        \\  nop
        \\  addi $t1, $t1, 1
        \\  break
        \\
        \\
    );
}

test "extern clobber contracts parse scalar and vector registers" {
    var parser = try parser_mod.Parser.init(testing.allocator,
        \\extern fn consume() writes($t0, $s4, $v03, $v20);
    );
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    try testing.expectEqual(@as(usize, 1), functions.len);
    try testing.expect(functions[0].has_clobber_contract);
    try testing.expectEqualSlices(ast.Register, &.{ .t0, .s4 }, functions[0].clobber_regs);
    try testing.expectEqualSlices(ast.VectorRegister, &.{ .v03, .v20 }, functions[0].clobber_vector_regs);
}

test "legacy clobbers function modifier is rejected" {
    try expectParseError(
        "extern fn consume() clobbers($t0);",
        .unsupported_function_modifier,
        1,
        21,
    );
}

test "extern vector clobbers constrain automatic values live across calls" {
    try expectAsm(
        \\extern fn consume() writes($v01);
        \\fn test() noreturn {
        \\  reg value: vec16 = 0;
        \\  consume();
        \\  reg addend: vec16 = 0;
        \\  value += addend;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a0210ac # vxor $v02, $v02, $v02
        \\  jal consume
        \\  nop
        \\  .word 0x4a01086c # vxor $v01, $v01, $v01
        \\  .word 0x4a011094 # vaddc $v02, $v02, $v01
        \\  break
        \\
        \\
    );
}

test "external clobbered parameter is an explicit register output" {
    try expectAsm(
        \\extern fn advance(reg($s4) value: dmem) writes($s4, $ra);
        \\fn test() noreturn {
        \\  reg($s4) address: dmem = 256;
        \\  advance(address);
        \\  store(u32, address, 0);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $s4, $zero, 256
        \\  jal advance
        \\  nop
        \\  sw $zero, 0($s4)
        \\
        \\
    );
}

test "extern calls without contracts conservatively clobber automatic registers" {
    try expectAsmError(
        \\extern fn consume();
        \\fn test() noreturn {
        \\  reg value: u32 = 7;
        \\  consume();
        \\  value += 1;
        \\  rsp.halt();
        \\}
    , error.OutOfFreeRegisters);
}

test "extern clobber contracts reject live pinned register conflicts" {
    try expectAsmError(
        \\extern fn consume() writes($t0);
        \\fn test() noreturn {
        \\  reg($t0) value: u32 = 7;
        \\  consume();
        \\  value += 1;
        \\  rsp.halt();
        \\}
    , error.PinnedRegisterClobberedByExternalCall);
}

test "call slot definitions survive callee clobbers" {
    try expectAsm(
        \\fn consume() writes($t0) {
        \\}
        \\fn test() noreturn {
        \\  reg value: u32 = undefined;
        \\  consume() slot {
        \\    value = 7;
        \\  }
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
        \\  jal consume
        \\  addiu $t1, $zero, 7
        \\  addi $t1, $t1, 1
        \\  break
        \\
        \\
    );
}

test "automatic values declared in call slots survive callee clobbers" {
    try expectAsm(
        \\fn consume() writes($t0) {
        \\}
        \\fn test() noreturn {
        \\  consume() slot {
        \\    reg value: u32 = 7;
        \\  }
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
        \\  jal consume
        \\  addiu $t1, $zero, 7
        \\  addi $t1, $t1, 1
        \\  break
        \\
        \\
    );
}

test "control-flow liveness preserves values when a branch bypasses a write" {
    try expectAsm(
        \\extern fn consume() writes($t0);
        \\fn test(reg($a0) flag: u32) noreturn {
        \\  reg value: u32 = 7;
        \\  consume();
        \\  if(flag == 0) goto use_value;
        \\  value = 9;
        \\use_value:
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t1, $zero, 7
        \\  jal consume
        \\  nop
        \\  beq $a0, $zero, LABEL_test_use_value_0
        \\  nop
        \\  addiu $t1, $zero, 9
        \\LABEL_test_use_value_0:
        \\  addi $t1, $t1, 1
        \\  break
        \\
        \\
    );
}

test "control-flow liveness ignores writes on mutually exclusive paths" {
    try expectAsm(
        \\extern fn consume() writes($t0);
        \\inline fn define(reg($t0) value: u32) {
        \\  value = 5;
        \\}
        \\fn test(reg($a0) flag: u32) noreturn {
        \\  reg value: u32 = undefined;
        \\  if(flag == 0) goto other_path;
        \\  consume();
        \\  value = 9;
        \\  goto done;
        \\other_path:
        \\  define(value);
        \\done:
        \\  value += 1;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  beq $a0, $zero, LABEL_test_other_path_0
        \\  nop
        \\  jal consume
        \\  nop
        \\  addiu $t0, $zero, 9
        \\  j LABEL_test_done_0
        \\  nop
        \\LABEL_test_other_path_0:
        \\  addiu $t0, $zero, 5
        \\LABEL_test_done_0:
        \\  addi $t0, $t0, 1
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

test "inline calls do not force command return-address preservation" {
    try expectAsm(
        \\inline fn primitive(reg($a0) value: u32) {
        \\  asm("mtc0 $a0, $9");
        \\}
        \\@rspq.command(1) fn commandHandler(reg($a0) value: u32) {
        \\  primitive(value);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl commandHandler
        \\commandHandler:
        \\  mtc0 $a0, $9
        \\  jr $ra
        \\  nop
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word commandHandler
        \\  .byte 1
        \\  .byte 4
        \\  .short 0
        \\
        \\
    );
}

test "automatic locals in inline functions honor nested call registers" {
    try expectAsm(
        \\fn consume(reg($t2) value: u32) {
        \\}
        \\inline fn helper(reg($a0) value: u32) {
        \\  reg scratch: u32 = 3;
        \\  consume(scratch);
        \\  value += 1;
        \\}
        \\fn test(reg($a0) value: u32) noreturn {
        \\  helper(value);
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
        \\  addiu $t2, $zero, 3
        \\  jal consume
        \\  nop
        \\  addi $a0, $a0, 1
        \\  break
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

test "function calls reject scalar argument move cycles" {
    try expectAsmError(
        \\fn callee(reg($t0) first: u32, reg($t1) second: u32) {}
        \\fn caller() {
        \\  reg($t0) second: u32 = 1;
        \\  reg($t1) first: u32 = 2;
        \\  callee(first, second);
        \\}
    , error.FunctionArgumentMoveCycle);
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

test "module imports public functions and qualified calls parse" {
    var parser = try parser_mod.Parser.init(testing.allocator,
        \\const dma = import("dma.zsp");
        \\pub fn helper() {}
        \\export fn _start() noreturn {
        \\  dma.exec();
        \\  jump dma.exec();
        \\  tail dma.exec();
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
    const direct_goto = functions[1].statements[1].builtin.direct_goto;
    try testing.expectEqualStrings("dma", direct_goto.target.module.?);
    try testing.expectEqualStrings("exec", direct_goto.target.name);
    const tail = functions[1].statements[2].builtin.tail;
    try testing.expectEqualStrings("dma", tail.target.module.?);
    try testing.expectEqualStrings("exec", tail.target.name);
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

test "syntax rejects unsupported function modifier" {
    try expectParseError(
        \\fn test() interrupt {
        \\}
    , .unsupported_function_modifier, 1, 11);
}

test "RSPQ metadata requires its namespace" {
    try expectSyntaxRejected(
        \\command(0) fn legacy() {}
    );
    try expectSyntaxRejected(
        \\const commands = commandTable();
    );
    try expectSyntaxRejected(
        \\@rspq.command(0) fn legacy() commandSize(8) {}
    );
}

test "command functions emit indexed handler metadata" {
    try expectAsm(
        \\@rspq.command(0) fn first(reg($a0) header: u32, reg($a1) _: u32) {
        \\}
        \\@rspq.command(1) fn second(reg($a0) header: u32) {
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl first
        \\first:
        \\  jr $ra
        \\  nop
        \\
        \\.globl second
        \\second:
        \\  jr $ra
        \\  nop
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word first
        \\  .byte 0
        \\  .byte 8
        \\  .short 0
        \\  .word second
        \\  .byte 1
        \\  .byte 4
        \\  .short 0
        \\
        \\
    );
}

test "commandSize overrides inferred command metadata size" {
    try expectAsm(
        \\@rspq.command(8) fn triangle(reg($a0) header: u32) @rspq.commandSize(176) noreturn {
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl triangle
        \\triangle:
        \\  break
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word triangle
        \\  .byte 8
        \\  .byte 176
        \\  .short 0
        \\
        \\
    );
}

test "commandSize maps individual sizes onto shared command slots" {
    try expectAsm(
        \\@rspq.command(8, 9) fn triangles(reg($a0) header: u32) @rspq.commandSize(32, 48) noreturn {
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl triangles
        \\triangles:
        \\  break
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word triangles
        \\  .byte 8
        \\  .byte 32
        \\  .short 0
        \\  .word triangles
        \\  .byte 9
        \\  .byte 48
        \\  .short 0
        \\
        \\
    );
}

test "command discard parameters describe trailing command words" {
    try expectAsm(
        \\@rspq.command(31) fn triangleData(
        \\  reg($a0) offset: u32,
        \\  reg($a1) xy: u32,
        \\  reg($a2) z: u32,
        \\  reg($a3) rgba: u32,
        \\  reg($t0) _: u32,
        \\  reg($t1) _: u32,
        \\  reg($t2) _: u32,
        \\) {}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl triangleData
        \\triangleData:
        \\  jr $ra
        \\  nop
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word triangleData
        \\  .byte 31
        \\  .byte 28
        \\  .short 0
        \\
        \\
    );
}

test "external resident functions can provide command table aliases" {
    try expectAsm(
        \\@rspq.command(21, 23) extern fn resident_command_loop() @rspq.commandSize(8) noreturn;
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word resident_command_loop
        \\  .byte 21
        \\  .byte 8
        \\  .short 0
        \\  .word resident_command_loop
        \\  .byte 23
        \\  .byte 8
        \\  .short 0
        \\
        \\
    );
}

test "command trailing parameters must be discarded" {
    try expectAsmError(
        \\@rspq.command(0) fn bad(
        \\  reg($a0) a: u32,
        \\  reg($a1) b: u32,
        \\  reg($a2) c: u32,
        \\  reg($a3) d: u32,
        \\  reg($t0) trailing: u32,
        \\) {}
    , error.InvalidCommandParameters);
}

test "command table materializes handlers, sizes, and empty slots" {
    try expectAsm(
        \\const commands = @rspq.commandTable();
        \\@rspq.command(0) fn wait() {
        \\}
        \\@rspq.command(2) fn jump(reg($a0) target: u32) {
        \\}
        \\export fn _start() noreturn {
        \\  reg($t0) table: u32 = commands;
        \\  rsp.halt();
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.data
        \\.balign 2
        \\commands:
        \\  .short 0
        \\  .short 0
        \\  .short 0
        \\.section .zsp_command_table,"",@progbits
        \\  .word commands
        \\  .word 3
        \\.data
        \\
        \\.text
        \\
        \\
        \\.globl wait
        \\wait:
        \\  jr $ra
        \\  nop
        \\
        \\.globl jump
        \\jump:
        \\  jr $ra
        \\  nop
        \\
        \\.globl _start
        \\_start:
        \\  addiu $t0, $zero, %lo(commands)
        \\  break
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word wait
        \\  .byte 0
        \\  .byte 0
        \\  .short 0
        \\  .word jump
        \\  .byte 2
        \\  .byte 4
        \\  .short 0
        \\
        \\
    );
}

test "command functions require unique indices and ABI parameters" {
    try expectAsmError(
        \\@rspq.command(0) fn first(reg($a0) header: u32) {}
        \\@rspq.command(0) fn second(reg($a0) header: u32) {}
    , error.DuplicateCommandIndex);
    try expectAsmError(
        \\@rspq.command(0) fn bad(reg($a1) header: u32) {}
    , error.InvalidCommandParameters);
}

test "command functions support indices spanning overlay IDs" {
    try expectAsm(
        \\@rspq.command(16) fn extended(reg($a0) header: u32) {
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl extended
        \\extended:
        \\  jr $ra
        \\  nop
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word extended
        \\  .byte 16
        \\  .byte 4
        \\  .short 0
        \\
        \\
    );
}

test "one command handler can occupy multiple command slots" {
    try expectAsm(
        \\@rspq.command(0, 15, 63) fn shared(reg($a0) header: u32) {}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\.globl shared
        \\shared:
        \\  jr $ra
        \\  nop
        \\
        \\.section .zsp_commands,"",@progbits
        \\  .word shared
        \\  .byte 0
        \\  .byte 4
        \\  .short 0
        \\  .word shared
        \\  .byte 15
        \\  .byte 4
        \\  .short 0
        \\  .word shared
        \\  .byte 63
        \\  .byte 4
        \\  .short 0
        \\
        \\
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

test "discard parameters contribute to command size without defining symbols" {
    try expectAsmError(
        \\@rspq.command(0) fn bad(reg($a0) _: u32) {
        \\  reg($t0) value: u32 = _;
        \\}
    , error.UnknownSymbol);
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
