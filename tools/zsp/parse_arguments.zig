//! Call arguments. A plain value passes as is; an expression such as
//! `helper(a + 4, -b)` is hoisted into a temporary declared just before the
//! statement that makes the call, so callees still receive registers.
const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const values = @import("parse_values.zig");
const Parser = parser_mod.Parser;

/// One argument, or every element of a register array passed by name.
pub fn appendArgument(self: *Parser, arguments: *std.ArrayList(ast.ValueRef)) !void {
    if (arrayLength(self)) |len| {
        const array = try self.expect(.ident);
        for (0..len) |index| try arguments.append(self.allocator, .{ .ident = try self.elementName(array.text, index) });
        return;
    }
    try arguments.append(self.allocator, try parseArgument(self));
}

/// The length of a register array named alone as an argument.
fn arrayLength(self: *const Parser) ?usize {
    if (self.current.tag != .ident) return null;
    const next = (self.peek(1) orelse return null)[0];
    if (next.tag != .comma and next.tag != .r_paren) return null;
    const symbol = self.lookupTypeSymbolInfo(self.current.text) orelse return null;
    return symbol.array_len;
}

pub fn parseArgument(self: *Parser) !ast.ValueRef {
    if (startsExpression(self)) return hoist(self, try self.parseScalarExpression(0));
    const ref = try self.parseValueRef();
    if (parser_mod.binaryPrecedence(self.current.tag) == null) return ref;
    return hoist(self, try values.continueScalarExpression(self, parser_mod.valueFromRef(ref), 0));
}

/// `(a + b)` or `-a`; a negative literal is still a plain value.
fn startsExpression(self: *const Parser) bool {
    if (self.current.tag == .l_paren) return true;
    if (self.current.tag != .minus) return false;
    const next = (self.peek(1) orelse return false)[0];
    return next.tag != .number;
}

fn hoist(self: *Parser, value: ast.Value) !ast.ValueRef {
    if (value != .scalar_expression) return parser_mod.valueRefFromValue(value);
    const data_type = expressionType(self, value) orelse return self.fail(self.current, .expected_data_type);
    const name = try self.generatedName("argument#{d}", .{self.generated_names.items.len});
    try self.addTypeSymbol(name, data_type);
    try self.hoisted_arguments.append(self.allocator, .{ .var_decl = .{
        .is_const = false,
        .data_type = data_type,
        .reg = null,
        .name = name,
        .value = value,
    } });
    return .{ .ident = name };
}

/// The type of the first named operand; expression operands share a type.
fn expressionType(self: *const Parser, value: ast.Value) ?ast.DataType {
    return switch (value) {
        .ident => |name| (self.lookupTypeSymbolInfo(name) orelse return null).data_type,
        .scalar_expression => |expression| expressionType(self, expression.lhs) orelse expressionType(self, expression.rhs),
        else => null,
    };
}
