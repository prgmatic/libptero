//! Spellings of registers, types, vector operations, and builtins, and
//! literal parsing, shared by the parser files.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub fn parseRegister(tok: token.Token) ?ast.Register {
    inline for (std.meta.fields(ast.Register)) |field| {
        if (std.mem.eql(u8, tok.text[1..], field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

pub fn parseVectorRegister(tok: token.Token) ?ast.VectorRegister {
    if (tok.text.len != 4 or tok.text[1] != 'v') return null;
    const index = std.fmt.parseInt(u5, tok.text[2..], 10) catch return null;
    return @enumFromInt(index);
}

pub fn isVectorType(data_type: ast.DataType) bool {
    return data_type == .vec16 or data_type == .vec32;
}

pub fn isSignedType(data_type: ast.DataType) bool {
    return data_type == .i8 or data_type == .i16 or data_type == .i32;
}

pub fn scalarTypeSize(data_type: ast.DataType) i64 {
    return switch (data_type) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .dmem => 4,
        .vec16, .vec32 => unreachable,
    };
}

pub fn literalFitsType(value: i64, data_type: ast.DataType) bool {
    const range = literal_ranges.get(data_type) orelse return false;
    return value >= range[0] and value <= range[1];
}

/// Inclusive literal bounds per type; DMEM addresses may name its end.
const literal_ranges = std.EnumArray(ast.DataType, ?[2]i64).init(.{
    .u8 = .{ 0, std.math.maxInt(u8) },
    .u16 = .{ 0, std.math.maxInt(u16) },
    .u32 = .{ 0, std.math.maxInt(u32) },
    .dmem = .{ 0, 4096 },
    .i8 = .{ std.math.minInt(i8), std.math.maxInt(i8) },
    .i16 = .{ std.math.minInt(i16), std.math.maxInt(i16) },
    .i32 = .{ std.math.minInt(i32), std.math.maxInt(i32) },
    .vec16 = null,
    .vec32 = null,
});

pub fn parseVectorView(text: []const u8) ?ast.VectorView {
    inline for (std.meta.fields(ast.VectorView)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

/// A vector instruction by its RSP mnemonic, such as `vsubc` or `vrsqh`.
pub fn parseVectorOp(text: []const u8) ?ast.VectorOp {
    inline for (std.meta.fields(ast.VectorOp)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn isUnaryVectorOp(op: ast.VectorOp) bool {
    return switch (op) {
        .vrcp, .vrcpl, .vrcph, .vrsq, .vrsql, .vrsqh, .vmov => true,
        else => false,
    };
}

pub fn parseAccumulatorPart(text: []const u8) ?ast.AccumulatorPart {
    inline for (std.meta.fields(ast.AccumulatorPart)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn vectorControlRegisterForOperation(name: []const u8, comptime prefix: []const u8) ?ast.VectorControlRegister {
    if (std.mem.eql(u8, name, prefix ++ "CarryOut")) return .carry_out;
    if (std.mem.eql(u8, name, prefix ++ "CompareCode")) return .compare_code;
    if (std.mem.eql(u8, name, prefix ++ "CompareExtension")) return .compare_extension;
    return null;
}

pub fn vectorMemoryOperationForBuiltin(name: []const u8) ?ast.VectorMemoryOperation {
    const names = .{
        .{ "loadQuad", ast.VectorMemoryOperation.load_quad_lane },
        .{ "loadRight", ast.VectorMemoryOperation.load_right },
        .{ "storeRight", ast.VectorMemoryOperation.store_right },
        .{ "loadTranspose", ast.VectorMemoryOperation.load_transpose },
        .{ "loadPackedSigned", ast.VectorMemoryOperation.load_packed_signed },
        .{ "loadPackedUnsigned", ast.VectorMemoryOperation.load_packed_unsigned },
        .{ "storePackedSigned", ast.VectorMemoryOperation.store_packed_signed },
        .{ "storePackedUnsigned", ast.VectorMemoryOperation.store_packed_unsigned },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub fn vectorMemoryOperationHasLane(operation: ast.VectorMemoryOperation) bool {
    return switch (operation) {
        .load32, .store32, .load64, .store64, .store_packed_signed, .store_packed_unsigned, .load_quad_lane, .load_transpose => true,
        .load128, .store128, .load_packed_signed, .load_packed_unsigned, .load_right, .store_right => false,
    };
}

pub fn cp0NamedReadRegister(name: []const u8) ?u4 {
    const names = [_]struct { []const u8, u4 }{
        .{ "dmaMemoryAddress", 0 },
        .{ "dmaRdramAddress", 1 },
        .{ "spStatus", 4 },
        .{ "dmaFull", 5 },
        .{ "dmaBusy", 6 },
        .{ "rdpCommandStart", 8 },
        .{ "rdpCommandEnd", 9 },
        .{ "rdpStatus", 11 },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub fn cp0NamedWriteRegister(name: []const u8) ?u4 {
    const names = [_]struct { []const u8, u4 }{
        .{ "setDmaMemoryAddress", 0 },
        .{ "setDmaRdramAddress", 1 },
        .{ "startDmaRead", 2 },
        .{ "startDmaWrite", 3 },
        .{ "setSpStatus", 4 },
        .{ "setRdpCommandStart", 8 },
        .{ "setRdpCommandEnd", 9 },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub fn vectorAccessFromRef(value: ast.ValueRef) !?ast.VectorAccess {
    return switch (value) {
        .ident => |name| .{ .name = name },
        .bit_cast => null,
        .vector_access => |access| access,
        .number => null,
    };
}

const ParsedSwizzle = struct { element: u4, lane: ?u3 = null };

pub fn parseSwizzle(text: []const u8) ?ParsedSwizzle {
    for (swizzles) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
}

/// Element selectors: one lane (`.x`, which also names the lane), one lane
/// broadcast (`.xxxxxxxx`), or a pattern within each half.
const swizzles = [_]struct { []const u8, ParsedSwizzle }{
    .{ "x", .{ .element = 8, .lane = 0 } },         .{ "y", .{ .element = 9, .lane = 1 } },
    .{ "z", .{ .element = 10, .lane = 2 } },        .{ "w", .{ .element = 11, .lane = 3 } },
    .{ "X", .{ .element = 12, .lane = 4 } },        .{ "Y", .{ .element = 13, .lane = 5 } },
    .{ "Z", .{ .element = 14, .lane = 6 } },        .{ "W", .{ .element = 15, .lane = 7 } },
    .{ "xxxxxxxx", .{ .element = 8 } },             .{ "yyyyyyyy", .{ .element = 9 } },
    .{ "zzzzzzzz", .{ .element = 10 } },            .{ "wwwwwwww", .{ .element = 11 } },
    .{ "XXXXXXXX", .{ .element = 12 } },            .{ "YYYYYYYY", .{ .element = 13 } },
    .{ "ZZZZZZZZ", .{ .element = 14 } },            .{ "WWWWWWWW", .{ .element = 15 } },
    .{ "xyzwXYZW", .{ .element = 0 } },             .{ "xxzzXXZZ", .{ .element = 2 } },
    .{ "yywwYYWW", .{ .element = 3 } },             .{ "xxxxXXXX", .{ .element = 4 } },
    .{ "yyyyYYYY", .{ .element = 5 } },             .{ "zzzzZZZZ", .{ .element = 6 } },
    .{ "wwwwWWWW", .{ .element = 7 } },
};

pub fn parseDataTypeName(text: []const u8) ?ast.DataType {
    inline for (std.meta.fields(ast.DataType)) |field| {
        if (std.mem.eql(u8, text, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

/// Decimal or `0x` hexadecimal, with `_` or `'` digit separators.
pub fn parseNumber(tok: token.Token) !i64 {
    var buffer: [64]u8 = undefined;
    const digits = try withoutSeparators(tok.text, &buffer);
    if (std.ascii.startsWithIgnoreCase(digits, "0x")) return std.fmt.parseInt(i64, digits[2..], 16);
    return std.fmt.parseInt(i64, digits, 10);
}

fn withoutSeparators(text: []const u8, buffer: *[64]u8) ![]const u8 {
    if (text.len > buffer.len) return error.NumberTooLong;
    var len: usize = 0;
    for (text) |c| {
        if (c == '\'' or c == '_') continue;
        buffer[len] = c;
        len += 1;
    }
    return buffer[0..len];
}
