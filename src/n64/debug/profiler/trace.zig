//! Bounded trace storage and versioned transport, independent of N64 hardware.
const std = @import("std");
pub const ticks_per_second = 46_875_000;
pub const max_labels = 64;
pub const max_label_bytes = 63;
pub const Lane = enum(u8) { cpu, rsp_low, rsp_high, rdp, pi, audio };
pub const Kind = enum(u8) { begin, end, instant, counter };
pub const Event = struct {
    ticks: u64,
    span: u32,
    value: u32,
    label: u16,
    lane: Lane,
    kind: Kind,
};
pub const Token = struct { span: u32 = 0, label: u16 = 0, lane: Lane = .cpu };

pub fn validNameSize(name: []const u8) bool {
    return name.len > 0 and name.len <= max_label_bytes;
}
pub fn validName(name: []const u8) bool {
    if (!validNameSize(name)) return false;
    for (name) |byte| if (byte < 32 or byte > 126) return false;
    return true;
}

/// Capture a prefix, never overwrite it. Overflow counts every omitted event.
/// Strings must outlive the recorder; the hardware API requires comptime names.
/// Call observeAt at least once per Count wrap (91.6 seconds).
pub const Recorder = struct {
    storage: []Event,
    labels: [max_labels][]const u8 = undefined,
    label_count: u16 = 0,
    count: usize = 0,
    dropped: u32 = 0,
    elapsed: u64 = 0,
    last_count: u32 = 0,
    next_span: u32 = 1,
    running: bool = false,

    pub fn init(storage: []Event) Recorder {
        return .{ .storage = storage };
    }
    pub fn startAt(self: *Recorder, count: u32) void {
        const storage = self.storage;
        self.* = .{ .storage = storage, .last_count = count, .running = true };
    }
    pub fn observeAt(self: *Recorder, count: u32) void {
        self.elapsed += count -% self.last_count;
        self.last_count = count;
    }
    pub fn stopAt(self: *Recorder, count: u32) void {
        self.observeAt(count);
        self.running = false;
    }
    pub fn events(self: *const Recorder) []const Event {
        return self.storage[0..self.count];
    }
    fn omit(self: *Recorder) void {
        self.dropped +|= 1;
    }
    fn labelId(self: *Recorder, name: []const u8) ?u16 {
        for (self.labels[0..self.label_count], 0..) |label, i| {
            if (std.mem.eql(u8, name, label)) return @intCast(i);
        }
        if (self.label_count == max_labels or name.len == 0 or name.len > max_label_bytes) return null;
        const id = self.label_count;
        self.labels[id] = name;
        self.label_count += 1;
        return id;
    }
    fn append(self: *Recorder, event: Event) void {
        if (self.count == self.storage.len) return self.omit();
        self.storage[self.count] = event;
        self.count += 1;
    }
    pub fn beginAt(self: *Recorder, count: u32, lane: Lane, name: []const u8, value: u32) Token {
        if (!self.running) return .{};
        self.observeAt(count);
        // Do not emit later events after a failed begin; retain a trace prefix.
        if (self.count == self.storage.len) {
            self.omit();
            return .{};
        }
        const label = self.labelId(name) orelse {
            self.omit();
            return .{};
        };
        if (self.next_span == 0) {
            self.omit();
            return .{};
        }
        const token: Token = .{ .span = self.next_span, .label = label, .lane = lane };
        self.next_span +%= 1;
        self.append(.{ .ticks = self.elapsed, .span = token.span, .value = value, .label = label, .lane = lane, .kind = .begin });
        return token;
    }
    pub fn endAt(self: *Recorder, count: u32, token: Token, value: u32) void {
        if (!self.running or token.span == 0) return;
        self.observeAt(count);
        self.append(.{ .ticks = self.elapsed, .span = token.span, .value = value, .label = token.label, .lane = token.lane, .kind = .end });
    }
    pub fn markAt(self: *Recorder, count: u32, lane: Lane, name: []const u8, kind: Kind, value: u32) void {
        if (!self.running) return;
        self.observeAt(count);
        if (self.count == self.storage.len) return self.omit();
        const label = self.labelId(name) orelse return self.omit();
        self.append(.{ .ticks = self.elapsed, .span = 0, .value = value, .label = label, .lane = lane, .kind = kind });
    }

    /// Writer needs print(comptime fmt, args). No heap or hardware access.
    /// Export only a stopped capture. IDs must be unique within a debug log.
    pub fn write(self: *const Recorder, writer: anytype, id: u32) !void {
        if (self.running) return error.CaptureRunning;
        try writer.print("@@PTERO_TRACE_BEGIN@@ {d} 1 {d} {d} {d} {d} {d}\n", .{ id, ticks_per_second, self.count, self.label_count, self.dropped, self.elapsed });
        var crc = std.hash.Crc32.init();
        checksumHeader(&crc, id, self.count, self.label_count, self.dropped, self.elapsed);
        var encoded: [max_label_bytes * 2]u8 = undefined;
        for (self.labels[0..self.label_count], 0..) |name, i| {
            for (name, 0..) |byte, j| {
                encoded[j * 2] = "0123456789abcdef"[byte >> 4];
                encoded[j * 2 + 1] = "0123456789abcdef"[byte & 15];
            }
            checksumLabel(&crc, name);
            try writer.print("@@PTERO_TRACE_LABEL@@ {d} {d} {s}\n", .{ id, i, encoded[0 .. name.len * 2] });
        }
        for (self.events(), 0..) |event, i| {
            checksumEvent(&crc, event);
            try writer.print("@@PTERO_TRACE_EVENT@@ {d} {d} {d} {d} {d} {d} {d} {d}\n", .{ id, i, event.ticks, @intFromEnum(event.kind), @intFromEnum(event.lane), event.label, event.span, event.value });
        }
        try writer.print("@@PTERO_TRACE_END@@ {d} {x:0>8}\n", .{ id, crc.final() });
    }
};

pub fn checksumHeader(crc: *std.hash.Crc32, id: u32, count: usize, labels: usize, dropped: u32, elapsed: u64) void {
    var bytes: [28]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], 1, .big);
    std.mem.writeInt(u32, bytes[2..6], id, .big);
    std.mem.writeInt(u32, bytes[6..10], ticks_per_second, .big);
    std.mem.writeInt(u32, bytes[10..14], @intCast(count), .big);
    std.mem.writeInt(u16, bytes[14..16], @intCast(labels), .big);
    std.mem.writeInt(u32, bytes[16..20], dropped, .big);
    std.mem.writeInt(u64, bytes[20..28], elapsed, .big);
    crc.update(&bytes);
}
pub fn checksumLabel(crc: *std.hash.Crc32, name: []const u8) void {
    var length: [2]u8 = undefined;
    std.mem.writeInt(u16, &length, @intCast(name.len), .big);
    crc.update(&length);
    crc.update(name);
}

/// Canonical bytes, independent of host endian, struct padding or enum layout.
pub fn checksumEvent(crc: *std.hash.Crc32, event: Event) void {
    var bytes: [20]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], event.ticks, .big);
    std.mem.writeInt(u32, bytes[8..12], event.span, .big);
    std.mem.writeInt(u32, bytes[12..16], event.value, .big);
    std.mem.writeInt(u16, bytes[16..18], event.label, .big);
    bytes[18] = @intFromEnum(event.lane);
    bytes[19] = @intFromEnum(event.kind);
    crc.update(&bytes);
}

test "nested scopes, independent lanes, and Count wrap preserve order" {
    var storage: [8]Event = undefined;
    var r = Recorder.init(&storage);
    r.startAt(0xfffffff0);
    const outer = r.beginAt(0xfffffff4, .cpu, "frame", 1);
    const inner = r.beginAt(2, .pi, "read", 4096);
    r.markAt(3, .audio, "buffers", .counter, 2);
    r.endAt(6, inner, 0);
    r.endAt(10, outer, 0);
    r.stopAt(16);
    try std.testing.expectEqual(@as(u64, 32), r.elapsed);
    try std.testing.expectEqual(@as(u64, 18), r.events()[1].ticks);
    try std.testing.expectEqual(outer.span, r.events()[4].span);
    try std.testing.expectEqual(inner.span, r.events()[3].span);
    try std.testing.expectEqual(@as(u16, 3), r.label_count);
}

test "overflow retains prefix, counts omitted events, and reset reuses storage" {
    var storage: [2]Event = undefined;
    var r = Recorder.init(&storage);
    r.startAt(0);
    const first = r.beginAt(1, .cpu, "work", 0);
    r.endAt(2, first, 0);
    const skipped = r.beginAt(3, .cpu, "work", 0);
    r.endAt(4, skipped, 0);
    r.markAt(5, .cpu, "later", .instant, 0);
    r.stopAt(6);
    try std.testing.expectEqual(@as(u32, 2), r.dropped);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(@as(u16, 1), r.label_count);
    r.startAt(8);
    try std.testing.expectEqual(@as(u32, 0), r.dropped);
    try std.testing.expectEqual(@as(usize, 0), r.count);
    r.stopAt(9);
    r.markAt(10, .cpu, "ignored", .instant, 0);
    try std.testing.expectEqual(@as(usize, 0), r.count);
}

test "label exhaustion is bounded and stopped captures refuse live export" {
    var storage: [128]Event = undefined;
    var r = Recorder.init(&storage);
    r.startAt(0);
    var names: [max_labels + 1][2]u8 = undefined;
    for (&names, 0..) |*name, i| {
        name.* = .{ @intCast(i), 32 };
        r.markAt(@intCast(i), .cpu, name, .instant, 0);
    }
    try std.testing.expectEqual(@as(u16, max_labels), r.label_count);
    try std.testing.expectEqual(@as(u32, 1), r.dropped);
    var bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expectError(error.CaptureRunning, r.write(&writer, 1));
}

test "names bound protocol lines and reject controls" {
    try std.testing.expect(validName("CPU <scope>"));
    try std.testing.expect(validName("a" ** max_label_bytes));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a" ** (max_label_bytes + 1)));
    try std.testing.expect(!validName("line\n"));
    try std.testing.expect(!validName("\x7f"));
}
