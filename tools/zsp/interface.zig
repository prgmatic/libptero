//! Writes importable `extern fn` declarations for a program's public
//! exports, including their inferred register-write contracts.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const registers = @import("registers.zig");

const Diagnostic = @import("explain.zig").Diagnostic;
const Writer = std.Io.Writer;

pub fn writeInterface(allocator: std.mem.Allocator, writer: *Writer, program: []const ast.Function, diagnostic: ?*Diagnostic) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const functions = try @import("param_alloc.zig").assign(arena.allocator(), program);
    var contracts = try analysis.FunctionClobberRegistry.init(allocator, functions, diagnostic);
    defer contracts.deinit();
    for (functions) |function| {
        if (!isInterfaceFunction(function)) continue;
        const contract = contracts.find(function.name) orelse return error.UnknownFunction;
        try writeDeclaration(writer, function, contract.scalar, contract.vector);
    }
}

fn isInterfaceFunction(function: ast.Function) bool {
    return function.public and function.export_symbol and !function.external and !function.inline_call;
}

fn writeDeclaration(writer: *Writer, function: ast.Function, scalar: u32, vector: u32) !void {
    try writer.print("// @zsp-symbol {s} {s}\n", .{ function.source_name, function.name });
    try writer.print("pub extern fn {s}(", .{function.source_name});
    for (function.parameters, 0..) |parameter, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeParameter(writer, parameter);
    }
    try writer.writeAll(") writes(");
    try writeRegisterList(writer, scalar, vector);
    try writer.writeByte(')');
    if (function.no_return) try writer.writeAll(" noreturn");
    try writer.writeAll(";\n\n");
}

fn writeParameter(writer: *Writer, parameter: ast.Parameter) !void {
    if (parameter.reg) |reg| try writer.print("reg({s}) ", .{registers.regName(reg)});
    if (parameter.vector_reg) |reg| try writer.print("reg(${s}) ", .{registers.vectorRegName(reg)});
    try writer.print("{s}: {s}", .{ parameter.name, @tagName(parameter.data_type) });
}

fn writeRegisterList(writer: *Writer, scalar: u32, vector: u32) !void {
    var separator: []const u8 = "";
    for (std.enums.values(ast.Register)) |reg| {
        if (scalar & registers.registerBit(reg) == 0) continue;
        try writer.print("{s}{s}", .{ separator, registers.regName(reg) });
        separator = ", ";
    }
    for (std.enums.values(ast.VectorRegister)) |reg| {
        if (vector & registers.vectorRegisterBit(reg) == 0) continue;
        try writer.print("{s}${s}", .{ separator, registers.vectorRegName(reg) });
        separator = ", ";
    }
}

test "inline calls contribute their expansion's registers, not their parameters'" {
    const allocator = std.testing.allocator;
    var parser = try @import("parser.zig").Parser.init(allocator,
        \\inline fn bump(a: u32, b: u32, c: u32, d: u32, e: u32) {
        \\  reg t: u32 = a + b;
        \\  e += t;
        \\  d -%= 1;
        \\}
        \\pub export fn entry() {
        \\  reg a: u32 = load(u32, 0);
        \\  reg b: u32 = load(u32, 4);
        \\  reg c: u32 = load(u32, 8);
        \\  reg d: u32 = load(u32, 12);
        \\  reg e: u32 = load(u32, 16);
        \\  bump(a, b, c, d, e);
        \\  store(u32, 0, e);
        \\  store(u32, 4, d);
        \\}
    );
    const functions = try parser.parse();
    defer ast.freeFunctions(allocator, functions);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeInterface(allocator, &output.writer, functions, null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "writes($t0, $t1, $t2, $t3, $t4, $t5);") != null);
}
