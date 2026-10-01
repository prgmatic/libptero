const std = @import("std");

pub const completion_prefix = "@@LIBPTERO_TEST_END@@";
pub const test_start_prefix = "[Run] ";

pub const Completion = struct {
    passed: usize,
    failed: usize,
};

pub const LineParser = struct {
    buffer: [2048]u8 = undefined,
    len: usize = 0,
    test_starts: usize = 0,

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
            // The runner prints test starts without a newline so a hung test
            // can still be identified before its result arrives.
            if (self.len == test_start_prefix.len and
                std.mem.eql(u8, self.buffer[0..self.len], test_start_prefix))
            {
                self.test_starts += 1;
            }
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

test "detects test starts across reads before a newline" {
    var parser: LineParser = .{};
    _ = try parser.feed("[Ru");
    try std.testing.expectEqual(@as(usize, 0), parser.test_starts);
    _ = try parser.feed("n] first test");
    try std.testing.expectEqual(@as(usize, 1), parser.test_starts);
    _ = try parser.feed(" [Pass ✅]\n[Run] second test");
    try std.testing.expectEqual(@as(usize, 2), parser.test_starts);
    const result = (try parser.feed(
        " [Pass ✅]\n@@LIBPTERO_TEST_END@@ {\"passed\":2,\"failed\":0}\n",
    )).?;
    try std.testing.expectEqual(@as(usize, 2), result.passed);
}

test "ordinary output does not count as a test start" {
    var parser: LineParser = .{};
    _ = try parser.feed("diagnostic: [Run] example\n[Run]");
    try std.testing.expectEqual(@as(usize, 0), parser.test_starts);
    _ = try parser.feed("ning diagnostic\n");
    try std.testing.expectEqual(@as(usize, 0), parser.test_starts);
}
