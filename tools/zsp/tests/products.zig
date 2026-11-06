//! Vector products and the multiply accumulator.
const support = @import("support.zig");

const expectAsm = support.expectAsm;
const expectRejectedWith = support.expectRejectedWith;

test "a vec32 product chain reads its result from the final multiplies" {
    try expectAsm(
        \\fn test() {
        \\  reg($v01) a: vec32 = undefined;
        \\  reg($v03) b: vec32 = undefined;
        \\  reg($v05) c: vec32 = undefined;
        \\  acc = a * b.xxxxXXXX;
        \\  acc += c * b.halfLane(1);
        \\  reg($v07) result: vec32 = acc;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a841244 # vmudl $v09, $v02, $v04
        \\  .word 0x4a840a4d # vmadm $v09, $v01, $v04
        \\  .word 0x4a83124e # vmadn $v09, $v02, $v03
        \\  .word 0x4a830a4f # vmadh $v09, $v01, $v03
        \\  .word 0x4aa4324c # vmadl $v09, $v06, $v04
        \\  .word 0x4aa42a4d # vmadm $v09, $v05, $v04
        \\  .word 0x4aa3320e # vmadn $v08, $v06, $v03
        \\  .word 0x4aa329cf # vmadh $v07, $v05, $v03
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "mixed-width and viewed products pick their partial multiplies" {
    try expectAsm(
        \\fn test() {
        \\  reg($v01) wide: vec32 = undefined;
        \\  reg($v03) narrow: vec16 = undefined;
        \\  reg($v04) out: vec32 = undefined;
        \\  reg($v06) single: vec16 = undefined;
        \\  out = wide * narrow.lane(3);
        \\  single = narrow * wide;
        \\  single.sfract = narrow.sfract * narrow.sfract.quarterLane(1);
        \\  single = narrow.sint * narrow.ufract;
        \\  single = narrow.ufract * narrow.sint;
        \\  single = narrow.ufract * narrow.ufract;
        \\  out.ufract = wide * wide;
        \\  out.sint = wide * wide;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4b631146 # vmudn $v05, $v02, $v03
        \\  .word 0x4b63090f # vmadh $v04, $v01, $v03
        \\  .word 0x4a0219c5 # vmudm $v07, $v03, $v02
        \\  .word 0x4a01198f # vmadh $v06, $v03, $v01
        \\  .word 0x4a631980 # vmulf $v06, $v03, $v03
        \\  .word 0x4a031985 # vmudm $v06, $v03, $v03
        \\  .word 0x4a031986 # vmudn $v06, $v03, $v03
        \\  .word 0x4a031984 # vmudl $v06, $v03, $v03
        \\  .word 0x4a0211c4 # vmudl $v07, $v02, $v02
        \\  .word 0x4a0209cd # vmadm $v07, $v01, $v02
        \\  .word 0x4a01114e # vmadn $v05, $v02, $v01
        \\  .word 0x4a0109cf # vmadh $v07, $v01, $v01
        \\  .word 0x4a0210c4 # vmudl $v03, $v02, $v02
        \\  .word 0x4a0208cd # vmadm $v03, $v01, $v02
        \\  .word 0x4a0110ce # vmadn $v03, $v02, $v01
        \\  .word 0x4a01090f # vmadh $v04, $v01, $v01
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "a chain keeps its scratch register until the final read" {
    try expectAsm(
        \\fn test(reg($t0) p: dmem) {
        \\  reg($v01) a: vec16 = undefined;
        \\  reg($v02) out: vec16 = undefined;
        \\  acc = a * a;
        \\  a = load(vec16, p);
        \\  acc += a * a.x;
        \\  out = acc;
        \\  reg($v03) product: vec16 = a * a.y;
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  .word 0x4a0108c7 # vmudh $v03, $v01, $v01
        \\  .word 0xc9012000 # lqv $v01, 0($t0)
        \\  .word 0x4b01088f # vmadh $v02, $v01, $v01
        \\  .word 0x4b2108c7 # vmudh $v03, $v01, $v01
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "a program variable named acc is an ordinary register" {
    try expectAsm(
        \\fn test() {
        \\  reg acc: u32 = 1;
        \\  acc += 2;
        \\  rsp.cp0.setSpStatus(acc);
        \\}
    ,
        \\.set noreorder
        \\.set noat
        \\.text
        \\
        \\test:
        \\  addiu $t0, $zero, 1
        \\  addi $t0, $t0, 2
        \\  mtc0 $t0, $4
        \\  jr $ra
        \\  nop
        \\
        \\
    );
}

test "accumulator misuse is diagnosed" {
    const vectors = "fn test() { reg($v01) a: vec16 = undefined; reg($v02) w: vec32 = undefined; reg($v04) n: vec16 = undefined; ";
    try expectRejectedWith(vectors ++ "acc += a * a; }", .accumulator_not_started);
    try expectRejectedWith(vectors ++ "acc = a * a; a = n; n = acc; }", .accumulator_read_not_adjacent);
    try expectRejectedWith(vectors ++ "n = acc; }", .accumulator_read_not_adjacent);
    try expectRejectedWith(vectors ++ "acc = a * w; w = acc; }", .accumulator_read_requires_fraction);
    try expectRejectedWith(vectors ++ "acc = a.sfract * a.sint; }", .invalid_vector_product);
    try expectRejectedWith(vectors ++ "acc = w * a.ufract; }", .invalid_vector_product);
    try expectRejectedWith(vectors ++ "acc = a.ufract * w; }", .invalid_vector_product);
    try expectRejectedWith(vectors ++ "acc = a * missing; }", .expected_vector_operand);
    try expectRejectedWith("fn test(x: u32) { reg($v01) a: vec16 = undefined; acc = a * x; }", .expected_vector_operand);
    try expectRejectedWith(vectors ++ "acc = a * 3; }", .expected_vector_operand);
    try expectRejectedWith(vectors ++ "acc = a * a; a[2] = acc; }", .unsupported_destination_swizzle);
    try expectRejectedWith("fn test(x: u32) { reg($v01) a: vec16 = undefined; acc = a * a; x = acc; }", .expected_vector_operand);
    try expectRejectedWith("fn test(x: u32) { reg($v01) a: vec16 = undefined; if (x == 1) { acc = a * a; } acc += a * a; }", .accumulator_not_started);
    try expectRejectedWith(vectors ++ "n = a * 2; }", .expected_vector_operand);
}
