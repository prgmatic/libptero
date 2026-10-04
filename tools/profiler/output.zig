const std = @import("std");
const Trace = @import("decode.zig").Trace;
const format = @import("profiler_trace");

// ASCII label encoder also protects inline JSON from HTML script termination.
fn string(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.writeByte('"');
    for (name) |byte| switch (byte) {
        '"', '\\' => {
            try writer.writeByte('\\');
            try writer.writeByte(byte);
        },
        '<', '>', '&' => try writer.print("\\u00{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}
/// Compact viewer data; raw timestamps remain integer Count ticks.
pub fn writeJson(t: Trace, w: *std.Io.Writer) !void {
    try w.print("{{\"version\":1,\"id\":{d},\"hz\":{d},\"elapsed\":{d},\"dropped\":{d},\"labels\":[", .{ t.id, t.hz, t.elapsed, t.dropped });
    for (t.labels, 0..) |name, i| {
        if (i != 0) try w.writeByte(',');
        try string(w, name);
    }
    try w.writeAll("],\"events\":[");
    for (t.events, 0..) |event, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("[{d},{d},{d},{d},{d},{d}]", .{ event.ticks, @intFromEnum(event.kind), @intFromEnum(event.lane), event.label, event.span, event.value });
    }
    try w.writeAll("]}");
}
pub fn writeHtml(t: Trace, w: *std.Io.Writer) !void {
    try w.writeAll(@embedFile("viewer_header.html"));
    try writeJson(t, w);
    try w.writeAll(@embedFile("viewer_footer.html"));
}

/// Chrome/Perfetto trace events: asynchronous scopes allow overlapping batches.
/// Endpoints are CPU observations, never inferred RSP/RDP execution intervals.
pub fn writeChrome(t: Trace, w: *std.Io.Writer) !void {
    try w.writeAll("{\"displayTimeUnit\":\"ms\",\"traceEvents\":[");
    inline for (std.meta.tags(format.Lane), 0..) |lane, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"ph\":\"M\",\"pid\":1,\"tid\":{d},\"name\":\"thread_name\",\"args\":{{\"name\":\"{s}\"}}}}", .{ i, @tagName(lane) });
    }
    for (t.events) |event| {
        try w.writeAll(",{\"name\":");
        try string(w, t.labels[event.label]);
        try w.print(",\"pid\":1,\"tid\":{d},\"ts\":{d:.6},", .{ @intFromEnum(event.lane), @as(f64, @floatFromInt(event.ticks)) * 1_000_000 / @as(f64, @floatFromInt(t.hz)) });
        try chromePhase(w, event);
        try w.print("\"args\":{{\"value\":{d}}}}}", .{event.value});
    }
    try w.print("],\"otherData\":{{\"dropped\":{d},\"duration_ticks\":{d},\"timing\":\"CPU-observed submissions and completions\"}}}}", .{ t.dropped, t.elapsed });
}
fn chromePhase(w: *std.Io.Writer, event: format.Event) !void {
    switch (event.kind) {
        .begin => try w.print("\"ph\":\"b\",\"cat\":\"{s}\",\"id\":{d},", .{ @tagName(event.lane), event.span }),
        .end => try w.print("\"ph\":\"e\",\"cat\":\"{s}\",\"id\":{d},", .{ @tagName(event.lane), event.span }),
        .instant => try w.writeAll("\"ph\":\"i\",\"s\":\"t\","),
        .counter => try w.writeAll("\"ph\":\"C\","),
    }
}
