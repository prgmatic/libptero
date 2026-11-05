//! Typed DMEM pointers. `*T` is a `dmem` address whose pointee the parser
//! remembers, so `p.field` and `p.*` become loads and stores with the
//! field's type and offset. Storage labels point at their declared type.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const Pointee = Parser.Pointee;

/// The pointee after `*`: a scalar or vector type, or a packed struct.
pub fn parsePointee(self: *Parser) !Pointee {
    const type_name = try self.expect(.ident);
    if (parser_mod.parseDataTypeName(type_name.text)) |data_type| return .{ .scalar = data_type };
    if (self.findPackedStruct(type_name.text) == null) return self.fail(type_name, .unknown_packed_struct);
    return .{ .packed_struct = type_name.text };
}

/// What a storage declaration's label points at.
pub fn storagePointee(storage_type: ast.DataStorageType) Pointee {
    return switch (storage_type) {
        .scalar => |data_type| .{ .scalar = data_type },
        .packed_struct => |name| .{ .packed_struct = name },
    };
}

pub fn samePointee(lhs: Pointee, rhs: Pointee) bool {
    return switch (lhs) {
        .scalar => |data_type| rhs == .scalar and rhs.scalar == data_type,
        .packed_struct => |name| rhs == .packed_struct and std.mem.eql(u8, rhs.packed_struct, name),
    };
}

/// Whether `.field` or `.*` follows `name`, a typed pointer just consumed.
pub fn isDereference(self: *const Parser, name: token.Token) bool {
    if (self.current.tag != .dot or !isPointer(self, name)) return false;
    const next = self.peek(1) orelse return false;
    return selectsPlace(next[0]);
}

/// Whether the current token is a typed pointer followed by a dereference.
pub fn isDereferenceAhead(self: *const Parser) bool {
    if (!isPointer(self, self.current)) return false;
    const next = self.peek(2) orelse return false;
    return next[0].tag == .dot and selectsPlace(next[1]);
}

fn isPointer(self: *const Parser, name: token.Token) bool {
    if (name.tag != .ident) return false;
    const symbol = self.lookupTypeSymbolInfo(name.text) orelse return false;
    return symbol.pointee != null;
}

fn selectsPlace(tok: token.Token) bool {
    return tok.tag == .ident or tok.tag == .star;
}

/// The memory a dereference names.
const Place = struct { data_type: ast.DataType, offset: i64 };

/// `.field` or `.*` after the pointer's name.
fn parsePlace(self: *Parser, pointer: token.Token) !Place {
    const pointee = self.lookupTypeSymbolInfo(pointer.text).?.pointee.?;
    _ = try self.expect(.dot);
    if (try self.eat(.star)) return switch (pointee) {
        .scalar => |data_type| .{ .data_type = data_type, .offset = 0 },
        .packed_struct => self.fail(pointer, .expected_pointer_field),
    };
    const field_name = try self.expect(.ident);
    if (pointee != .packed_struct) return self.fail(field_name, .expected_pointer_field);
    const declaration = self.findPackedStruct(pointee.packed_struct).?;
    const field = @import("parse_declarations.zig").packedField(declaration, field_name.text) orelse
        return self.fail(field_name, .unknown_packed_struct_field);
    return .{ .data_type = field.data_type, .offset = field.offset };
}

/// `p.field` or `p.*` as a value: a load.
pub fn parseLoad(self: *Parser) !ast.Value {
    const pointer = try self.expect(.ident);
    const place = try parsePlace(self, pointer);
    return .{ .load = .{ .data_type = place.data_type, .address = .{ .ident = pointer.text }, .offset = place.offset } };
}

/// `p.field = value;` or `p.* = value;` after the pointer's name: a store.
pub fn parseStore(self: *Parser, pointer: token.Token) !ast.Statement {
    const place = try parsePlace(self, pointer);
    _ = try self.expect(.equal);
    self.allow_lane_range = true;
    const value = self.parseValueRef();
    self.allow_lane_range = false;
    const stored = try value;
    _ = try self.expect(self.terminator);
    return .{ .store = .{
        .data_type = place.data_type,
        .address = .{ .ident = pointer.text },
        .value = stored,
        .offset = place.offset,
    } };
}
