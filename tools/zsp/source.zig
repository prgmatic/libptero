//! A parsed source owns all AST allocations, including partially constructed
//! nodes on failure. Source bytes are borrowed and must outlive this value.
const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    functions: []ast.Function,
    imports: []ast.Import,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostic: *?parser_mod.Diagnostic) !Program {
        diagnostic.* = null;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var parser = try parser_mod.Parser.init(arena.allocator(), source);
        const functions = parser.parse() catch |err| {
            diagnostic.* = parser.diagnostic;
            return err;
        };
        return .{ .arena = arena, .functions = functions, .imports = try parser.takeImports() };
    }

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "owned parsing releases partial functions and nested expressions on error" {
    var diagnostic: ?parser_mod.Diagnostic = null;
    try std.testing.expectError(error.ParseError, Program.parse(std.testing.allocator, "fn valid() { reg a: u32 = 1; } fn invalid() { reg a: u32 = 1; a = (a + 2) * ; }", &diagnostic));
    try std.testing.expect(diagnostic != null);
    try std.testing.expectEqualStrings(";", diagnostic.?.token_text);
}

test "owned parsing provides functions imports and nested source locations" {
    var diagnostic: ?parser_mod.Diagnostic = null;
    var program = try Program.parse(std.testing.allocator, "const dep = import(\"dep.zsp\"); fn entry(value: u32) { if (value == 1) { rsp.nop(); } }", &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
    try std.testing.expectEqual(@as(usize, 1), program.imports.len);
    try std.testing.expectEqual(@as(usize, 2), program.functions[0].source_locations.len);
    try std.testing.expect(diagnostic == null);
}
