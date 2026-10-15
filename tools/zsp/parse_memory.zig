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
        if (isLegacyLabel(parser.current)) return self.parseLegacyLabel(parser);
        self.offset += try parser.parseLiteralOffset();
    }

    fn parseLegacyLabel(self: *Operand, parser: *Parser) !void {
        if (self.label != null) return parser.fail(parser.current, .unexpected_token);
        self.label = (try parser.expect(.ident)).text;
        if (try parser.eat(.comma)) self.offset += try parser.parseLiteralOffset();
    }
};

fn isLegacyLabel(current: token.Token) bool {
    return current.tag == .ident and !std.mem.eql(u8, current.text, "offsetOf");
}

pub const LoadType = struct { data_type: ast.DataType, offset: i64 = 0 };

pub fn parseLoadType(parser: *Parser, implicit_vector: bool) !LoadType {
    if (implicit_vector) return .{ .data_type = .vec16 };
    const memory_type = try parser.parseMemoryType();
    if (memory_type.half_vector or memory_type.quarter_vector) return parser.fail(parser.current, .expected_data_type);
    _ = try parser.expect(.comma);
    return .{ .data_type = memory_type.data_type, .offset = memory_type.offset };
}

pub fn parseWordLane(parser: *Parser, partial_words: bool) !?u3 {
    if (!partial_words) return null;
    if (!try parser.eat(.comma)) return 0;
    const lane_token = parser.current;
    const lane = try parser.parseLiteralOffset();
    return std.math.cast(u3, lane) orelse parser.fail(lane_token, .invalid_vector_lane);
}
