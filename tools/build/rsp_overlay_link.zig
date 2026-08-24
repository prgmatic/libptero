const std = @import("std");

const imem_base = 0x1000;
const imem_end = 0x2000;
const overlay_data_start = 0x0a00;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 5) return error.InvalidArguments;
    const overlay_state_start = try std.fmt.parseInt(u16, args[3], 0);
    if (overlay_state_start > overlay_data_start) return error.InvalidStateStart;

    const resident_elf = try readAll(io, alloc, args[1]);
    defer alloc.free(resident_elf);
    var reader = std.Io.Reader.fixed(resident_elf);
    const header = try std.elf.Header.read(&reader);
    if (header.is_64 or header.endian != .big) return error.UnsupportedElf;
    const text = (try findSection(resident_elf, header, ".text")) orelse return error.MissingTextSection;
    const text_start = try overlayTextStart(text.sh_addr, text.sh_size);
    const interface_source = try readAll(io, alloc, args[2]);
    defer alloc.free(interface_source);
    const aliases = try parseAliases(alloc, interface_source);
    defer alloc.free(aliases);
    const symbols = try exportedSymbols(alloc, resident_elf, header, aliases);
    defer alloc.free(symbols);

    const output = try std.Io.Dir.cwd().createFile(io, args[4], .{});
    defer output.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = output.writer(io, &buffer);
    try writeLinkerScript(&file_writer.interface, text_start, overlay_state_start, symbols);
    try file_writer.interface.flush();
}

fn readAll(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(alloc, .unlimited);
}

const ExportedSymbol = struct { name: []const u8, value: u32 };
const SymbolAlias = struct { interface_name: []const u8, symbol_name: []const u8 };

fn parseAliases(alloc: std.mem.Allocator, source: []const u8) ![]SymbolAlias {
    const prefix = "// @zsp-symbol ";
    var aliases: std.ArrayList(SymbolAlias) = .empty;
    errdefer aliases.deinit(alloc);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var fields = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
        const interface_name = fields.next() orelse return error.InvalidInterfaceMetadata;
        const symbol_name = fields.next() orelse return error.InvalidInterfaceMetadata;
        if (fields.next() != null) return error.InvalidInterfaceMetadata;
        for (aliases.items) |alias| {
            if (std.mem.eql(u8, alias.interface_name, interface_name) or
                std.mem.eql(u8, alias.symbol_name, symbol_name))
            {
                return error.DuplicateInterfaceSymbol;
            }
        }
        try aliases.append(alloc, .{ .interface_name = interface_name, .symbol_name = symbol_name });
    }
    return aliases.toOwnedSlice(alloc);
}

fn overlayTextStart(address: u64, size: u64) !u16 {
    if (address < imem_base or size == 0) return error.InvalidResidentText;
    const start = std.mem.alignForward(u32, @intCast(address + size), 16);
    if (start >= imem_end) return error.ResidentTextTooLarge;
    return @intCast(start);
}

fn exportedSymbols(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    header: std.elf.Header,
    aliases: []const SymbolAlias,
) ![]ExportedSymbol {
    const symtab = (try findSection(bytes, header, ".symtab")) orelse return error.MissingSymbolTable;
    const strtab = try sectionAt(bytes, header, symtab.sh_link);
    const strings = try sectionBytes(bytes, strtab);
    const symbol_bytes = try sectionBytes(bytes, symtab);
    if (symtab.sh_entsize != 16 or symbol_bytes.len % 16 != 0) return error.InvalidSymbolTable;

    var symbols: std.ArrayList(ExportedSymbol) = .empty;
    errdefer symbols.deinit(alloc);
    const aliases_found = try alloc.alloc(bool, aliases.len);
    defer alloc.free(aliases_found);
    @memset(aliases_found, false);
    var offset: usize = 0;
    while (offset < symbol_bytes.len) : (offset += 16) {
        const entry = symbol_bytes[offset..][0..16];
        const name_offset = std.mem.readInt(u32, entry[0..4], .big);
        const value = std.mem.readInt(u32, entry[4..8], .big);
        const info = entry[12];
        const section_index = std.mem.readInt(u16, entry[14..16], .big);
        if (section_index == 0 or name_offset >= strings.len) continue;
        const name = std.mem.sliceTo(strings[name_offset..], 0);
        if (value >= imem_base and value < imem_end) {
            for (aliases, 0..) |alias, alias_index| {
                if (std.mem.eql(u8, name, alias.symbol_name)) {
                    aliases_found[alias_index] = true;
                    try symbols.append(alloc, .{ .name = alias.interface_name, .value = value });
                    break;
                }
            }
            continue;
        }
        if (info >> 4 != 1 or value >= imem_base) continue;
        if (name.len == 0 or std.mem.eql(u8, name, "_start")) continue;
        try symbols.append(alloc, .{ .name = name, .value = value });
    }
    for (aliases_found) |found| if (!found) return error.MissingInterfaceSymbol;
    const owned = try symbols.toOwnedSlice(alloc);
    std.mem.sort(ExportedSymbol, owned, {}, struct {
        fn lessThan(_: void, lhs: ExportedSymbol, rhs: ExportedSymbol) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
    return owned;
}

fn findSection(bytes: []const u8, header: std.elf.Header, name: []const u8) !?std.elf.Elf64_Shdr {
    const names = try sectionNameTable(bytes, header);
    var sections = header.iterateSectionHeadersBuffer(bytes);
    while (try sections.next()) |section| {
        if (section.sh_name >= names.len) return error.BadElf;
        const section_name = std.mem.sliceTo(names[section.sh_name..], 0);
        if (std.mem.eql(u8, section_name, name)) return section;
    }
    return null;
}

fn sectionNameTable(bytes: []const u8, header: std.elf.Header) ![]const u8 {
    return sectionBytes(bytes, try sectionAt(bytes, header, header.shstrndx));
}

fn sectionAt(bytes: []const u8, header: std.elf.Header, wanted: usize) !std.elf.Elf64_Shdr {
    if (wanted >= header.shnum) return error.BadElf;
    var sections = header.iterateSectionHeadersBuffer(bytes);
    var index: usize = 0;
    while (try sections.next()) |section| : (index += 1) {
        if (index == wanted) return section;
    }
    return error.BadElf;
}

fn sectionBytes(bytes: []const u8, section: std.elf.Elf64_Shdr) ![]const u8 {
    const offset: usize = @intCast(section.sh_offset);
    const size: usize = @intCast(section.sh_size);
    if (offset + size > bytes.len) return error.BadElf;
    return bytes[offset..][0..size];
}

fn writeLinkerScript(writer: *std.Io.Writer, text_start: u16, state_start: u16, symbols: []const ExportedSymbol) !void {
    if (state_start == overlay_data_start) {
        try writeStandardLinkerScript(writer, text_start, symbols);
        return;
    }
    try writer.print(
        \\OUTPUT_ARCH(mips)
        \\ENTRY(_start)
        \\
        \\MEMORY {{
        \\    DATA_DMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
        \\    STATE_DMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
        \\    IMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
        \\}}
        \\
        \\SECTIONS {{
        \\    .state 0x{x:0>4} : SUBALIGN(1) {{
        \\        KEEP(*(.state*))
        \\    }} > STATE_DMEM
        \\
        \\    .bss (NOLOAD) : SUBALIGN(1) {{
        \\        *(.bss*)
        \\    }} > STATE_DMEM
        \\
        \\    .data 0x{x:0>4} : {{
        \\        KEEP(*(.data*))
        \\        KEEP(*(.rodata*))
        \\    }} > DATA_DMEM
        \\
        \\    .text 0x{x:0>4} : {{
        \\        *(.text*)
        \\    }} > IMEM
        \\
        \\    .zsp_commands 0 : {{
        \\        KEEP(*(.zsp_commands))
        \\    }}
        \\
        \\    /DISCARD/ : {{
        \\        *(.MIPS.abiflags)
        \\        *(.reginfo)
        \\        *(.got*)
        \\    }}
        \\}}
        \\
    , .{
        overlay_data_start,
        0x1000 - overlay_data_start,
        state_start,
        0x1000 - state_start,
        text_start,
        imem_end - text_start,
        state_start,
        overlay_data_start,
        text_start,
    });
    for (symbols) |symbol| {
        try writer.print("PROVIDE({s} = 0x{x});\n", .{ symbol.name, symbol.value });
    }
}

fn writeStandardLinkerScript(writer: *std.Io.Writer, text_start: u16, symbols: []const ExportedSymbol) !void {
    try writer.print(
        \\OUTPUT_ARCH(mips)
        \\ENTRY(_start)
        \\
        \\MEMORY {{
        \\    DMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
        \\    IMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
        \\}}
        \\
        \\SECTIONS {{
        \\    .data 0x{x:0>4} : {{
        \\        KEEP(*(.data*))
        \\        KEEP(*(.rodata*))
        \\    }} > DMEM
        \\
        \\    .bss (NOLOAD) : SUBALIGN(1) {{
        \\        *(.bss*)
        \\    }} > DMEM
        \\
        \\    .state ALIGN(16) : SUBALIGN(1) {{
        \\        KEEP(*(.state*))
        \\    }} > DMEM
        \\
        \\    .text 0x{x:0>4} : {{
        \\        *(.text*)
        \\    }} > IMEM
        \\
        \\    .zsp_commands 0 : {{
        \\        KEEP(*(.zsp_commands))
        \\    }}
        \\
        \\    /DISCARD/ : {{
        \\        *(.MIPS.abiflags)
        \\        *(.reginfo)
        \\        *(.got*)
        \\    }}
        \\}}
        \\
    , .{
        overlay_data_start,
        0x1000 - overlay_data_start,
        text_start,
        imem_end - text_start,
        overlay_data_start,
        text_start,
    });
    for (symbols) |symbol| {
        try writer.print("PROVIDE({s} = 0x{x});\n", .{ symbol.name, symbol.value });
    }
}

test "overlay text follows aligned resident text" {
    try std.testing.expectEqual(@as(u16, 0x11b0), try overlayTextStart(0x1000, 0x01a8));
}

test "generated interface symbol metadata is parsed" {
    const aliases = try parseAliases(std.testing.allocator,
        \\// @zsp-symbol out zsp_m1_dma__out
        \\pub extern fn out() writes();
        \\// @zsp-symbol commandLoop commandLoop
        \\
    );
    defer std.testing.allocator.free(aliases);
    try std.testing.expectEqual(@as(usize, 2), aliases.len);
    try std.testing.expectEqualStrings("out", aliases[0].interface_name);
    try std.testing.expectEqualStrings("zsp_m1_dma__out", aliases[0].symbol_name);
    try std.testing.expectEqualStrings("commandLoop", aliases[1].interface_name);
    try std.testing.expectEqualStrings("commandLoop", aliases[1].symbol_name);
}
