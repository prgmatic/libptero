const std = @import("std");
const capture = @import("framebuffer_capture");
const usage = "Usage: framebuffer-capture <debug.log> <frame.png>\nDecodes the first complete libptero framebuffer transfer in a relayed debug log.\n";

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| fatal("{s}\n{s}", .{ @errorName(err), usage });
}

fn run(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    const paths = try parseArguments(args) orelse {
        std.debug.print("{s}", .{usage});
        return;
    };
    try convert(init.io, a, paths.input, paths.output);
}

const Paths = struct { input: []const u8, output: []const u8 };
fn parseArguments(args: []const []const u8) !?Paths {
    if (showUsage(args)) return null;
    if (args.len != 3) return error.InvalidArguments;
    return .{ .input = args[1], .output = args[2] };
}

fn showUsage(args: []const []const u8) bool {
    if (args.len == 1) return true;
    if (args.len != 2) return false;
    return std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h");
}

test "usage recognizes help, empty arguments, and not conversion arguments" {
    try std.testing.expect(showUsage(&.{"framebuffer-capture"}));
    try std.testing.expect(showUsage(&.{ "framebuffer-capture", "--help" }));
    try std.testing.expect(showUsage(&.{ "framebuffer-capture", "-h" }));
    try std.testing.expect(!showUsage(&.{ "framebuffer-capture", "log" }));
    try std.testing.expect(!showUsage(&.{ "framebuffer-capture", "log", "png" }));
    try std.testing.expectEqual(null, try parseArguments(&.{"framebuffer-capture"}));
    try std.testing.expectError(error.InvalidArguments, parseArguments(&.{ "framebuffer-capture", "log" }));
    const paths = (try parseArguments(&.{ "framebuffer-capture", "log", "png" })).?;
    try std.testing.expectEqualStrings("log", paths.input);
    try std.testing.expectEqualStrings("png", paths.output);
}

fn convert(io: std.Io, a: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, input, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const log = try reader.interface.allocRemaining(a, .limited(256 * 1024 * 1024));
    defer a.free(log);
    const frame = try capture.decode(a, log);
    defer frame.deinit(a);
    const png = try capture.encodePng(a, frame.width, frame.height, frame.rgba);
    defer a.free(png);
    var destination = try std.Io.Dir.cwd().createFile(io, output, .{ .exclusive = true });
    defer destination.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = destination.writer(io, &write_buffer);
    try writer.interface.writeAll(png);
    try writer.interface.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("framebuffer-capture: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
