const std = @import("std");
const elf = std.elf;

const header_size = 8;
const imem_base = 0x1000;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;
    const io = init.io;

    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &err_buf);
    const stderr = &err_writer.interface;

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 3) {
        try stderr.print("Usage: rsp_pack <input.elf> <output.rsp>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const elf_bytes = try readAll(io, alloc, args[1]);
    defer alloc.free(elf_bytes);

    const rsp = try pack(alloc, elf_bytes);
    defer alloc.free(rsp);

    const out = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer out.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = out.writer(io, &write_buf);
    try writer.interface.writeAll(rsp);
    try writer.interface.flush();
}

fn readAll(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var reader = f.reader(io, &buf);
    return reader.interface.allocRemaining(alloc, .unlimited);
}

fn pack(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(bytes);
    const header = try elf.Header.read(&reader);
    if (header.is_64 or header.endian != .big) return error.UnsupportedElf;

    const text = (try findSection(bytes, header, ".text")) orelse return error.MissingTextSection;
    const data = try findSection(bytes, header, ".data");

    if (header.entry < text.sh_addr or header.entry >= text.sh_addr + text.sh_size) return error.EntryOutsideText;
    const pc_start = header.entry - imem_base;
    if (pc_start > std.math.maxInt(u16)) return error.ProgramCounterTooLarge;
    if (text.sh_size > 0x1000) return error.TextTooLarge;
    if (data) |d| {
        if (d.sh_size > 0x1000) return error.DataTooLarge;
    }

    const text_size: usize = @intCast(text.sh_size);
    const data_size: usize = if (data) |d| @intCast(d.sh_size) else 0;
    const padded_text_size = std.mem.alignForward(usize, text_size, 8);
    const padded_data_size = std.mem.alignForward(usize, data_size, 8);
    const data_offset = header_size + padded_text_size;
    if (padded_text_size > 0x1000) return error.TextTooLarge;
    if (padded_data_size > 0x1000) return error.DataTooLarge;
    if (padded_text_size > std.math.maxInt(u16)) return error.TextTooLarge;
    if (padded_data_size > std.math.maxInt(u16)) return error.DataTooLarge;
    if (data_offset > std.math.maxInt(u16)) return error.DataOffsetTooLarge;
    const out_size = data_offset + padded_data_size;

    const out = try alloc.alloc(u8, out_size);
    @memset(out, 0);

    w16(out, 0, @intCast(padded_text_size));
    w16(out, 2, @intCast(padded_data_size));
    w16(out, 4, @intCast(data_offset));
    w16(out, 6, @intCast(pc_start));

    copySection(out[header_size..][0..text_size], bytes, text) catch |err| {
        alloc.free(out);
        return err;
    };
    if (data) |d| {
        copySection(out[data_offset..][0..data_size], bytes, d) catch |err| {
            alloc.free(out);
            return err;
        };
    }

    return out;
}

fn copySection(dest: []u8, bytes: []const u8, section: elf.Elf64_Shdr) !void {
    if (section.sh_type == elf.SHT_NOBITS) {
        @memset(dest, 0);
        return;
    }
    const offset: usize = @intCast(section.sh_offset);
    const size: usize = @intCast(section.sh_size);
    if (offset + size > bytes.len) return error.BadElf;
    @memcpy(dest, bytes[offset..][0..size]);
}

fn findSection(bytes: []const u8, header: elf.Header, name: []const u8) !?elf.Elf64_Shdr {
    const shstr = try sectionNameTable(bytes, header);
    var sections = header.iterateSectionHeadersBuffer(bytes);
    while (try sections.next()) |section| {
        if (section.sh_name >= shstr.len) return error.BadElf;
        const section_name = std.mem.sliceTo(shstr[section.sh_name..], 0);
        if (!std.mem.eql(u8, section_name, name)) continue;
        return section;
    }

    return null;
}

fn sectionNameTable(bytes: []const u8, header: elf.Header) ![]const u8 {
    if (header.shstrndx >= header.shnum) return error.BadElf;
    var sections = header.iterateSectionHeadersBuffer(bytes);
    var index: usize = 0;
    while (try sections.next()) |section| : (index += 1) {
        if (index != header.shstrndx) continue;
        const offset: usize = @intCast(section.sh_offset);
        const size: usize = @intCast(section.sh_size);
        if (offset + size > bytes.len) return error.BadElf;
        return bytes[offset..][0..size];
    }
    return error.BadElf;
}

fn w16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .big);
}
