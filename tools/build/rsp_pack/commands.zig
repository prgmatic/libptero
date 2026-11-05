//! RSPQ command records. ZSP emits one 8-byte record per command in
//! `.zsp_commands`: handler address, index, and size. Overlays carry them
//! packed to 4 bytes; a command table in `.data` gets 16-bit descriptors.
const std = @import("std");
const elf_file = @import("elf_file.zig");

const Section = elf_file.Section;

pub const imem_base = 0x1000;
pub const source_size = 8;
pub const packed_size = 4;
pub const max_commands = 240;

const Record = struct { handler: u32, index: u8, size: u8 };

fn readRecord(source: []const u8, position: usize) Record {
    const bytes = source[position * source_size ..][0..source_size];
    return .{ .handler = std.mem.readInt(u32, bytes[0..4], .big), .index = bytes[4], .size = bytes[5] };
}

/// Indices claimed so far; each may appear once and below `limit`.
const Seen = struct {
    bits: std.StaticBitSet(max_commands) = .initEmpty(),
    limit: usize,

    fn claim(self: *Seen, index: u8) !void {
        if (index >= self.limit or self.bits.isSet(index)) return error.InvalidCommandIndex;
        self.bits.set(index);
    }
};

/// The number of records in a command section.
pub fn count(section: Section) !usize {
    if (section.sh_size % source_size != 0) return error.InvalidCommandSection;
    const records: usize = @intCast(section.sh_size / source_size);
    if (records > max_commands) return error.TooManyCommands;
    return records;
}

/// Writes `index, size, handler offset` per record. Handlers may be
/// anywhere in IMEM, so overlay commands can target resident code.
pub fn packRecords(destination: []u8, source: []const u8) !void {
    if (source.len % source_size != 0 or destination.len < source.len / source_size * packed_size) {
        return error.InvalidCommandSection;
    }
    var seen: Seen = .{ .limit = max_commands };
    for (0..source.len / source_size) |position| {
        const record = readRecord(source, position);
        try seen.claim(record.index);
        if (record.size & 3 != 0) return error.InvalidCommandSize;
        const output = destination[position * packed_size ..][0..packed_size];
        output[0] = record.index;
        output[1] = record.size;
        std.mem.writeInt(u16, output[2..4], try imemOffset(record.handler), .big);
    }
}

fn imemOffset(handler: u32) !u16 {
    if (handler < imem_base or handler >= imem_base + 0x1000 or handler & 3 != 0) return error.InvalidCommandHandler;
    return @intCast(handler - imem_base);
}

/// The table's location from `.zsp_command_table`: its DMEM address and
/// entry count.
const Table = struct { offset: usize, len: usize };

fn tableLocation(metadata: []const u8, data: Section, image_len: usize) !Table {
    if (metadata.len != 8) return error.InvalidCommandTable;
    const address = std.mem.readInt(u32, metadata[0..4], .big);
    const len = std.mem.readInt(u32, metadata[4..8], .big);
    if (len > max_commands or address < data.sh_addr) return error.InvalidCommandTable;
    const offset: usize = @intCast(address - data.sh_addr);
    if (offset + len * 2 > image_len) return error.InvalidCommandTable;
    return .{ .offset = offset, .len = len };
}

/// Fills the command table in the data image: per index, the handler's
/// IMEM word in the low 10 bits and the command size above it.
pub fn patchTable(data_image: []u8, file: elf_file.File, table_section: Section, sections: elf_file.Sections) !void {
    const data = sections.data orelse return error.MissingDataSection;
    const command_section = sections.commands orelse return error.MissingCommandSection;
    const table = try tableLocation(try file.contents(table_section), data, data_image.len);
    const slots = data_image[table.offset..][0 .. table.len * 2];
    @memset(slots, 0);
    const source = try file.contents(command_section);
    if (source.len % source_size != 0) return error.InvalidCommandSection;
    var seen: Seen = .{ .limit = table.len };
    for (0..source.len / source_size) |position| {
        const record = readRecord(source, position);
        try seen.claim(record.index);
        std.mem.writeInt(u16, slots[@as(usize, record.index) * 2 ..][0..2], try descriptor(record, sections.text), .big);
    }
}

fn descriptor(record: Record, text: Section) !u16 {
    if (record.size & 3 != 0 or record.size > 0xfc) return error.InvalidCommandSize;
    return @intCast(try handlerWord(record.handler, text) | (@as(u32, record.size) << 8));
}

/// Table handlers must be in this image's text.
fn handlerWord(handler: u32, text: Section) !u32 {
    if (handler < text.sh_addr or handler >= text.sh_addr + text.sh_size or handler & 3 != 0) return error.InvalidCommandHandler;
    return (handler - imem_base) >> 2;
}

const testing = std.testing;

fn testRecords(comptime records: []const Record) [records.len * source_size]u8 {
    var bytes: [records.len * source_size]u8 = @splat(0);
    for (records, 0..) |record, position| {
        const out = bytes[position * source_size ..][0..source_size];
        std.mem.writeInt(u32, out[0..4], record.handler, .big);
        out[4] = record.index;
        out[5] = record.size;
    }
    return bytes;
}

test "packed commands retain indices across the full overlay range" {
    const indices = [_]u8{ 0, 15, 16, 63, 239 };
    const source = testRecords(&.{
        .{ .handler = imem_base, .index = 0, .size = 4 },
        .{ .handler = imem_base + 4, .index = 15, .size = 4 },
        .{ .handler = imem_base + 8, .index = 16, .size = 4 },
        .{ .handler = imem_base + 12, .index = 63, .size = 4 },
        .{ .handler = imem_base + 16, .index = 239, .size = 4 },
    });
    var destination: [indices.len * packed_size]u8 = @splat(0);
    try packRecords(&destination, &source);
    for (indices, 0..) |index, position| {
        const record = destination[position * packed_size ..][0..packed_size];
        try testing.expectEqual(index, record[0]);
        try testing.expectEqual(@as(u8, 4), record[1]);
        try testing.expectEqual(@as(u16, @intCast(position * 4)), std.mem.readInt(u16, record[2..4], .big));
    }
}

test "packed commands reject duplicates, index 240, odd sizes, and bad handlers" {
    var destination: [2 * packed_size]u8 = @splat(0);
    const duplicate = testRecords(&.{ .{ .handler = imem_base, .index = 63, .size = 4 }, .{ .handler = imem_base, .index = 63, .size = 4 } });
    try testing.expectError(error.InvalidCommandIndex, packRecords(&destination, &duplicate));
    const too_high = testRecords(&.{.{ .handler = imem_base, .index = 240, .size = 4 }});
    try testing.expectError(error.InvalidCommandIndex, packRecords(&destination, &too_high));
    const odd = testRecords(&.{.{ .handler = imem_base, .index = 1, .size = 3 }});
    try testing.expectError(error.InvalidCommandSize, packRecords(&destination, &odd));
    const outside = testRecords(&.{.{ .handler = 0x2000, .index = 1, .size = 4 }});
    try testing.expectError(error.InvalidCommandHandler, packRecords(&destination, &outside));
    try testing.expectError(error.InvalidCommandSection, packRecords(destination[0..2], &odd));
}

test "command sections hold whole records and at most 240 of them" {
    try testing.expectEqual(@as(usize, 2), try count(std.mem.zeroInit(Section, .{ .sh_size = 16 })));
    try testing.expectError(error.InvalidCommandSection, count(std.mem.zeroInit(Section, .{ .sh_size = 12 })));
    try testing.expectError(error.TooManyCommands, count(std.mem.zeroInit(Section, .{ .sh_size = 241 * 8 })));
}

test "table descriptors require handlers in this text and small word-sized commands" {
    const text = std.mem.zeroInit(Section, .{ .sh_addr = imem_base + 0x100, .sh_size = 0x100 });
    try testing.expectEqual(@as(u16, 0x0841), try descriptor(.{ .handler = imem_base + 0x104, .index = 0, .size = 8 }, text));
    try testing.expectError(error.InvalidCommandSize, descriptor(.{ .handler = imem_base + 0x104, .index = 0, .size = 0x100 - 1 }, text));
    try testing.expectError(error.InvalidCommandHandler, descriptor(.{ .handler = imem_base, .index = 0, .size = 8 }, text));
    const data = std.mem.zeroInit(Section, .{ .sh_addr = 0x100 });
    var metadata: [8]u8 = undefined;
    std.mem.writeInt(u32, metadata[0..4], 0x0f0, .big);
    std.mem.writeInt(u32, metadata[4..8], 2, .big);
    try testing.expectError(error.InvalidCommandTable, tableLocation(&metadata, data, 64));
    try testing.expectError(error.InvalidCommandTable, tableLocation(metadata[0..4], data, 64));
    std.mem.writeInt(u32, metadata[0..4], 0x13e, .big);
    try testing.expectError(error.InvalidCommandTable, tableLocation(&metadata, data, 64));
}
