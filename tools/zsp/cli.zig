//! The `zsp` command: argument handling, file outputs, and diagnostics.
//! `main.zig` supplies the process's writers; tests supply buffers.
const std = @import("std");
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const compiler = @import("compiler.zig");
const diagnostics = @import("diagnostics.zig");
const modules = @import("modules.zig");
const parser_mod = @import("parser.zig");
const rspq = @import("rspq.zig");

const Writer = std.Io.Writer;
const Options = @import("options.zig").Options;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *Writer,
    stderr: *Writer,
};

pub const usage =
    "usage: zsp <input.zsp> [--module-dir <dir>] [--module-file <name> <file>] [--depfile <file>] [--interface <file>] [--no-optimize] [--report] [output.s]\n" ++
    "       zsp explain <input.zsp> [--module-dir <dir>] [--module-file <name> <file>] [--no-optimize]\n";

/// Runs the command for `args` (without argv[0]); returns the exit code.
pub fn main(context: Context, args: []const []const u8) u8 {
    run(context, args) catch |err| {
        if (err != error.Reported) reportCompileError(context.stderr, err);
        return 1;
    };
    return 0;
}

fn run(context: Context, args: []const []const u8) !void {
    const options = @import("options.zig").parse(args) catch {
        say(context.stderr, usage, .{});
        return error.Reported;
    };
    if (options.help) return say(context.stderr, usage, .{});
    var loader: modules.Loader = .{
        .allocator = context.allocator,
        .io = context.io,
        .module_dir = options.module_dir,
        .module_override_name = options.module_override_name,
        .module_override_path = options.module_override_path,
    };
    defer loader.deinit();
    const functions = try loadProgram(context, &loader, options.input.?);
    defer context.allocator.free(functions);
    if (options.explain) return writeExplain(context, options, functions);
    return writeOutputs(context, options, loader.modules.items, functions);
}

fn loadProgram(context: Context, loader: *modules.Loader, path: []const u8) ![]ast.Function {
    const root = loader.load(path) catch |err| {
        if (loader.diagnostic) |diagnostic| reportParseDiagnostic(context.stderr, diagnostic);
        return reported(context.stderr, err);
    };
    return loader.link(root) catch |err| reported(context.stderr, err);
}

// ---------------------------------------------------------------- outputs

fn writeOutputs(context: Context, options: Options, loaded: []const modules.Module, functions: []const ast.Function) !void {
    var diagnostic: codegen.Diagnostic = .{};
    var result = compiler.compile(context.allocator, functions, .{ .optimize = options.optimize }, &diagnostic) catch |err|
        return backendFailure(context.stderr, err, diagnostic);
    defer result.deinit(context.allocator);
    try writeSideOutputs(context, options, loaded, functions, &diagnostic, result.final_stats);
    if (options.output) |path| return writeFile(context.io, path, result.assembly);
    try context.stdout.writeAll(result.assembly);
}

/// The size report, dependency file, and C interface header.
fn writeSideOutputs(
    context: Context,
    options: Options,
    loaded: []const modules.Module,
    functions: []const ast.Function,
    diagnostic: *codegen.Diagnostic,
    stats: diagnostics.AssemblyReport,
) !void {
    if (options.report) say(context.stderr, "zsp: {d} functions, {d} instructions, {d} IMEM bytes ({d} bytes free)\n", .{
        functions.len,
        stats.instruction_count,
        stats.text_bytes,
        4096 - stats.text_bytes,
    });
    if (options.depfile) |path| try writeDepfile(context, path, options.output orelse "zsp-output", loaded);
    if (options.interface_output) |path| try writeInterfaceFile(context, path, functions, diagnostic);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// A Make rule naming every loaded module as a prerequisite.
fn writeDepfile(context: Context, path: []const u8, target: []const u8, loaded: []const modules.Module) !void {
    var rule: Writer.Allocating = .init(context.allocator);
    defer rule.deinit();
    try rule.writer.print("{s}:", .{target});
    for (loaded) |module| try rule.writer.print(" {s}", .{module.path});
    try rule.writer.writeByte('\n');
    try writeFile(context.io, path, rule.written());
}

fn writeInterfaceFile(context: Context, path: []const u8, functions: []const ast.Function, diagnostic: *codegen.Diagnostic) !void {
    var text: Writer.Allocating = .init(context.allocator);
    defer text.deinit();
    try @import("interface.zig").writeInterface(context.allocator, &text.writer, functions, diagnostic);
    try writeFile(context.io, path, text.written());
}

// ---------------------------------------------------------------- explain

fn writeExplain(context: Context, options: Options, functions: []const ast.Function) !void {
    var report: codegen.ExplainReport = .{};
    var diagnostic: codegen.Diagnostic = .{};
    const compile_options: compiler.Options = .{ .optimize = options.optimize, .explain = &report };
    var result = compiler.compile(context.allocator, functions, compile_options, &diagnostic) catch |err|
        return backendFailure(context.stderr, err, diagnostic);
    defer result.deinit(context.allocator);
    const writer = context.stdout;
    try writer.print("zsp explain {s}\n", .{options.input.?});
    try report.write(writer);
    try writeCommandLayout(writer, try rspq.analyzeCommands(functions));
    try writeOptimizationSummary(writer, result, options.optimize);
}

fn writeCommandLayout(writer: *Writer, commands: rspq.CommandAnalysis) !void {
    try writer.writeAll("command layout:\n");
    var any_command = false;
    for (commands.entries, 0..) |entry, index| {
        const command = entry orelse continue;
        try writer.print("  {d}: {s}, {d} bytes\n", .{ index, command.function.source_name, command.size });
        any_command = true;
    }
    if (!any_command) try writer.writeAll("  none\n");
}

fn writeOptimizationSummary(writer: *Writer, result: compiler.Result, optimize: bool) !void {
    const raw = result.raw_stats;
    const final = result.final_stats;
    try writer.print("size:\n  before optimization: {d} instructions, {d} IMEM text bytes\n", .{ raw.instruction_count, raw.text_bytes });
    try writer.print("  final: {d} instructions, {d} IMEM text bytes, {d} IMEM bytes free\n", .{
        final.instruction_count,
        final.text_bytes,
        4096 - final.text_bytes,
    });
    try writer.print("optimization:\n  {s}; assembly {s}; {d} instructions removed or folded\n", .{
        if (optimize) "enabled" else "disabled",
        if (result.changed) "changed" else "unchanged",
        raw.instruction_count -| final.instruction_count,
    });
    if (optimize) try writer.print("  passes: {s}\n", .{@import("optimizer.zig").pass_names});
}

// ------------------------------------------------------------ diagnostics

/// Diagnostics go to stderr; failing to write them is not itself an error.
fn say(writer: *Writer, comptime format: []const u8, args: anytype) void {
    writer.print(format, args) catch {};
}

fn reported(stderr: *Writer, err: anyerror) error{Reported} {
    reportCompileError(stderr, err);
    return error.Reported;
}

fn reportCompileError(stderr: *Writer, err: anyerror) void {
    if (err == error.ParseError) return;
    const hint = diagnostics.errorHint(err) orelse return say(stderr, "zsp: error: compilation failed ({s})\n", .{@errorName(err)});
    say(stderr, "zsp: error: {s} ({s})\n", .{ hint, @errorName(err) });
}

/// The source position, function, and value a backend error concerns,
/// then the values occupying registers when allocation failed.
fn backendFailure(stderr: *Writer, err: anyerror, diagnostic: codegen.Diagnostic) error{Reported} {
    if (diagnostic.location) |location| {
        say(stderr, "{s}:{d}:{d}: ", .{ diagnostic.source_path orelse "<source>", location.line, location.column });
    }
    reportErrorInFunction(stderr, err, diagnostic.function_name, diagnostic.symbol_name);
    diagnostic.writeLive(stderr) catch {};
    return error.Reported;
}

fn reportErrorInFunction(stderr: *Writer, err: anyerror, function_name: ?[]const u8, symbol_name: ?[]const u8) void {
    const hint = diagnostics.errorHint(err) orelse return reportCompileError(stderr, err);
    const name = function_name orelse return reportCompileError(stderr, err);
    const symbol = symbol_name orelse return say(stderr, "zsp: error in function '{s}': {s} ({s})\n", .{ name, hint, @errorName(err) });
    say(stderr, "zsp: error in function '{s}' for '{s}': {s} ({s})\n", .{ name, symbol, hint, @errorName(err) });
}

fn reportParseDiagnostic(stderr: *Writer, diagnostic: modules.ParseDiagnostic) void {
    const detail = diagnostic.detail;
    say(stderr, "{s}:{d}:{d}: {s}: '{s}'\n", .{
        diagnostic.path,
        detail.line,
        detail.column,
        parser_mod.errorString(detail.err),
        detail.token_text,
    });
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Harness = struct {
    stdout: Writer.Allocating,
    stderr: Writer.Allocating,
    temp: testing.TmpDir,

    fn init() Harness {
        return .{ .stdout = .init(testing.allocator), .stderr = .init(testing.allocator), .temp = testing.tmpDir(.{}) };
    }

    fn deinit(self: *Harness) void {
        self.stdout.deinit();
        self.stderr.deinit();
        self.temp.cleanup();
    }

    fn run(self: *Harness, args: []const []const u8) u8 {
        return main(.{ .allocator = testing.allocator, .io = testing.io, .stdout = &self.stdout.writer, .stderr = &self.stderr.writer }, args);
    }

    /// Writes `source` to `name` and returns its absolute path.
    fn file(self: *Harness, name: []const u8, source: []const u8) ![:0]u8 {
        try self.temp.dir.writeFile(testing.io, .{ .sub_path = name, .data = source });
        return self.temp.dir.realPathFileAlloc(testing.io, name, testing.allocator);
    }

    fn path(self: *Harness, name: []const u8) ![]u8 {
        const directory = try self.temp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(directory);
        return std.fs.path.join(testing.allocator, &.{ directory, name });
    }

    fn read(self: *Harness, name: []const u8) ![]u8 {
        return self.temp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
    }
};

const command_source =
    \\const commands = @rspq.commandTable();
    \\@rspq.command(0) fn first(reg($a0) value: u32) noreturn {
    \\  rsp.cp0.setSpStatus(value);
    \\  rsp.halt();
    \\}
;

test "usage is shown for no arguments and invalid ones" {
    var harness = Harness.init();
    defer harness.deinit();
    try testing.expectEqual(@as(u8, 0), harness.run(&.{}));
    try testing.expectEqual(@as(u8, 1), harness.run(&.{"--bogus"}));
    try testing.expectEqualStrings(usage ++ usage, harness.stderr.written());
}

test "compiling writes assembly, dependencies, interface, and a report" {
    var harness = Harness.init();
    defer harness.deinit();
    const input = try harness.file("commands.zsp", command_source);
    defer testing.allocator.free(input);
    const output = try harness.path("out.s");
    defer testing.allocator.free(output);
    const depfile = try harness.path("out.d");
    defer testing.allocator.free(depfile);
    const header = try harness.path("out.h");
    defer testing.allocator.free(header);
    try testing.expectEqual(@as(u8, 0), harness.run(&.{ input, "--depfile", depfile, "--interface", header, "--report", output }));
    const assembly = try harness.read("out.s");
    defer testing.allocator.free(assembly);
    try testing.expect(std.mem.indexOf(u8, assembly, "first:") != null);
    const rule = try harness.read("out.d");
    defer testing.allocator.free(rule);
    try testing.expect(std.mem.startsWith(u8, rule, output));
    try testing.expect(std.mem.indexOf(u8, rule, input) != null);
    testing.allocator.free(try harness.read("out.h"));
    try testing.expect(std.mem.endsWith(u8, harness.stderr.written(), " bytes free)\n"));
}

test "without an output path assembly goes to stdout" {
    var harness = Harness.init();
    defer harness.deinit();
    const input = try harness.file("commands.zsp", command_source);
    defer testing.allocator.free(input);
    try testing.expectEqual(@as(u8, 0), harness.run(&.{ input, "--no-optimize" }));
    try testing.expect(std.mem.indexOf(u8, harness.stdout.written(), "first:") != null);
}

test "explain lists commands, sizes, and optimization" {
    var harness = Harness.init();
    defer harness.deinit();
    const input = try harness.file("commands.zsp", command_source);
    defer testing.allocator.free(input);
    try testing.expectEqual(@as(u8, 0), harness.run(&.{ "explain", input }));
    const text = harness.stdout.written();
    try testing.expect(std.mem.indexOf(u8, text, "  0: first, 4 bytes\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  passes: ") != null);
    const plain = try harness.file("plain.zsp", "fn entry() noreturn { rsp.halt(); }");
    defer testing.allocator.free(plain);
    try testing.expectEqual(@as(u8, 0), harness.run(&.{ "explain", plain, "--no-optimize" }));
    try testing.expect(std.mem.indexOf(u8, harness.stdout.written(), "  none\n") != null);
    try testing.expect(std.mem.indexOf(u8, harness.stdout.written(), "disabled; assembly unchanged") != null);
}

test "parse, load, and link errors are reported once" {
    var harness = Harness.init();
    defer harness.deinit();
    const broken = try harness.file("broken.zsp", "fn entry() { reg value: u32 = ; }");
    defer testing.allocator.free(broken);
    try testing.expectEqual(@as(u8, 1), harness.run(&.{broken}));
    try testing.expect(std.mem.endsWith(u8, harness.stderr.written(), ":1:31: expected value: ';'\n"));
    harness.stderr.clearRetainingCapacity();
    const missing = try harness.path("missing.zsp");
    defer testing.allocator.free(missing);
    try testing.expectEqual(@as(u8, 1), harness.run(&.{missing}));
    try testing.expectEqualStrings("zsp: error: compilation failed (FileNotFound)\n", harness.stderr.written());
    harness.stderr.clearRetainingCapacity();
    const unknown = try harness.file("unknown.zsp", "fn entry() { other.run(); }");
    defer testing.allocator.free(unknown);
    try testing.expectEqual(@as(u8, 1), harness.run(&.{unknown}));
    try testing.expect(std.mem.indexOf(u8, harness.stderr.written(), "(UnknownModule)") != null);
}

test "backend errors name the function, the value, and live registers" {
    var harness = Harness.init();
    defer harness.deinit();
    const conflict = try harness.file("conflict.zsp",
        \\fn entry() noreturn {
        \\  reg($t0) first: u32 = 1;
        \\  reg($t0) second: u32 = 2;
        \\  rsp.cp0.setSpStatus(first);
        \\  rsp.cp0.setSpStatus(second);
        \\  rsp.halt();
        \\}
    );
    defer testing.allocator.free(conflict);
    try testing.expectEqual(@as(u8, 1), harness.run(&.{ "explain", conflict }));
    try testing.expect(std.mem.indexOf(u8, harness.stderr.written(), "error in function 'entry'") != null);
    harness.stderr.clearRetainingCapacity();
    try testing.expectEqual(error.Reported, backendFailure(&harness.stderr.writer, error.Unhinted, .{}));
    const named: codegen.Diagnostic = .{ .function_name = "f", .symbol_name = "x" };
    try testing.expectEqual(error.Reported, backendFailure(&harness.stderr.writer, error.RegisterAlreadyInUse, named));
    const text = harness.stderr.written();
    try testing.expect(std.mem.startsWith(u8, text, "zsp: error: compilation failed (Unhinted)\nzsp: error in function 'f' for 'x': "));
    try testing.expect(std.mem.endsWith(u8, text, " (RegisterAlreadyInUse)\n"));
}
