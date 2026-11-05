const std = @import("std");
const interp = @import("rsp_interp");

const usage =
    \\Usage: rsp-interp <program.rsp> [--limit <instructions>] [--rdram-size <bytes>]
    \\                  [--dmem-out <file>] [--rdp-out <file>]
    \\Runs a packed RSP program from its entry point until BREAK, an SP halt,
    \\or the instruction limit, then reports instructions and estimated cycles.
    \\
;

const Options = struct {
    program: []const u8,
    limit: u64 = 10_000_000,
    rdram_size: usize = 8 * 1024 * 1024,
    dmem_out: ?[]const u8 = null,
    rdp_out: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| fatal("{s} (run with --help for usage)", .{@errorName(err)});
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    const report = try dispatch(init.io, init.gpa, std.Io.Dir.cwd(), try parseArguments(args)) orelse
        return std.debug.print("{s}", .{usage});
    std.debug.print("{f}\n", .{report});
}

/// Runs the selected program, or returns null when usage was requested.
fn dispatch(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, options: ?Options) !?Report {
    const selected = options orelse return null;
    return try execute(io, a, dir, selected);
}

fn parseArguments(args: []const []const u8) !?Options {
    if (args.len < 2 or isHelp(args[1])) return null;
    var options: Options = .{ .program = args[1] };
    var index: usize = 2;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingOptionValue;
        try applyOption(&options, args[index], args[index + 1]);
    }
    return options;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn applyOption(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--limit")) {
        options.limit = try std.fmt.parseInt(u64, value, 0);
    } else if (std.mem.eql(u8, name, "--rdram-size")) {
        options.rdram_size = try std.fmt.parseInt(usize, value, 0);
    } else if (std.mem.eql(u8, name, "--dmem-out")) {
        options.dmem_out = value;
    } else if (std.mem.eql(u8, name, "--rdp-out")) {
        options.rdp_out = value;
    } else return error.UnknownOption;
}

test "argument parsing" {
    const testing = std.testing;
    try testing.expectEqual(null, try parseArguments(&.{"rsp-interp"}));
    try testing.expectEqual(null, try parseArguments(&.{ "rsp-interp", "-h" }));
    const options = (try parseArguments(&.{ "rsp-interp", "a.rsp", "--limit", "0x10", "--rdram-size", "64", "--dmem-out", "d", "--rdp-out", "r" })).?;
    try testing.expectEqualStrings("a.rsp", options.program);
    try testing.expectEqual(@as(u64, 16), options.limit);
    try testing.expectEqual(@as(usize, 64), options.rdram_size);
    try testing.expectEqualStrings("d", options.dmem_out.?);
    try testing.expectEqualStrings("r", options.rdp_out.?);
    try testing.expectError(error.MissingOptionValue, parseArguments(&.{ "rsp-interp", "a.rsp", "--limit" }));
    try testing.expectError(error.UnknownOption, parseArguments(&.{ "rsp-interp", "a.rsp", "--nope", "1" }));
}

const Report = struct {
    result: interp.RunResult,
    pc: u32,
    rdp_bytes: usize,

    pub fn format(self: Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("stop={s} pc=0x{x:0>3} instructions={d} estimated_cycles={d} rdp_bytes={d}", .{
            @tagName(self.result.stop), self.pc, self.result.instructions, self.result.cycles, self.rdp_bytes,
        });
    }
};

fn execute(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, options: Options) !Report {
    const blob = try dir.readFileAlloc(io, options.program, a, .limited(1 << 20));
    defer a.free(blob);
    const rdram = try a.alloc(u8, options.rdram_size);
    defer a.free(rdram);
    @memset(rdram, 0);
    var rdp_bytes: std.Io.Writer.Allocating = .init(a);
    defer rdp_bytes.deinit();

    var machine = interp.Machine.init(rdram);
    machine.rdp_output = &rdp_bytes.writer;
    machine.load(interp.Program.fromBlob(blob));
    machine.start(machine.pc);
    const result = try machine.run(options.limit);
    try writeOptional(io, dir, options.dmem_out, &machine.dmem);
    try writeOptional(io, dir, options.rdp_out, rdp_bytes.written());
    return .{ .result = result, .pc = machine.pc, .rdp_bytes = rdp_bytes.written().len };
}

fn writeOptional(io: std.Io, dir: std.Io.Dir, path: ?[]const u8, bytes: []const u8) !void {
    const selected = path orelse return;
    try dir.writeFile(io, .{ .sub_path = selected, .data = bytes });
}

test "executes a packed program and writes requested outputs" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Header: text_len=4, data/commands/state offsets at the end of text.
    var blob: [28]u8 = @splat(0);
    std.mem.writeInt(u16, blob[0..2], 4, .big);
    for ([_]usize{ 4, 10, 18 }) |field| std.mem.writeInt(u16, blob[field..][0..2], 28, .big);
    std.mem.writeInt(u32, blob[24..28], interp.encode.brk, .big);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "p.rsp", .data = &blob });
    const report = try execute(testing.io, testing.allocator, tmp.dir, .{
        .program = "p.rsp",
        .rdram_size = 64,
        .dmem_out = "dmem.bin",
        .rdp_out = "rdp.bin",
    });
    try testing.expectEqual(interp.Stop.broke, report.result.stop);
    try testing.expectEqual(@as(u64, 1), report.result.instructions);
    const dmem = try tmp.dir.readFileAlloc(testing.io, "dmem.bin", testing.allocator, .limited(8192));
    defer testing.allocator.free(dmem);
    try testing.expectEqual(@as(usize, 4096), dmem.len);
    try testing.expectEqual(null, try dispatch(testing.io, testing.allocator, tmp.dir, null));
    const plain = (try dispatch(testing.io, testing.allocator, tmp.dir, .{ .program = "p.rsp", .rdram_size = 64 })).?;
    var text: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "stop=broke pc=0x004 instructions=1 estimated_cycles=1 rdp_bytes=0",
        try std.fmt.bufPrint(&text, "{f}", .{plain}),
    );
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("rsp-interp: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
