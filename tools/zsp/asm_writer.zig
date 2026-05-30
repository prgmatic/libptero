const std = @import("std");
const ast = @import("ast.zig");

const compiler_scratch = "$at";

pub fn write(writer: *std.Io.Writer, functions: []const ast.Function) !void {
    try writer.writeAll(".set noreorder\n");
    try writer.writeAll(".set noat\n");
    try writer.writeAll(".text\n\n");

    for (functions) |function| {
        if (function.inline_call) continue;
        if (function.export_symbol) {
            try writer.print(".globl {s}\n", .{function.name});
        }
        try writer.print("{s}:\n", .{function.name});
        var context = FunctionContext{ .label_prefix = function.name };
        try writeStatements(writer, functions, &context, function.statements);
        if (!function.no_return) {
            try writer.writeAll("  jr $ra\n");
            try writer.writeAll("  nop\n");
        }
        try writer.writeByte('\n');
    }
}

const Symbol = struct {
    name: []const u8,
    reg: ?[]const u8,
    constant: ?i64,
};

const FunctionContext = struct {
    label_prefix: []const u8,
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

    fn pushScope(self: *FunctionContext) usize {
        return self.symbol_count;
    }

    fn popScope(self: *FunctionContext, scope: usize) void {
        self.symbol_count = scope;
    }
};

fn writeStatements(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    statements: []const ast.Statement,
) anyerror!void {
    for (statements) |statement| {
        switch (statement) {
            .var_decl => |decl| try writeVarDecl(writer, context, decl),
            .add_assign => |assign| try writeAddAssign(writer, context, assign.name, assign.value),
            .store => |store| try writeStore(writer, context, store),
            .call => |name| try writeCall(writer, functions, context, name),
            .while_loop => |loop| try writeWhile(writer, functions, context, loop),
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
    if (std.mem.eql(u8, reg, compiler_scratch)) return error.RegisterReservedForBackend;
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
    const address_reg = try valueAsAddressReg(writer, context, store.address);
    const value_reg = try valueAsStoreReg(writer, context, store.value);
    try writer.print("  sh {s}, 0({s})\n", .{ value_reg, address_reg });
}

fn writeCall(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    name: []const u8,
) anyerror!void {
    const function = findFunction(functions, name) orelse return error.UnknownFunction;
    if (function.inline_call) {
        const scope = context.pushScope();
        defer context.popScope(scope);
        try writeStatements(writer, functions, context, function.statements);
        return;
    }

    try writer.print("  jal {s}\n", .{name});
    try writer.writeAll("  nop\n");
}

fn writeWhile(
    writer: *std.Io.Writer,
    functions: []const ast.Function,
    context: *FunctionContext,
    loop: anytype,
) anyerror!void {
    const label = context.allocLabel();

    try writer.print("LABEL_{s}_while_{d}:\n", .{ context.label_prefix, label });
    try writeConditionBranchToEnd(writer, context, loop.condition, label);
    try writeStatements(writer, functions, context, loop.statements);
    try writer.print("  j LABEL_{s}_while_{d}\n", .{ context.label_prefix, label });
    try writer.writeAll("  nop\n");
    try writer.print("LABEL_{s}_whileend_{d}:\n", .{ context.label_prefix, label });
}

fn writeConditionBranchToEnd(
    writer: *std.Io.Writer,
    context: *FunctionContext,
    condition: ast.Condition,
    label: usize,
) !void {
    if (condition.op != .lt) return error.UnsupportedCondition;

    const lhs = try context.lookup(condition.lhs);
    const lhs_reg = lhs.reg orelse return error.ConditionLhsMustBeRegister;
    switch (condition.rhs) {
        .number => |number| try writer.print("  sltiu {s}, {s}, {d}\n", .{ compiler_scratch, lhs_reg, number }),
        .ident => |name| {
            const rhs = try context.lookup(name);
            if (rhs.constant) |constant| {
                try writer.print("  sltiu {s}, {s}, {d}\n", .{ compiler_scratch, lhs_reg, constant });
            } else {
                const rhs_reg = rhs.reg orelse return error.ConditionRhsMustBeRegister;
                try writer.print("  sltu {s}, {s}, {s}\n", .{ compiler_scratch, lhs_reg, rhs_reg });
            }
        },
    }
    try writer.print("  beq {s}, $zero, LABEL_{s}_whileend_{d}\n", .{ compiler_scratch, context.label_prefix, label });
    try writer.writeAll("  nop\n");
}

fn valueAsImmediate(context: *FunctionContext, value: ast.Value) !i64 {
    return switch (value) {
        .number => |number| number,
        .ident => |name| (try context.lookup(name)).constant orelse error.ExpectedConstant,
    };
}

fn valueAsAddressReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.Value) ![]const u8 {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            return symbol.reg orelse error.AddressMustBeRegister;
        },
        .number => |number| {
            if (number == 0) return "$zero";
            try loadImmediateInto(writer, "$t8", number);
            return "$t8";
        },
    }
}

fn valueAsStoreReg(writer: *std.Io.Writer, context: *FunctionContext, value: ast.Value) ![]const u8 {
    switch (value) {
        .ident => |name| {
            const symbol = try context.lookup(name);
            if (symbol.reg) |reg| return reg;
            return try loadImmediate(writer, symbol.constant orelse return error.StoreValueMustBeRegister);
        },
        .number => |number| return try loadImmediate(writer, number),
    }
}

fn loadImmediate(writer: *std.Io.Writer, value: i64) ![]const u8 {
    if (value == 0) return "$zero";
    try loadImmediateInto(writer, "$t9", value);
    return "$t9";
}

fn loadImmediateInto(writer: *std.Io.Writer, reg: []const u8, value: i64) !void {
    if (value >= 0 and value <= 0xffff) {
        try writer.print("  ori {s}, $zero, {d}\n", .{ reg, value });
    } else {
        try writer.print("  addiu {s}, $zero, {d}\n", .{ reg, value });
    }
}

fn findFunction(functions: []const ast.Function, name: []const u8) ?ast.Function {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}
