const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const optimizer = @import("../optimizer.zig");
const parser_mod = @import("../parser.zig");

const testing = std.testing;

const expectAsm = @import("support.zig").expectAsm;
const expectAsmError = @import("support.zig").expectAsmError;
const expectParseError = @import("support.zig").expectParseError;
const expectSyntaxRejected = @import("support.zig").expectSyntaxRejected;
const expectOptimizedAsm = @import("support.zig").expectOptimizedAsm;

test "module imports public functions and qualified calls parse" {
    var parser = try parser_mod.Parser.init(testing.allocator,
        \\const dma = import("dma.zsp");
        \\pub fn helper() {}
        \\export fn _start() noreturn {
        \\  dma.exec();
        \\  jump dma.exec();
        \\  tail dma.exec();
        \\}
    );
    const functions = try parser.parse();
    defer ast.freeFunctions(testing.allocator, functions);
    const imports = try parser.takeImports();
    defer testing.allocator.free(imports);

    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("dma", imports[0].name);
    try testing.expectEqualStrings("dma.zsp", imports[0].path);
    try testing.expect(functions[0].public);

    const call = functions[1].statements[0].call;
    try testing.expectEqualStrings("dma", call.module.?);
    try testing.expectEqualStrings("exec", call.name);
    const direct_goto = functions[1].statements[1].builtin.direct_goto;
    try testing.expectEqualStrings("dma", direct_goto.target.module.?);
    try testing.expectEqualStrings("exec", direct_goto.target.name);
    const tail = functions[1].statements[2].builtin.tail;
    try testing.expectEqualStrings("dma", tail.target.module.?);
    try testing.expectEqualStrings("exec", tail.target.name);
}

test "syntax rejects unsupported function modifier" {
    try expectParseError(
        \\fn test() interrupt {
        \\}
    , .unsupported_function_modifier, 1, 11);
}

test "syntax rejects invalid number literal" {
    try expectParseError(
        \\fn test() {
        \\  reg($t0) a: u32 = 0xzz;
        \\}
    , .invalid_number, 2, 21);
}

test "syntax rejects removed var keyword" {
    try expectParseError(
        \\fn test() {
        \\  var a: u16 = 0;
        \\}
    , .var_keyword_removed, 2, 3);
}
