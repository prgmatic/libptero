//! Deterministic ROM payloads and native handles. No runtime directory is needed.
const std = @import("std");
pub const Input = struct { name: []const u8, data: []const u8 };
pub const Result = struct {
    data: []u8,
    source: []u8,
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.source);
    }
};
pub fn pack(allocator: std.mem.Allocator, inputs: []const Input) !Result {
    var data: std.Io.Writer.Allocating = .init(allocator);
    defer data.deinit();
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    for (inputs, 0..) |input, index| {
        try validate(inputs[0..index], input);
        if (data.written().len + input.data.len > 64 * 1024 * 1024) return error.PayloadTooLarge;
        try source.writer.print("pub const {s}: @import(\"n64\").rom.Region = .{{ .offset = {d}, .size = {d} }};\n", .{ input.name, data.written().len, input.data.len });
        try data.writer.writeAll(input.data);
        const padding = if (input.data.len == 0) 16 else std.mem.alignForward(usize, data.written().len, 16) - data.written().len;
        try data.writer.splatByteAll(0, padding);
    }
    return .{ .data = try data.toOwnedSlice(), .source = try source.toOwnedSlice() };
}
fn validate(previous: []const Input, input: Input) !void {
    if (!std.zig.isValidId(input.name)) return error.InvalidAssetName;
    for (previous) |entry| if (std.mem.eql(u8, input.name, entry.name)) return error.DuplicateAsset;
}
test "packing is deterministic, padded and exposes logical sizes" {
    const a = std.testing.allocator;
    const inputs = [_]Input{ .{ .name = "a", .data = "odd" }, .{ .name = "b", .data = "payload" } };
    const result = try pack(a, &inputs);
    defer result.deinit(a);
    const again = try pack(a, &inputs);
    defer again.deinit(a);
    try std.testing.expectEqualSlices(u8, result.data, again.data);
    try std.testing.expectEqual(@as(usize, 32), result.data.len);
    try std.testing.expectEqualSlices(u8, "payload", result.data[16..23]);
    for (result.data[3..16]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(std.mem.indexOf(u8, result.source, ".offset = 16, .size = 7") != null);
    try std.testing.expectError(error.DuplicateAsset, pack(a, &.{ inputs[0], inputs[0] }));
    try std.testing.expectError(error.InvalidAssetName, pack(a, &.{.{ .name = "bad name", .data = "" }}));
}
