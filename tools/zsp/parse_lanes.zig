//! Lane-range transfers: `v[first..end] = load(T, address, offset);` and
//! `store(T, address, v[first..end], offset);`. One, two, four, or eight
//! lanes select the 2, 4, 8, or 16-byte RSP transfer starting at `first`.
//! A whole `vec32` transfers its integer lanes at `offset` and its fraction
//! lanes right after them.
const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const StatementList = Parser.StatementList;

/// `v[first..end] = load(...)` with more than one lane. Returns false for
/// other assignments.
pub fn lowerLoad(self: *Parser, list: *StatementList, assignment: ast.Assignment, location: ast.SourceLocation) !bool {
    if (assignment.destination_lane_count <= 1) return false;
    const load = plainLoad(assignment) orelse return self.fail(self.current, .invalid_lane_range_transfer);
    const transfer: Transfer = .{
        .vector = .{ .name = assignment.destination, .view = assignment.destination_view },
        .data_type = load.data_type,
        .lane = assignment.destination_lane.?,
        .count = assignment.destination_lane_count,
        .address = load.address,
        .offset = load.offset,
    };
    try transfer.append(self, list, location, .load);
    return true;
}

/// The load an assignment sets, unless it is packed, unaligned, or
/// label-relative.
fn plainLoad(assignment: ast.Assignment) ?ast.Load {
    if (assignment.lhs != .load or assignment.op != .set or assignment.rhs != null) return null;
    const load = assignment.lhs.load;
    if (load.label_offset != null or isSpecialLoad(load)) return null;
    return load;
}

fn isSpecialLoad(load: ast.Load) bool {
    return load.packed_u8 or load.packed_unsigned_u8 or load.unaligned;
}

/// `store(T, address, v[first..end], offset)` with more than one lane.
pub fn lowerStore(self: *Parser, list: *StatementList, statement: ast.Statement, location: ast.SourceLocation) !bool {
    if (statement != .store) return false;
    const store = statement.store;
    if (store.value != .vector_access or store.value.vector_access.lane_count <= 1) return false;
    if (store.label_offset != null) return self.fail(self.current, .invalid_lane_range_transfer);
    const vector = store.value.vector_access;
    const transfer: Transfer = .{
        .vector = .{ .name = vector.name, .view = vector.view },
        .data_type = store.data_type,
        .lane = vector.lane.?,
        .count = vector.lane_count,
        .address = store.address,
        .offset = store.offset,
    };
    try transfer.append(self, list, location, .store);
    return true;
}

const Direction = enum { load, store };

const Transfer = struct {
    vector: ast.VectorAccess,
    data_type: ast.DataType,
    lane: u3,
    count: u4,
    address: ast.ValueRef,
    offset: i64,

    fn append(self: Transfer, parser: *Parser, list: *StatementList, location: ast.SourceLocation, direction: Direction) !void {
        const operation = try self.selectOperation(parser, direction);
        if (try self.isWhole(parser)) {
            try self.appendHalf(parser, list, location, operation, .sint, 0);
            return self.appendHalf(parser, list, location, operation, .ufract, @as(i64, self.count) * 2);
        }
        try self.appendHalf(parser, list, location, operation, self.vector.view, 0);
    }

    /// Whether the transfer covers both halves of a `vec32`.
    fn isWhole(self: Transfer, parser: *Parser) !bool {
        const symbol = parser.lookupTypeSymbolInfo(self.vector.name) orelse return parser.fail(parser.current, .expected_vector_operand);
        if (!parser_mod.isVectorType(symbol.data_type)) return parser.fail(parser.current, .expected_vector_operand);
        const selected: ast.DataType = if (self.vector.view != null) .vec16 else symbol.data_type;
        if (selected != self.data_type) return parser.fail(parser.current, .invalid_lane_range_transfer);
        return selected == .vec32;
    }

    fn selectOperation(self: Transfer, parser: *Parser, direction: Direction) !ast.VectorMemoryOperation {
        if (!self.fitsVector()) return parser.fail(parser.current, .invalid_lane_range);
        const size = std.math.log2_int(u4, self.count);
        if (size == 0 or @as(u4, 1) << size != self.count) return parser.fail(parser.current, .invalid_lane_range);
        return operations.get(direction)[size - 1];
    }

    /// Within the register; a whole-register transfer starts at lane 0.
    fn fitsVector(self: Transfer) bool {
        if (@as(usize, self.lane) + self.count > 8) return false;
        return self.count != 8 or self.lane == 0;
    }

    fn appendHalf(
        self: Transfer,
        parser: *Parser,
        list: *StatementList,
        location: ast.SourceLocation,
        operation: ast.VectorMemoryOperation,
        view: ?ast.VectorView,
        offset: i64,
    ) !void {
        try list.append(parser.allocator, .{ .builtin = .{ .vector_memory = .{
            .operation = operation,
            .vector = .{ .name = self.vector.name, .view = view },
            .lane = self.lane,
            .address = self.address,
            .offset = self.offset + offset,
        } } }, location);
        parser.accumulator.term = null;
    }
};

/// The 4, 8, and 16-byte transfers.
const operations = std.EnumArray(Direction, [3]ast.VectorMemoryOperation).init(.{
    .load = .{ .load32, .load64, .load128 },
    .store = .{ .store32, .store64, .store128 },
});
