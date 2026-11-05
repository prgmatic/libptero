//! Typed DMEM pointers and storage-label dereferences.
const support = @import("support.zig");

const expectAsm = support.expectAsm;
const expectRejectedWith = support.expectRejectedWith;

test "pointer fields load and store with the field's type and offset" {
    try expectAsm(
        \\packed struct Header { opcode: u8; size: i16; address: u32; }
        \\fn test(reg($a0) header: *Header, reg($a1) words: *u32, reg($a2) vector: *vec16) {
        \\  reg size: i16 = header.size;
        \\  header.opcode = size;
        \\  reg word: u32 = words.*;
        \\  words.* = word;
        \\  reg($v01) value: vec16 = vector.*;
        \\  value[0..4] = vector.*;
        \\  vector.* = value;
        \\  header += sizeOf(Header);
        \\  reg next: *Header = header;
        \\  next.address = word;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\
        \\test:
        \\  lh $t0, 1($a0)
        \\  sb $t0, 0($a0)
        \\  lw $t0, 0($a1)
        \\  sw $t0, 0($a1)
        \\  .word 0xc8c12000 # lqv $v01, 0($a2)
        \\  .word 0xc8c11800 # ldv $v01[0], 0($a2)
        \\  .word 0xe8c12000 # sqv $v01, 0($a2)
        \\  addi $a0, $a0, 7
        \\  or $t1, $a0, $zero
        \\  sw $t0, 3($t1)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "storage labels dereference relative to the zero register" {
    try expectAsm(
        \\packed struct Header { opcode: u8; size: u8; address: u32; }
        \\bss { header: Header; counter: u32; }
        \\fn test() {
        \\  reg count: u32 = counter.*;
        \\  reg size: u8 = header.size;
        \\  count += bitCast(size);
        \\  counter.* = count;
        \\  header.address = count;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.bss
        \\header:
        \\  .space 6
        \\.balign 4
        \\counter:
        \\  .space 4
        \\
        \\.text
        \\
        \\
        \\test:
        \\  lw $t0, %lo(counter)($zero)
        \\  lbu $t1, %lo(header + 1)($zero)
        \\  add $t0, $t0, $t1
        \\  sw $t0, %lo(counter)($zero)
        \\  sw $t0, %lo(header + 2)($zero)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "pointer misuse is diagnosed" {
    const header = "packed struct Header { opcode: u8; } packed struct Other { size: u8; } ";
    try expectRejectedWith(header ++ "fn test(reg($a0) p: *Header) { reg a: u8 = p.*; }", .expected_pointer_field);
    try expectRejectedWith(header ++ "fn test(reg($a0) p: *u32) { reg a: u32 = p.size; }", .expected_pointer_field);
    try expectRejectedWith(header ++ "fn test(reg($a0) p: *Header) { reg a: u8 = p.missing; }", .unknown_packed_struct_field);
    try expectRejectedWith(header ++ "fn test(reg($a0) p: *Missing) { }", .unknown_packed_struct);
    try expectRejectedWith(header ++ "fn test(reg($a0) p: *Header) { reg q: *Other = p; }", .pointer_type_mismatch);
    try expectRejectedWith(header ++ "fn test(reg($a0) p: *u32) { reg q: *u16 = p; }", .pointer_type_mismatch);
}
