const std = @import("std");
pub const Packet = struct {
    kind: enum { response, failure, notification },
    id: u8,
    data: []const u8,
};
pub const Debug = struct { datatype: u8, data: []const u8 };
pub fn sc64Header(bytes: *const [8]u8) !struct { kind: @FieldType(Packet, "kind"), id: u8, size: u32 } {
    const kind = try sc64Kind(bytes[0..3]);
    return .{ .kind = kind, .id = bytes[3], .size = std.mem.readInt(u32, bytes[4..8], .big) };
}
fn sc64Kind(prefix: []const u8) !@FieldType(Packet, "kind") {
    const kinds = .{ .{ "CMP", .response }, .{ "ERR", .failure }, .{ "PKT", .notification } };
    inline for (kinds) |pair| {
        if (std.mem.eql(u8, prefix, pair[0])) return pair[1];
    }
    return error.InvalidSc64Packet;
}
pub fn debug(data: []const u8) !Debug {
    if (data.len < 4) return error.InvalidDebugPacket;
    const header = std.mem.readInt(u32, data[0..4], .big);
    if (header & 0xffffff != data.len - 4) return error.InvalidDebugPacket;
    return .{ .datatype = @truncate(header >> 24), .data = data[4..] };
}
pub fn sc64Command(id: u8, first: u32, second: u32) [12]u8 {
    var bytes: [12]u8 = undefined;
    bytes[0..4].* = .{ 'C', 'M', 'D', id };
    std.mem.writeInt(u32, bytes[4..8], first, .big);
    std.mem.writeInt(u32, bytes[8..12], second, .big);
    return bytes;
}
pub fn everdriveCommand(id: u8, address: u32, size: u32) [16]u8 {
    var bytes: [16]u8 = @splat(0);
    bytes[0..4].* = .{ 'c', 'm', 'd', id };
    std.mem.writeInt(u32, bytes[4..8], address, .big);
    std.mem.writeInt(u32, bytes[8..12], size / 512, .big);
    return bytes;
}

test "wire headers match cartridge protocols and reject malformed packets" {
    try std.testing.expectEqualSlices(u8, &.{ 'C', 'M', 'D', 'M', 0x01, 2, 3, 4, 0, 0, 2, 0 }, &sc64Command('M', 0x01020304, 512));
    try std.testing.expectEqualSlices(u8, &.{ 'c', 'm', 'd', 'W', 0x10, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 }, &everdriveCommand('W', 0x10000000, 1024));
    try std.testing.expectEqual(.response, (try sc64Header("CMPv\x00\x00\x00\x04")).kind);
    try std.testing.expectEqual(.failure, (try sc64Header("ERRM\x00\x00\x00\x00")).kind);
    try std.testing.expectEqual(.notification, (try sc64Header("PKTU\x00\x00\x00\x04")).kind);
    try std.testing.expectError(error.InvalidSc64Packet, sc64Header("BAD!\x00\x00\x00\x00"));
    const d = try debug("\x01\x00\x00\x03abc");
    try std.testing.expectEqualStrings("abc", d.data);
    try std.testing.expectEqual(@as(u8, 1), d.datatype);
    try std.testing.expectError(error.InvalidDebugPacket, debug("x"));
    try std.testing.expectError(error.InvalidDebugPacket, debug("\x01\x00\x00\x04abc"));
}
