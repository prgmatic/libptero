//! Completion records shared by the ROM debug API and ptero-deploy.
const std = @import("std");

pub const prefix = "@@LIBPTERO_RUN_END@@";
pub const Summary = struct { passed: u32, failed: u32 };
pub const Result = union(enum) { success, failure, tests: Summary };
pub const Completion = struct {
    code: u1,
    passed: u32 = 0,
    failed: u32 = 0,
};

pub fn completion(result: Result) Completion {
    return switch (result) {
        .success => .{ .code = 0 },
        .failure => .{ .code = 1 },
        .tests => |s| .{ .code = @intFromBool(s.failed != 0), .passed = s.passed, .failed = s.failed },
    };
}

pub fn encode(buffer: []u8, result: Result) ![]const u8 {
    const c = completion(result);
    return std.fmt.bufPrint(buffer, prefix ++ " {{\"code\":{d},\"passed\":{d},\"failed\":{d}}}\n", .{ c.code, c.passed, c.failed });
}

pub fn parse(line: []const u8) !?Completion {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const json = std.mem.trim(u8, line[prefix.len..], " \r");
    var storage: [2048]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    const value = std.json.parseFromSlice(Completion, arena.allocator(), json, .{}) catch return error.MalformedCompletion;
    defer value.deinit();
    if (value.value.failed != 0 and value.value.code == 0) return error.MalformedCompletion;
    return value.value;
}

pub const Parser = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    test_starts: usize = 0,

    pub fn feed(self: *Parser, bytes: []const u8) !?Completion {
        for (bytes) |byte| {
            if (try self.feedByte(byte)) |c| return c;
        }
        return null;
    }

    fn feedByte(self: *Parser, byte: u8) !?Completion {
        if (byte == '\n') return self.endLine();
        if (self.len == self.buffer.len) {
            self.overflow = true;
            return null;
        }
        self.buffer[self.len] = byte;
        self.len += 1;
        self.trackTestStart();
        return null;
    }

    fn trackTestStart(self: *Parser) void {
        if (std.mem.eql(u8, self.buffer[0..self.len], "[Run] ")) self.test_starts += 1;
    }

    fn endLine(self: *Parser) !?Completion {
        defer self.len = 0;
        defer self.overflow = false;
        if (self.overflow) {
            if (std.mem.startsWith(u8, &self.buffer, prefix)) return error.MalformedCompletion;
            return null;
        }
        return parse(self.buffer[0..self.len]);
    }
};

test "completion records roundtrip for success, failure and test summaries" {
    const cases = [_]Result{ .success, .failure, .{ .tests = .{ .passed = 25, .failed = 2 } }, .{ .tests = .{ .passed = 1, .failed = 0 } } };
    for (cases) |result| {
        var buffer: [128]u8 = undefined;
        var parser: Parser = .{};
        const encoded = try encode(&buffer, result);
        _ = try parser.feed(encoded[0..7]);
        try std.testing.expectEqualDeep(completion(result), (try parser.feed(encoded[7..])).?);
    }
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, encode(&tiny, .success));
}

test "stream parsing ignores long logs, tracks split starts and rejects corrupt completion" {
    var parser: Parser = .{};
    _ = try parser.feed(&(@as([900]u8, @splat('x'))));
    _ = try parser.feed("\n[Ru");
    _ = try parser.feed("n] example");
    try std.testing.expectEqual(@as(usize, 1), parser.test_starts);
    _ = try parser.feed(" passed\r\n");
    try std.testing.expectEqual(null, try parse("ordinary output"));
    try std.testing.expectError(error.MalformedCompletion, parse(prefix ++ " nope"));
    try std.testing.expectError(error.MalformedCompletion, parse(prefix ++ " {\"code\":0,\"failed\":1}"));
    try std.testing.expectError(error.MalformedCompletion, parse(prefix ++ " {\"code\":2}"));
    _ = try parser.feed(prefix);
    _ = try parser.feed(&(@as([900]u8, @splat('x'))));
    try std.testing.expectError(error.MalformedCompletion, parser.feed("\n"));
}
