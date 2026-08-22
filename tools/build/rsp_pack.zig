const std = @import("std");
const elf = std.elf;

const header_size = 24;
const imem_base = 0x1000;
const command_source_size = 8;
const command_packed_size = 4;

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
    const commands = try findSection(bytes, header, ".zsp_commands");
    const command_table = try findSection(bytes, header, ".zsp_command_table");
    const state = try findSection(bytes, header, ".state");
    const bss = try findSection(bytes, header, ".bss");

    if (header.entry < text.sh_addr or header.entry >= text.sh_addr + text.sh_size) return error.EntryOutsideText;
    const pc_start = header.entry - imem_base;
    if (text.sh_addr < imem_base) return error.TextOutsideImem;
    const text_start = text.sh_addr - imem_base;
    if (pc_start > std.math.maxInt(u16)) return error.ProgramCounterTooLarge;
    if (text_start > std.math.maxInt(u16)) return error.TextOutsideImem;
    if (text.sh_size > 0x1000) return error.TextTooLarge;
    if (data) |d| {
        if (d.sh_size > 0x1000) return error.DataTooLarge;
    }

    const text_size: usize = @intCast(text.sh_size);
    const data_size: usize = if (data) |d| @intCast(d.sh_size) else 0;
    const padded_text_size = std.mem.alignForward(usize, text_size, 8);
    const padded_data_size = std.mem.alignForward(usize, data_size, 8);
    const data_offset = header_size + padded_text_size;
    const command_count: usize = if (commands) |section| blk: {
        if (section.sh_size % command_source_size != 0) return error.InvalidCommandSection;
        const count: usize = @intCast(section.sh_size / command_source_size);
        if (count > 16) return error.TooManyCommands;
        break :blk count;
    } else 0;
    const commands_offset = data_offset + padded_data_size;
    var state_offset: u16 = 0;
    var state_size: u16 = 0;
    if (state) |section| {
        if (section.sh_addr + section.sh_size > 0x1000 or section.sh_addr & 7 != 0 or section.sh_size & 7 != 0) {
            return error.InvalidStateSection;
        }
        state_offset = @intCast(section.sh_addr);
        state_size = @intCast(section.sh_size);
    } else {
        var state_start: u64 = if (data) |section| section.sh_addr + section.sh_size else 0;
        if (bss) |section| state_start = @max(state_start, section.sh_addr + section.sh_size);
        state_start = std.mem.alignForward(u64, state_start, 8);
        if (state_start + 8 > 0x1000) return error.StateOutsideDmem;
        state_offset = @intCast(state_start);
        state_size = 8;
    }
    if (padded_text_size > 0x1000) return error.TextTooLarge;
    if (padded_data_size > 0x1000) return error.DataTooLarge;
    if (padded_text_size > std.math.maxInt(u16)) return error.TextTooLarge;
    if (padded_data_size > std.math.maxInt(u16)) return error.DataTooLarge;
    if (data_offset > std.math.maxInt(u16)) return error.DataOffsetTooLarge;
    const out_size = commands_offset + command_count * command_packed_size;

    const out = try alloc.alloc(u8, out_size);
    @memset(out, 0);

    w16(out, 0, @intCast(padded_text_size));
    w16(out, 2, @intCast(padded_data_size));
    w16(out, 4, @intCast(data_offset));
    w16(out, 6, @intCast(pc_start));
    w16(out, 8, @intCast(text_start));
    w16(out, 10, @intCast(commands_offset));
    w16(out, 12, @intCast(command_count));
    w16(out, 14, state_offset);
    w16(out, 16, state_size);

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
    if (command_table) |table| {
        const d = data orelse return error.MissingDataSection;
        const command_section = commands orelse return error.MissingCommandSection;
        try patchCommandTable(out[data_offset..][0..data_size], bytes, table, command_section, text, d);
    }
    if (commands) |section| {
        try packCommands(out[commands_offset..], bytes, section, text);
    }

    return out;
}

fn patchCommandTable(
    data_image: []u8,
    elf_bytes: []const u8,
    table_section: elf.Elf64_Shdr,
    command_section: elf.Elf64_Shdr,
    text: elf.Elf64_Shdr,
    data: elf.Elf64_Shdr,
) !void {
    const metadata = try sectionBytes(elf_bytes, table_section);
    if (metadata.len != 8) return error.InvalidCommandTable;
    const table_address = std.mem.readInt(u32, metadata[0..4], .big);
    const table_len = std.mem.readInt(u32, metadata[4..8], .big);
    if (table_len > 240 or table_address < data.sh_addr) return error.InvalidCommandTable;
    const table_offset: usize = @intCast(table_address - data.sh_addr);
    const table_size: usize = @intCast(table_len * 2);
    if (table_offset + table_size > data_image.len) return error.InvalidCommandTable;
    @memset(data_image[table_offset..][0..table_size], 0);

    const commands = try sectionBytes(elf_bytes, command_section);
    if (commands.len % command_source_size != 0) return error.InvalidCommandSection;
    var seen = std.StaticBitSet(240).initEmpty();
    for (0..commands.len / command_source_size) |record_index| {
        const record = commands[record_index * command_source_size ..][0..command_source_size];
        const handler = std.mem.readInt(u32, record[0..4], .big);
        const index = record[4];
        const command_size = record[5];
        if (index >= table_len or seen.isSet(index)) return error.InvalidCommandIndex;
        seen.set(index);
        if (command_size & 3 != 0 or command_size > 0xfc) return error.InvalidCommandSize;
        if (handler < text.sh_addr or handler >= text.sh_addr + text.sh_size or handler & 3 != 0) {
            return error.InvalidCommandHandler;
        }
        const handler_words = (handler - imem_base) >> 2;
        if (handler_words > 0x3ff) return error.InvalidCommandHandler;
        const descriptor: u16 = @intCast(handler_words | (@as(u32, command_size) << 8));
        std.mem.writeInt(
            u16,
            data_image[table_offset + @as(usize, index) * 2 ..][0..2],
            descriptor,
            .big,
        );
    }
}

fn packCommands(
    destination: []u8,
    elf_bytes: []const u8,
    section: elf.Elf64_Shdr,
    text: elf.Elf64_Shdr,
) !void {
    const offset: usize = @intCast(section.sh_offset);
    const size: usize = @intCast(section.sh_size);
    if (offset + size > elf_bytes.len) return error.BadElf;
    const source = elf_bytes[offset..][0..size];
    var seen: u16 = 0;
    for (0..size / command_source_size) |record_index| {
        const record = source[record_index * command_source_size ..][0..command_source_size];
        const handler = std.mem.readInt(u32, record[0..4], .big);
        const index = record[4];
        const command_size = record[5];
        if (index >= 16 or seen & (@as(u16, 1) << @intCast(index)) != 0) {
            return error.InvalidCommandIndex;
        }
        seen |= @as(u16, 1) << @intCast(index);
        if (command_size & 3 != 0) return error.InvalidCommandSize;
        if (handler < text.sh_addr or handler >= text.sh_addr + text.sh_size or handler & 3 != 0) {
            return error.InvalidCommandHandler;
        }
        const handler_offset = handler - imem_base;
        if (handler_offset >> 2 > 0x3ff) return error.InvalidCommandHandler;
        const output_record = destination[record_index * command_packed_size ..][0..command_packed_size];
        output_record[0] = index;
        output_record[1] = command_size;
        std.mem.writeInt(u16, output_record[2..4], @intCast(handler_offset), .big);
    }
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

fn sectionBytes(bytes: []const u8, section: elf.Elf64_Shdr) ![]const u8 {
    const offset: usize = @intCast(section.sh_offset);
    const size: usize = @intCast(section.sh_size);
    if (offset + size > bytes.len) return error.BadElf;
    return bytes[offset..][0..size];
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
