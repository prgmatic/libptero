//! Values returned by inline functions. `inline fn f(x: u32) u32 { ...;
//! return expr; }` gains a hidden last parameter bound to the caller's
//! destination, and its final `return expr;` assigns that parameter. A
//! caller writes `reg y: u32 = f(x);` or `y = f(x);`, which become a call
//! passing `y`. A named result, `inline fn f(x: u32) result: u32 { result
//! = ...; }`, lets the body build the value in the caller's register.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;

/// The hidden parameter that carries an inline function's result.
pub const Result = struct { name: []const u8, data_type: ast.DataType, named: bool };

pub const ReturnType = struct { name: ?[]const u8 = null, data_type: ast.DataType };

/// `T` or `name: T` after an inline function's parameters. Other functions
/// return nothing; their callers pass values in registers.
pub fn parseReturnType(self: *Parser, inline_call: bool) !?ReturnType {
    if (!atReturnType(self)) return null;
    if (!inline_call) return self.fail(self.current, .return_value_requires_inline);
    const name = try parseResultName(self);
    return .{ .name = name, .data_type = try self.parseDataType(try self.expect(.ident)) };
}

/// A data type name, or `name:` naming the result.
fn atReturnType(self: *const Parser) bool {
    if (self.current.tag != .ident) return false;
    return namedResultAhead(self) or parser_mod.parseDataTypeName(self.current.text) != null;
}

fn parseResultName(self: *Parser) !?[]const u8 {
    if (!namedResultAhead(self)) return null;
    const name = try self.expect(.ident);
    _ = try self.expect(.colon);
    return name.text;
}

fn namedResultAhead(self: *const Parser) bool {
    const next = (self.peek(1) orelse return false)[0];
    return next.tag == .colon;
}

pub fn resultParameter(self: *Parser, function_name: []const u8, return_type: ReturnType) !ast.Parameter {
    const name = return_type.name orelse try self.generatedName("{s}#result", .{function_name});
    try self.addTypeSymbol(name, return_type.data_type);
    return .{ .name = name, .data_type = return_type.data_type, .reg = null, .automatic = true };
}

/// `return expr;`: allowed once, as the last statement of the body.
pub fn parseReturnValue(self: *Parser) !ast.Statement {
    const result = self.inline_result orelse return self.fail(self.current, .return_value_requires_inline);
    if (self.block_depth != 1 or self.returned_value) return self.fail(self.current, .return_value_not_last);
    const statement = try @import("parse_statements.zig").parseAssignedValueTo(self, result.name);
    if (self.current.tag != .r_brace) return self.fail(self.current, .return_value_not_last);
    self.returned_value = true;
    return statement;
}

/// Whether a function returning a value ended with `return expr;`.
pub fn checkReturned(self: *Parser, name: token.Token) !void {
    const result = self.inline_result orelse return;
    if (!result.named and !self.returned_value) return self.fail(name, .missing_return_value);
}

/// `name(` or `module.name(` where `name` is not a builtin value.
pub fn atValueCall(self: *const Parser) bool {
    if (self.current.tag != .ident) return false;
    const next = self.peek(3) orelse return false;
    if (next[0].tag == .l_paren) return !isBuiltinValue(self.current.text);
    return isModuleCall(next) and !isNamespace(self.current.text);
}

/// `.name(` after a module alias.
fn isModuleCall(next: [3]token.Token) bool {
    return next[0].tag == .dot and next[1].tag == .ident and next[2].tag == .l_paren;
}

fn isNamespace(text: []const u8) bool {
    return std.mem.eql(u8, text, "rsp") or std.mem.eql(u8, text, "dmem") or std.mem.eql(u8, text, "code");
}

const builtin_values = std.StaticStringMap(void).initComptime(.{
    .{"signedLessThan"},             .{"bitCast"},            .{"load"},
    .{"loadUnaligned"},              .{"loadVectorBytes"},    .{"loadVectorBytesUnsigned"},
    .{"accumulator"},                .{"vectorShiftLeft8"},   .{"vectorShiftRightArithmetic"},
    .{"vectorShiftRightLogical"},    .{"sizeOf"},             .{"offsetOf"},
});

fn isBuiltinValue(text: []const u8) bool {
    if (builtin_values.has(text)) return true;
    return parser_mod.parseVectorOp(text) != null or parser_mod.explicitAccumulatorPart(text) != null;
}

/// The call `f(args..., destination)`.
pub fn parseValueCall(self: *Parser, destination: []const u8) !ast.Statement {
    const first = try self.expect(.ident);
    var module: ?[]const u8 = null;
    var name = first.text;
    if (try self.eat(.dot)) {
        module = first.text;
        name = (try self.expect(.ident)).text;
    }
    _ = try self.expect(.l_paren);
    const arguments = try self.parseCallArguments();
    const with_result = try self.allocator.alloc(ast.ValueRef, arguments.len + 1);
    @memcpy(with_result[0..arguments.len], arguments);
    with_result[arguments.len] = .{ .ident = destination };
    self.allocator.free(arguments);
    _ = try self.expect(self.terminator);
    return .{ .call = .{ .module = module, .name = name, .arguments = with_result } };
}
