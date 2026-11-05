//! Vector products and the multiply accumulator.
//!
//! `acc = a * b;` starts a chain, `acc += a * b;` adds a product, and
//! `r = acc;` reads it. `r = a * b;` is a one-product chain. Operand types
//! pick the RSP multiplies: a `vec32` is a 16.16 pair, a `vec16` is an
//! integer unless a view says otherwise. The read is folded into the last
//! product, whose multiplies write their clamped slices straight into `r`;
//! the other multiplies write a scratch register.
const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const StatementList = Parser.StatementList;
const VectorAccess = ast.VectorAccess;
const VectorOp = ast.VectorOp;

/// The accumulator chain being parsed.
pub const Chain = struct {
    count: usize = 0,
    /// Whether `acc +=` may continue: a chain started in an open list.
    active: bool = false,
    started_in: ?*const StatementList = null,
    scratch: ?Scratch = null,
    /// The latest product, while nothing else has followed it.
    term: ?Term = null,

    /// Forgets anything that lives in `list`, which is finished.
    pub fn closeList(self: *Chain, list: *const StatementList) void {
        if (self.term) |term| if (term.list == list) {
            self.term = null;
        };
        if (self.scratch) |scratch| if (scratch.list == list) {
            self.scratch = null;
        };
        if (self.started_in == list) {
            self.active = false;
            self.started_in = null;
        }
    }
};

/// The register that non-final multiplies write.
const Scratch = struct {
    name: []const u8,
    list: *const StatementList,
    index: usize,
    uses: usize = 0,
};

const Term = struct {
    list: *const StatementList,
    start: usize,
    count: usize,
    fraction: ?usize = null,
    integer: ?usize = null,

    /// Notes where a multiply that leaves a result slice readable is.
    fn record(self: *Term, multiply: Multiply, position: usize) void {
        switch (multiply.output) {
            .none => {},
            .fraction => self.fraction = position,
            .integer => self.integer = position,
        }
    }

    /// The same product after one statement is inserted before it.
    fn shifted(self: Term) Term {
        var moved = self;
        moved.start += 1;
        if (moved.fraction) |*index| index.* += 1;
        if (moved.integer) |*index| index.* += 1;
        return moved;
    }
};

/// `acc = a * b;` and `acc += a * b;`. Returns false for other statements,
/// including any that use a variable the program itself named `acc`.
pub fn parseAccumulatorStatement(self: *Parser, list: *StatementList, location: ast.SourceLocation) !bool {
    if (!isAccumulator(self, self.current)) return false;
    const next = self.peek(1) orelse return false;
    if (next[0].tag != .equal and next[0].tag != .plus_equal) return false;
    const accumulator = try self.expect(.ident);
    const starts = try self.eat(.equal);
    if (!starts) _ = try self.expect(.plus_equal);
    const lhs = try parseOperand(self);
    _ = try self.expect(.star);
    const rhs = try parseOperand(self);
    _ = try self.expect(self.terminator);
    try appendProduct(self, list, location, .{ .lhs = lhs, .rhs = rhs, .at = accumulator }, starts);
    return true;
}

fn isAccumulator(self: *const Parser, tok: token.Token) bool {
    return tok.tag == .ident and std.mem.eql(u8, tok.text, "acc") and self.lookupTypeSymbolInfo("acc") == null;
}

/// Appends a parsed statement, lowering products, accumulator reads, and
/// lane ranges.
pub fn appendStatement(self: *Parser, list: *StatementList, statement: ast.Statement, location: ast.SourceLocation) anyerror!void {
    if (statement == .assignment) {
        if (try lowerAssignment(self, list, statement.assignment, location)) return;
    }
    if (statement == .var_decl) {
        if (try lowerDeclaration(self, list, statement.var_decl, location)) return;
    }
    if (try @import("parse_lanes.zig").lowerStore(self, list, statement, location)) return;
    try list.append(self.allocator, statement, location);
    self.accumulator.term = null;
}

fn lowerAssignment(self: *Parser, list: *StatementList, assignment: ast.Assignment, location: ast.SourceLocation) !bool {
    if (isAccumulatorRead(self, assignment)) {
        try readAccumulator(self, list, assignment);
        return true;
    }
    if (try productOf(self, assignment)) |product| {
        self.allocator.destroy(assignment.lhs.scalar_expression);
        try appendProduct(self, list, location, product, true);
        try readAccumulator(self, list, assignment);
        return true;
    }
    return @import("parse_lanes.zig").lowerLoad(self, list, assignment, location);
}

fn isAccumulatorRead(self: *const Parser, assignment: ast.Assignment) bool {
    if (assignment.op != .set or assignment.rhs != null) return false;
    return namesAccumulator(self, assignment.lhs);
}

fn namesAccumulator(self: *const Parser, value: ast.Value) bool {
    if (value != .ident or !std.mem.eql(u8, value.ident, "acc")) return false;
    return self.lookupTypeSymbolInfo("acc") == null;
}

/// `reg r: T = acc;` and `reg r: T = a * b;` for a vector `r`: the
/// declaration moves before the multiplies that write it.
/// Any other expression initializer becomes a declaration and an assignment.
fn lowerDeclaration(self: *Parser, list: *StatementList, declaration: ast.VarDecl, location: ast.SourceLocation) !bool {
    const value = declaration.value orelse return false;
    const split: Split = .{ .list = list, .location = location, .declaration = declaration };
    if (namesAccumulator(self, value)) return split.beforeProduct(self);
    if (value != .scalar_expression) return false;
    if (try productOf(self, split.read())) |product| return split.withProduct(self, product);
    return split.thenAssign(self);
}

/// A declaration split from its initializer.
const Split = struct {
    list: *StatementList,
    location: ast.SourceLocation,
    declaration: ast.VarDecl,

    fn declared(self: Split) ast.Statement {
        var declaration = self.declaration;
        declaration.value = null;
        declaration.allow_undefined_read = true;
        return .{ .var_decl = declaration };
    }

    fn read(self: Split) ast.Assignment {
        return .{ .destination = self.declaration.name, .lhs = self.declaration.value.?, .op = .set, .rhs = null };
    }

    fn thenAssign(self: Split, parser: *Parser) !bool {
        try self.list.append(parser.allocator, self.declared(), self.location);
        try appendStatement(parser, self.list, .{ .assignment = self.read() }, self.location);
        return true;
    }

    /// `reg r: T = acc;`: declared before the product that writes it.
    fn beforeProduct(self: Split, parser: *Parser) !bool {
        if (!parser_mod.isVectorType(self.declaration.data_type)) return parser.fail(parser.current, .expected_vector_operand);
        const term = try adjacentTerm(parser, self.list);
        try self.list.insert(parser.allocator, term.start, self.declared(), self.location);
        parser.accumulator.term = term.shifted();
        try readAccumulator(parser, self.list, self.read());
        return true;
    }

    fn withProduct(self: Split, parser: *Parser, product: Product) !bool {
        parser.allocator.destroy(self.declaration.value.?.scalar_expression);
        try self.list.append(parser.allocator, self.declared(), self.location);
        try appendProduct(parser, self.list, self.location, product, true);
        try readAccumulator(parser, self.list, self.read());
        return true;
    }
};

/// The product just appended to `list`.
fn adjacentTerm(self: *Parser, list: *const StatementList) !Term {
    const term = self.accumulator.term orelse return self.fail(self.current, .accumulator_read_not_adjacent);
    if (term.list != list or term.start + term.count != list.len()) return self.fail(self.current, .accumulator_read_not_adjacent);
    return term;
}

const Product = struct { lhs: VectorAccess, rhs: VectorAccess, at: token.Token };

/// `r = a * b;` where `r` is a vector.
fn productOf(self: *Parser, assignment: ast.Assignment) !?Product {
    const expression = multiplication(assignment) orelse return null;
    if (!isVectorName(self, assignment.destination)) return null;
    return .{
        .lhs = vectorValue(expression.lhs) orelse return self.fail(self.current, .expected_vector_operand),
        .rhs = vectorValue(expression.rhs) orelse return self.fail(self.current, .expected_vector_operand),
        .at = self.current,
    };
}

fn multiplication(assignment: ast.Assignment) ?*ast.ScalarExpression {
    if (assignment.op != .set or assignment.rhs != null or assignment.lhs != .scalar_expression) return null;
    const expression = assignment.lhs.scalar_expression;
    return if (expression.op == .mul) expression else null;
}

fn isVectorName(self: *const Parser, name: []const u8) bool {
    const symbol = self.lookupTypeSymbolInfo(name) orelse return false;
    return parser_mod.isVectorType(symbol.data_type);
}

fn vectorValue(value: ast.Value) ?VectorAccess {
    return switch (value) {
        .ident => |name| .{ .name = name },
        .vector_access => |access| access,
        else => null,
    };
}

fn parseOperand(self: *Parser) !VectorAccess {
    const at = self.current;
    return try parser_mod.vectorAccessFromRef(try self.parseValueRef()) orelse self.fail(at, .expected_vector_operand);
}

// ------------------------------------------------------------- products

/// One multiply of a product and the result slice it leaves readable.
const Multiply = struct {
    part: Part,
    lhs: VectorAccess,
    rhs: VectorAccess,
    output: enum { none, fraction, integer } = .none,
};

/// The partial-product family; the first multiply of a chain uses the
/// form that clears the accumulator.
const Part = enum {
    low,
    middle,
    middle_swapped,
    high,
    fractional,

    fn op(self: Part, first: bool) VectorOp {
        const forms = part_ops.get(self);
        return if (first) forms[0] else forms[1];
    }
};

/// Each part's clearing and accumulating multiply.
const part_ops = std.EnumArray(Part, [2]VectorOp).init(.{
    .low = .{ .vmudl, .vmadl },
    .middle = .{ .vmudm, .vmadm },
    .middle_swapped = .{ .vmudn, .vmadn },
    .high = .{ .vmudh, .vmadh },
    .fractional = .{ .vmulf, .vmacf },
});

const Operand = struct {
    access: VectorAccess,
    /// A whole `vec32`: integer and fraction halves.
    wide: bool,

    fn integer(self: Operand) VectorAccess {
        return half(self.access, .sint);
    }

    fn fraction(self: Operand) VectorAccess {
        return half(self.access, .ufract);
    }

    fn view(self: Operand) ast.VectorView {
        return self.access.view orelse .sint;
    }
};

fn half(access: VectorAccess, view: ast.VectorView) VectorAccess {
    var selected = access;
    selected.view = view;
    return selected;
}

fn classify(self: *Parser, access: VectorAccess, at: token.Token) !Operand {
    const symbol = self.lookupTypeSymbolInfo(access.name) orelse return self.fail(at, .expected_vector_operand);
    if (!parser_mod.isVectorType(symbol.data_type)) return self.fail(at, .expected_vector_operand);
    return .{ .access = access, .wide = symbol.data_type == .vec32 and access.view == null };
}

const Multiplies = struct {
    items: [4]Multiply = undefined,
    len: usize = 0,

    fn add(self: *Multiplies, multiply: Multiply) void {
        self.items[self.len] = multiply;
        self.len += 1;
    }

    fn addAll(self: *Multiplies, all: []const Multiply) void {
        for (all) |multiply| self.add(multiply);
    }

    fn slice(self: *const Multiplies) []const Multiply {
        return self.items[0..self.len];
    }
};

/// The multiplies of `lhs * rhs`, lowest partial product first.
fn multiplies(self: *Parser, product: Product) !Multiplies {
    const pair: Pair = .{ .lhs = try classify(self, product.lhs, product.at), .rhs = try classify(self, product.rhs, product.at) };
    const shape: usize = @as(usize, @intFromBool(pair.lhs.wide)) * 2 + @intFromBool(pair.rhs.wide);
    return shapes[shape](pair) orelse self.fail(product.at, .invalid_vector_product);
}

const Pair = struct { lhs: Operand, rhs: Operand };

/// Products by which operands are whole `vec32` pairs: neither, the right
/// only, the left only, or both.
const shapes = [4]*const fn (Pair) ?Multiplies{ &narrowProduct, &narrowByWide, &wideByNarrow, &wideProduct };

fn wideProduct(pair: Pair) ?Multiplies {
    var result: Multiplies = .{};
    result.addAll(&.{
        .{ .part = .low, .lhs = pair.lhs.fraction(), .rhs = pair.rhs.fraction() },
        .{ .part = .middle, .lhs = pair.lhs.integer(), .rhs = pair.rhs.fraction() },
        .{ .part = .middle_swapped, .lhs = pair.lhs.fraction(), .rhs = pair.rhs.integer(), .output = .fraction },
        .{ .part = .high, .lhs = pair.lhs.integer(), .rhs = pair.rhs.integer(), .output = .integer },
    });
    return result;
}

/// A 16.16 pair times integers.
fn wideByNarrow(pair: Pair) ?Multiplies {
    if (pair.rhs.view() != .sint) return null;
    var result: Multiplies = .{};
    result.addAll(&.{
        .{ .part = .middle_swapped, .lhs = pair.lhs.fraction(), .rhs = pair.rhs.access, .output = .fraction },
        .{ .part = .high, .lhs = pair.lhs.integer(), .rhs = pair.rhs.access, .output = .integer },
    });
    return result;
}

/// Integers times a 16.16 pair; only the integer result is readable.
fn narrowByWide(pair: Pair) ?Multiplies {
    if (pair.lhs.view() != .sint) return null;
    var result: Multiplies = .{};
    result.addAll(&.{
        .{ .part = .middle, .lhs = pair.lhs.access, .rhs = pair.rhs.fraction() },
        .{ .part = .high, .lhs = pair.lhs.access, .rhs = pair.rhs.integer(), .output = .integer },
    });
    return result;
}

fn narrowProduct(pair: Pair) ?Multiplies {
    const part = narrowPart(pair.lhs.view(), pair.rhs.view()) orelse return null;
    var result: Multiplies = .{};
    result.add(.{ .part = part, .lhs = pair.lhs.access, .rhs = pair.rhs.access });
    return result;
}

/// The multiply for two `vec16` operands by their views.
fn narrowPart(lhs: ast.VectorView, rhs: ast.VectorView) ?Part {
    for (narrow_parts) |entry| {
        if (entry[0] == lhs and entry[1] == rhs) return entry[2];
    }
    return null;
}

const narrow_parts = [_]struct { ast.VectorView, ast.VectorView, Part }{
    .{ .sint, .sint, .high },
    .{ .sint, .ufract, .middle },
    .{ .ufract, .sint, .middle_swapped },
    .{ .ufract, .ufract, .low },
    .{ .sfract, .sfract, .fractional },
};

fn appendProduct(self: *Parser, list: *StatementList, location: ast.SourceLocation, product: Product, starts: bool) !void {
    const parts = try multiplies(self, product);
    if (starts) startChain(self, list);
    if (!self.accumulator.active) return self.fail(product.at, .accumulator_not_started);
    const scratch = try scratchRegister(self, list, location);
    var term: Term = .{ .list = list, .start = list.len(), .count = parts.len };
    for (parts.slice(), 0..) |multiply, index| {
        term.record(multiply, list.len());
        const op = multiply.part.op(starts and index == 0);
        try list.append(self.allocator, multiplyInto(scratch.name, null, op, multiply), location);
        scratch.uses += 1;
    }
    self.accumulator.term = term;
}

fn startChain(self: *Parser, list: *const StatementList) void {
    self.accumulator.active = true;
    self.accumulator.started_in = list;
    self.accumulator.scratch = null;
}

/// The chain's scratch register, declared before its first use.
fn scratchRegister(self: *Parser, list: *StatementList, location: ast.SourceLocation) !*Scratch {
    if (self.accumulator.scratch) |*scratch| return scratch;
    self.accumulator.count += 1;
    const name = try self.generatedName("acc#{d}", .{self.accumulator.count});
    self.accumulator.scratch = .{ .name = name, .list = list, .index = list.len() };
    try declareScratch(self, list, location, name);
    return &self.accumulator.scratch.?;
}

fn declareScratch(self: *Parser, list: *StatementList, location: ast.SourceLocation, name: []const u8) !void {
    try list.append(self.allocator, .{ .var_decl = .{
        .is_const = false,
        .allow_undefined_read = true,
        .data_type = .vec16,
        .reg = null,
        .name = name,
        .value = null,
    } }, location);
}

fn multiplyInto(destination: []const u8, view: ?ast.VectorView, op: VectorOp, multiply: Multiply) ast.Statement {
    return .{ .assignment = .{
        .destination = destination,
        .destination_view = view,
        .lhs = .{ .vector_operation = .{ .op = op, .lhs = multiply.lhs, .rhs = multiply.rhs } },
        .op = .set,
        .rhs = null,
    } };
}

// ------------------------------------------------------------------ reads

/// `r = acc;` right after a product: its multiplies write `r` instead of
/// the scratch register.
fn readAccumulator(self: *Parser, list: *StatementList, assignment: ast.Assignment) !void {
    const term = try adjacentTerm(self, list);
    if (assignment.destination_lane != null) return self.fail(self.current, .unsupported_destination_swizzle);
    const read: Read = .{
        .list = list,
        .term = term,
        .destination = assignment.destination,
        .data_type = try vectorType(self, assignment.destination),
        .view = assignment.destination_view,
    };
    releaseScratch(self, list, try read.apply(self));
    self.accumulator.term = null;
}

fn vectorType(self: *Parser, name: []const u8) !ast.DataType {
    const symbol = self.lookupTypeSymbolInfo(name) orelse return self.fail(self.current, .expected_vector_operand);
    if (!parser_mod.isVectorType(symbol.data_type)) return self.fail(self.current, .expected_vector_operand);
    return symbol.data_type;
}

/// Retargets a product's final multiplies at the read's destination.
const Read = struct {
    list: *StatementList,
    term: Term,
    destination: []const u8,
    data_type: ast.DataType,
    view: ?ast.VectorView,

    /// The number of multiplies retargeted: both halves of a whole `vec32`,
    /// else the selected fraction or the last multiply.
    fn apply(self: Read, parser: *Parser) !usize {
        if (self.data_type == .vec32 and self.view == null) return self.whole(parser);
        self.retarget(self.selected(), self.view);
        return 1;
    }

    fn whole(self: Read, parser: *Parser) !usize {
        const fraction = self.term.fraction orelse return parser.fail(parser.current, .accumulator_read_requires_fraction);
        self.retarget(fraction, .ufract);
        self.retarget(self.term.integer.?, .sint);
        return 2;
    }

    fn selected(self: Read) usize {
        const last = self.term.start + self.term.count - 1;
        if (self.data_type != .vec32 or !selectsFraction(self.view)) return last;
        return self.term.fraction orelse last;
    }

    fn retarget(self: Read, index: usize, view: ?ast.VectorView) void {
        const assignment = &self.list.statements.items[index].assignment;
        assignment.destination = self.destination;
        assignment.destination_view = view;
    }
};

fn selectsFraction(view: ?ast.VectorView) bool {
    const selected = view orelse return false;
    return selected == .sfract or selected == .ufract;
}

/// Drops the scratch declaration when no multiply writes it any more.
fn releaseScratch(self: *Parser, list: *StatementList, retargeted: usize) void {
    const scratch = &(self.accumulator.scratch.?);
    scratch.uses -= retargeted;
    if (scratch.uses != 0 or scratch.list != list) return;
    list.remove(scratch.index);
    self.accumulator.scratch = null;
}
