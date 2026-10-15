const std = @import("std");
const ast = @import("../ast.zig");
const asm_writer = @import("../asm_writer.zig");
const asm_optimizer = @import("../asm_optimizer.zig");
const parser_mod = @import("../parser.zig");

const testing = std.testing;

pub fn expectAsm(source: []const u8, expected: []const u8) !void {
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);

    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try asm_writer.write(&output.writer, functions);

    const actual = try output.toOwnedSlice();
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

pub fn expectParseError(source: []const u8, err: parser_mod.ErrorType, line: usize, column: usize) !void {
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const result = parser.parse();
    try testing.expectError(error.ParseError, result);
    try testing.expect(parser.diagnostic != null);
    try testing.expectEqual(err, parser.diagnostic.?.err);
    try testing.expectEqual(line, parser.diagnostic.?.line);
    try testing.expectEqual(column, parser.diagnostic.?.column);
}

pub fn expectAsmError(source: []const u8, expected_err: anyerror) !void {
    var parser = try parser_mod.Parser.init(testing.allocator, source);
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);

    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try testing.expectError(expected_err, asm_writer.write(&output.writer, functions));
}

pub fn expectSyntaxRejected(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try parser_mod.Parser.init(arena.allocator(), source);
    const functions = parser.parse() catch return;
    _ = functions;
    return error.ExpectedSyntaxError;
}

pub fn expectOptimizedAsm(input: []const u8, expected: []const u8) !void {
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try asm_optimizer.writeOptimized(testing.allocator, &output.writer, input);
    const actual = try output.toOwnedSlice();
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}
