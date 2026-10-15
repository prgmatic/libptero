const std = @import("std");
const ast = @import("ast.zig");
const asm_writer = @import("asm_writer.zig");
const diagnostics = @import("diagnostics.zig");
const parser_mod = @import("parser.zig");
const rspq = @import("rspq.zig");

const compiler = @import("root.zig");
const Loader = compiler.Loader;
const Module = @import("modules.zig").Module;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.Reported and err != error.InvalidArgs) reportCompileError(err);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    const options = @import("options.zig").parse(args[1..]) catch return usage();
    if (options.help) {
        printUsage();
        return;
    }
    const input_path = options.input.?;

    var loader = Loader{
        .allocator = allocator,
        .io = init.io,
        .module_dir = options.module_dir,
        .module_override_name = options.module_override_name,
        .module_override_path = options.module_override_path,
    };
    defer loader.deinit();
    const root = loader.load(input_path) catch |err| {
        if (loader.diagnostic) |diagnostic| reportParseDiagnostic(diagnostic);
        reportCompileError(err);
        return error.Reported;
    };
    const functions = loader.link(root) catch |err| {
        reportCompileError(err);
        return error.Reported;
    };
    defer allocator.free(functions);

    if (options.explain) {
        return writeExplain(init, allocator, input_path, functions, options.optimize);
    }

    var backend_diagnostic: asm_writer.Diagnostic = .{};
    var result = compiler.compile(allocator, functions, .{ .optimize = options.optimize }, &backend_diagnostic) catch |err| {
        reportBackendError(err, backend_diagnostic);
        return error.Reported;
    };
    defer result.deinit(allocator);
    const emitted = result.assembly;
    const stats = result.final_stats;
    if (options.report) {
        std.debug.print("zsp: {d} functions, {d} instructions, {d} IMEM bytes ({d} bytes free)\n", .{
            functions.len,
            stats.instruction_count,
            stats.text_bytes,
            4096 - stats.text_bytes,
        });
    }

    if (options.depfile) |depfile_path| {
        try writeDepfile(init.io, depfile_path, options.output orelse "zsp-output", loader.modules.items);
    }

    if (options.interface_output) |interface_path| {
        var interface_file = try std.Io.Dir.cwd().createFile(init.io, interface_path, .{});
        defer interface_file.close(init.io);
        var interface_buf: [4096]u8 = undefined;
        var interface_writer = interface_file.writer(init.io, &interface_buf);
        try asm_writer.writeInterface(&interface_writer.interface, functions, &backend_diagnostic);
        try interface_writer.interface.flush();
    }

    var out_buf: [4096]u8 = undefined;
    if (options.output) |output_path| {
        var out_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
        defer out_file.close(init.io);
        var writer = out_file.writer(init.io, &out_buf);
        try writer.interface.writeAll(emitted);
        try writer.interface.flush();
    } else {
        var writer = std.Io.File.stdout().writer(init.io, &out_buf);
        try writer.interface.writeAll(emitted);
        try writer.interface.flush();
    }
}

fn usage() error{InvalidArgs} {
    printUsage();
    return error.InvalidArgs;
}

fn printUsage() void {
    std.debug.print(
        "usage: zsp <input.zsp> [--module-dir <dir>] [--module-file <name> <file>] [--depfile <file>] [--interface <file>] [--no-optimize] [--report] [output.s]\n" ++
            "       zsp explain <input.zsp> [--module-dir <dir>] [--module-file <name> <file>] [--no-optimize]\n",
        .{},
    );
}

fn writeExplain(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    functions: []const ast.Function,
    optimize: bool,
) !void {
    var explain_report: asm_writer.ExplainReport = .{};
    var backend_diagnostic: asm_writer.Diagnostic = .{};
    var result = compiler.compile(allocator, functions, .{ .optimize = optimize, .explain = &explain_report }, &backend_diagnostic) catch |err| {
        reportBackendError(err, backend_diagnostic);
        return error.Reported;
    };
    defer result.deinit(allocator);
    const raw_stats = result.raw_stats;
    const final_stats = result.final_stats;
    const commands = try rspq.analyzeCommands(functions);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout.interface;
    try writer.print("zsp explain {s}\n", .{input_path});
    try explain_report.write(writer);
    try writer.writeAll("command layout:\n");
    var any_command = false;
    for (commands.entries, 0..) |entry, index| {
        const command = entry orelse continue;
        try writer.print("  {d}: {s}, {d} bytes\n", .{ index, command.function.source_name, command.size });
        any_command = true;
    }
    if (!any_command) try writer.writeAll("  none\n");
    try writer.print("size:\n  before optimization: {d} instructions, {d} IMEM text bytes\n", .{
        raw_stats.instruction_count,
        raw_stats.text_bytes,
    });
    try writer.print("  final: {d} instructions, {d} IMEM text bytes, {d} IMEM bytes free\n", .{
        final_stats.instruction_count,
        final_stats.text_bytes,
        4096 - final_stats.text_bytes,
    });
    try writer.print("optimization:\n  {s}; assembly {s}; {d} instructions removed or folded\n", .{
        if (optimize) "enabled" else "disabled",
        if (!result.changed) "unchanged" else "changed",
        raw_stats.instruction_count -| final_stats.instruction_count,
    });
    if (optimize) {
        try writer.writeAll("  passes: address folding, dead writes, polling loops, transfer slots, hazards, pipeline pairing\n");
    }
    try writer.flush();
}

fn reportCompileError(err: anyerror) void {
    if (err == error.ParseError) return;
    if (diagnostics.errorHint(err)) |hint| {
        std.debug.print("zsp: error: {s} ({s})\n", .{ hint, @errorName(err) });
    } else {
        std.debug.print("zsp: error: compilation failed ({s})\n", .{@errorName(err)});
    }
}

fn reportBackendError(err: anyerror, diagnostic: asm_writer.Diagnostic) void {
    if (diagnostic.location) |location| {
        std.debug.print("{s}:{d}:{d}: ", .{ diagnostic.source_path orelse "<source>", location.line, location.column });
    }
    reportCompileErrorInFunction(err, diagnostic.function_name, diagnostic.symbol_name);
}

fn reportCompileErrorInFunction(
    err: anyerror,
    function_name: ?[]const u8,
    symbol_name: ?[]const u8,
) void {
    if (err == error.ParseError) return;
    if (diagnostics.errorHint(err)) |hint| {
        if (function_name) |name| {
            if (symbol_name) |symbol| {
                std.debug.print("zsp: error in function '{s}' for '{s}': {s} ({s})\n", .{
                    name,
                    symbol,
                    hint,
                    @errorName(err),
                });
            } else {
                std.debug.print("zsp: error in function '{s}': {s} ({s})\n", .{ name, hint, @errorName(err) });
            }
            return;
        }
    }
    reportCompileError(err);
}

fn writeDepfile(io: std.Io, path: []const u8, target: []const u8, modules: []const Module) !void {
    var buffer: [4096]u8 = undefined;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer = file.writer(io, &buffer);
    try writer.interface.print("{s}:", .{target});
    for (modules) |module| try writer.interface.print(" {s}", .{module.path});
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn reportParseDiagnostic(diagnostic: @import("modules.zig").ParseDiagnostic) void {
    const detail = diagnostic.detail;
    std.debug.print("{s}:{d}:{d}: {s}: '{s}'\n", .{
        diagnostic.path,                    detail.line,       detail.column,
        parser_mod.errorString(detail.err), detail.token_text,
    });
}
