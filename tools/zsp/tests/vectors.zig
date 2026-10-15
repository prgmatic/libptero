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
        \\  rsp.vector.storePackedSigned(value, 0, ptr, 8);
        \\  rsp.vector.storePackedUnsigned(value, 4, ptr, 8);
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
        \\  .word 0xe9013001 # spv $v01[0], 8($t0)
        \\  .word 0xe9013a01 # suv $v01[4], 8($t0)
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
        \\  result = vectorClipHigh(left, right);
        \\  result = vectorClipLow(left, right);
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
        \\  .word 0x4a0208e5 # vch $v03, $v01, $v02
        \\  .word 0x4a0208e4 # vcl $v03, $v01, $v02
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

test "VADPCM quad lane, reverse and transpose transfers preserve hardware encodings" {
    try expectAsm(
        \\fn test() noreturn {
        \\  reg($t0) ptr: dmem = 8;
        \\  reg($v08) value: vec16 = undefined;
        \\  exact {
        \\    rsp.vector.loadQuad(value, 3, ptr, 16);
        \\    rsp.vector.loadRight(value, ptr, 16);
        \\    rsp.vector.storeRight(value, ptr, 16);
        \\    rsp.vector.loadTranspose(value, 0, ptr, 0);
        \\    rsp.halt();
        \\  }
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 8
        \\# zsp exact block begin
        \\  .word 0xc9082301 # lqv $v08[3], 16($t0)
        \\  .word 0xc9082801 # lrv $v08[0], 16($t0)
        \\  .word 0xe9082801 # srv $v08[0], 16($t0)
        \\  .word 0xc9085800 # ltv $v08[0], 0($t0)
        \\  break
        \\# zsp exact block end
        \\
        \\
    );
}

test "transpose interfaces include the complete register bank and reject invalid banks" {
    const source =
        \\pub export fn transpose(reg($t0) ptr: dmem) noreturn {
        \\  reg($v08) bank: vec16 = undefined;
        \\  rsp.vector.loadTranspose(bank, 0, ptr, 0);
        \\  rsp.halt();
        \\}
    ;
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    var interface = std.Io.Writer.Allocating.init(testing.allocator);
    defer interface.deinit();
    try asm_writer.writeInterface(&interface.writer, functions, null);
    try testing.expect(std.mem.indexOf(u8, interface.written(), "writes($v08, $v09, $v10, $v11, $v12, $v13, $v14, $v15)") != null);
    try expectAsmError(
        \\fn test() noreturn {
        \\  reg($t0) ptr: dmem = 8;
        \\  reg($v09) bank: vec16 = undefined;
        \\  rsp.vector.loadTranspose(bank, 0, ptr, 0);
        \\  rsp.halt();
        \\}
    , error.TransposeRequiresRegisterBank);
}
