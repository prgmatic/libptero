//! Instruction field extraction for the RSP encodings.
pub fn opcode(op: u32) u6 {
    return @truncate(op >> 26);
}

pub fn rs(op: u32) u5 {
    return @truncate(op >> 21);
}

pub fn rt(op: u32) u5 {
    return @truncate(op >> 16);
}

pub fn rd(op: u32) u5 {
    return @truncate(op >> 11);
}

pub fn sa(op: u32) u5 {
    return @truncate(op >> 6);
}

pub fn funct(op: u32) u6 {
    return @truncate(op);
}

pub fn imm(op: u32) u16 {
    return @truncate(op);
}

pub fn simm(op: u32) i16 {
    return @bitCast(imm(op));
}

pub fn target(op: u32) u32 {
    return op & 0x03ff_ffff;
}

/// Destination vector register of a computational instruction.
pub fn vd(op: u32) u5 {
    return @truncate(op >> 6);
}

/// First source vector register; also the register of MFC2/MTC2.
pub fn vs(op: u32) u5 {
    return @truncate(op >> 11);
}

/// Element-selected source vector register; also LWC2/SWC2's register.
pub fn vt(op: u32) u5 {
    return @truncate(op >> 16);
}

/// Element modifier of a computational vector instruction.
pub fn element(op: u32) u4 {
    return @truncate(op >> 21);
}

/// Byte element of a vector move, load, or store.
pub fn byteElement(op: u32) u4 {
    return @truncate(op >> 7);
}

/// Destination lane of single-lane vector instructions (VMOV, VRCP, ...).
pub fn destinationLane(op: u32) u3 {
    return @truncate(op >> 11);
}

/// Signed seven-bit offset of LWC2/SWC2, before scaling by access size.
pub fn vectorOffset(op: u32) i32 {
    const raw: u7 = @truncate(op);
    return @as(i7, @bitCast(raw));
}

test "fields decode representative encodings" {
    const testing = @import("std").testing;
    // addiu $t1, $t0, -4
    const addiu: u32 = 0x2509fffc;
    try testing.expectEqual(@as(u6, 9), opcode(addiu));
    try testing.expectEqual(@as(u5, 8), rs(addiu));
    try testing.expectEqual(@as(u5, 9), rt(addiu));
    try testing.expectEqual(@as(i16, -4), simm(addiu));
    // vmudh $v03, $v01, $v02[6]
    const vmudh: u32 = 0x4bc208c7;
    try testing.expectEqual(@as(u5, 3), vd(vmudh));
    try testing.expectEqual(@as(u5, 1), vs(vmudh));
    try testing.expectEqual(@as(u5, 2), vt(vmudh));
    try testing.expectEqual(@as(u4, 14), element(vmudh));
    try testing.expectEqual(@as(u6, 7), funct(vmudh));
    try testing.expectEqual(@as(i32, -1), vectorOffset(0x7f));
    try testing.expectEqual(@as(i32, 63), vectorOffset(0x3f));
    try testing.expectEqual(@as(u4, 3), byteElement(3 << 7));
    try testing.expectEqual(@as(u3, 5), destinationLane(5 << 11));
    try testing.expectEqual(@as(u5, 2), rd(2 << 11));
    try testing.expectEqual(@as(u5, 4), sa(4 << 6));
    try testing.expectEqual(@as(u32, 0x0123456), target(0x0c123456));
}
