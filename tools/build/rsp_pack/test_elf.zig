//! Builds small 32-bit big-endian ELF files for tests.
const std = @import("std");
const elf = std.elf;

pub const Section = struct {
    name: []const u8,
    type: u32 = elf.SHT_PROGBITS,
    addr: u32 = 0,
    data: []const u8 = &.{},
    /// Size of a `NOBITS` section, which has no data in the file.
    nobits_size: u32 = 0,
    link: u32 = 0,
    entsize: u32 = 0,
};

/// Section `i` of `sections` gets index `i + 1`; the name table is last.
pub fn build(allocator: std.mem.Allocator, entry: u32, sections: []const Section) ![]u8 {
    var names: std.Io.Writer.Allocating = .init(allocator);
    defer names.deinit();
    try names.writer.writeByte(0);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.splatByteAll(0, @sizeOf(elf.Elf32_Ehdr));
    var headers: std.ArrayList(elf.Elf32_Shdr) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, std.mem.zeroes(elf.Elf32_Shdr));
    for (sections) |section| {
        try headers.append(allocator, .{
            .sh_name = @intCast(names.written().len),
            .sh_type = section.type,
            .sh_flags = 0,
            .sh_addr = section.addr,
            .sh_offset = @intCast(out.written().len),
            .sh_size = if (section.type == elf.SHT_NOBITS) section.nobits_size else @intCast(section.data.len),
            .sh_link = section.link,
            .sh_info = 0,
            .sh_addralign = 1,
            .sh_entsize = section.entsize,
        });
        try names.writer.print("{s}\x00", .{section.name});
        try w.writeAll(section.data);
    }
    const names_name: u32 = @intCast(names.written().len);
    try names.writer.writeAll(".shstrtab\x00");
    try headers.append(allocator, .{
        .sh_name = names_name,
        .sh_type = elf.SHT_STRTAB,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = @intCast(out.written().len),
        .sh_size = @intCast(names.written().len),
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    });
    try w.writeAll(names.written());
    try w.splatByteAll(0, std.mem.alignForward(usize, out.written().len, 4) - out.written().len);
    const section_offset: u32 = @intCast(out.written().len);
    for (headers.items) |header| try w.writeStruct(header, .big);
    var bytes = try out.toOwnedSlice();
    var header_writer = std.Io.Writer.fixed(bytes[0..@sizeOf(elf.Elf32_Ehdr)]);
    try header_writer.writeStruct(fileHeader(entry, section_offset, @intCast(headers.items.len)), .big);
    return bytes;
}

fn fileHeader(entry: u32, section_offset: u32, section_count: u16) elf.Elf32_Ehdr {
    var ident: [elf.EI.NIDENT]u8 = @splat(0);
    @memcpy(ident[0..4], elf.MAGIC);
    ident[elf.EI.CLASS] = elf.ELFCLASS32;
    ident[elf.EI.DATA] = elf.ELFDATA2MSB;
    ident[elf.EI.VERSION] = 1;
    return .{
        .e_ident = ident,
        .e_type = .EXEC,
        .e_machine = .MIPS,
        .e_version = 1,
        .e_entry = entry,
        .e_phoff = 0,
        .e_shoff = section_offset,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Elf32_Ehdr),
        .e_phentsize = @sizeOf(elf.Elf32_Phdr),
        .e_phnum = 0,
        .e_shentsize = @sizeOf(elf.Elf32_Shdr),
        .e_shnum = section_count,
        .e_shstrndx = section_count - 1,
    };
}

/// One `Elf32_Sym` entry, as bytes.
pub fn symbol(name: u32, value: u32, section: u16) [16]u8 {
    var bytes: [16]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], name, .big);
    std.mem.writeInt(u32, bytes[4..8], value, .big);
    std.mem.writeInt(u16, bytes[14..16], section, .big);
    return bytes;
}

/// A global `Elf32_Sym` entry, as bytes.
pub fn globalSymbol(name: u32, value: u32, section: u16) [16]u8 {
    var bytes = symbol(name, value, section);
    bytes[12] = @as(u8, elf.STB_GLOBAL) << 4;
    return bytes;
}
