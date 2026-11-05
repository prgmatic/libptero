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

    /// `address` or `label + index`, where `label` is a data label or a
    /// `const` and `index` is any scalar register.
    pub fn parseBase(parser: *Parser, offset: i64, diagnostic_token: ?token.Token) !Operand {
        if (isLabelPlusIndex(parser)) {
            const label = try parser.expect(.ident);
            _ = try parser.expect(.plus);
            return .{ .address = try parser.parseValueRef(), .label = label.text, .offset = offset };
        }
        const operand = Operand{ .address = try parser.parseValueRef(), .offset = offset };
        if (parser.current.tag == .plus) return parser.fail(diagnostic_token orelse parser.current, .unexpected_token);
        return operand;
    }

    fn isLabelPlusIndex(parser: *const Parser) bool {
        if (parser.current.tag != .ident) return false;
        const next = parser.peek(1) orelse return false;
        return next[0].tag == .plus;
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
