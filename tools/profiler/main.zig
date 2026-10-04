const std = @import("std");
const profiler = @import("profiler");
const usage = "Usage: ptero-profiler <debug.log> <trace.html|trace.json> [--chrome]\nBuilds a standalone timeline or exports trace JSON from the first captured trace.\n";
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("ptero-profiler: {s}\n{s}", .{ @errorName(err), usage });
        std.process.exit(1);
    };
}
const Options = struct { input: []const u8, output: []const u8, chrome: bool };
fn showUsage(args: []const []const u8) bool {
    if (args.len == 1) return true;
    if (args.len != 2) return false;
    return std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h");
}
fn chromeOption(args: []const []const u8) !bool {
    if (args.len == 3) return false;
    if (!std.mem.eql(u8, args[3], "--chrome")) return error.InvalidArguments;
    return true;
}
fn validateExtension(name: []const u8, chrome: bool) !void {
    const json = std.mem.endsWith(u8, name, ".json");
    if (chrome) {
        if (!json) return error.InvalidOutputExtension;
    } else if (!json and !std.mem.endsWith(u8, name, ".html")) return error.InvalidOutputExtension;
}
fn parseArguments(args: []const []const u8) !?Options {
    if (showUsage(args)) return null;
    if (args.len < 3 or args.len > 4) return error.InvalidArguments;
    const chrome = try chromeOption(args);
    try validateExtension(args[2], chrome);
    return .{ .input = args[1], .output = args[2], .chrome = chrome };
}
fn run(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    const options = try parseArguments(args) orelse {
        std.debug.print("{s}", .{usage});
        return;
    };
    try convert(init.io, a, options);
}
fn convert(io: std.Io, a: std.mem.Allocator, options: Options) !void {
    var input = try std.Io.Dir.cwd().openFile(io, options.input, .{});
    defer input.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = input.reader(io, &read_buffer);
    const log = try reader.interface.allocRemaining(a, .limited(256 * 1024 * 1024));
    defer a.free(log);
    const trace = try profiler.decode(a, log);
    defer trace.deinit(a);
    // Decode and validate everything before creating a new output.
    var file = try std.Io.Dir.cwd().createFile(io, options.output, .{ .exclusive = true });
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, options.output) catch {};
    var write_buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writeFormat(trace, &writer.interface, options);
    try writer.interface.flush();
    if (!@import("builtin").is_test) std.debug.print("saved {d} events, {d} labels, {d} omitted events to {s}\n", .{ trace.events.len, trace.labels.len, trace.dropped, options.output });
}
fn writeFormat(trace: profiler.Trace, writer: *std.Io.Writer, options: Options) !void {
    if (options.chrome) try profiler.writeChrome(trace, writer) else if (std.mem.endsWith(u8, options.output, ".html")) try profiler.writeHtml(trace, writer) else try profiler.writeJson(trace, writer);
}
test "CLI handles usage, output formats and invalid arguments" {
    try std.testing.expectEqual(null, try parseArguments(&.{"ptero-profiler"}));
    try std.testing.expectEqual(null, try parseArguments(&.{ "ptero-profiler", "--help" }));
    try std.testing.expectEqual(null, try parseArguments(&.{ "ptero-profiler", "-h" }));
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{ "p", "log" }));
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{ "p", "log", "out.html", "--unknown" }));
    try std.testing.expectError(error.InvalidOutputExtension, parseArguments(&.{ "p", "log", "out.png" }));
    try std.testing.expectError(error.InvalidOutputExtension, parseArguments(&.{ "p", "log", "out.html", "--chrome" }));
    try std.testing.expect((try parseArguments(&.{ "p", "log", "out.json", "--chrome" })).?.chrome);
    try std.testing.expect(!(try parseArguments(&.{ "p", "log", "out.html" })).?.chrome);
}

test "conversion preserves existing output and validates before creating files" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const input = try std.fs.path.join(a, &.{ directory, "debug.log" });
    defer a.free(input);
    const html = try std.fs.path.join(a, &.{ directory, "trace.html" });
    defer a.free(html);
    const json = try std.fs.path.join(a, &.{ directory, "trace.json" });
    defer a.free(json);
    const chrome = try std.fs.path.join(a, &.{ directory, "chrome.json" });
    defer a.free(chrome);
    const invalid = try std.fs.path.join(a, &.{ directory, "invalid.json" });
    defer a.free(invalid);
    try temp.dir.writeFile(io, .{ .sub_path = "debug.log", .data = "not a capture\n" });
    try std.testing.expectError(error.NoTrace, convert(io, a, .{ .input = input, .output = invalid, .chrome = false }));
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "invalid.json", .{}));
    // Empty stopped captures are valid and can be exported in all three formats.
    var buffer: [0]@import("profiler_trace").Event = .{};
    var recorder = @import("profiler_trace").Recorder.init(&buffer);
    recorder.startAt(0);
    recorder.stopAt(0);
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    try recorder.write(&log.writer, 1);
    try temp.dir.writeFile(io, .{ .sub_path = "debug.log", .data = log.written() });
    try convert(io, a, .{ .input = input, .output = html, .chrome = false });
    try convert(io, a, .{ .input = input, .output = json, .chrome = false });
    try convert(io, a, .{ .input = input, .output = chrome, .chrome = true });
    const options: Options = .{ .input = input, .output = json, .chrome = false };
    try std.testing.expectError(error.PathAlreadyExists, convert(io, a, options));
    var file = try temp.dir.openFile(io, "trace.json", .{});
    defer file.close(io);
    var read_buffer: [256]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const saved = try reader.interface.allocRemaining(a, .limited(1024));
    defer a.free(saved);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, saved, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
}
