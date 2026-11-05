//! The `.rsp` image: a 24-byte header of big-endian 16-bit fields, then
//! text, data, packed command records, and initial state, each 8-aligned.
const std = @import("std");
const elf_file = @import("elf_file.zig");
const commands = @import("commands.zig");

const Section = elf_file.Section;
const imem_base = commands.imem_base;
const memory_size = 0x1000;

pub const header_size = 24;

/// Where each part of the image goes, and the header describing it.
const Layout = struct {
    pc_start: u16,
    text_start: u16,
    text_size: usize,
    data_size: usize,
    data_address: u16,
    command_count: usize,
    state: Placement,
    state_init_size: usize,

    fn paddedText(self: Layout) usize {
        return std.mem.alignForward(usize, self.text_size, 8);
    }

    fn paddedData(self: Layout) usize {
        return std.mem.alignForward(usize, self.data_size, 8);
    }

    fn dataOffset(self: Layout) usize {
        return header_size + self.paddedText();
    }

    fn commandsOffset(self: Layout) usize {
        return self.dataOffset() + self.paddedData();
    }

    fn stateInitOffset(self: Layout) usize {
        return self.commandsOffset() + self.command_count * commands.packed_size;
    }

    fn size(self: Layout) usize {
        return self.stateInitOffset() + self.state_init_size;
    }

    /// The header fields, in order.
    fn header(self: Layout) [header_size / 2]u16 {
        return .{
            @intCast(self.paddedText()),       @intCast(self.paddedData()),
            @intCast(self.dataOffset()),       self.pc_start,
            self.text_start,                   @intCast(self.commandsOffset()),
            @intCast(self.command_count),      self.state.offset,
            self.state.size,                   @intCast(self.stateInitOffset()),
            @intCast(self.state_init_size),    self.data_address,
        };
    }
};

const Placement = struct { offset: u16, size: u16 };

fn computeLayout(entry: u64, sections: elf_file.Sections) !Layout {
    const text = try textPlacement(entry, sections.text);
    const data = sections.data orelse std.mem.zeroes(Section);
    try checkData(data);
    return .{
        .pc_start = text.offset,
        .text_start = text.size,
        .text_size = @intCast(sections.text.sh_size),
        .data_size = @intCast(data.sh_size),
        .data_address = @intCast(data.sh_addr),
        .command_count = if (sections.commands) |section| try commands.count(section) else 0,
        .state = try statePlacement(sections),
        .state_init_size = if (sections.state) |state| @intCast(state.sh_size) else 0,
    };
}

/// The entry point and text start as IMEM offsets (offset, size fields).
fn textPlacement(entry: u64, text: Section) !Placement {
    if (entry < text.sh_addr or entry >= text.sh_addr + text.sh_size) return error.EntryOutsideText;
    if (text.sh_addr < imem_base or text.sh_addr + text.sh_size > imem_base + memory_size) return error.TextOutsideImem;
    return .{ .offset = @intCast(entry - imem_base), .size = @intCast(text.sh_addr - imem_base) };
}

/// Data loads by 8-byte DMA, so it must start aligned and end in DMEM.
fn checkData(data: Section) !void {
    const end = data.sh_addr + std.mem.alignForward(u64, data.sh_size, 8);
    if (end > memory_size or data.sh_addr & 7 != 0) return error.DataOutsideDmem;
}

/// The `.state` section, or 8 bytes after all other DMEM storage.
fn statePlacement(sections: elf_file.Sections) !Placement {
    const state = sections.state orelse return defaultState(sections);
    if (state.sh_addr + state.sh_size > memory_size or (state.sh_addr | state.sh_size) & 7 != 0) return error.InvalidStateSection;
    return .{ .offset = @intCast(state.sh_addr), .size = @intCast(state.sh_size) };
}

fn defaultState(sections: elf_file.Sections) !Placement {
    var start: u64 = 0;
    for (sections.dmem()) |candidate| {
        const section = candidate orelse continue;
        start = @max(start, section.sh_addr + section.sh_size);
    }
    start = std.mem.alignForward(u64, start, 8);
    if (start + 8 > memory_size) return error.StateOutsideDmem;
    return .{ .offset = @intCast(start), .size = 8 };
}

/// Builds the image for a linked RSP ELF. The caller frees it.
pub fn pack(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const file = try elf_file.File.parse(bytes);
    const sections = try elf_file.Sections.find(file);
    const layout = try computeLayout(file.header.entry, sections);
    const out = try allocator.alloc(u8, layout.size());
    errdefer allocator.free(out);
    @memset(out, 0);
    for (layout.header(), 0..) |value, index| std.mem.writeInt(u16, out[index * 2 ..][0..2], value, .big);
    try fill(out, file, sections, layout);
    return out;
}

fn fill(out: []u8, file: elf_file.File, sections: elf_file.Sections, layout: Layout) !void {
    try file.copy(out[header_size..][0..layout.text_size], sections.text);
    const data_image = out[layout.dataOffset()..][0..layout.data_size];
    if (sections.data) |data| try file.copy(data_image, data);
    if (sections.command_table) |table| try commands.patchTable(data_image, file, table, sections);
    if (sections.commands) |section| try commands.packRecords(out[layout.commandsOffset()..], try file.contents(section));
    if (sections.state) |state| try file.copy(out[layout.stateInitOffset()..][0..layout.state_init_size], state);
}

const testing = std.testing;
const test_elf = @import("test_elf.zig");

fn field(image: []const u8, index: usize) u16 {
    return std.mem.readInt(u16, image[index * 2 ..][0..2], .big);
}

test "text-only images get a default state slot" {
    const bytes = try test_elf.build(testing.allocator, imem_base + 4, &.{
        .{ .name = ".text", .addr = imem_base, .data = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } },
    });
    defer testing.allocator.free(bytes);
    const image = try pack(testing.allocator, bytes);
    defer testing.allocator.free(image);
    try testing.expectEqual(@as(usize, header_size + 16), image.len);
    try testing.expectEqualSlices(u16, &.{ 16, 0, header_size + 16, 4, 0, header_size + 16, 0, 0, 8, header_size + 16, 0, 0 }, &layoutFields(image));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, 0, 0, 0 }, image[header_size..]);
}

fn layoutFields(image: []const u8) [header_size / 2]u16 {
    var fields: [header_size / 2]u16 = undefined;
    for (&fields, 0..) |*value, index| value.* = field(image, index);
    return fields;
}

test "images carry data, a patched command table, packed commands, and state" {
    var text: [16]u8 = @splat(0);
    var data: [16]u8 = @splat(0xaa);
    var command_table: [8]u8 = undefined;
    std.mem.writeInt(u32, command_table[0..4], 0x18, .big);
    std.mem.writeInt(u32, command_table[4..8], 2, .big);
    var records: [2 * commands.source_size]u8 = @splat(0);
    std.mem.writeInt(u32, records[0..4], imem_base + 0x104, .big);
    records[4] = 1;
    records[5] = 8;
    std.mem.writeInt(u32, records[8..12], imem_base + 0x108, .big);
    records[12] = 0;
    records[13] = 4;
    const state = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const bytes = try test_elf.build(testing.allocator, imem_base + 0x100, &.{
        .{ .name = ".text", .addr = imem_base + 0x100, .data = &text },
        .{ .name = ".data", .addr = 0x10, .data = &data },
        .{ .name = ".zsp_command_table", .data = &command_table },
        .{ .name = ".zsp_commands", .data = &records },
        .{ .name = ".state", .addr = 0x40, .data = &state },
        .{ .name = ".bss", .type = std.elf.SHT_NOBITS, .addr = 0x20, .nobits_size = 16 },
    });
    defer testing.allocator.free(bytes);
    const image = try pack(testing.allocator, bytes);
    defer testing.allocator.free(image);
    const data_offset = header_size + 16;
    try testing.expectEqualSlices(u16, &.{ 16, 16, data_offset, 0x100, 0x100, data_offset + 16, 2, 0x40, 8, data_offset + 24, 8, 0x10 }, &layoutFields(image));
    const table = image[data_offset + 8 ..][0..4];
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x42, 0x08, 0x41 }, table);
    try testing.expectEqualSlices(u8, &.{ 1, 8, 0x01, 0x04, 0, 4, 0x01, 0x08 }, image[data_offset + 16 ..][0..8]);
    try testing.expectEqualSlices(u8, &state, image[data_offset + 24 ..]);
}

test "layouts reject entries, text, data, and state outside RSP memory" {
    const text = std.mem.zeroInit(Section, .{ .sh_addr = imem_base, .sh_size = 8 });
    try testing.expectError(error.EntryOutsideText, textPlacement(imem_base + 8, text));
    const low = std.mem.zeroInit(Section, .{ .sh_addr = 0x800, .sh_size = 0x1000 });
    try testing.expectError(error.TextOutsideImem, textPlacement(0x800, low));
    try testing.expectError(error.DataOutsideDmem, checkData(std.mem.zeroInit(Section, .{ .sh_addr = 4, .sh_size = 8 })));
    try testing.expectError(error.DataOutsideDmem, checkData(std.mem.zeroInit(Section, .{ .sh_addr = 0xff8, .sh_size = 9 })));
    var sections: elf_file.Sections = .{ .text = text, .data = null, .commands = null, .command_table = null, .state = null, .bss = null };
    sections.bss = std.mem.zeroInit(Section, .{ .sh_addr = 0xff0, .sh_size = 0xc });
    try testing.expectError(error.StateOutsideDmem, statePlacement(sections));
    sections.state = std.mem.zeroInit(Section, .{ .sh_addr = 0x24, .sh_size = 8 });
    try testing.expectError(error.InvalidStateSection, statePlacement(sections));
}

test "non-RSP ELF files are rejected" {
    var bytes = try test_elf.build(testing.allocator, 0, &.{});
    defer testing.allocator.free(bytes);
    try testing.expectError(error.MissingTextSection, pack(testing.allocator, bytes));
    bytes[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    try testing.expectError(error.UnsupportedElf, pack(testing.allocator, bytes));
}
