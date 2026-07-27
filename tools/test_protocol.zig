const std = @import("std");

pub const completion_prefix = "@@LIBPTERO_TEST_END@@";

pub const Completion = struct {
    passed: usize,
    failed: usize,
};

pub const LineParser = struct {
    buffer: [2048]u8 = undefined,
    len: usize = 0,

    pub fn feed(self: *LineParser, bytes: []const u8) !?Completion {
        for (bytes) |byte| {
            if (byte == '\n') {
                const line = std.mem.trimEnd(u8, self.buffer[0..self.len], "\r");
                self.len = 0;
                if (try parseCompletionLine(line)) |completion| return completion;
                continue;
            }
            if (self.len == self.buffer.len) return error.DebugLineTooLong;
            self.buffer[self.len] = byte;
            self.len += 1;
        }
        return null;
    }
};

pub fn parseCompletionLine(line: []const u8) !?Completion {
    if (!std.mem.startsWith(u8, line, completion_prefix)) return null;

    const json = std.mem.trim(u8, line[completion_prefix.len..], " ");
    const passed = try parseField(json, "\"passed\":", ',');
    const failed = try parseField(json, "\"failed\":", '}');
    return .{ .passed = passed, .failed = failed };
}

fn parseField(json: []const u8, key: []const u8, delimiter: u8) !usize {
    const key_start = std.mem.indexOf(u8, json, key) orelse
        return error.MalformedCompletionMarker;
    const value_start = key_start + key.len;
    const value_end = std.mem.indexOfScalarPos(
        u8,
        json,
        value_start,
        delimiter,
    ) orelse return error.MalformedCompletionMarker;
    const value = std.mem.trim(u8, json[value_start..value_end], " ");
    return std.fmt.parseInt(usize, value, 10) catch
        return error.MalformedCompletionMarker;
}

test "parses completion marker" {
    const result = (try parseCompletionLine(
        "@@LIBPTERO_TEST_END@@ {\"passed\":14,\"failed\":2}",
    )).?;
    try std.testing.expectEqual(@as(usize, 14), result.passed);
    try std.testing.expectEqual(@as(usize, 2), result.failed);
}

test "ignores normal debug output" {
    try std.testing.expectEqual(
        null,
        try parseCompletionLine("[ PASS ] color: RGBA16 bytes"),
    );
}

test "handles marker split across reads" {
    var parser: LineParser = .{};
    try std.testing.expectEqual(null, try parser.feed("@@LIBPTERO_"));
    try std.testing.expectEqual(
        null,
        try parser.feed("TEST_END@@ {\"passed\":3,"),
    );
    const result = (try parser.feed("\"failed\":0}\n")).?;
    try std.testing.expectEqual(@as(usize, 3), result.passed);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
}

test "rejects malformed completion marker" {
    try std.testing.expectError(
        error.MalformedCompletionMarker,
        parseCompletionLine("@@LIBPTERO_TEST_END@@ nope"),
    );
}
