const std = @import("std");
const mksprite = @import("mksprite");

const Cli = struct {
    options: mksprite.Options = .{},
    output_dir: []const u8 = ".",
    verbose: bool = false,
    inputs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Cli, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var cli = parseArgs(allocator, args[1..]) catch |err| {
        if (err == error.HelpRequested or err == error.MissingInput) {
            printUsage();
            return;
        }
        std.debug.print("mksprite: {s}\n\n", .{errorMessage(err)});
        printUsage();
        std.process.exit(1);
    };
    defer cli.deinit(allocator);

    for (cli.inputs.items) |input| {
        convertFile(init.io, allocator, input, cli) catch |err| {
            std.debug.print("mksprite: {s}: {s}\n", .{ input, errorMessage(err) });
            std.process.exit(1);
        };
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Cli {
    var cli = Cli{};
    errdefer cli.deinit(allocator);
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!std.mem.startsWith(u8, arg, "-")) {
            try cli.inputs.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            cli.verbose = true;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--gamma")) {
            cli.options.gamma_correct = true;
        } else {
            index = try parseValueOption(args, index, &cli);
        }
    }
    if (cli.inputs.items.len == 0) return error.MissingInput;
    return cli;
}

fn parseValueOption(args: []const []const u8, index: usize, cli: *Cli) !usize {
    if (index + 1 == args.len) return error.MissingOptionValue;
    const option = args[index];
    const value = args[index + 1];
    if (std.mem.eql(u8, option, "-o") or std.mem.eql(u8, option, "--output")) {
        cli.output_dir = value;
    } else if (std.mem.eql(u8, option, "-f") or std.mem.eql(u8, option, "--format")) {
        cli.options.format = if (std.ascii.eqlIgnoreCase(value, "auto")) null else mksprite.Format.parse(value) orelse return error.InvalidFormat;
    } else if (std.mem.eql(u8, option, "-m") or std.mem.eql(u8, option, "--mipmap")) {
        cli.options.mipmap = parseMipmap(value) orelse return error.InvalidMipmap;
    } else if (std.mem.eql(u8, option, "-D") or std.mem.eql(u8, option, "--dither")) {
        cli.options.dither = parseDither(value) orelse return error.InvalidDither;
    } else {
        return error.UnknownOption;
    }
    return index + 1;
}

fn parseMipmap(value: []const u8) ?mksprite.Mipmap {
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "box")) return .box;
    return null;
}

fn parseDither(value: []const u8) ?mksprite.Dither {
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "ordered")) return .ordered;
    return null;
}

fn convertFile(io: std.Io, allocator: std.mem.Allocator, input: []const u8, cli: Cli) !void {
    const source = try readFile(io, allocator, input);
    defer allocator.free(source);
    const result = try mksprite.convertPng(allocator, source, cli.options);
    defer result.deinit(allocator);

    const output = try outputPath(allocator, cli.output_dir, input);
    defer allocator.free(output);
    try writeFile(io, output, result.bytes);
    if (cli.verbose) std.debug.print("{s}: {d}x{d} {s}, {d} level(s), {d} bytes -> {s}\n", .{
        input, result.width, result.height, result.format.name(), result.levels, result.bytes.len, output,
    });
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

fn outputPath(allocator: std.mem.Allocator, directory: []const u8, input: []const u8) ![]u8 {
    const basename = std.fs.path.basename(input);
    const stem = if (std.fs.path.extension(basename).len > 0)
        basename[0 .. basename.len - std.fs.path.extension(basename).len]
    else
        basename;
    const filename = try std.fmt.allocPrint(allocator, "{s}.sprite", .{stem});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ directory, filename });
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingInput => "no input PNG files were provided",
        error.MissingOptionValue => "an option is missing its value",
        error.UnknownOption => "unknown option",
        error.InvalidFormat => "invalid format (use AUTO, RGBA16, RGBA32, YUV16, CI4, CI8, I4, I8, IA4, IA8, or IA16)",
        error.InvalidMipmap => "invalid mipmap algorithm (use NONE or BOX)",
        error.InvalidDither => "invalid dither algorithm (use NONE or ORDERED)",
        error.TooManyColors => "indexed image has too many colors; pre-quantize it or choose RGBA16",
        error.YuvRequiresEvenWidth => "YUV16 images must have an even width",
        else => @errorName(err),
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage: mksprite [options] <input.png>...
        \\
        \\Options:
        \\  -o, --output <dir>     Output directory (default: current directory)
        \\  -f, --format <format>  AUTO, RGBA16, RGBA32, YUV16, CI4, CI8,
        \\                         I4, I8, IA4, IA8, or IA16 (default: AUTO)
        \\  -m, --mipmap <algo>    NONE or BOX (default: NONE)
        \\  -D, --dither <algo>    NONE or ORDERED (default: NONE)
        \\  -g, --gamma            Convert color channels to linear space
        \\  -v, --verbose          Describe each generated sprite
        \\  -h, --help             Show this help
        \\
    , .{});
}

test "CLI accepts case-insensitive values" {
    var cli = try parseArgs(std.testing.allocator, &.{ "-f", "rgba16", "-m", "box", "image.png" });
    defer cli.deinit(std.testing.allocator);
    try std.testing.expectEqual(mksprite.Format.rgba16, cli.options.format.?);
    try std.testing.expectEqual(mksprite.Mipmap.box, cli.options.mipmap);
}

test "CLI diagnostics are human readable" {
    try std.testing.expectEqualStrings("unknown option", errorMessage(error.UnknownOption));
}
