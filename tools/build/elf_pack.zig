const std = @import("std");

// Produces a stripped, ROM-ready ELF from the canonical debug ELF + srcmap:
//   - copies only PT_LOAD segments, preserving their linked virtual addresses
//   - removes section headers, symbols, DWARF, and other non-loadable data
//   - appends srcmap as raw ROM data and patches its ROM offset/size into RAM
//
// Usage: elf_pack <input.elf> <input.srcmap> <output.elf>

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;
    const io = init.io;

    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &err_buf);
    const stderr = &err_writer.interface;

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 4) {
        try stderr.print("Usage: elf_pack <input.elf> <input.srcmap> <output.elf>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const elf_data = try readAll(io, alloc, args[1]);
    defer alloc.free(elf_data);
    const srcmap_data = try readAll(io, alloc, args[2]);
    defer alloc.free(srcmap_data);

    const out = try pack(alloc, elf_data, srcmap_data);
    defer alloc.free(out);

    const f = try std.Io.Dir.cwd().createFile(io, args[3], .{});
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var writer = f.writer(io, &write_buf);
    try writer.interface.writeAll(out);
    try writer.interface.flush();
}

fn readAll(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    return reader.interface.allocRemaining(alloc, .unlimited);
}

const Error = error{
    BadElf,
    UnsupportedElf,
    MissingSymbol,
    ProgramHeaderTableTooLarge,
};

fn pack(alloc: std.mem.Allocator, elf: []const u8, srcmap: []const u8) ![]u8 {
    if (elf.len < 52) return Error.BadElf;
    if (!std.mem.eql(u8, elf[0..4], "\x7fELF")) return Error.BadElf;
    if (elf[4] != 1 or elf[5] != 2) return Error.UnsupportedElf; // ELF32, big-endian

    const phoff = r32(elf, EH_PHOFF);
    const phnum = r16(elf, EH_PHNUM);
    const phent = r16(elf, EH_PHENT);
    if (phent != 32) return Error.UnsupportedElf;
    if (@as(usize, phoff) + @as(usize, phnum) * phent > elf.len) return Error.BadElf;

    const srcmap_rom_offset_vaddr = try findSymbol(elf, "__srcmap_rom_offset");
    const srcmap_rom_size_vaddr = try findSymbol(elf, "__srcmap_rom_size");

    var load_count: u16 = 0;
    for (0..phnum) |i| {
        const ph = @as(usize, phoff) + i * phent;
        if (r32(elf, ph + PH_TYPE) != PT_LOAD) continue;
        load_count += 1;
    }

    const new_phnum = load_count;
    const ph_table_end: u32 = phoff + @as(u32, new_phnum) * phent;
    if (ph_table_end > 1024) return Error.ProgramHeaderTableTooLarge;

    var cursor: u32 = std.mem.alignForward(u32, ph_table_end, 16);
    for (0..phnum) |i| {
        const ph = @as(usize, phoff) + i * phent;
        if (r32(elf, ph + PH_TYPE) != PT_LOAD) continue;

        const segment_align = @max(r32(elf, ph + PH_ALIGN), 2);
        cursor = std.mem.alignForward(u32, cursor, segment_align);
        cursor += r32(elf, ph + PH_FILESZ);
    }

    cursor = std.mem.alignForward(u32, cursor, 4);
    const srcmap_offset = cursor;
    cursor += @intCast(srcmap.len);

    const out = try alloc.alloc(u8, cursor);
    @memset(out, 0);

    @memcpy(out[0..52], elf[0..52]);
    w32(out, EH_SHOFF, 0);
    w16(out, EH_PHNUM, new_phnum);
    w16(out, EH_SHNUM, 0);
    w16(out, EH_SHSTRNDX, 0);

    var ph_idx: u16 = 0;
    var data_cursor: u32 = std.mem.alignForward(u32, ph_table_end, 16);
    for (0..phnum) |i| {
        const src_ph = @as(usize, phoff) + i * phent;
        if (r32(elf, src_ph + PH_TYPE) != PT_LOAD) continue;

        const segment_align = @max(r32(elf, src_ph + PH_ALIGN), 2);
        data_cursor = std.mem.alignForward(u32, data_cursor, segment_align);

        const filesz = r32(elf, src_ph + PH_FILESZ);
        const src_off = r32(elf, src_ph + PH_OFFSET);
        if (@as(usize, src_off) + filesz > elf.len) return Error.BadElf;

        @memcpy(
            out[@as(usize, data_cursor)..@as(usize, data_cursor + filesz)],
            elf[@as(usize, src_off)..@as(usize, src_off + filesz)],
        );

        const dst_ph = @as(usize, phoff) + @as(usize, ph_idx) * phent;
        @memcpy(out[dst_ph..][0..32], elf[src_ph..][0..32]);
        w32(out, dst_ph + PH_OFFSET, data_cursor);

        data_cursor += filesz;
        ph_idx += 1;
    }

    patchU32AtVaddr(out, phoff, new_phnum, phent, srcmap_rom_offset_vaddr, srcmap_offset) catch return Error.BadElf;
    patchU32AtVaddr(out, phoff, new_phnum, phent, srcmap_rom_size_vaddr, @intCast(srcmap.len)) catch return Error.BadElf;
    @memcpy(out[@as(usize, srcmap_offset)..@as(usize, srcmap_offset + srcmap.len)], srcmap);

    return out;
}

fn patchU32AtVaddr(out: []u8, phoff: u32, phnum: u16, phent: u16, vaddr: u32, value: u32) !void {
    const off = try vaddrToFileOffset(out, phoff, phnum, phent, vaddr);
    if (off + 4 > out.len) return Error.BadElf;
    w32(out, off, value);
}

fn vaddrToFileOffset(elf: []const u8, phoff: u32, phnum: u16, phent: u16, vaddr: u32) !usize {
    for (0..phnum) |i| {
        const ph = @as(usize, phoff) + i * phent;
        if (ph + 32 > elf.len) return Error.BadElf;
        if (r32(elf, ph + PH_TYPE) != PT_LOAD) continue;
        const offset = r32(elf, ph + PH_OFFSET);
        const seg_vaddr = r32(elf, ph + PH_VADDR);
        const filesz = r32(elf, ph + PH_FILESZ);
        if (vaddr >= seg_vaddr and vaddr + 4 <= seg_vaddr + filesz)
            return @as(usize, offset) + (vaddr - seg_vaddr);
    }
    return Error.BadElf;
}

fn findSymbol(elf: []const u8, name: []const u8) !u32 {
    const shoff = r32(elf, EH_SHOFF);
    const shnum = r16(elf, EH_SHNUM);
    const shent = r16(elf, EH_SHENT);
    if (shoff == 0 or shnum == 0 or shent < 40) return Error.MissingSymbol;
    if (@as(usize, shoff) + @as(usize, shnum) * shent > elf.len) return Error.BadElf;

    for (0..shnum) |i| {
        const sh = @as(usize, shoff) + i * shent;
        if (r32(elf, sh + SH_TYPE) != SHT_SYMTAB) continue;

        const sym_off = r32(elf, sh + SH_OFFSET);
        const sym_size = r32(elf, sh + SH_SIZE);
        const sym_ent = r32(elf, sh + SH_ENTSIZE);
        const str_idx = r32(elf, sh + SH_LINK);
        if (sym_ent < 16 or str_idx >= shnum) return Error.BadElf;

        const str_sh = @as(usize, shoff) + @as(usize, str_idx) * shent;
        const str_off = r32(elf, str_sh + SH_OFFSET);
        const str_size = r32(elf, str_sh + SH_SIZE);
        if (@as(usize, sym_off) + sym_size > elf.len) return Error.BadElf;
        if (@as(usize, str_off) + str_size > elf.len) return Error.BadElf;

        var off: u32 = 0;
        while (off + sym_ent <= sym_size) : (off += sym_ent) {
            const sym = @as(usize, sym_off + off);
            const name_off = r32(elf, sym + ST_NAME);
            if (name_off >= str_size) continue;

            const sym_name = sliceZ(elf[@as(usize, str_off + name_off)..@as(usize, str_off + str_size)]);
            if (std.mem.eql(u8, sym_name, name))
                return r32(elf, sym + ST_VALUE);
        }
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
const PH_PADDR = 12;
const PH_FILESZ = 16;
const PH_MEMSZ = 20;
const PH_FLAGS = 24;
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
