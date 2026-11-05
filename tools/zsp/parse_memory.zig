//! Memory operand syntax shared by loads and stores. Addresses, relocation
//! labels, and byte offsets are kept separate until instruction selection.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const Parser = @import("parser.zig").Parser;

pub const Operand = struct {
    address: ast.ValueRef,
    label: ?[]const u8 = null,
    offset: i64,

    pub fn parseBase(parser: *Parser, offset: i64, diagnostic_token: ?token.Token) !Operand {
        var operand = Operand{ .address = try parser.parseValueRef(), .offset = offset };
        if (try parser.eat(.plus)) {
            operand.label = switch (operand.address) {
                .ident => |name| name,
                else => return parser.fail(diagnostic_token orelse parser.current, .unexpected_token),
            };
            operand.address = try parser.parseValueRef();
        }
        return operand;
    }

    pub fn parseOffset(self: *Operand, parser: *Parser) !void {
        if (!try parser.eat(.comma)) return;
        self.offset += try parser.parseLiteralOffset();
    }
};

pub const LoadType = struct { data_type: ast.DataType, offset: i64 = 0 };

pub fn parseLoadType(parser: *Parser, implicit_vector: bool) !LoadType {
    if (implicit_vector) return .{ .data_type = .vec16 };
    const memory_type = try parser.parseMemoryType();
    _ = try parser.expect(.comma);
    return .{ .data_type = memory_type.data_type, .offset = memory_type.offset };
}
