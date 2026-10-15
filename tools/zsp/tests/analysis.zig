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

test "analysis capacity exhaustion cannot bypass definite assignment checks" {
    var source = std.Io.Writer.Allocating.init(testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("fn large() { reg value: u32;\n");
    for (0..2048) |_| try source.writer.writeAll("rsp.nop();\n");
    try source.writer.writeAll("rsp.cp0.setSpStatus(value); }");
    try expectAsmError(source.written(), error.AnalysisCapacityExceeded);
}

test "lifetime event exhaustion reports a capacity error" {
    var source = std.Io.Writer.Allocating.init(testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("fn large() { reg value: u32 = 1;\n");
    for (0..1100) |_| try source.writer.writeAll("value += 1;\n");
    try source.writer.writeAll("rsp.cp0.setSpStatus(value); }");
    try expectAsmError(source.written(), error.AnalysisCapacityExceeded);
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

test "assigning an initially undefined ABI binding is a hardware write" {
    try expectAsmError(
        \\fn overwrite() {
        \\    reg($t3) counter: u32 = undefined;
        \\    counter = 0;
        \\}
        \\fn test() noreturn {
        \\    reg($t3) counter: u32 = 8;
        \\    overwrite();
        \\    counter += 1;
        \\    rsp.halt();
        \\}
    , error.PinnedRegisterClobberedByCall);
}

test "backend errors retain the nested statement source location" {
    var parser = try parser_mod.Parser.init(testing.allocator, "fn broken() {\n  reg value: u32 = 1;\n  if (value == 1) {\n    value = missing;\n  }\n}");
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    functions[0].source_path = "broken.zsp";
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    var diagnostic: asm_writer.Diagnostic = .{};
    try testing.expectError(error.UnknownSymbol, asm_writer.writeWithDiagnostic(&output.writer, functions, &diagnostic));
    try testing.expectEqualStrings("broken.zsp", diagnostic.source_path.?);
    try testing.expectEqual(@as(usize, 4), diagnostic.location.?.line);
    try testing.expectEqual(@as(usize, 5), diagnostic.location.?.column);
    try testing.expectEqualStrings("missing", diagnostic.symbol_name.?);
}
