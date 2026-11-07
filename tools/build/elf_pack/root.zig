//! Produces a stripped, ROM-ready ELF from the canonical debug ELF + srcmap:
//!   - copies only PT_LOAD segments, preserving their linked virtual addresses
//!   - removes section headers, symbols, DWARF, and other non-loadable data
//!   - appends srcmap as raw ROM data and patches its ROM offset/size into RAM
//!   - optionally appends ROM assets and patches their final ROM offset/size
const std = @import("std");

pub const usage = "Usage: elf_pack <input.elf> <input.srcmap> <output.elf> [<rom-assets.bin> <boot.bin> [<rom-limit>]]\n";

pub const Error = error{
    BadElf,
    UnsupportedElf,
    MissingSymbol,
    ProgramHeaderTableTooLarge,
    RomTooLarge,
};

pub const Options = struct {
    elf: []const u8,
    srcmap: []const u8,
    output: []const u8,
    assets: ?[]const u8 = null,
    boot: ?[]const u8 = null,
    rom_limit: u32 = max_rom_bytes,
};

const max_rom_bytes = 64 * 1024 * 1024;

/// Parses arguments without argv[0].
pub fn parseArgs(args: []const []const u8) error{InvalidArguments}!Options {
    if (args.len != 3 and args.len != 5 and args.len != 6) return error.InvalidArguments;
    var options: Options = .{ .elf = args[0], .srcmap = args[1], .output = args[2] };
    if (args.len == 3) return options;
    options.assets = args[3];
    options.boot = args[4];
    if (args.len == 6) options.rom_limit = std.fmt.parseInt(u32, args[5], 10) catch return error.InvalidArguments;
    return options;
}

/// Reads the inputs, packs them, and writes the output file.
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const options = try parseArgs(args);
    const elf = try readFile(io, allocator, options.elf);
    defer allocator.free(elf);
    const srcmap = try readFile(io, allocator, options.srcmap);
    defer allocator.free(srcmap);
    const assets = try readOptional(io, allocator, options.assets);
    defer allocator.free(assets);
    const boot = try readOptional(io, allocator, options.boot);
    defer allocator.free(boot);
    const out = try pack(allocator, elf, srcmap, assets, romBase(boot.len), options.rom_limit);
    defer allocator.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = options.output, .data = out });
}

/// ipl3_cat pads the boot code to the NEXT 256-byte boundary, even when it
/// is already aligned.
fn romBase(boot_len: usize) u32 {
    return @intCast(boot_len + 256 - boot_len % 256);
}

fn readOptional(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    return if (path) |file| readFile(io, allocator, file) else allocator.alloc(u8, 0);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

const Header = struct {
    phoff: u32,
    phnum: u16,
    phent: u16,

    fn programHeader(self: Header, index: usize) usize {
        return @as(usize, self.phoff) + index * self.phent;
    }
};

/// Checks the magic and that the ELF is 32-bit big-endian.
fn checkIdentity(elf: []const u8) Error!void {
    if (elf.len < 52 or !std.mem.eql(u8, elf[0..4], "\x7fELF")) return Error.BadElf;
    if (elf[4] != 1 or elf[5] != 2) return Error.UnsupportedElf;
}

fn readHeader(elf: []const u8) Error!Header {
    try checkIdentity(elf);
    const header: Header = .{ .phoff = r32(elf, EH_PHOFF), .phnum = r16(elf, EH_PHNUM), .phent = r16(elf, EH_PHENT) };
    if (header.phent != 32) return Error.UnsupportedElf;
    if (header.programHeader(header.phnum) > elf.len) return Error.BadElf;
    return header;
}

/// Offsets of the PT_LOAD program headers; the output table must fit the
/// first KiB, so 32 entries is the most a valid input can keep.
const LoadHeaders = struct {
    offsets: [32]usize = undefined,
    len: u16 = 0,

    fn slice(self: *const LoadHeaders) []const usize {
        return self.offsets[0..self.len];
    }
};

fn loadHeaders(elf: []const u8, header: Header) Error!LoadHeaders {
    var result: LoadHeaders = .{};
    for (0..header.phnum) |index| {
        const ph = header.programHeader(index);
        if (r32(elf, ph + PH_TYPE) != PT_LOAD) continue;
        if (result.len == result.offsets.len) return Error.ProgramHeaderTableTooLarge;
        result.offsets[result.len] = ph;
        result.len += 1;
    }
    if (header.phoff + @as(u32, result.len) * header.phent > 1024) return Error.ProgramHeaderTableTooLarge;
    return result;
}

const Layout = struct {
    segments_start: u32,
    srcmap_offset: u32,
    assets_offset: u32,
    size: u32,
};

fn segmentAlign(elf: []const u8, ph: usize) u32 {
    return @max(r32(elf, ph + PH_ALIGN), 2);
}

fn layout(elf: []const u8, header: Header, loads: *const LoadHeaders, srcmap_len: usize, assets_len: usize, rom_base: u32, rom_limit: u32) Error!Layout {
    const segments_start = std.mem.alignForward(u32, header.phoff + @as(u32, loads.len) * header.phent, 16);
    var cursor = segments_start;
    for (loads.slice()) |ph| cursor = std.mem.alignForward(u32, cursor, segmentAlign(elf, ph)) + r32(elf, ph + PH_FILESZ);
    const srcmap_offset = std.mem.alignForward(u32, cursor, 4);
    const srcmap_end = srcmap_offset + @as(u32, @intCast(srcmap_len));
    const assets_offset = std.mem.alignForward(u32, srcmap_end, 16);
    if (assets_len == 0) return .{ .segments_start = segments_start, .srcmap_offset = srcmap_offset, .assets_offset = assets_offset, .size = srcmap_end };
    const assets_end = @as(u64, assets_offset) + assets_len;
    if (rom_base + assets_end > max_rom_bytes) return Error.RomTooLarge;
    try validateRomSize(rom_base + assets_end, rom_limit);
    return .{ .segments_start = segments_start, .srcmap_offset = srcmap_offset, .assets_offset = assets_offset, .size = @intCast(assets_end) };
}

/// Copies each loadable segment after the program headers and points its
/// header at the new file offset.
fn copySegments(out: []u8, elf: []const u8, header: Header, loads: *const LoadHeaders, start: u32) Error!void {
    var cursor = start;
    for (loads.slice(), 0..) |src_ph, index| {
        cursor = std.mem.alignForward(u32, cursor, segmentAlign(elf, src_ph));
        const filesz = r32(elf, src_ph + PH_FILESZ);
        const src_off = r32(elf, src_ph + PH_OFFSET);
        if (@as(usize, src_off) + filesz > elf.len) return Error.BadElf;
        @memcpy(out[cursor..][0..filesz], elf[src_off..][0..filesz]);
        const dst_ph = header.programHeader(index);
        @memcpy(out[dst_ph..][0..32], elf[src_ph..][0..32]);
        w32(out, dst_ph + PH_OFFSET, cursor);
        cursor += filesz;
    }
}

/// Copies the ELF header, dropping section headers.
fn writeHeader(out: []u8, elf: []const u8, load_count: u16) void {
    @memcpy(out[0..52], elf[0..52]);
    w32(out, EH_SHOFF, 0);
    w16(out, EH_PHNUM, load_count);
    w16(out, EH_SHNUM, 0);
    w16(out, EH_SHSTRNDX, 0);
}

/// Appends `payload` at `offset` and stores its ROM address and size in the
/// two named RAM words.
fn embed(out: []u8, elf: []const u8, header: Header, names: [2][]const u8, payload: []const u8, offset: u32, rom_address: u32) Error!void {
    const address = try findSymbol(elf, names[0]);
    const size = try findSymbol(elf, names[1]);
    try patchU32AtVaddr(out, header, address, rom_address);
    try patchU32AtVaddr(out, header, size, @intCast(payload.len));
    @memcpy(out[offset..][0..payload.len], payload);
}

pub fn pack(alloc: std.mem.Allocator, elf: []const u8, srcmap: []const u8, assets: []const u8, rom_base: u32, rom_limit: u32) ![]u8 {
    const header = try readHeader(elf);
    const loads = try loadHeaders(elf, header);
    const plan = try layout(elf, header, &loads, srcmap.len, assets.len, rom_base, rom_limit);

    const out = try alloc.alloc(u8, plan.size);
    errdefer alloc.free(out);
    @memset(out, 0);
    writeHeader(out, elf, loads.len);
    try copySegments(out, elf, header, &loads, plan.segments_start);
    const packed_header: Header = .{ .phoff = header.phoff, .phnum = loads.len, .phent = header.phent };
    try embed(out, elf, packed_header, .{ "__srcmap_rom_offset", "__srcmap_rom_size" }, srcmap, plan.srcmap_offset, plan.srcmap_offset);
    if (assets.len != 0) try embed(out, elf, packed_header, .{ "__rom_assets_rom_offset", "__rom_assets_rom_size" }, assets, plan.assets_offset, rom_base + plan.assets_offset);
    return out;
}

fn validateRomSize(unpadded: u64, limit: u32) Error!void {
    // ipl3_cat rounds to the NEXT 16 KiB boundary, including aligned inputs.
    const padded = (unpadded / (16 * 1024) + 1) * (16 * 1024);
    if (padded > @min(limit, max_rom_bytes)) return Error.RomTooLarge;
}

fn patchU32AtVaddr(out: []u8, header: Header, vaddr: u32, value: u32) Error!void {
    const off = try vaddrToFileOffset(out, header, vaddr);
    if (off + 4 > out.len) return Error.BadElf;
    w32(out, off, value);
}

fn vaddrToFileOffset(elf: []const u8, header: Header, vaddr: u32) Error!usize {
    for (0..header.phnum) |index| {
        const ph = header.programHeader(index);
        if (ph + 32 > elf.len) return Error.BadElf;
        if (r32(elf, ph + PH_TYPE) != PT_LOAD) continue;
        const seg_vaddr = r32(elf, ph + PH_VADDR);
        if (vaddr >= seg_vaddr and vaddr + 4 <= seg_vaddr + r32(elf, ph + PH_FILESZ))
            return @as(usize, r32(elf, ph + PH_OFFSET)) + (vaddr - seg_vaddr);
    }
    return Error.BadElf;
}

const SymbolTable = struct {
    symbols: []const u8,
    entry_size: u32,
    strings: []const u8,

    fn find(self: SymbolTable, name: []const u8) ?u32 {
        var off: usize = 0;
        while (off + self.entry_size <= self.symbols.len) : (off += self.entry_size) {
            const name_off = r32(self.symbols, off + ST_NAME);
            if (name_off >= self.strings.len) continue;
            if (std.mem.eql(u8, sliceZ(self.strings[name_off..]), name)) return r32(self.symbols, off + ST_VALUE);
        }
        return null;
    }
};

const Sections = struct {
    shoff: u32,
    shnum: u16,
    shent: u16,

    fn header(self: Sections, index: usize) usize {
        return @as(usize, self.shoff) + index * self.shent;
    }

    fn bytes(self: Sections, elf: []const u8, index: usize) Error![]const u8 {
        const sh = self.header(index);
        const offset = r32(elf, sh + SH_OFFSET);
        const size = r32(elf, sh + SH_SIZE);
        if (@as(usize, offset) + size > elf.len) return Error.BadElf;
        return elf[offset..][0..size];
    }

    fn symbolTable(self: Sections, elf: []const u8, index: usize) Error!SymbolTable {
        const sh = self.header(index);
        const entry_size = r32(elf, sh + SH_ENTSIZE);
        const strings_index = r32(elf, sh + SH_LINK);
        if (entry_size < 16 or strings_index >= self.shnum) return Error.BadElf;
        return .{ .symbols = try self.bytes(elf, index), .entry_size = entry_size, .strings = try self.bytes(elf, strings_index) };
    }
};

fn readSections(elf: []const u8) Error!Sections {
    const sections: Sections = .{ .shoff = r32(elf, EH_SHOFF), .shnum = r16(elf, EH_SHNUM), .shent = r16(elf, EH_SHENT) };
    if (sections.shoff == 0 or sections.shnum == 0 or sections.shent < 40) return Error.MissingSymbol;
    if (sections.header(sections.shnum) > elf.len) return Error.BadElf;
    return sections;
}

fn findSymbol(elf: []const u8, name: []const u8) Error!u32 {
    const sections = try readSections(elf);
    for (0..sections.shnum) |index| {
        if (r32(elf, sections.header(index) + SH_TYPE) != SHT_SYMTAB) continue;
        if ((try sections.symbolTable(elf, index)).find(name)) |value| return value;
    }
    return Error.MissingSymbol;
}

fn sliceZ(bytes: []const u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

fn r16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .big);
}

fn r32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .big);
}

fn w16(b: []u8, o: usize, v: u16) void {
    std.mem.writeInt(u16, b[o..][0..2], v, .big);
}

fn w32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .big);
}

const EH_PHOFF = 28;
const EH_SHOFF = 32;
const EH_PHENT = 42;
const EH_PHNUM = 44;
const EH_SHENT = 46;
const EH_SHNUM = 48;
const EH_SHSTRNDX = 50;

const PH_TYPE = 0;
const PH_OFFSET = 4;
const PH_VADDR = 8;
const PH_FILESZ = 16;
const PH_MEMSZ = 20;
const PH_ALIGN = 28;

const SH_TYPE = 4;
const SH_OFFSET = 16;
const SH_SIZE = 20;
const SH_LINK = 24;
const SH_ENTSIZE = 36;

const ST_NAME = 0;
const ST_VALUE = 4;

const PT_LOAD: u32 = 1;
const SHT_SYMTAB: u32 = 2;

/// A one-segment ELF defining the four metadata symbols.
fn fixtureElf() [640]u8 {
    var elf = [_]u8{0} ** 640;
    @memcpy(elf[0..6], "\x7fELF\x01\x02");
    w32(&elf, EH_PHOFF, 64);
    w16(&elf, EH_PHNUM, 1);
    w16(&elf, EH_PHENT, 32);
    w32(&elf, EH_SHOFF, 400);
    w16(&elf, EH_SHNUM, 3);
    w16(&elf, EH_SHENT, 40);
    w32(&elf, 64 + PH_TYPE, PT_LOAD);
    w32(&elf, 64 + PH_OFFSET, 128);
    w32(&elf, 64 + PH_VADDR, 0x80000000);
    w32(&elf, 64 + PH_FILESZ, 16);
    w32(&elf, 64 + PH_MEMSZ, 32);
    w32(&elf, 64 + PH_ALIGN, 8);
    w32(&elf, 440 + SH_TYPE, SHT_SYMTAB);
    w32(&elf, 440 + SH_OFFSET, 192);
    w32(&elf, 440 + SH_SIZE, 64);
    w32(&elf, 440 + SH_ENTSIZE, 16);
    w32(&elf, 440 + SH_LINK, 2);
    w32(&elf, 480 + SH_OFFSET, 256);
    var offset: u32 = 0;
    for ([_][]const u8{ "__srcmap_rom_offset", "__srcmap_rom_size", "__rom_assets_rom_offset", "__rom_assets_rom_size" }, 0..) |name, i| {
        w32(&elf, 192 + i * 16 + ST_NAME, offset);
        w32(&elf, 192 + i * 16 + ST_VALUE, 0x80000000 + @as(u32, @intCast(i * 4)));
        @memcpy(elf[256 + offset ..][0..name.len], name);
        offset += @intCast(name.len + 1);
    }
    w32(&elf, 480 + SH_SIZE, offset);
    return elf;
}

test "ROM payload stays outside loaded segments and metadata uses final ROM addresses" {
    const elf = fixtureElf();
    const out = try pack(std.testing.allocator, &elf, "srcmap", "ROM asset", 0x5000, 64 * 1024 * 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(u32, 16), r32(out, 64 + PH_FILESZ));
    try std.testing.expectEqual(@as(u32, 32), r32(out, 64 + PH_MEMSZ));
    const asset_offset = r32(out, 104) - 0x5000;
    try std.testing.expectEqual(@as(u32, 0), asset_offset % 16);
    try std.testing.expectEqualSlices(u8, "ROM asset", out[asset_offset..]);
    try std.testing.expectEqual(@as(u32, 9), r32(out, 108));
    try std.testing.expectEqual(@as(u16, 0), r16(out, EH_SHNUM));
    const minimal = try pack(std.testing.allocator, &elf, "srcmap", &.{}, 0, 64 * 1024 * 1024);
    defer std.testing.allocator.free(minimal);
    try std.testing.expectEqual(@as(usize, 118), minimal.len);
}

test "ROM limits include final cartridge padding and reject exact-capacity payloads" {
    try validateRomSize(64 * 1024 * 1024 - 1, 64 * 1024 * 1024);
    try std.testing.expectError(error.RomTooLarge, validateRomSize(64 * 1024 * 1024, 64 * 1024 * 1024));
    try validateRomSize(32767, 32768);
    try std.testing.expectError(error.RomTooLarge, validateRomSize(32768, 32768));
    try std.testing.expectError(error.RomTooLarge, validateRomSize(0, 0));
}

test "arguments select optional assets, boot code, and a ROM limit" {
    const testing = std.testing;
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "a", "b" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "a", "b", "c", "d", "e", "x" }));
    const minimal = try parseArgs(&.{ "in.elf", "in.srcmap", "out.elf" });
    try testing.expectEqual(@as(?[]const u8, null), minimal.assets);
    try testing.expectEqual(@as(u32, max_rom_bytes), minimal.rom_limit);
    const full = try parseArgs(&.{ "in.elf", "in.srcmap", "out.elf", "assets.bin", "boot.bin", "32768" });
    try testing.expectEqualStrings("boot.bin", full.boot.?);
    try testing.expectEqual(@as(u32, 32768), full.rom_limit);
    try testing.expectEqual(@as(u32, 256), romBase(0));
    try testing.expectEqual(@as(u32, 512), romBase(256));
}

test "run packs files on disk" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const elf = fixtureElf();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "in.elf", .data = &elf });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "in.srcmap", .data = "srcmap" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "assets.bin", .data = "ROM asset" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "boot.bin", .data = "boot" });
    const directory = try temp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory);
    var paths: [5][]u8 = undefined;
    for (&paths, [_][]const u8{ "in.elf", "in.srcmap", "out.elf", "assets.bin", "boot.bin" }) |*path, name| {
        path.* = try std.fs.path.join(testing.allocator, &.{ directory, name });
    }
    defer for (paths) |path| testing.allocator.free(path);
    try run(testing.allocator, testing.io, &.{ paths[0], paths[1], paths[2] });
    const minimal = try temp.dir.readFileAlloc(testing.io, "out.elf", testing.allocator, .unlimited);
    defer testing.allocator.free(minimal);
    try testing.expectEqual(@as(usize, 118), minimal.len);
    try run(testing.allocator, testing.io, &.{ paths[0], paths[1], paths[2], paths[3], paths[4] });
    const with_assets = try temp.dir.readFileAlloc(testing.io, "out.elf", testing.allocator, .unlimited);
    defer testing.allocator.free(with_assets);
    try testing.expectEqual(@as(u32, 256), r32(with_assets, 104) - (with_assets.len - 9));
}

test "malformed inputs are rejected" {
    const testing = std.testing;
    const allocator = testing.allocator;
    try testing.expectError(Error.BadElf, pack(allocator, "short", "", &.{}, 0, max_rom_bytes));
    var elf = fixtureElf();
    elf[4] = 2;
    try testing.expectError(Error.UnsupportedElf, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w16(&elf, EH_PHENT, 56);
    try testing.expectError(Error.UnsupportedElf, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    var late_table = [_]u8{0} ** 1200;
    @memcpy(late_table[0..640], &fixtureElf());
    @memcpy(late_table[1000..1032], late_table[64..96]);
    w32(&late_table, EH_PHOFF, 1000);
    try testing.expectError(Error.ProgramHeaderTableTooLarge, pack(allocator, &late_table, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w32(&elf, 64 + PH_OFFSET, 630);
    try testing.expectError(Error.BadElf, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w32(&elf, 192 + ST_VALUE, 0x9000_0000);
    try testing.expectError(Error.BadElf, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w32(&elf, 440 + SH_TYPE, 0);
    try testing.expectError(Error.MissingSymbol, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w16(&elf, EH_SHNUM, 0);
    try testing.expectError(Error.MissingSymbol, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w16(&elf, EH_SHNUM, 30);
    try testing.expectError(Error.BadElf, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w32(&elf, 440 + SH_ENTSIZE, 8);
    try testing.expectError(Error.BadElf, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w32(&elf, 480 + SH_SIZE, 4000);
    try testing.expectError(Error.BadElf, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    w32(&elf, 192 + ST_NAME, 900);
    try testing.expectError(Error.MissingSymbol, pack(allocator, &elf, "", &.{}, 0, max_rom_bytes));
    elf = fixtureElf();
    try testing.expectError(Error.RomTooLarge, pack(allocator, &elf, "", "asset", max_rom_bytes, max_rom_bytes));
    try testing.expectError(Error.RomTooLarge, pack(allocator, &elf, "", "asset", 0, 1024));
}
