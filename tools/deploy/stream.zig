//! Small injectable USB interface. Zero-byte reads mean no data yet, not EOF.
const std = @import("std");
pub const Stream = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        read: *const fn (*anyopaque, []u8) anyerror!usize,
        write: *const fn (*anyopaque, []const u8) anyerror!usize,
        now: *const fn (*anyopaque) i64,
        sleep: *const fn (*anyopaque, u32) anyerror!void,
        dtr: *const fn (*anyopaque, bool) anyerror!void,
        dsr: *const fn (*anyopaque) anyerror!bool,
        purge: *const fn (*anyopaque) anyerror!void,
    };

    pub fn read(self: Stream, bytes: []u8) !usize {
        return self.vtable.read(self.context, bytes);
    }
    pub fn now(self: Stream) i64 {
        return self.vtable.now(self.context);
    }
    pub fn sleep(self: Stream, ms: u32) !void {
        return self.vtable.sleep(self.context, ms);
    }
    pub fn writeAll(self: Stream, bytes: []const u8) !void {
        var offset: usize = 0;
        const deadline = self.now() + 5000;
        while (offset < bytes.len) {
            try self.checkDeadline(deadline);
            const count = try self.vtable.write(self.context, bytes[offset..]);
            if (count == 0) return error.UsbWriteStalled;
            offset += count;
        }
    }
    pub fn readExact(self: Stream, bytes: []u8, deadline: i64) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.checkDeadline(deadline);
            offset += try self.read(bytes[offset..]);
        }
    }
    pub fn checkDeadline(self: Stream, deadline: i64) !void {
        if (self.now() >= deadline) return error.UsbTimeout;
    }
    pub fn resetSc64(self: Stream) !void {
        try self.setDtrAndWait(true);
        try self.vtable.purge(self.context);
        try self.setDtrAndWait(false);
    }
    fn setDtrAndWait(self: Stream, enabled: bool) !void {
        try self.vtable.dtr(self.context, enabled);
        const deadline = self.now() + 1000;
        while (try self.vtable.dsr(self.context) != enabled) {
            try self.checkDeadline(deadline);
            try self.sleep(10);
        }
    }
};

pub const Fake = struct {
    input: []const u8 = &.{},
    cursor: usize = 0,
    output: std.ArrayList(u8) = .empty,
    clock: i64 = 0,
    fragment: usize = 3,
    dtr: bool = false,
    stuck_dsr: bool = false,
    purges: usize = 0,
    pub fn deinit(self: *Fake) void {
        self.output.deinit(std.testing.allocator);
    }
    pub fn stream(self: *Fake) Stream {
        return .{ .context = self, .vtable = &.{ .read = read, .write = write, .now = now, .sleep = sleep, .dtr = setDtr, .dsr = dsr, .purge = purge } };
    }
    fn cast(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn read(ctx: *anyopaque, bytes: []u8) !usize {
        const self = cast(ctx);
        self.clock += 1;
        const n = @min(bytes.len, self.input.len - self.cursor, self.fragment);
        @memcpy(bytes[0..n], self.input[self.cursor..][0..n]);
        self.cursor += n;
        return n;
    }
    fn write(ctx: *anyopaque, bytes: []const u8) !usize {
        const self = cast(ctx);
        const n = @min(bytes.len, self.fragment);
        try self.output.appendSlice(std.testing.allocator, bytes[0..n]);
        return n;
    }
    fn now(ctx: *anyopaque) i64 {
        return cast(ctx).clock;
    }
    fn sleep(ctx: *anyopaque, ms: u32) !void {
        cast(ctx).clock += ms;
    }
    fn setDtr(ctx: *anyopaque, enabled: bool) !void {
        cast(ctx).dtr = enabled;
    }
    fn dsr(ctx: *anyopaque) !bool {
        const self = cast(ctx);
        return !self.stuck_dsr and self.dtr;
    }
    fn purge(ctx: *anyopaque) !void {
        cast(ctx).purges += 1;
    }
};

test "partial USB transfers, reset handshake, stalled writes and read deadlines" {
    var fake: Fake = .{ .input = "abcdef" };
    defer fake.deinit();
    const s = fake.stream();
    try s.resetSc64();
    try std.testing.expectEqual(@as(usize, 1), fake.purges);
    try std.testing.expect(!fake.dtr);
    try s.writeAll("abcdefgh");
    try std.testing.expectEqualStrings("abcdefgh", fake.output.items);
    var buffer: [6]u8 = undefined;
    try s.readExact(&buffer, 20);
    try std.testing.expectEqualStrings("abcdef", &buffer);
    try std.testing.expectError(error.UsbTimeout, s.readExact(&buffer, 20));
    fake.fragment = 0;
    try std.testing.expectError(error.UsbWriteStalled, s.writeAll("x"));
    fake.stuck_dsr = true;
    try std.testing.expectError(error.UsbTimeout, s.resetSc64());
}
