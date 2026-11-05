//! Named addresses from the linked ELF: IMEM labels and DMEM storage,
//! written as a Zig module or a readable memory map.
const std = @import("std");
const elf = std.elf;
const elf_file = @import("elf_file.zig");

const Section = elf_file.Section;
const imem_base = @import("commands.zig").imem_base;

pub const Kind = enum(u8) { dmem, imem };
pub const Symbol = struct { name: []const u8, value: u16, kind: Kind };

const entry_size = 16;

/// Every named RSP address, sorted by name. The caller frees the slice.
pub fn collect(allocator: std.mem.Allocator, file: elf_file.File, sections: elf_file.Sections) ![]Symbol {
    const table = try symbolTable(file) orelse return &.{};
    var result: std.ArrayList(Symbol) = .empty;
    errdefer result.deinit(allocator);
    var offset: usize = 0;
    while (offset < table.entries.len) : (offset += entry_size) {
        const symbol = try readSymbol(file, sections, table.strings, table.entries[offset..][0..entry_size]) orelse continue;
        if (findName(result.items, symbol.name)) return error.DuplicateSymbol;
        try result.append(allocator, symbol);
    }
    std.mem.sort(Symbol, result.items, {}, nameOrder);
    return result.toOwnedSlice(allocator);
}

const SymbolTable = struct { entries: []const u8, strings: []const u8 };

fn symbolTable(file: elf_file.File) !?SymbolTable {
    const symtab = try file.find(".symtab") orelse return null;
    const entries = try file.contents(symtab);
    if (symtab.sh_entsize != entry_size or entries.len % entry_size != 0) return error.InvalidSymbolTable;
    return .{ .entries = entries, .strings = try file.contents(try file.sectionAt(symtab.sh_link)) };
}

fn findName(symbols: []const Symbol, name: []const u8) bool {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return true;
    }
    return false;
}

fn nameOrder(_: void, lhs: Symbol, rhs: Symbol) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

/// IMEM labels are offsets from the start of IMEM.
fn readSymbol(file: elf_file.File, sections: elf_file.Sections, strings: []const u8, entry: *const [entry_size]u8) !?Symbol {
    const name = symbolName(strings, std.mem.readInt(u32, entry[0..4], .big)) orelse return null;
    const value = std.mem.readInt(u32, entry[4..8], .big);
    const kind = try symbolKind(file, sections, std.mem.readInt(u16, entry[14..16], .big), value) orelse return null;
    const offset = if (kind == .imem) value - imem_base else value;
    if (offset > std.math.maxInt(u16)) return error.SymbolOutsideRspMemory;
    return .{ .name = name, .value = @intCast(offset), .kind = kind };
}

/// Names worth exporting: not empty, not section symbols such as `.text`.
fn symbolName(strings: []const u8, offset: u32) ?[]const u8 {
    if (offset >= strings.len) return null;
    const name = std.mem.sliceTo(strings[offset..], 0);
    if (name.len == 0 or name.len > std.math.maxInt(u8) or name[0] == '.') return null;
    return name;
}

fn symbolKind(file: elf_file.File, sections: elf_file.Sections, section_index: u16, value: u32) !?Kind {
    if (section_index == elf.SHN_UNDEF) return null;
    if (section_index == elf.SHN_ABS) return absoluteKind(value);
    if (section_index >= file.header.shnum) return null;
    return sectionKind(sections, try file.sectionAt(section_index));
}

/// Absolute symbols are classified by address alone.
fn absoluteKind(value: u32) ?Kind {
    if (value >= imem_base and value < imem_base + 0x1000) return .imem;
    if (value < 0x1000) return .dmem;
    return null;
}

fn sectionKind(sections: elf_file.Sections, section: Section) ?Kind {
    if (elf_file.sameSection(section, sections.text)) return .imem;
    for (sections.dmem()) |candidate| {
        const known = candidate orelse continue;
        if (elf_file.sameSection(section, known)) return .dmem;
    }
    return null;
}

/// One constant per symbol plus an IMEM table used by host-side tools
/// such as the RSP interpreter's profiler. Unreferenced declarations do not
/// reach a ROM.
pub fn formatModule(writer: *std.Io.Writer, symbols: []const Symbol) !void {
    for (symbols) |symbol| try writer.print("pub const @\"{s}\": u16 = 0x{x:0>4}; // {s}\n", .{ symbol.name, symbol.value, @tagName(symbol.kind) });
    try writer.writeAll("pub const zsp_imem_symbols = [_]struct { name: []const u8, offset: u16 }{\n");
    for (symbols) |symbol| {
        if (symbol.kind != .imem) continue;
        try writer.print("    .{{ .name = \"{s}\", .offset = 0x{x:0>4} }},\n", .{ symbol.name, symbol.value });
    }
    try writer.writeAll("};\n");
}

/// Section ranges, then symbols by memory and address. Sorts `symbols`.
pub fn formatMap(writer: *std.Io.Writer, sections: elf_file.Sections, symbols: []Symbol) !void {
    std.mem.sort(Symbol, symbols, {}, addressOrder);
    try writer.writeAll("RSP linked memory map\n\nSections:\n");
    const listed = [_]struct { []const u8, ?Section, u64 }{
        .{ "data", sections.data, 0 },
        .{ "state", sections.state, 0 },
        .{ "bss", sections.bss, 0 },
        .{ "text", sections.text, imem_base },
    };
    for (listed) |item| {
        const section = item[1] orelse continue;
        const start = section.sh_addr - item[2];
        try writer.print("  {s: <5} 0x{x:0>4}..0x{x:0>4} ({d} bytes)\n", .{ item[0], start, start + section.sh_size, section.sh_size });
    }
    try writer.writeAll("\nSymbols:\n");
    for (symbols) |symbol| try writer.print("  {s} 0x{x:0>4} {s}\n", .{ @tagName(symbol.kind), symbol.value, symbol.name });
}

fn addressOrder(_: void, lhs: Symbol, rhs: Symbol) bool {
    if (lhs.kind != rhs.kind) return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    if (lhs.value != rhs.value) return lhs.value < rhs.value;
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

const testing = std.testing;

test "symbol modules list constants and an IMEM table" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try formatModule(&writer, &.{
        .{ .name = "table", .value = 0x40, .kind = .dmem },
        .{ .name = "loop", .value = 0x84, .kind = .imem },
    });
    try testing.expectEqualStrings(
        \\pub const @"table": u16 = 0x0040; // dmem
        \\pub const @"loop": u16 = 0x0084; // imem
        \\pub const zsp_imem_symbols = [_]struct { name: []const u8, offset: u16 }{
        \\    .{ .name = "loop", .offset = 0x0084 },
        \\};
        \\
    , writer.buffered());
}

test "symbols are classified by address and named sensibly" {
    try testing.expectEqual(@as(?Kind, .imem), absoluteKind(0x1004));
    try testing.expectEqual(@as(?Kind, .dmem), absoluteKind(0x10));
    try testing.expectEqual(@as(?Kind, null), absoluteKind(0x2000));
    try testing.expectEqualStrings("loop", symbolName("\x00loop\x00", 1).?);
    try testing.expectEqual(@as(?[]const u8, null), symbolName("\x00.text\x00", 1));
    try testing.expectEqual(@as(?[]const u8, null), symbolName("\x00", 7));
    var order = [_]Symbol{
        .{ .name = "b", .value = 4, .kind = .imem },
        .{ .name = "a", .value = 4, .kind = .imem },
        .{ .name = "z", .value = 8, .kind = .dmem },
        .{ .name = "y", .value = 0, .kind = .imem },
    };
    std.mem.sort(Symbol, &order, {}, addressOrder);
    try testing.expectEqualStrings("z", order[0].name);
    try testing.expectEqualStrings("y", order[1].name);
    try testing.expectEqualStrings("a", order[2].name);
}
