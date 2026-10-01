const std = @import("std");

/// Encode up to 64 bytes without allocation. Volatile input supports KSEG1 reads.
pub fn encode(input: [*]const volatile u8, length: usize, output: *[128]u8) []const u8 {
    // @min infers u7 without this annotation: doubling 64 would wrap in ROMs.
    const count: usize = @min(64, length);
    const hex = "0123456789abcdef";
    for (0..count) |i| {
        const byte = input[i];
        output[i * 2] = hex[byte >> 4];
        output[i * 2 + 1] = hex[byte & 15];
    }
    return output[0 .. count * 2];
}

test "full capture chunk is 128 characters, partial chunk preserves exact length" {
    var bytes = [_]u8{0xff} ** 65;
    var output: [128]u8 = undefined;
    try std.testing.expectEqualStrings("ff" ** 64, encode(&bytes, 64, &output));
    try std.testing.expectEqualStrings("ff" ** 64, encode(&bytes, 65, &output));
    try std.testing.expectEqualStrings("ff" ** 12, encode(&bytes, 12, &output));
    try std.testing.expectEqualStrings("", encode(&bytes, 0, &output));
    bytes[0] = 0;
    bytes[1] = 0x1a;
    try std.testing.expectEqualStrings("001a", encode(&bytes, 2, &output));
}
