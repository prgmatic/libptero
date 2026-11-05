//! DMEM storage sections, packed structs, and command-table metadata.
const std = @import("std");
const ast = @import("ast.zig");
const analysis = @import("analysis.zig");
const common = @import("emit_common.zig");
const rspq = @import("rspq.zig");
const Emitter = @import("Emitter.zig");

const DataType = ast.DataType;
const FunctionContext = analysis.FunctionContext;

pub const PackedStructRegistry = struct {
    declarations: [32]ast.PackedStructDecl = undefined,
    len: usize = 0,

    pub fn collect(functions: []const ast.Function) !PackedStructRegistry {
        var registry: PackedStructRegistry = .{};
        for (functions) |function| for (function.statements) |statement| {
            if (statement == .packed_struct_decl) try registry.add(statement.packed_struct_decl);
        };
        return registry;
    }

    fn add(self: *PackedStructRegistry, declaration: ast.PackedStructDecl) !void {
        if (self.len >= self.declarations.len) return error.TooManyPackedStructs;
        if (self.find(declaration.name) != null) return error.SymbolAlreadyDefined;
        if (hasDuplicateField(declaration.fields)) return error.SymbolAlreadyDefined;
        self.declarations[self.len] = declaration;
        self.len += 1;
    }

    fn lookup(self: *const PackedStructRegistry, name: []const u8) !ast.PackedStructDecl {
        return self.find(name) orelse error.UnknownPackedStruct;
    }

    fn find(self: *const PackedStructRegistry, name: []const u8) ?ast.PackedStructDecl {
        for (self.declarations[0..self.len]) |declaration| {
            if (std.mem.eql(u8, declaration.name, name)) return declaration;
        }
        return null;
    }

    fn sizeOf(self: *const PackedStructRegistry, name: []const u8) !usize {
        var size: usize = 0;
        for ((try self.lookup(name)).fields) |field| size += try common.scalarDataSize(field.data_type);
        return size;
    }
};

fn hasDuplicateField(fields: []const ast.PackedStructField) bool {
    for (fields, 0..) |field, index| {
        for (fields[0..index]) |previous| if (std.mem.eql(u8, field.name, previous.name)) return true;
    }
    return false;
}

const Section = struct { tag: std.meta.Tag(ast.Statement), header: []const u8 };

/// Saved overlay state is part of the loadable DMEM image, so zero-only
/// declarations stay in the same PROGBITS section in source order.
const sections = [_]Section{
    .{ .tag = .data_block, .header = ".data" },
    .{ .tag = .bss_block, .header = ".bss" },
    .{ .tag = .state_block, .header = ".section .state,\"aw\",@progbits" },
};

const Storage = struct { out: *Emitter, context: *FunctionContext, structs: *const PackedStructRegistry };

pub fn writeStorageBlocks(out: *Emitter, functions: []const ast.Function, context: *FunctionContext) !void {
    const structs = try PackedStructRegistry.collect(functions);
    const storage: Storage = .{ .out = out, .context = context, .structs = &structs };
    for (sections) |section| try writeSection(storage, functions, section);
}

fn sectionDeclarations(statement: ast.Statement) []const ast.DataDecl {
    return switch (statement) {
        .data_block, .bss_block, .state_block => |items| items,
        else => &.{},
    };
}

fn writeSection(storage: Storage, functions: []const ast.Function, section: Section) !void {
    var wrote_section = false;
    for (functions) |function| {
        wrote_section = try writeSectionBlocks(storage, function.statements, section, wrote_section);
    }
    if (!wrote_section) return;
    if (section.tag == .state_block) try storage.out.text(".balign 8");
    try storage.out.blank();
}

/// Writes a function's blocks of this section, opening it on first use.
fn writeSectionBlocks(storage: Storage, statements: []const ast.Statement, section: Section, opened: bool) !bool {
    var wrote_section = opened;
    for (statements) |statement| {
        if (std.meta.activeTag(statement) != section.tag) continue;
        if (!wrote_section) try storage.out.text(section.header);
        wrote_section = true;
        for (sectionDeclarations(statement)) |declaration| try writeDeclaration(storage, declaration);
    }
    return wrote_section;
}

fn writeDeclaration(storage: Storage, declaration: ast.DataDecl) !void {
    const element_size = try elementSize(storage, declaration);
    if (!declaration.external) try writeDefinition(storage, declaration, element_size);
    // Modules may each declare the same external storage they use.
    if (declaration.external and isDataLabel(storage.context, declaration.name)) return;
    try storage.context.add(.{
        .name = declaration.name,
        .data_type = .dmem,
        .reg = null,
        .constant = null,
        .data_label = declaration.name,
    });
}

fn isDataLabel(context: *const FunctionContext, name: []const u8) bool {
    const existing = context.lookup(name) catch return false;
    return existing.data_label != null;
}

fn elementSize(storage: Storage, declaration: ast.DataDecl) !usize {
    return switch (declaration.storage_type) {
        .scalar => |data_type| common.scalarDataSize(data_type),
        .packed_struct => |name| storage.structs.sizeOf(name),
    };
}

fn writeDefinition(storage: Storage, declaration: ast.DataDecl, element_size: usize) !void {
    const out = storage.out;
    try writeDefinitionLabel(out, declaration, element_size);
    if (!declaration.initialized) return out.textFmt("  .space {d}", .{declaration.array_len * element_size});
    switch (declaration.storage_type) {
        .scalar => |data_type| try writeScalarValues(out, declaration, data_type, element_size),
        .packed_struct => |name| try writePackedValues(out, declaration, try storage.structs.lookup(name)),
    }
}

/// Scalars align to their size; packed structs are byte-aligned.
fn writeDefinitionLabel(out: *Emitter, declaration: ast.DataDecl, element_size: usize) !void {
    const alignment = if (declaration.storage_type == .scalar) element_size else 1;
    if (alignment > 1) try out.textFmt(".balign {d}", .{alignment});
    if (declaration.public) try out.textFmt(".globl {s}", .{declaration.name});
    try out.label(declaration.name);
}

fn writeScalarValues(out: *Emitter, declaration: ast.DataDecl, data_type: DataType, element_size: usize) !void {
    for (declaration.values) |value| try writeDataValue(out, data_type, value);
    const remaining = declaration.array_len - declaration.values.len;
    if (remaining > 0) try out.textFmt("  .space {d}, 0", .{remaining * element_size});
}

fn writePackedValues(out: *Emitter, declaration: ast.DataDecl, layout: ast.PackedStructDecl) !void {
    if (declaration.is_array) return error.PackedStructArraysUnsupported;
    if (declaration.values.len != layout.fields.len) return error.IncorrectPackedStructInitializerCount;
    for (declaration.values, layout.fields) |value, field| try writeDataValue(out, field.data_type, value);
}

fn writeDataValue(out: *Emitter, data_type: DataType, value: i64) !void {
    try validateDataValue(data_type, value);
    try out.textFmt("  {s} {d}", .{ dataDirective(data_type), value });
}

fn dataDirective(data_type: DataType) []const u8 {
    return switch (data_type) {
        .u8, .i8 => ".byte",
        .u16, .i16 => ".short",
        else => ".word",
    };
}

const Range = struct { min: i64, max: i64 };

const data_ranges = std.EnumArray(DataType, Range).init(.{
    .u8 = .{ .min = 0, .max = std.math.maxInt(u8) },
    .u16 = .{ .min = 0, .max = std.math.maxInt(u16) },
    .u32 = .{ .min = 0, .max = std.math.maxInt(u32) },
    .dmem = .{ .min = 0, .max = 4096 },
    .i8 = .{ .min = std.math.minInt(i8), .max = std.math.maxInt(i8) },
    .i16 = .{ .min = std.math.minInt(i16), .max = std.math.maxInt(i16) },
    .i32 = .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) },
    .vec16 = .{ .min = 1, .max = 0 },
    .vec32 = .{ .min = 1, .max = 0 },
});

fn validateDataValue(data_type: DataType, value: i64) !void {
    const range = data_ranges.get(data_type);
    if (value < range.min or value > range.max) return error.DataInitializerOutOfRange;
}

/// The handler table is filled at link time; this reserves its slots.
pub fn writeCommandTable(out: *Emitter, analysis_: *const rspq.CommandAnalysis, context: *FunctionContext) !void {
    const name = analysis_.table_name orelse return;
    try out.text(".data");
    try out.text(".balign 2");
    try out.label(name);
    for (analysis_.entries[0..analysis_.table_len]) |_| try out.text("  .short 0");
    try out.text(".section .zsp_command_table,\"\",@progbits");
    try out.textFmt("  .word {s}", .{name});
    try out.textFmt("  .word {d}", .{analysis_.table_len});
    try out.text(".data");
    try out.blank();
    try context.add(.{ .name = name, .data_type = .dmem, .reg = null, .constant = null, .data_label = name });
}

/// Per-command handler, index, and size records for the packer.
pub fn writeCommandManifest(out: *Emitter, functions: []const ast.Function, analysis_: *const rspq.CommandAnalysis) !void {
    var wrote_section = false;
    for (functions) |function| for (function.command_indices) |index| {
        if (!wrote_section) try out.text(".section .zsp_commands,\"\",@progbits");
        wrote_section = true;
        try out.textFmt("  .word {s}", .{function.name});
        try out.textFmt("  .byte {d}", .{index});
        try out.textFmt("  .byte {d}", .{analysis_.find(index).?.size});
        try out.text("  .short 0");
    };
    if (wrote_section) try out.blank();
}

test "data initializers must fit their declared type" {
    try validateDataValue(.u8, 255);
    try std.testing.expectError(error.DataInitializerOutOfRange, validateDataValue(.u8, 256));
    try std.testing.expectError(error.DataInitializerOutOfRange, validateDataValue(.i16, -40000));
    try std.testing.expectError(error.DataInitializerOutOfRange, validateDataValue(.vec16, 0));
    try validateDataValue(.dmem, 4096);
    try std.testing.expectEqualStrings(".short", dataDirective(.i16));
    try std.testing.expect(hasDuplicateField(&.{ .{ .name = "a", .data_type = .u8 }, .{ .name = "a", .data_type = .u8 } }));
}
