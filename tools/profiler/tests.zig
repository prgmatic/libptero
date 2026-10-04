const std = @import("std");
const format = @import("profiler_trace");
const decoder = @import("decode.zig");
const output = @import("output.zig");
const a = std.testing.allocator;

fn fixture(allocator: std.mem.Allocator) ![]u8 {
    var events: [8]format.Event = undefined;
    var r = format.Recorder.init(&events);
    r.startAt(0xfffffff0);
    const cpu = r.beginAt(0xfffffff2, .cpu, "frame </script> \" \\", 1);
    const pi = r.beginAt(0xfffffff3, .pi, "DMA", 4096);
    r.markAt(0xfffffff4, .audio, "queued", .counter, 2);
    r.endAt(5, pi, 0);
    r.markAt(6, .rsp_low, "submit", .instant, 100);
    r.endAt(7, cpu, 0);
    _ = r.beginAt(8, .rdp, "open fence", 2);
    r.stopAt(9);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try r.write(&writer.writer, 42);
    return writer.toOwnedSlice();
}
fn replace(log: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, log, needle) orelse return error.MissingTestSubstring;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ log[0..i], replacement, log[i + needle.len ..] });
}
fn expectChangedError(expected: anyerror, log: []const u8, needle: []const u8, replacement: []const u8) !void {
    const changed = try replace(log, needle, replacement);
    defer a.free(changed);
    try std.testing.expectError(expected, decoder.decode(a, changed));
}

test "recorder protocol roundtrip preserves wrap, scopes, counters and open work" {
    const log = try fixture(a);
    defer a.free(log);
    const prefixed = try std.fmt.allocPrint(a, "boot noise\n[SC64] {s}other noise\n", .{log});
    defer a.free(prefixed);
    const t = try decoder.decode(a, prefixed);
    defer t.deinit(a);
    try std.testing.expectEqual(@as(u32, 42), t.id);
    try std.testing.expectEqual(@as(u64, 25), t.elapsed);
    try std.testing.expectEqual(@as(usize, 7), t.events.len);
    try std.testing.expectEqual(@as(u64, 21), t.events[3].ticks);
    try std.testing.expectEqual(@as(u32, 4096), t.events[1].value);
    try std.testing.expectEqual(format.Kind.counter, t.events[2].kind);
    try std.testing.expectEqual(format.Lane.rdp, t.events[6].lane);
}

test "decoder rejects missing, reordered, malformed and corrupt records" {
    const log = try fixture(a);
    defer a.free(log);
    try expectChangedError(error.InvalidEventIndex, log, "TRACE_EVENT@@ 42 0", "TRACE_EVENT@@ 42 1");
    try expectChangedError(error.WrongTraceId, log, "TRACE_EVENT@@ 42 0", "TRACE_EVENT@@ 43 0");
    try expectChangedError(error.InvalidEvent, log, "42 0 2 0 0", "42 0 2 9 0");
    try expectChangedError(error.InvalidEvent, log, "42 0 2 0 0", "42 0 2 0 9");
    try expectChangedError(error.InvalidEvent, log, "42 0 2 0 0 0 1", "42 0 2 0 0 0 0");
    try expectChangedError(error.InvalidEvent, log, "42 0 2 0 0 0", "42 0 2 0 0 9");
    try expectChangedError(error.InvalidEvent, log, "42 0 2 0", "42 0 26 0");
    try expectChangedError(error.ChecksumMismatch, log, "42 1 3 0 4 1 2 4096", "42 1 3 0 4 1 2 4097");
    try expectChangedError(error.InvalidLabel, log, "TRACE_LABEL@@ 42 0", "TRACE_LABEL@@ 42 1");
    try expectChangedError(error.InvalidLabel, log, "6672616d65", "zz72616d65");
    try expectChangedError(error.InvalidTrace, log, "TRACE_EVENT@@ 42 0 2", "TRACE_EVENT@@ 42 0 nope");
    try expectChangedError(error.UnsupportedVersion, log, "BEGIN@@ 42 1", "BEGIN@@ 42 2");
    try expectChangedError(error.InvalidHeader, log, "46875000 7 5", "46875000 1000001 5");
    try expectChangedError(error.InvalidHeader, log, "46875000 7 5", "46875000 7 65");
    try expectChangedError(error.ChecksumMismatch, log, "7 5 0 25", "7 5 1 25");
    const stop = std.mem.indexOf(u8, log, "@@PTERO_TRACE_END@@").?;
    try std.testing.expectError(error.IncompleteTrace, decoder.decode(a, log[0..stop]));
}

test "decoder validates framing and first capture without allocation leaks" {
    try std.testing.expectError(error.NoTrace, decoder.decode(a, "ordinary debug output"));
    try std.testing.expectError(error.MissingHeader, decoder.decode(a, "@@PTERO_TRACE_EVENT@@ 1 0\n"));
    try std.testing.expectError(error.InvalidTrace, decoder.decode(a, "@@PTERO_TRACE_UNKNOWN@@\n"));
    try std.testing.expectError(error.InvalidHeader, decoder.decode(a, "@@PTERO_TRACE_BEGIN@@ 0 1 1 0 0 0 0\n"));
    try std.testing.expectError(error.InvalidTrace, decoder.decode(a, "@@PTERO_TRACE_BEGIN@@ 0\n"));
    const empty = "@@PTERO_TRACE_BEGIN@@ 0 1 46875000 0 0 0 0\n@@PTERO_TRACE_END@@ 0 79e2d90c\n";
    const t = try decoder.decode(a, empty ++ empty);
    defer t.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), t.events.len);
    try std.testing.expectError(error.InvalidTrace, decoder.decode(a, empty[0 .. empty.len - 1] ++ " extra\n"));
    try std.testing.expectError(error.IncompleteTrace, decoder.decode(a, "@@PTERO_TRACE_BEGIN@@ 0 1 46875000 1 0 0 0\n@@PTERO_TRACE_END@@ 0 79e2d90c\n"));
    try std.testing.expectError(error.IncompleteTrace, decoder.decode(a, "@@PTERO_TRACE_BEGIN@@ 0 1 46875000 0 0 0 0\n@@PTERO_TRACE_BEGIN@@ 1 1 46875000 0 0 0 0\n"));
}

test "HTML protects script boundaries and JSON exports preserve every event phase" {
    const log = try fixture(a);
    defer a.free(log);
    const t = try decoder.decode(a, log);
    defer t.deinit(a);
    var json: std.Io.Writer.Allocating = .init(a);
    defer json.deinit();
    try output.writeJson(t, &json.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 7), parsed.value.object.get("events").?.array.items.len);
    try std.testing.expectEqualStrings(t.labels[0], parsed.value.object.get("labels").?.array.items[0].string);
    try std.testing.expect(std.mem.indexOf(u8, json.written(), "</script>") == null);
    var html: std.Io.Writer.Allocating = .init(a);
    defer html.deinit();
    try output.writeHtml(t, &html.writer);
    try std.testing.expect(std.mem.indexOf(u8, html.written(), "trace-data") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.written(), "Fit capture") != null);
    var chrome: std.Io.Writer.Allocating = .init(a);
    defer chrome.deinit();
    try output.writeChrome(t, &chrome.writer);
    const chrome_json = try std.json.parseFromSlice(std.json.Value, a, chrome.written(), .{});
    defer chrome_json.deinit();
    try std.testing.expectEqual(@as(usize, 13), chrome_json.value.object.get("traceEvents").?.array.items.len);
    try std.testing.expectEqualStrings("b", chrome_json.value.object.get("traceEvents").?.array.items[6].object.get("ph").?.string);
}

test "span mismatches and duplicates fail even when transport checksum is correct" {
    var events: [6]format.Event = undefined;
    var r = format.Recorder.init(&events);
    r.startAt(0);
    const token = r.beginAt(1, .cpu, "scope", 0);
    r.endAt(2, token, 0);
    r.endAt(3, token, 0);
    r.stopAt(4);
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    try r.write(&log.writer, 1);
    try std.testing.expectError(error.InvalidSpan, decoder.decode(a, log.written()));
    r.storage[2].kind = .begin;
    log.clearRetainingCapacity();
    try r.write(&log.writer, 1);
    try std.testing.expectError(error.InvalidSpan, decoder.decode(a, log.written()));
    r.count = 2;
    r.storage[1].lane = .pi;
    log.clearRetainingCapacity();
    try r.write(&log.writer, 1);
    try std.testing.expectError(error.InvalidSpan, decoder.decode(a, log.written()));
}

test "full buffer exports a valid prefix with explicit loss and unfinished scopes" {
    var events: [1]format.Event = undefined;
    var r = format.Recorder.init(&events);
    r.startAt(0);
    const token = r.beginAt(1, .cpu, "scope", 0);
    r.endAt(2, token, 0);
    r.stopAt(3);
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    try r.write(&log.writer, 1);
    const t = try decoder.decode(a, log.written());
    defer t.deinit(a);
    try std.testing.expectEqual(@as(u32, 1), t.dropped);
    try std.testing.expectEqual(@as(usize, 1), t.events.len);
}

fn allocationRoundtrip(allocator: std.mem.Allocator, log: []const u8) !void {
    const t = try decoder.decode(allocator, log);
    defer t.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    // Allocating Writer maps allocation failure to its generic WriteFailed.
    output.writeHtml(t, &writer.writer) catch return error.OutOfMemory;
}
test "decoder and exporter release partial allocations on allocation failure" {
    const log = try fixture(a);
    defer a.free(log);
    try std.testing.checkAllAllocationFailures(a, allocationRoundtrip, .{log});
}
