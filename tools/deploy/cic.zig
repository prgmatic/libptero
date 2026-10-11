//! IPL2's 48-bit IPL3 checksum. Algorithm reference: UNFLoader/device.cpp (WTFPL).
const std = @import("std");
const magic: u32 = 0x6c078965;
pub const Signature = struct { seed: u8, checksum: u48 };
const known = [_]Signature{
    .{ .seed = 0x3f, .checksum = 0x45cc73ee317a },
    .{ .seed = 0x3f, .checksum = 0x44160ec5d9af },
    .{ .seed = 0x3f, .checksum = 0xa536c0f1d859 },
    .{ .seed = 0x78, .checksum = 0x586fd4709867 },
    .{ .seed = 0x91, .checksum = 0x8618a45bc2d3 },
    .{ .seed = 0x85, .checksum = 0x2bbad4e6eb74 },
    .{ .seed = 0xdd, .checksum = 0x083c6c77e0b1 },
    .{ .seed = 0xdd, .checksum = 0x32b294e2ab90 },
    .{ .seed = 0xdd, .checksum = 0x6ee8d9e84970 },
    .{ .seed = 0xdd, .checksum = 0x6c216495c8b9 },
    .{ .seed = 0xdd, .checksum = 0xe27f43ba93ac },
    .{ .seed = 0xde, .checksum = 0x05ba2ef0a5f1 },
};

pub fn sign(ipl3: *const [0xfc0]u8, custom_seed: ?u8) Signature {
    if (custom_seed) |seed| return .{ .seed = seed, .checksum = checksum(ipl3, seed) };
    for (known) |candidate| {
        if (checksum(ipl3, candidate.seed) == candidate.checksum) return candidate;
    }
    return .{ .seed = 0x3f, .checksum = checksum(ipl3, 0x3f) };
}

pub fn checksum(ipl3: *const [0xfc0]u8, seed: u8) u48 {
    var state: [16]u32 = @splat((magic *% seed +% 1) ^ word(ipl3, 0));
    for (1..1009) |index| {
        const i: u32 = @intCast(index);
        const previous = word(ipl3, index -| 2);
        const data = word(ipl3, index - 1);
        updateCurrent(&state, i, previous, data);
        if (index < 1008) updateNext(&state, i, previous, data, word(ipl3, index));
    }
    return reduce(state);
}

fn word(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index * 4 ..][0..4], .big);
}
fn mix(a: u32, b: u32, fallback: u32) u32 {
    const product = @as(u64, a) * (if (b == 0) fallback else b);
    const difference = @as(u32, @truncate(product >> 32)) -% @as(u32, @truncate(product));
    return if (difference == 0) a else difference;
}
fn left(v: u32, n: u32) u32 {
    return std.math.rotl(u32, v, @as(u5, @truncate(n)));
}
fn right(v: u32, n: u32) u32 {
    return std.math.rotr(u32, v, @as(u5, @truncate(n)));
}

fn updateCurrent(s: *[16]u32, i: u32, previous: u32, data: u32) void {
    s[0] +%= mix(1007 -% i, data, i);
    s[1] = mix(s[1], data, i);
    s[2] ^= data;
    s[3] +%= mix(data +% 5, magic, i);
    s[4] +%= right(data, previous);
    s[5] +%= left(data, previous >> 27);
    s[6] = if (data < s[6]) (s[3] +% s[6]) ^ (data +% i) else (s[4] +% data) ^ s[6];
    s[7] = mix(s[7], left(data, previous), i);
    s[8] = mix(s[8], right(data, previous >> 27), i);
    s[9] = if (previous < data) mix(s[9], data, i) else s[9] +% data;
}
fn updateNext(s: *[16]u32, i: u32, previous: u32, data: u32, next: u32) void {
    s[10] = mix(s[10] +% data, next, i);
    s[11] = mix(s[11] ^ data, next, i);
    s[12] +%= s[8] ^ data;
    s[13] +%= right(data, data) +% right(next, next);
    s[14] = mix(mix(s[14], right(data, previous), i), right(next, data), i);
    s[15] = mix(mix(s[15], left(data, previous >> 27), i), left(next, data >> 27), i);
}
fn reduce(state: [16]u32) u48 {
    var final: [4]u32 = @splat(state[0]);
    for (state, 0..) |data, index| {
        const i: u32 = @intCast(index);
        final[0] +%= right(data, data);
        final[1] = if (data < final[0]) final[1] +% data else mix(final[1], data, i);
        final[2] = if (((data >> 1) ^ data) & 1 == 0) final[2] +% data else mix(final[2], data, i);
        final[3] = if (data & 1 == 1) final[3] ^ data else mix(final[3], data, i);
    }
    return (@as(u48, @truncate(mix(final[0], final[1], 16))) << 32) | (final[3] ^ final[2]);
}

test "CIC signing handles arbitrary boot code and explicit seeds" {
    const bytes: [0xfc0]u8 = @splat(0);
    const automatic = sign(&bytes, null);
    // Independently generated with UNFLoader's ipl2checksum reference.
    try std.testing.expectEqual(@as(u48, 0x2982ad8c201d), automatic.checksum);
    try std.testing.expectEqual(@as(u8, 0x3f), automatic.seed);
    try std.testing.expectEqual(checksum(&bytes, 0x3f), automatic.checksum);
    const custom = sign(&bytes, 0x91);
    try std.testing.expectEqual(@as(u8, 0x91), custom.seed);
    try std.testing.expect(custom.checksum != automatic.checksum);
    var pattern: [0xfc0]u8 = undefined;
    for (&pattern, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    try std.testing.expectEqual(@as(u48, 0x13c83f54d7ca), checksum(&pattern, 0x3f));
    try std.testing.expectEqual(@as(u48, 0x97b209f433a9), checksum(&pattern, 0x91));
}
