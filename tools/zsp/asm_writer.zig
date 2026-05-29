const std = @import("std");
const ast = @import("ast.zig");

pub fn write(writer: *std.Io.Writer, functions: []const ast.Function) !void {
    try writer.writeAll(".set noreorder\n");
    try writer.writeAll(".set noat\n");
    try writer.writeAll(".text\n\n");

    for (functions) |function| {
        if (function.export_symbol) {
            try writer.print(".globl {s}\n", .{function.name});
        }
        try writer.print("{s}:\n", .{function.name});
        var context = FunctionContext{};
        try writeStatements(writer, &context, function.statements);
        try writer.writeByte('\n');
    }
}

const Symbol = struct {
    name: []const u8,
    reg: ?[]const u8,
    constant: ?i64,
};

const FunctionContext = struct {
    symbols: [64]Symbol = undefined,
    symbol_count: usize = 0,
    next_label: usize = 0,

    fn add(self: *FunctionContext, symbol: Symbol) !void {
        if (self.symbol_count >= self.symbols.len) return error.TooManySymbols;
        self.symbols[self.symbol_count] = symbol;
        self.symbol_count += 1;
    }

    fn lookup(self: *const FunctionContext, name: []const u8) !Symbol {
        var i = self.symbol_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.symbols[i].name, name)) return self.symbols[i];
        }
        return error.UnknownSymbol;
    }

    fn allocLabel(self: *FunctionContext) usize {
        const label = self.next_label;
        self.next_label += 1;
        return label;
    }
};

fn writeStatements(writer: *std.Io.Writer, context: *FunctionContext, statements: []const ast.Statement) anyerror!void {
    for (statements) |statement| {
        switch (statement) {
            .var_decl => |decl| try writeVarDecl(writer, context, decl),
            .add_assign => |assign| try writeAddAssign(writer, context, assign.name, assign.value),
            .store => |store| try writeStore(writer, context, store),
            .while_loop => |loop| try writeWhile(writer, context, loop),
            .asm_line => |asm_line| try writer.print("  {s}\n", .{asm_line}),
        }
    }
}

fn writeVarDecl(writer: *std.Io.Writer, context: *FunctionContext, decl: ast.VarDecl) !void {
    if (!std.mem.eql(u8, decl.data_type, "u16")) return error.UnsupportedType;

    if (decl.is_const) {
        try context.add(.{
            .name = decl.name,
            .reg = null,
            .constant = try valueAsImmediate(context, decl.value),
        });
        return;
    }

    const reg = decl.reg orelse return error.UnboundVariable;
    try writer.print("  addiu {s}, $zero, {d}\n", .{ reg, try valueAsImmediate(context, decl.value) });
    try context.add(.{
        .name = decl.name,
        .reg = reg,
        .constant = null,
    });
}

fn writeAddAssign(writer: *std.Io.Writer, context: *FunctionContext, name: []const u8, value: i64) !void {
    const symbol = try context.lookup(name);
    const reg = symbol.reg orelse return error.CannotAssignConst;
    try writer.print("  addiu {s}, {s}, {d}\n", .{ reg, reg, value });
}

fn writeStore(writer: *std.Io.Writer, context: *FunctionContext, store: anytype) !void {
    if (!std.mem.eql(u8, store.data_type, "u16")) return error.UnsupportedStoreType;
    const address = try context.lookup(store.address);
    const value = try context.lookup(store.value);
    const address_reg = address.reg orelse return error.StoreAddressMustBeRegister;
    const value_reg = value.reg orelse return error.StoreValueMustBeRegister;
    try writer.print("  sh {s}, 0({s})\n", .{ value_reg, address_reg });
}

fn writeWhile(writer: *std.Io.Writer, context: *FunctionContext, loop: anytype) anyerror!void {
    const label = context.allocLabel();
    const start_label = "L_zsp_while";
    const end_label = "L_zsp_endwhile";

    try writer.print("{s}_{d}:\n", .{ start_label, label });
    try writeConditionBranchToEnd(writer, context, loop.condition, end_label, label);
    try writeStatements(writer, context, loop.statements);
    try writer.print("  beq $zero, $zero, {s}_{d}\n", .{ start_label, label });
    try writer.writeAll("  nop\n");
    try writer.print("{s}_{d}:\n", .{ end_label, label });
}

fn writeConditionBranchToEnd(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    condition: ast.Condition,
    end_label: []const u8,
    label: usize,
) !void {
    if (condition.op != .lt) return error.UnsupportedCondition;

    const lhs = try context.lookup(condition.lhs);
    const lhs_reg = lhs.reg orelse return error.ConditionLhsMustBeRegister;
    switch (condition.rhs) {
        .number => |number| try writer.print("  sltiu $t9, {s}, {d}\n", .{ lhs_reg, number }),
        .ident => |name| {
            const rhs = try context.lookup(name);
            if (rhs.constant) |constant| {
                try writer.print("  sltiu $t9, {s}, {d}\n", .{ lhs_reg, constant });
            } else {
                const rhs_reg = rhs.reg orelse return error.ConditionRhsMustBeRegister;
                try writer.print("  sltu $t9, {s}, {s}\n", .{ lhs_reg, rhs_reg });
            }
        },
    }
    try writer.print("  beq $t9, $zero, {s}_{d}\n", .{ end_label, label });
    try writer.writeAll("  nop\n");
}

fn valueAsImmediate(context: *FunctionContext, value: ast.Value) !i64 {
    return switch (value) {
        .number => |number| number,
        .ident => |name| (try context.lookup(name)).constant orelse error.ExpectedConstant,
    };
}
