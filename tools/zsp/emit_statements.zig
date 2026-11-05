//! Statement dispatch and transfer delay slots.
const std = @import("std");
const ast = @import("ast.zig");
const common = @import("emit_common.zig");
const calls = @import("emit_calls.zig");
const control = @import("emit_control.zig");
const builtins = @import("emit_builtins.zig");
const memory = @import("emit_memory.zig");
const scalar = @import("emit_scalar.zig");

const Gen = common.Gen;
const Statement = ast.Statement;
const Tag = std.meta.Tag(Statement);

pub fn writeStatements(g: Gen, statements: []const Statement) anyerror!void {
    var index: usize = 0;
    while (index < statements.len) : (index += 1) {
        if (g.context.diagnostic) |diagnostic| diagnostic.selectStatement(g.functions, &statements[index]);
        if (calls.isContinuationPairAt(statements, index)) {
            try calls.writeContinuationPair(g, statements[index].call, statements[index + 1].builtin.tail);
            index += 1;
            continue;
        }
        g.advance(1);
        if (control.isColdIf(g, statements, index)) return control.writeColdIf(g, &statements[index], statements[index + 1 ..]);
        try handlers.get(std.meta.activeTag(statements[index]))(g, &statements[index]);
    }
}

const Handler = *const fn (Gen, *const Statement) anyerror!void;

const handlers = std.EnumArray(Tag, Handler).init(.{
    .packed_struct_decl = &declaration,
    .command_table_decl = &declaration,
    .data_block = &declaration,
    .bss_block = &declaration,
    .state_block = &declaration,
    .var_decl = &varDecl,
    .assignment = &assignment,
    .store = &store,
    .call = &call,
    .builtin = &builtin,
    .label = &label,
    .exported_label = &exportedLabel,
    .goto = &control.writeGoto,
    .conditional_goto = &control.writeConditionalGoto,
    .conditional_direct_goto = &control.writeConditionalDirectGoto,
    .do_while_loop = &control.writeDoWhile,
    .labeled_block = &control.writeLabeledBlock,
    .break_loop = &control.writeBreak,
    .continue_loop = &control.writeContinue,
    .if_statement = &control.writeIf,
    .ordered_block = &ordered,
    .asm_line = &assembly,
});

/// Storage, structure, and command-table declarations emit no code.
fn declaration(_: Gen, _: *const Statement) !void {}

fn varDecl(g: Gen, statement: *const Statement) !void {
    try scalar.writeVarDecl(g, statement.var_decl);
}

fn assignment(g: Gen, statement: *const Statement) !void {
    try scalar.writeAssignment(g, statement.assignment);
}

fn store(g: Gen, statement: *const Statement) !void {
    try memory.writeStore(g, statement.store);
}

fn call(g: Gen, statement: *const Statement) !void {
    try calls.writeCall(g, statement.call);
}

fn builtin(g: Gen, statement: *const Statement) !void {
    try builtins.writeBuiltin(g, statement.builtin);
}

fn label(g: Gen, statement: *const Statement) !void {
    try g.out.label(try g.localLabel(statement.label, 0));
}

fn exportedLabel(g: Gen, statement: *const Statement) !void {
    try g.out.textFmt(".globl {s}", .{statement.exported_label});
    try g.out.label(statement.exported_label);
}

fn ordered(g: Gen, statement: *const Statement) !void {
    try g.out.exactBegin();
    try writeStatements(g, statement.ordered_block);
    try g.out.exactEnd();
}

fn assembly(g: Gen, statement: *const Statement) !void {
    try g.out.assembly(statement.asm_line);
}

/// A `slot` block holds exactly one instruction statement, optionally
/// preceded by labels, and is never a plain `nop`.
pub fn validateDelaySlot(statements: []const Statement) !void {
    var index: usize = 0;
    while (index < statements.len and isLabel(statements[index])) index += 1;
    if (statements.len != index + 1) return error.InvalidSlot;
    if (statements[index] == .builtin and statements[index].builtin == .nop) return error.UnnecessarySlot;
}

fn isLabel(statement: Statement) bool {
    return statement == .label or statement == .exported_label;
}

/// The explicit slot, or a `nop` the optimizer may later fill.
pub fn writeDelaySlot(g: Gen, delay_slot: ?[]const Statement) !void {
    const statements = delay_slot orelse return g.out.nop();
    try writeSlot(g, statements);
}

/// An optional slot for structured branches whose nop is emitted elsewhere.
pub fn writeStructuredDelaySlot(g: Gen, delay_slot: ?[]const Statement) !void {
    try writeSlot(g, delay_slot orelse return);
}

pub fn writeSlot(g: Gen, statements: []const Statement) !void {
    try validateDelaySlot(statements);
    try writeStatements(g, statements);
}

/// Inside a block with a shared `exit slot`, the final conditional exit
/// places the block's end label and exit statement in its own slot.
pub fn writeConditionalDirectDelaySlot(g: Gen, delay_slot: ?[]const Statement) !void {
    const exit_label = g.context.shared_exit_label;
    if (delay_slot != null or exit_label == null) return writeDelaySlot(g, delay_slot);
    const delay = g.context.shared_exit_delay orelse return error.MissingSharedExitSlot;
    try validateDelaySlot(delay);
    try g.out.label(try g.localLabel("blockend", exit_label.?));
    try writeStatements(g, delay);
    g.context.shared_exit_consumed = true;
}

test "slots contain one statement after optional labels" {
    var nop = [_]Statement{.{ .builtin = .nop }};
    var labeled = [_]Statement{ .{ .label = "a" }, .{ .builtin = .{ .breakpoint = 0 } } };
    var two = [_]Statement{ .{ .builtin = .{ .breakpoint = 0 } }, .{ .builtin = .{ .breakpoint = 0 } } };
    try std.testing.expectError(error.UnnecessarySlot, validateDelaySlot(&nop));
    try validateDelaySlot(&labeled);
    try std.testing.expectError(error.InvalidSlot, validateDelaySlot(&two));
    try std.testing.expectError(error.InvalidSlot, validateDelaySlot(&.{}));
}
