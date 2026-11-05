//! A parsed source owns all AST allocations, including partially constructed
//! nodes on failure. Source bytes are borrowed and must outlive this value.
const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

var generated_text: [64]u8 = undefined;

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
            if (diagnostic.*) |*detail| detail.token_text = outliveArena(source, detail.token_text);
            return err;
        };
        return .{ .arena = arena, .functions = functions, .imports = try parser.takeImports() };
    }

    /// Generated token names (unrolled or array element names) live in the
    /// arena freed on error; such text is copied out, truncated if long.
    fn outliveArena(source: []const u8, text: []const u8) []const u8 {
        const begin = @intFromPtr(source.ptr);
        const at = @intFromPtr(text.ptr);
        if (at >= begin and at + text.len <= begin + source.len) return text;
        const len = @min(text.len, generated_text.len);
        @memcpy(generated_text[0..len], text[0..len]);
        return generated_text[0..len];
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

test "diagnostics on generated names outlive the parser" {
    var diagnostic: ?parser_mod.Diagnostic = null;
    try std.testing.expectError(error.ParseError, Program.parse(std.testing.allocator,
        \\fn f() { inline for (0..2) |i| { reg x: u32 = 0; x = x + ; } }
    , &diagnostic));
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
