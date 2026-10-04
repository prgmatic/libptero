//! Strict framed trace decoder. Treat debug logs as untrusted input.
const std = @import("std");
const format = @import("profiler_trace");
pub const Trace = struct {
    id: u32,
    hz: u32,
    dropped: u32,
    elapsed: u64,
    labels: [][]u8,
    events: []format.Event,
    pub fn deinit(self: Trace, a: std.mem.Allocator) void {
        for (self.labels) |label| a.free(label);
        a.free(self.labels);
        a.free(self.events);
    }
};
const Fields = std.mem.TokenIterator(u8, .any);
const Transfer = struct {
    a: std.mem.Allocator,
    trace: ?Trace = null,
    label_index: usize = 0,
    event_index: usize = 0,
    crc: std.hash.Crc32 = std.hash.Crc32.init(),

    fn begin(self: *Transfer, fields: *Fields) !void {
        if (self.trace != null) return error.IncompleteTrace;
        const h = try readHeader(fields);
        try validateHeader(h);
        const names = try self.a.alloc([]u8, h.labels);
        errdefer self.a.free(names);
        for (names) |*name| name.* = &.{};
        // Finish fallible allocations before publishing the optional owner.
        const records = try self.a.alloc(format.Event, h.count);
        format.checksumHeader(&self.crc, h.id, h.count, h.labels, h.dropped, h.elapsed);
        self.trace = .{ .id = h.id, .hz = h.hz, .dropped = h.dropped, .elapsed = h.elapsed, .labels = names, .events = records };
    }
    fn checkId(self: *Transfer, fields: *Fields) !void {
        const t = self.trace orelse return error.MissingHeader;
        if (try integer(u32, fields) != t.id) return error.WrongTraceId;
    }
    fn label(self: *Transfer, fields: *Fields) !void {
        try self.checkId(fields);
        const t = &self.trace.?;
        if (self.event_index != 0 or self.label_index == t.labels.len) return error.InvalidLabel;
        if (try integer(usize, fields) != self.label_index) return error.InvalidLabel;
        const hex = fields.next() orelse return error.InvalidLabel;
        const name = try decodeName(self.a, hex);
        t.labels[self.label_index] = name;
        self.label_index += 1;
        format.checksumLabel(&self.crc, name);
    }
    fn event(self: *Transfer, fields: *Fields) !void {
        try self.checkId(fields);
        const t = &self.trace.?;
        if (self.label_index != t.labels.len or self.event_index == t.events.len) return error.InvalidEventIndex;
        if (try integer(usize, fields) != self.event_index) return error.InvalidEventIndex;
        const e = try readEvent(fields);
        try validateEvent(t.*, self.event_index, e);
        t.events[self.event_index] = e;
        self.event_index += 1;
        format.checksumEvent(&self.crc, e);
    }
    fn end(self: *Transfer, fields: *Fields) !void {
        try self.checkId(fields);
        const checksum = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidTrace, 16) catch return error.InvalidTrace;
        const t = self.trace.?;
        if (self.event_index != t.events.len or self.label_index != t.labels.len) return error.IncompleteTrace;
        if (checksum != self.crc.final()) return error.ChecksumMismatch;
        try validateSpans(self.a, t.events);
    }
    fn consumeLine(self: *Transfer, line: []const u8) !bool {
        const start = std.mem.indexOf(u8, line, "@@PTERO_TRACE_") orelse return false;
        var fields = std.mem.tokenizeAny(u8, line[start..], " \t");
        const finished = try self.consume(fields.next().?, &fields);
        if (fields.next() != null) return error.InvalidTrace;
        return finished;
    }
    fn consume(self: *Transfer, tag: []const u8, fields: *Fields) !bool {
        if (std.mem.eql(u8, tag, "@@PTERO_TRACE_BEGIN@@")) {
            try self.begin(fields);
        } else if (std.mem.eql(u8, tag, "@@PTERO_TRACE_LABEL@@")) {
            try self.label(fields);
        } else if (std.mem.eql(u8, tag, "@@PTERO_TRACE_EVENT@@")) {
            try self.event(fields);
        } else if (std.mem.eql(u8, tag, "@@PTERO_TRACE_END@@")) {
            try self.end(fields);
            return true;
        } else return error.InvalidTrace;
        return false;
    }
};
fn enumeration(comptime T: type, fields: *Fields) !T {
    const value = try integer(u8, fields);
    if (value >= std.meta.tags(T).len) return error.InvalidEvent;
    return @enumFromInt(value);
}
fn integer(comptime T: type, fields: *Fields) !T {
    return std.fmt.parseInt(T, fields.next() orelse return error.InvalidTrace, 10) catch error.InvalidTrace;
}
const Header = struct { id: u32, hz: u32, count: u32, labels: u16, dropped: u32, elapsed: u64 };
fn readHeader(fields: *Fields) !Header {
    const id = try integer(u32, fields);
    if (try integer(u32, fields) != 1) return error.UnsupportedVersion;
    return .{ .id = id, .hz = try integer(u32, fields), .count = try integer(u32, fields), .labels = try integer(u16, fields), .dropped = try integer(u32, fields), .elapsed = try integer(u64, fields) };
}
fn validateHeader(h: Header) !void {
    if (h.hz != format.ticks_per_second or h.count > 1_000_000 or h.labels > format.max_labels or h.elapsed > 9_007_199_254_740_991) return error.InvalidHeader;
}
fn validHexLength(length: usize) bool {
    return length > 0 and length % 2 == 0 and length <= format.max_label_bytes * 2;
}
fn labelByte(hex: []const u8) !u8 {
    const byte = std.fmt.parseInt(u8, hex, 16) catch return error.InvalidLabel;
    if (byte < 32 or byte > 126) return error.InvalidLabel;
    return byte;
}
fn decodeName(a: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (!validHexLength(hex.len)) return error.InvalidLabel;
    const name = try a.alloc(u8, hex.len / 2);
    errdefer a.free(name);
    for (name, 0..) |*byte, i| byte.* = try labelByte(hex[i * 2 ..][0..2]);
    return name;
}
fn readEvent(fields: *Fields) !format.Event {
    return .{ .ticks = try integer(u64, fields), .kind = try enumeration(format.Kind, fields), .lane = try enumeration(format.Lane, fields), .label = try integer(u16, fields), .span = try integer(u32, fields), .value = try integer(u32, fields) };
}
fn validSpanTag(event: format.Event) bool {
    return (event.kind == .begin or event.kind == .end) == (event.span != 0);
}
fn validateEvent(t: Trace, index: usize, e: format.Event) !void {
    if (e.label >= t.labels.len or e.ticks > t.elapsed) return error.InvalidEvent;
    if (index != 0 and e.ticks < t.events[index - 1].ticks) return error.InvalidEvent;
    if (!validSpanTag(e)) return error.InvalidEvent;
}
const OpenSpans = std.AutoHashMap(u32, format.Event);
fn addSpan(open: *OpenSpans, last: *u32, event: format.Event) !void {
    if (event.span <= last.*) return error.InvalidSpan;
    last.* = event.span;
    try open.put(event.span, event);
}
fn closeSpan(open: *OpenSpans, event: format.Event) !void {
    const start = (open.fetchRemove(event.span) orelse return error.InvalidSpan).value;
    if (start.label != event.label or start.lane != event.lane) return error.InvalidSpan;
}
fn validateSpans(a: std.mem.Allocator, events: []const format.Event) !void {
    var open = OpenSpans.init(a);
    defer open.deinit();
    var last_span: u32 = 0;
    for (events) |event| switch (event.kind) {
        .begin => try addSpan(&open, &last_span, event),
        .end => try closeSpan(&open, event),
        else => {},
    };
    // Open scopes are valid when capture stops mid-work or its buffer fills.
}

/// Decode the first capture; reject transport loss, reordering and silent event
/// corruption. Ordinary surrounding/prefixed debug lines are ignored.
pub fn decode(a: std.mem.Allocator, log: []const u8) !Trace {
    var transfer: Transfer = .{ .a = a };
    errdefer if (transfer.trace) |t| t.deinit(a);
    var lines = std.mem.tokenizeAny(u8, log, "\r\n");
    while (lines.next()) |line| {
        if (try transfer.consumeLine(line)) return transfer.trace.?;
    }
    return if (transfer.trace == null) error.NoTrace else error.IncompleteTrace;
}
