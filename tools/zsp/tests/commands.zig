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

test "discard parameters contribute to command size without defining symbols" {
    try expectAsmError(
        \\@rspq.command(0) fn bad(reg($a0) _: u32) {
        \\  reg($t0) value: u32 = _;
        \\}
    , error.UnknownSymbol);
}
