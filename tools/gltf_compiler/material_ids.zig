//! Preserve glTF material names as compile-time metadata for generated providers.
const std = @import("std");
const compiler = @import("compiler.zig");

pub fn emit(allocator: std.mem.Allocator, source: *std.ArrayList(u8), materials: []const compiler.Material) !void {
    try source.appendSlice(allocator, "    pub const material_names = [_][]const u8{\n");
    for (materials) |material| try compiler.appendFormat(allocator, source, "        \"{f}\",\n", .{std.zig.fmtString(material.name)});
    try source.appendSlice(allocator, "    };\n");
}

test "names use Zig escaping without normalization or loss of source indices" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try emit(allocator, &source, &.{ .{ .name = "body" }, .{ .name = "visor\"\n\x01" }, .{ .name = "" } });
    try std.testing.expectEqualStrings(
        "    pub const material_names = [_][]const u8{\n        \"body\",\n        \"visor\\\"\\n\\x01\",\n        \"\",\n    };\n",
        source.items,
    );
}
