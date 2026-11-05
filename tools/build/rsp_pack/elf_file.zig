//! Section access for the big-endian MIPS ELF files the RSP linker writes.
const std = @import("std");
const elf = std.elf;

pub const Section = elf.Elf64_Shdr;

pub const File = struct {
    bytes: []const u8,
    header: elf.Header,
    /// The section-name string table.
    names: []const u8,

    /// Reads the header; RSP images come only from 32-bit big-endian ELF.
    pub fn parse(bytes: []const u8) !File {
        var reader = std.Io.Reader.fixed(bytes);
        const header = try elf.Header.read(&reader);
        if (header.is_64 or header.endian != .big) return error.UnsupportedElf;
        var file: File = .{ .bytes = bytes, .header = header, .names = &.{} };
        file.names = try file.contents(try file.sectionAt(header.shstrndx));
        return file;
    }

    pub fn sectionAt(self: File, wanted: usize) !Section {
        if (wanted >= self.header.shnum) return error.BadElf;
        var sections = self.header.iterateSectionHeadersBuffer(self.bytes);
        var index: usize = 0;
        while (try sections.next()) |section| : (index += 1) {
            if (index == wanted) return section;
        }
        return error.BadElf;
    }

    pub fn find(self: File, name: []const u8) !?Section {
        var sections = self.header.iterateSectionHeadersBuffer(self.bytes);
        while (try sections.next()) |section| {
            if (std.mem.eql(u8, try self.sectionName(section), name)) return section;
        }
        return null;
    }

    fn sectionName(self: File, section: Section) ![]const u8 {
        if (section.sh_name >= self.names.len) return error.BadElf;
        return std.mem.sliceTo(self.names[section.sh_name..], 0);
    }

    pub fn contents(self: File, section: Section) ![]const u8 {
        const offset: usize = @intCast(section.sh_offset);
        const size: usize = @intCast(section.sh_size);
        if (offset + size > self.bytes.len) return error.BadElf;
        return self.bytes[offset..][0..size];
    }

    /// Copies a section's initial bytes; `NOBITS` sections start as zero.
    pub fn copy(self: File, destination: []u8, section: Section) !void {
        if (section.sh_type == elf.SHT_NOBITS) return @memset(destination, 0);
        @memcpy(destination, try self.contents(section));
    }
};

/// Whether two headers describe the same section.
pub fn sameSection(a: Section, b: Section) bool {
    return a.sh_offset == b.sh_offset and a.sh_addr == b.sh_addr and a.sh_size == b.sh_size;
}

/// The sections an RSP image is built from.
pub const Sections = struct {
    text: Section,
    data: ?Section,
    commands: ?Section,
    command_table: ?Section,
    state: ?Section,
    bss: ?Section,

    pub fn find(file: File) !Sections {
        return .{
            .text = (try file.find(".text")) orelse return error.MissingTextSection,
            .data = try file.find(".data"),
            .commands = try file.find(".zsp_commands"),
            .command_table = try file.find(".zsp_command_table"),
            .state = try file.find(".state"),
            .bss = try file.find(".bss"),
        };
    }

    /// DMEM sections: initialized data, state, and reserved storage.
    pub fn dmem(self: Sections) [3]?Section {
        return .{ self.data, self.state, self.bss };
    }
};
