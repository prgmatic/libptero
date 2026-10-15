const std = @import("std");

pub const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    module_dir: ?[]const u8 = null,
    module_override_name: ?[]const u8 = null,
    module_override_path: ?[]const u8 = null,
    depfile: ?[]const u8 = null,
    interface_output: ?[]const u8 = null,
    optimize: bool = true,
    report: bool = false,
    explain: bool = false,
    help: bool = false,
};

const Arguments = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(self: *Arguments) ?[]const u8 {
        if (self.index == self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }

    fn value(self: *Arguments) ![]const u8 {
        return self.next() orelse error.InvalidArgs;
    }
};

/// Arguments exclude argv[0]. Parsing has no IO and rejects invalid output
/// combinations before opening the input or creating any generated file.
pub fn parse(args: []const []const u8) !Options {
    var options: Options = .{};
    if (args.len == 0) return .{ .help = true };
    var arguments = Arguments{ .items = args };
    if (std.mem.eql(u8, args[0], "explain")) {
        options.explain = true;
        arguments.index = 1;
    }
    while (arguments.next()) |arg| try consume(&options, arg, &arguments);
    try validate(options);
    return options;
}

fn consume(options: *Options, arg: []const u8, arguments: *Arguments) !void {
    if (consumeFlag(options, arg)) return;
    if (try consumePath(options, arg, arguments)) return;
    if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArgs;
    try consumePositional(options, arg);
}

fn consumeFlag(options: *Options, arg: []const u8) bool {
    const flags = .{
        .{ "--no-optimize", "optimize", false },
        .{ "--report", "report", true },
        .{ "--help", "help", true },
        .{ "-h", "help", true },
    };
    inline for (flags) |flag| {
        if (std.mem.eql(u8, arg, flag[0])) {
            @field(options, flag[1]) = flag[2];
            return true;
        }
    }
    return false;
}

fn consumePath(options: *Options, arg: []const u8, arguments: *Arguments) !bool {
    const paths = .{
        .{ "--module-dir", "module_dir" },
        .{ "--depfile", "depfile" },
        .{ "--interface", "interface_output" },
    };
    inline for (paths) |path| {
        if (std.mem.eql(u8, arg, path[0])) {
            @field(options, path[1]) = try arguments.value();
            return true;
        }
    }
    if (!std.mem.eql(u8, arg, "--module-file")) return false;
    options.module_override_name = try arguments.value();
    options.module_override_path = try arguments.value();
    return true;
}

fn consumePositional(options: *Options, arg: []const u8) !void {
    if (options.input == null) {
        options.input = arg;
    } else if (options.output == null) {
        options.output = arg;
    } else {
        return error.InvalidArgs;
    }
}

fn validate(options: Options) !void {
    if (options.help) return;
    if (options.input == null) return error.InvalidArgs;
    if (!options.explain) return;
    try validateExplainOutput(options);
}

fn validateExplainOutput(options: Options) !void {
    if (options.output != null) return error.InvalidArgs;
    if (options.depfile != null) return error.InvalidArgs;
    if (options.interface_output != null) return error.InvalidArgs;
}

test "CLI options retain paths and compilation controls" {
    const options = try parse(&.{ "input.zsp", "--module-dir", "lib", "--module-file", "resident.zsp", "resident.zspi", "--depfile", "deps.d", "--interface", "api.zspi", "--no-optimize", "--report", "output.s" });
    try std.testing.expectEqualStrings("input.zsp", options.input.?);
    try std.testing.expectEqualStrings("output.s", options.output.?);
    try std.testing.expectEqualStrings("lib", options.module_dir.?);
    try std.testing.expectEqualStrings("resident.zsp", options.module_override_name.?);
    try std.testing.expectEqualStrings("resident.zspi", options.module_override_path.?);
    try std.testing.expectEqualStrings("deps.d", options.depfile.?);
    try std.testing.expectEqualStrings("api.zspi", options.interface_output.?);
    try std.testing.expect(!options.optimize);
    try std.testing.expect(options.report);
    try std.testing.expect((try parse(&.{ "explain", "input.zsp" })).explain);
}

test "CLI help and malformed arguments" {
    try std.testing.expect((try parse(&.{})).help);
    try std.testing.expect((try parse(&.{"--help"})).help);
    try std.testing.expect((try parse(&.{"-h"})).help);
    const invalid = [_][]const []const u8{
        &.{"--module-dir"},                             &.{ "--module-file", "name" },      &.{"--module-file"},
        &.{"--depfile"},                                &.{"--interface"},                  &.{"--unknown"},
        &.{ "a", "b", "c" },                            &.{ "explain", "input", "output" }, &.{ "explain", "input", "--depfile", "dep" },
        &.{ "explain", "input", "--interface", "api" }, &.{"explain"},
    };
    for (invalid) |args| try std.testing.expectError(error.InvalidArgs, parse(args));
}
