const std = @import("std");

const imem_base = 0x1000;
const imem_end = 0x2000;
const overlay_data_start = 0x0a00;

pub const usage =
    \\usage: rsp_overlay_link <resident.elf> <resident.zspi> <state_start> <output.ld> [data_start]
    \\       rsp_overlay_link --patch <resident.elf> <resident.zspi> <parent.elf> <symbol> <output.ld>
    \\
;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    run(init.io, alloc, args[1..]) catch |err| fail(err);
}

fn fail(err: anyerror) noreturn {
    var buffer: [256]u8 = undefined;
    std.debug.print("{s}", .{failureMessage(&buffer, err)});
    std.process.exit(1);
}

/// Usage text for bad arguments, or the error's name.
fn failureMessage(buffer: []u8, err: anyerror) []const u8 {
    if (err == error.InvalidArguments) return usage;
    return std.fmt.bufPrint(buffer, "rsp_overlay_link: error: {s}\n", .{@errorName(err)}) catch "rsp_overlay_link: error\n";
}

fn run(io: std.Io, alloc: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 6 and std.mem.eql(u8, args[0], "--patch")) return linkPatch(io, alloc, args[1..]);
    if (args.len != 4 and args.len != 5) return error.InvalidArguments;
    return linkOverlay(io, alloc, args);
}

/// An overlay's text follows the resident's, and it sees the resident's
/// public symbols.
fn linkOverlay(io: std.Io, alloc: std.mem.Allocator, args: []const []const u8) !void {
    const layout = try parseLayout(args[2], if (args.len == 5) args[4] else null);
    const resident_elf = try readAll(io, alloc, args[0]);
    defer alloc.free(resident_elf);
    const header = try readHeader(resident_elf);
    const text = (try findSection(resident_elf, header, ".text")) orelse return error.MissingTextSection;
    const text_start = try overlayTextStart(text.sh_addr, text.sh_size);
    const symbols = try residentSymbols(io, alloc, resident_elf, args[1]);
    defer alloc.free(symbols);
    try writeScript(io, args[3], OverlayScript{
        .text_start = text_start,
        .state_start = layout.state_start,
        .data_start = layout.data_start,
        .symbols = symbols,
    });
}

/// A patch replaces part of a parent overlay's text while that overlay is
/// loaded: its text starts at `symbol` in the parent, it has no DMEM
/// contents of its own, and it sees the resident's public symbols and the
/// parent's global ones.
fn linkPatch(io: std.Io, alloc: std.mem.Allocator, args: []const []const u8) !void {
    const resident_elf = try readAll(io, alloc, args[0]);
    defer alloc.free(resident_elf);
    const resident = try residentSymbols(io, alloc, resident_elf, args[1]);
    defer alloc.free(resident);
    const parent_elf = try readAll(io, alloc, args[2]);
    defer alloc.free(parent_elf);
    const parent_header = try readHeader(parent_elf);
    const target = (try symbolValue(parent_elf, parent_header, args[3])) orelse return error.MissingPatchSymbol;
    if (!isImem(target) or target & 7 != 0) return error.InvalidPatchSymbol;
    const parent = try globalSymbols(alloc, parent_elf, parent_header);
    defer alloc.free(parent);
    const symbols = try mergeSymbols(alloc, resident, parent);
    defer alloc.free(symbols);
    try writeScript(io, args[4], PatchScript{ .text_start = @intCast(target), .symbols = symbols });
}

const Layout = struct { state_start: u16, data_start: u16 };

/// State and initialized-data starts; data defaults to 0x0a00.
fn parseLayout(state_text: []const u8, data_text: ?[]const u8) !Layout {
    const state_start = try std.fmt.parseInt(u16, state_text, 0);
    const data_start = if (data_text) |text| try std.fmt.parseInt(u16, text, 0) else overlay_data_start;
    if (data_start < 0x0220 or data_start >= imem_base or data_start & 15 != 0) return error.InvalidDataStart;
    if (state_start > data_start) return error.InvalidStateStart;
    return .{ .state_start = state_start, .data_start = data_start };
}

fn readHeader(bytes: []const u8) !std.elf.Header {
    var reader = std.Io.Reader.fixed(bytes);
    const header = try std.elf.Header.read(&reader);
    if (header.is_64 or header.endian != .big) return error.UnsupportedElf;
    return header;
}

fn residentSymbols(io: std.Io, alloc: std.mem.Allocator, resident_elf: []const u8, interface_path: []const u8) ![]ExportedSymbol {
    const header = try readHeader(resident_elf);
    // Interface names in the result point into this text, so it lives as
    // long as the allocator.
    const interface_source = try readAll(io, alloc, interface_path);
    const aliases = try parseAliases(alloc, interface_source);
    defer alloc.free(aliases);
    return exportedSymbols(alloc, resident_elf, header, aliases);
}

fn writeScript(io: std.Io, path: []const u8, script: anytype) !void {
    const output = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer output.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = output.writer(io, &buffer);
    try script.write(&file_writer.interface);
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
    var aliases: std.ArrayList(SymbolAlias) = .empty;
    errdefer aliases.deinit(alloc);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const alias = try parseAlias(line) orelse continue;
        if (sharesName(aliases.items, alias)) return error.DuplicateInterfaceSymbol;
        try aliases.append(alloc, alias);
    }
    return aliases.toOwnedSlice(alloc);
}

/// The alias a `// @zsp-symbol <interface> <symbol>` line declares.
fn parseAlias(line: []const u8) !?SymbolAlias {
    const prefix = "// @zsp-symbol ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var fields = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
    const interface_name = fields.next() orelse return error.InvalidInterfaceMetadata;
    const symbol_name = fields.next() orelse return error.InvalidInterfaceMetadata;
    if (fields.next() != null) return error.InvalidInterfaceMetadata;
    return .{ .interface_name = interface_name, .symbol_name = symbol_name };
}

fn sharesName(aliases: []const SymbolAlias, candidate: SymbolAlias) bool {
    for (aliases) |alias| {
        if (std.mem.eql(u8, alias.interface_name, candidate.interface_name)) return true;
        if (std.mem.eql(u8, alias.symbol_name, candidate.symbol_name)) return true;
    }
    return false;
}

fn overlayTextStart(address: u64, size: u64) !u16 {
    if (address < imem_base or size == 0) return error.InvalidResidentText;
    const start = std.mem.alignForward(u32, @intCast(address + size), 16);
    if (start >= imem_end) return error.ResidentTextTooLarge;
    return @intCast(start);
}

/// One defined entry of an ELF symbol table.
const ElfSymbol = struct { name: []const u8, value: u32, global: bool };

const SymbolTable = struct {
    strings: []const u8,
    entries: []const u8,
    offset: usize = 0,

    fn init(bytes: []const u8, header: std.elf.Header) !SymbolTable {
        const symtab = (try findSection(bytes, header, ".symtab")) orelse return error.MissingSymbolTable;
        const strtab = try sectionAt(bytes, header, symtab.sh_link);
        const entries = try sectionBytes(bytes, symtab);
        if (symtab.sh_entsize != 16 or entries.len % 16 != 0) return error.InvalidSymbolTable;
        return .{ .strings = try sectionBytes(bytes, strtab), .entries = entries };
    }

    /// The next named symbol defined in some section, absolute ones included.
    fn next(self: *SymbolTable) ?ElfSymbol {
        while (self.offset < self.entries.len) {
            const entry = self.entries[self.offset..][0..16];
            self.offset += 16;
            const name_offset = std.mem.readInt(u32, entry[0..4], .big);
            const section_index = std.mem.readInt(u16, entry[14..16], .big);
            if (section_index == 0 or name_offset >= self.strings.len) continue;
            const name = std.mem.sliceTo(self.strings[name_offset..], 0);
            if (name.len == 0) continue;
            return .{ .name = name, .value = std.mem.readInt(u32, entry[4..8], .big), .global = entry[12] >> 4 == 1 };
        }
        return null;
    }
};

fn exportedSymbols(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    header: std.elf.Header,
    aliases: []const SymbolAlias,
) ![]ExportedSymbol {
    var table = try SymbolTable.init(bytes, header);
    var symbols: std.ArrayList(ExportedSymbol) = .empty;
    errdefer symbols.deinit(alloc);
    const aliases_found = try alloc.alloc(bool, aliases.len);
    defer alloc.free(aliases_found);
    @memset(aliases_found, false);
    while (table.next()) |symbol| {
        const exported = residentExport(symbol, aliases) orelse continue;
        if (exported.alias) |index| aliases_found[index] = true;
        try symbols.append(alloc, .{ .name = exported.name, .value = symbol.value });
    }
    if (std.mem.indexOfScalar(bool, aliases_found, false) != null) return error.MissingInterfaceSymbol;
    return sortedSymbols(alloc, &symbols);
}

const ResidentExport = struct { name: []const u8, alias: ?usize = null };

/// Resident code is visible through its interface aliases; its global DMEM
/// labels are visible by name.
fn residentExport(symbol: ElfSymbol, aliases: []const SymbolAlias) ?ResidentExport {
    if (isImem(symbol.value)) {
        const index = aliasIndex(aliases, symbol.name) orelse return null;
        return .{ .name = aliases[index].interface_name, .alias = index };
    }
    if (!symbol.global or symbol.value >= imem_base or std.mem.eql(u8, symbol.name, "_start")) return null;
    return .{ .name = symbol.name };
}

fn isImem(address: u32) bool {
    return address >= imem_base and address < imem_end;
}

fn aliasIndex(aliases: []const SymbolAlias, symbol_name: []const u8) ?usize {
    for (aliases, 0..) |alias, index| {
        if (std.mem.eql(u8, symbol_name, alias.symbol_name)) return index;
    }
    return null;
}

fn sortedSymbols(alloc: std.mem.Allocator, symbols: *std.ArrayList(ExportedSymbol)) ![]ExportedSymbol {
    const owned = try symbols.toOwnedSlice(alloc);
    std.mem.sort(ExportedSymbol, owned, {}, struct {
        fn lessThan(_: void, lhs: ExportedSymbol, rhs: ExportedSymbol) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
    return owned;
}

/// The value of `name`, whatever its binding.
fn symbolValue(bytes: []const u8, header: std.elf.Header, name: []const u8) !?u32 {
    var table = try SymbolTable.init(bytes, header);
    while (table.next()) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol.value;
    }
    return null;
}

/// Every global symbol of a linked program except its entry point.
fn globalSymbols(alloc: std.mem.Allocator, bytes: []const u8, header: std.elf.Header) ![]ExportedSymbol {
    var table = try SymbolTable.init(bytes, header);
    var symbols: std.ArrayList(ExportedSymbol) = .empty;
    errdefer symbols.deinit(alloc);
    while (table.next()) |symbol| {
        if (!symbol.global or std.mem.eql(u8, symbol.name, "_start")) continue;
        try symbols.append(alloc, .{ .name = symbol.name, .value = symbol.value });
    }
    return sortedSymbols(alloc, &symbols);
}

/// `first` and the names of `second` it lacks. A name both define must
/// agree on its value.
fn mergeSymbols(alloc: std.mem.Allocator, first: []const ExportedSymbol, second: []const ExportedSymbol) ![]ExportedSymbol {
    var symbols: std.ArrayList(ExportedSymbol) = .empty;
    errdefer symbols.deinit(alloc);
    try symbols.appendSlice(alloc, first);
    for (second) |symbol| {
        if (findSymbol(first, symbol.name)) |existing| {
            if (existing.value != symbol.value) return error.ConflictingSymbol;
            continue;
        }
        try symbols.append(alloc, symbol);
    }
    return sortedSymbols(alloc, &symbols);
}

fn findSymbol(symbols: []const ExportedSymbol, name: []const u8) ?ExportedSymbol {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
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

const OverlayScript = struct {
    text_start: u16,
    state_start: u16,
    data_start: u16,
    symbols: []const ExportedSymbol,

    fn write(self: OverlayScript, writer: *std.Io.Writer) !void {
        try writeLinkerScript(writer, self.text_start, self.state_start, self.data_start, self.symbols);
    }
};

const PatchScript = struct {
    text_start: u16,
    symbols: []const ExportedSymbol,

    /// Text only: DMEM sections and commands must stay empty, because a
    /// patch is loaded into IMEM alone and runs on its parent's state. The
    /// target only needs the DMA's 8-byte alignment, so the text's own
    /// section alignment is lowered to match.
    fn write(self: PatchScript, writer: *std.Io.Writer) !void {
        try writer.print(
            \\OUTPUT_ARCH(mips)
            \\ENTRY(_start)
            \\
            \\MEMORY {{
            \\    DMEM : ORIGIN = 0x0000, LENGTH = 0x1000
            \\    IMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
            \\}}
            \\
            \\SECTIONS {{
            \\    .text 0x{x:0>4} : SUBALIGN(8) {{
            \\        *(.text*)
            \\    }} > IMEM
            \\
            \\    .data 0 : {{
            \\        KEEP(*(.data*))
            \\        KEEP(*(.rodata*))
            \\        KEEP(*(.state*))
            \\        KEEP(*(.bss*))
            \\        KEEP(*(.zsp_commands))
            \\    }} > DMEM
            \\    ASSERT(SIZEOF(.data) == 0, "an overlay patch cannot have DMEM contents or commands")
            \\
            \\    /DISCARD/ : {{
            \\        *(.MIPS.abiflags)
            \\        *(.reginfo)
            \\        *(.got*)
            \\    }}
            \\}}
            \\
        , .{ self.text_start, imem_end - self.text_start, self.text_start });
        try writeProvides(writer, self.symbols);
    }
};

fn writeProvides(writer: *std.Io.Writer, symbols: []const ExportedSymbol) !void {
    for (symbols) |symbol| {
        try writer.print("PROVIDE({s} = 0x{x});\n", .{ symbol.name, symbol.value });
    }
}

fn writeLinkerScript(writer: *std.Io.Writer, text_start: u16, state_start: u16, data_start: u16, symbols: []const ExportedSymbol) !void {
    if (state_start == data_start) {
        try writeStandardLinkerScript(writer, text_start, data_start, symbols);
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
        data_start,
        0x1000 - data_start,
        state_start,
        0x1000 - state_start,
        text_start,
        imem_end - text_start,
        state_start,
        data_start,
        text_start,
    });
    try writeProvides(writer, symbols);
}

fn writeStandardLinkerScript(writer: *std.Io.Writer, text_start: u16, data_start: u16, symbols: []const ExportedSymbol) !void {
    const state_first =
        \\    .state ALIGN(16) : SUBALIGN(1) {
        \\        KEEP(*(.state*))
        \\    } > DMEM
        \\
        \\    .bss (NOLOAD) : SUBALIGN(1) {
        \\        *(.bss*)
        \\    } > DMEM
        \\
    ;
    const bss_first =
        \\    .bss (NOLOAD) : SUBALIGN(1) {
        \\        *(.bss*)
        \\    } > DMEM
        \\
        \\    .state ALIGN(16) : SUBALIGN(1) {
        \\        KEEP(*(.state*))
        \\    } > DMEM
        \\
    ;
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
        \\{s}
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
        data_start,
        0x1000 - data_start,
        text_start,
        imem_end - text_start,
        data_start,
        if (data_start == overlay_data_start) bss_first else state_first,
        text_start,
    });
    try writeProvides(writer, symbols);
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

test "compact PCM state precedes scratch while the legacy order is retained" {
    var compact = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer compact.deinit();
    try writeLinkerScript(&compact.writer, 0x1290, 0x220, 0x220, &.{});
    const bytes = compact.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, ".data 0x0220") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ".state ALIGN").? < std.mem.indexOf(u8, bytes, ".bss (NOLOAD)").?);
    var legacy = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer legacy.deinit();
    try writeLinkerScript(&legacy.writer, 0x1290, 0xa00, 0xa00, &.{});
    const old = legacy.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, old, ".data 0x0a00") != null);
    try std.testing.expect(std.mem.indexOf(u8, old, ".bss (NOLOAD)").? < std.mem.indexOf(u8, old, ".state ALIGN").?);
}

const test_elf = @import("rsp_pack/test_elf.zig");

const TestFiles = struct {
    temp: std.testing.TmpDir,
    directory: [:0]u8,

    fn init() !TestFiles {
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        return .{ .temp = temp, .directory = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator) };
    }

    fn deinit(self: *TestFiles) void {
        std.testing.allocator.free(self.directory);
        self.temp.cleanup();
    }

    fn write(self: *TestFiles, name: []const u8, data: []const u8) ![]u8 {
        try self.temp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
        return self.path(name);
    }

    fn path(self: *TestFiles, name: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.directory, name });
    }

    fn read(self: *TestFiles, name: []const u8) ![]u8 {
        return self.temp.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .unlimited);
    }
};

/// An ELF with `.text` at `text` and the symbols `entries` naming `strings`.
fn testElf(text: u32, strings: []const u8, entries: []const u8) ![]u8 {
    return test_elf.build(std.testing.allocator, text, &.{
        .{ .name = ".text", .addr = text, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .name = ".symtab", .type = std.elf.SHT_SYMTAB, .data = entries, .link = 3, .entsize = 16 },
        .{ .name = ".strtab", .type = std.elf.SHT_STRTAB, .data = strings },
    });
}

const resident_strings = "\x00commandLoop\x00zsp_m1_dma__out\x00rdp_current\x00local\x00_start\x00";
const resident_entries = test_elf.globalSymbol(1, 0x1100, 1) ++ test_elf.symbol(13, 0x1120, 1) ++
    test_elf.globalSymbol(29, 0x1d0, 1) ++ test_elf.symbol(41, 0x80, 1) ++ test_elf.globalSymbol(47, 0x1000, 1);
const resident_interface =
    \\// @zsp-symbol commandLoop commandLoop
    \\// @zsp-symbol out zsp_m1_dma__out
    \\
;

fn runArgs(args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try run(std.testing.io, arena.allocator(), args);
}

test "an overlay links after the resident and sees its public symbols" {
    var files = try TestFiles.init();
    defer files.deinit();
    const elf = try testElf(0x1000, resident_strings, &resident_entries);
    defer std.testing.allocator.free(elf);
    const resident = try files.write("resident.elf", elf);
    defer std.testing.allocator.free(resident);
    const interface = try files.write("resident.zspi", resident_interface);
    defer std.testing.allocator.free(interface);
    const output = try files.path("overlay.ld");
    defer std.testing.allocator.free(output);

    try runArgs(&.{ resident, interface, "0x230", output });
    const script = try files.read("overlay.ld");
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, ".text 0x1010") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "PROVIDE(commandLoop = 0x1100);") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "PROVIDE(out = 0x1120);") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "PROVIDE(rdp_current = 0x1d0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "local") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "_start =") == null);

    try std.testing.expectError(error.InvalidStateStart, runArgs(&.{ resident, interface, "0xb00", output }));
    try std.testing.expectError(error.InvalidDataStart, runArgs(&.{ resident, interface, "0x230", output, "0x234" }));
    try std.testing.expectError(error.InvalidArguments, runArgs(&.{resident}));
    const missing = try files.write("missing.zspi", "// @zsp-symbol absent absent\n");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.MissingInterfaceSymbol, runArgs(&.{ resident, missing, "0x230", output }));
}

test "a patch links at its parent's symbol and sees the parent's globals" {
    var files = try TestFiles.init();
    defer files.deinit();
    const elf = try testElf(0x1000, resident_strings, &resident_entries);
    defer std.testing.allocator.free(elf);
    const resident = try files.write("resident.elf", elf);
    defer std.testing.allocator.free(resident);
    const interface = try files.write("resident.zspi", resident_interface);
    defer std.testing.allocator.free(interface);

    const parent_strings = "\x00_start\x00send\x00planes\x00rdp_current\x00hidden\x00odd\x00";
    const parent_entries = test_elf.globalSymbol(1, 0x1880, 1) ++ test_elf.globalSymbol(8, 0x1400, 1) ++
        test_elf.globalSymbol(13, 0x330, 1) ++ test_elf.globalSymbol(20, 0x1d0, std.elf.SHN_ABS) ++
        test_elf.symbol(32, 0x340, 1) ++ test_elf.symbol(39, 0x1884, 1);
    const parent_elf = try testElf(0x1290, parent_strings, &parent_entries);
    defer std.testing.allocator.free(parent_elf);
    const parent = try files.write("parent.elf", parent_elf);
    defer std.testing.allocator.free(parent);
    const output = try files.path("patch.ld");
    defer std.testing.allocator.free(output);

    try runArgs(&.{ "--patch", resident, interface, parent, "_start", output });
    const script = try files.read("patch.ld");
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, ".text 0x1880") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ASSERT(SIZEOF(.data) == 0") != null);
    for ([_][]const u8{ "PROVIDE(send = 0x1400);", "PROVIDE(planes = 0x330);", "PROVIDE(commandLoop = 0x1100);" }) |line| {
        try std.testing.expect(std.mem.indexOf(u8, script, line) != null);
    }
    // The resident's DMEM symbol is provided once, and locals not at all.
    const first = std.mem.indexOf(u8, script, "PROVIDE(rdp_current").?;
    try std.testing.expect(std.mem.indexOf(u8, script[first + 1 ..], "PROVIDE(rdp_current") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "hidden") == null);

    try std.testing.expectError(error.MissingPatchSymbol, runArgs(&.{ "--patch", resident, interface, parent, "absent", output }));
    try std.testing.expectError(error.InvalidPatchSymbol, runArgs(&.{ "--patch", resident, interface, parent, "odd", output }));
    try std.testing.expectError(error.InvalidPatchSymbol, runArgs(&.{ "--patch", resident, interface, parent, "planes", output }));
}

test "merged symbols must agree on shared names" {
    const first = [_]ExportedSymbol{.{ .name = "a", .value = 1 }};
    const agreeing = [_]ExportedSymbol{ .{ .name = "b", .value = 2 }, .{ .name = "a", .value = 1 } };
    const merged = try mergeSymbols(std.testing.allocator, &first, &agreeing);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("b", merged[1].name);
    const conflicting = [_]ExportedSymbol{.{ .name = "a", .value = 3 }};
    try std.testing.expectError(error.ConflictingSymbol, mergeSymbols(std.testing.allocator, &first, &conflicting));
}

test "failures print usage or the error name" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(usage, failureMessage(&buffer, error.InvalidArguments));
    try std.testing.expectEqualStrings("rsp_overlay_link: error: MissingPatchSymbol\n", failureMessage(&buffer, error.MissingPatchSymbol));
    try std.testing.expectEqualStrings("rsp_overlay_link: error\n", failureMessage(buffer[0..4], error.MissingPatchSymbol));
}

test "interface aliases are well formed and unique" {
    try std.testing.expectError(error.InvalidInterfaceMetadata, parseAliases(std.testing.allocator, "// @zsp-symbol lonely\n"));
    try std.testing.expectError(error.InvalidInterfaceMetadata, parseAliases(std.testing.allocator, "// @zsp-symbol a b c\n"));
    try std.testing.expectError(error.DuplicateInterfaceSymbol, parseAliases(std.testing.allocator, "// @zsp-symbol a b\n// @zsp-symbol a c\n"));
    try std.testing.expectError(error.DuplicateInterfaceSymbol, parseAliases(std.testing.allocator, "// @zsp-symbol a b\n// @zsp-symbol c b\n"));
}
