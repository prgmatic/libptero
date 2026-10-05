const std = @import("std");

/// Escape a Make dependency path, including spaces in an artist's asset folder.
pub fn path(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        ' ', '\t', '#', '\\', ':' => {
            try writer.writeByte('\\');
            try writer.writeByte(byte);
        },
        '$' => try writer.writeAll("$$"),
        '\n', '\r' => return error.InvalidDependencyPath,
        else => try writer.writeByte(byte),
    };
}

test "dependency paths preserve spaces and Make metacharacters" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try path(&out.writer, "assets/my font#$:a\\b.png");
    try std.testing.expectEqualStrings("assets/my\\ font\\#$$\\:a\\\\b.png", out.written());
    try std.testing.expectError(error.InvalidDependencyPath, path(&out.writer, "a\nb"));
}
