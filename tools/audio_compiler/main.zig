const std = @import("std");
const audio = @import("audio_compiler");
pub fn main(init: std.process.Init) void {
    run(init) catch |err| fatal("{s}", .{@errorName(err)});
}
const Arguments = struct { input: []const u8, data: []const u8, source: []const u8, name: []const u8, loop: bool, streamed: bool, vadpcm: bool };
fn parseArguments(args: []const []const u8) !Arguments {
    if (args.len < 5 or args.len > 8) return error.Usage;
    var result: Arguments = .{ .input = args[1], .data = args[2], .source = args[3], .name = args[4], .loop = false, .streamed = false, .vadpcm = false };
    for (args[5..]) |arg| try applySwitch(&result, arg);
    return result;
}
fn applySwitch(result: *Arguments, arg: []const u8) !void {
    if (std.mem.eql(u8, arg, "--loop")) {
        try enable(&result.loop);
    } else if (std.mem.eql(u8, arg, "--stream")) {
        try enable(&result.streamed);
    } else if (std.mem.eql(u8, arg, "--vadpcm")) {
        try enable(&result.vadpcm);
    } else return error.UnknownOption;
}
fn enable(flag: *bool) !void {
    if (flag.*) return error.UnknownOption;
    flag.* = true;
}
fn conversionOptions(options: Arguments) audio.Options {
    return .{ .loop = options.loop, .streamed = options.streamed or options.vadpcm, .compression = if (options.vadpcm) .vadpcm else .none };
}
fn run(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    const options = try parseArguments(args);
    const bytes = try readFile(init.io, a, options.input);
    defer a.free(bytes);
    const result = try audio.convert(a, bytes, conversionOptions(options));
    defer result.deinit(a);
    const source = try audio.generateSource(a, options.name, result);
    defer a.free(source);
    try writeFile(init.io, options.data, result.data);
    try writeFile(init.io, options.source, source);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("usage: audio-compiler <input.wav> <pcm.bin> <sample.zig> <name> [--loop] [--stream] [--vadpcm]\n", .{});
    std.debug.print("audio-compiler: " ++ format ++ "\n", args);
    std.process.exit(1);
}

test "CLI requires explicit outputs and accepts only the loop switch" {
    try std.testing.expectError(error.Usage, parseArguments(&.{"audio-compiler"}));
    const args = [_][]const u8{ "audio-compiler", "in.wav", "out.pcm", "out.zig", "clip", "--loop" };
    try std.testing.expect((try parseArguments(&args)).loop);
    try std.testing.expect(!(try parseArguments(args[0..5])).loop);
    var invalid = args;
    invalid[5] = "--bad";
    try std.testing.expectError(error.UnknownOption, parseArguments(&invalid));
}

test "stream switches work in either order and reject duplicates" {
    const args = [_][]const u8{ "audio-compiler", "in", "data", "source", "track", "--stream", "--loop" };
    const result = try parseArguments(&args);
    try std.testing.expect(result.streamed and result.loop);
    var duplicate = args;
    duplicate[6] = "--stream";
    try std.testing.expectError(error.UnknownOption, parseArguments(&duplicate));
}

test "compression selection implies ROM storage and duplicate codec switches fail" {
    const args = [_][]const u8{ "audio-compiler", "in", "data", "source", "track", "--vadpcm" };
    const result = conversionOptions(try parseArguments(&args));
    try std.testing.expect(result.streamed and result.compression == .vadpcm);
    try std.testing.expect(conversionOptions(try parseArguments(args[0..5])).compression == .none);
    try std.testing.expect(conversionOptions(try parseArguments(&.{ "tool", "in", "data", "source", "name", "--stream" })).streamed);
    try std.testing.expectError(error.UnknownOption, parseArguments(&.{ "tool", "in", "data", "source", "name", "--vadpcm", "--vadpcm" }));
}
