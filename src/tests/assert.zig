const std = @import("std");

pub const max_message_len = 128;

pub const Diagnostic = struct {
    address: u32,
    message: [max_message_len]u8,
    message_len: u8,

    pub fn messageSlice(self: *const Diagnostic) []const u8 {
        return self.message[0..self.message_len];
    }
};

var last_failure: ?Diagnostic = null;

pub fn reset() void {
    last_failure = null;
}

pub fn failure() ?Diagnostic {
    return last_failure;
}

pub noinline fn expect(condition: bool) !void {
    if (!condition) {
        record(@returnAddress() -% 4, "condition was false", .{});
        return error.TestUnexpectedResult;
    }
}

pub noinline fn expectEqual(expected: anytype, actual: anytype) !void {
    if (expected != actual) {
        record(
            @returnAddress() -% 4,
            "expected {any}, got {any}",
            .{ expected, actual },
        );
        return error.TestExpectedEqual;
    }
}

fn record(address: usize, comptime format: []const u8, args: anytype) void {
    var diagnostic: Diagnostic = .{
        .address = @truncate(address),
        .message = undefined,
        .message_len = 0,
    };
    const message = std.fmt.bufPrint(&diagnostic.message, format, args) catch blk: {
        const fallback = "failure details too long";
        @memcpy(diagnostic.message[0..fallback.len], fallback);
        break :blk diagnostic.message[0..fallback.len];
    };
    diagnostic.message_len = @intCast(message.len);
    last_failure = diagnostic;
}
