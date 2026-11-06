//! Compile-time expansion: `inline for`, register arrays, constant
//! expressions, lane-range transfers, and the removed parity spellings.
const support = @import("support.zig");

const expectAsm = support.expectAsm;
const expectRejectedWith = support.expectRejectedWith;
const expectSyntaxRejected = support.expectSyntaxRejected;

test "inline for unrolls with a constant index and renames body locals" {
    try expectAsm(
        \\fn test(reg($t0) table: dmem) {
        \\  inline for (0..3) |index| {
        \\    reg value: u32 = load(u32, table, index * 4);
        \\    value += index;
        \\    store(u32, table, value, index * 4 + 16);
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  lw $t1, 0($t0)
        \\  addi $t1, $t1, 0
        \\  sw $t1, 16($t0)
        \\  lw $t2, 4($t0)
        \\  addi $t2, $t2, 1
        \\  sw $t2, 20($t0)
        \\  lw $t3, 8($t0)
        \\  addi $t3, $t3, 2
        \\  sw $t3, 24($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "nested inline for keeps names unique and an empty range emits nothing" {
    try expectAsm(
        \\fn test(reg($t0) table: dmem) {
        \\  inline for (0..2) |outer| {
        \\    inline for (0..2) |inner| {
        \\      reg value: u32 = outer * 2 + inner;
        \\      store(u32, table, value, (outer * 2 + inner) * 4);
        \\    }
        \\  }
        \\  inline for (2..2) |unused| {
        \\    reg value: u32 = unused;
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t1, $zero, 0
        \\  sw $t1, 0($t0)
        \\  addiu $t2, $zero, 1
        \\  sw $t2, 4($t0)
        \\  addiu $t3, $zero, 2
        \\  sw $t3, 8($t0)
        \\  addiu $t1, $zero, 3
        \\  sw $t1, 12($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "register arrays allocate one register per element" {
    try expectAsm(
        \\fn test(reg($t0) table: dmem) {
        \\  reg sums: [2]u32 = 0;
        \\  reg($v04) rows: [2]vec32 = undefined;
        \\  inline for (0..2) |index| {
        \\    sums[index] += 1;
        \\    store(u32, table, sums[index], index * 4);
        \\    rows[index] = load(vec32, table, index * 32);
        \\    store(vec32, table, rows[index], index * 32 + 64);
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t1, $zero, 0
        \\  addiu $t2, $zero, 0
        \\  addi $t1, $t1, 1
        \\  sw $t1, 0($t0)
        \\  .word 0xc9042000 # lqv $v04, 0($t0)
        \\  .word 0xc9052001 # lqv $v05, 16($t0)
        \\  .word 0xe9042004 # sqv $v04, 64($t0)
        \\  .word 0xe9052005 # sqv $v05, 80($t0)
        \\  addi $t2, $t2, 1
        \\  sw $t2, 4($t0)
        \\  .word 0xc9062002 # lqv $v06, 32($t0)
        \\  .word 0xc9072003 # lqv $v07, 48($t0)
        \\  .word 0xe9062006 # sqv $v06, 96($t0)
        \\  .word 0xe9072007 # sqv $v07, 112($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "constant expressions size memory offsets" {
    try expectAsm(
        \\packed struct Header { opcode: u8; size: u16; address: u32; }
        \\enum Mode: u32 { slow = 2; fast = 4; }
        \\fn test(reg($t0) table: dmem) {
        \\  reg value: u32 = load(u32, table, sizeOf(Header) * 2 + offsetOf(Header, address));
        \\  store(u32, table, value, -(Mode.fast << 2));
        \\  store(u32, table, value, (sizeOf(vec32) - sizeOf(u16)) / 2);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\
        \\test:
        \\  lw $t1, 17($t0)
        \\  sw $t1, -16($t0)
        \\  sw $t1, 15($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "lane ranges select the 4, 8, and 16 byte transfers" {
    try expectAsm(
        \\fn test(reg($t0) table: dmem) {
        \\  reg($v01) narrow: vec16 = undefined;
        \\  reg($v02) wide: vec32 = undefined;
        \\  narrow[2..4] = load(vec16, table, 4);
        \\  narrow[4..8] = load(vec16, table, 8);
        \\  narrow[0..8] = load(vec16, table, 16);
        \\  wide[0..4] = load(vec32, table, 32);
        \\  wide.sfract[4..8] = load(vec16, table, 48);
        \\  store(vec16, table, narrow[6..8], 4);
        \\  store(vec32, table, wide[4..8], 64);
        \\  store(vec16, table, wide.sint[0..8], 80);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0xc9011201 # llv $v01[2], 4($t0)
        \\  .word 0xc9011c01 # ldv $v01[4], 8($t0)
        \\  .word 0xc9012001 # lqv $v01, 16($t0)
        \\  .word 0xc9021804 # ldv $v02[0], 32($t0)
        \\  .word 0xc9031805 # ldv $v03[0], 40($t0)
        \\  .word 0xc9031c06 # ldv $v03[4], 48($t0)
        \\  .word 0xe9011601 # slv $v01[6], 4($t0)
        \\  .word 0xe9021c08 # sdv $v02[4], 64($t0)
        \\  .word 0xe9031c09 # sdv $v03[4], 72($t0)
        \\  .word 0xe9022005 # sqv $v02, 80($t0)
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "malformed compile-time expansions are rejected" {
    try expectRejectedWith("fn test() { inline for (3..1) |i| { } }", .invalid_inline_range);
    try expectRejectedWith("fn test() { inline for (0..300) |i| { } }", .invalid_inline_range);
    try expectRejectedWith("fn test() { inline while (0..3) |i| { } }", .unexpected_token);
    try expectRejectedWith("fn test() { inline for (0..1) |i| { }", .unexpected_token);
    try expectRejectedWith("fn test() { reg a: [2]u32 = 0; a[2] = 1; }", .array_index_out_of_range);
    try expectRejectedWith("fn test(i: u32) { reg a: [2]u32 = 0; a[i] = 1; }", .expected_array_index);
    try expectRejectedWith("fn test() { reg a: [0]u32 = 0; }", .invalid_array_length);
    try expectRejectedWith("fn test() { reg($t0) a: [2]u32 = 0; }", .expected_vector_register);
    try expectRejectedWith("fn test() { reg($v31) a: [2]vec16 = undefined; }", .expected_vector_register);
    try expectRejectedWith("fn test(reg($t0) p: dmem) { reg v: u32 = load(u32, p, 1 / 0); }", .invalid_constant_expression);
    try expectRejectedWith("fn test(reg($t0) p: dmem) { reg v: u32 = load(u32, p, 1 << 64); }", .invalid_constant_expression);
    try expectRejectedWith("fn test(reg($t0) p: dmem) { reg v: u32 = load(u32, p, Missing.member); }", .expected_literal_offset);
    try expectRejectedWith("fn test(reg($t0) p: dmem) { reg v: u32 = load(u32, p, sizeOf(Missing)); }", .unknown_packed_struct);
}

test "lane ranges must name a supported transfer" {
    const vector = "fn test(reg($t0) p: dmem) { reg($v01) v: vec16 = undefined; reg($v02) w: vec32 = undefined; ";
    try expectRejectedWith(vector ++ "v[0..3] = load(vec16, p, 0); }", .invalid_lane_range);
    try expectRejectedWith(vector ++ "v[4..12] = load(vec16, p, 0); }", .invalid_lane_range);
    try expectRejectedWith(vector ++ "v[2..1] = load(vec16, p, 0); }", .invalid_lane_range);
    try expectRejectedWith(vector ++ "v[0..4] = w; }", .invalid_lane_range_transfer);
    try expectRejectedWith(vector ++ "w[0..4] = load(vec16, p, 0); }", .invalid_lane_range_transfer);
    try expectRejectedWith(vector ++ "v[0..4] = loadVectorBytes(p, 0); }", .invalid_lane_range_transfer);
    try expectRejectedWith(vector ++ "v = v[0..4] + v; }", .invalid_lane_range_transfer);
    try expectRejectedWith(vector ++ "store(vec16, p + p, v[0..4]); }", .invalid_lane_range_transfer);
}

test "parity spellings are no longer accepted" {
    try expectSyntaxRejected("fn test() { reg a: u32 = scalar.zero(); }");
    try expectSyntaxRejected("fn test() { reg a: u32 = scalar.unsigned(4); }");
    try expectSyntaxRejected("bss { b: u32; } fn test() { reg a: dmem = dmem.addressOfUnsigned(b); }");
    try expectSyntaxRejected("fn test() { reg a: u32 = code.addressOfUnsigned(test); }");
    try expectSyntaxRejected("fn test(reg($t0) p: dmem) { reg($v01) v: vec16 = undefined; rsp.vector.load64(v, 0, p, 0); }");
    try expectSyntaxRejected("fn test(reg($t0) p: dmem) { reg($v01) v: vec16 = undefined; store(vec64, p, v, 0); }");
    try expectSyntaxRejected("fn test(reg($t0) p: dmem) { reg($v01) v: vec16 = loadVectorWords(p, 0); }");
    try expectSyntaxRejected("bss { t: u32; } fn test(reg($t0) i: u32) { reg a: u32 = load(u32, i, t); }");
}

test "not of a constant folds in values and constant expressions" {
    try expectAsm(
        \\const flag: u32 = 0x20000;
        \\const mask: u32 = ~flag & 0xffff0000;
        \\fn test(reg($a0) value: u32) {
        \\  value &= ~flag;
        \\  value |= mask;
        \\  value = ~value;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\
        \\test:
        \\  lui $v1, 65533
        \\  ori $v1, $v1, 65535
        \\  and $a0, $a0, $v1
        \\  lui $v1, 65533
        \\  or $a0, $a0, $v1
        \\  nor $a0, $a0, $zero
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}
