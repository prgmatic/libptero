//! Pure layout of a registered RSP overlay: its DMEM descriptor block (header
//! plus command descriptors) and resident overlay-table entry. The runtime
//! registration path and the host RSP interpreter harness share this code so
//! the resident dispatcher sees identical overlay metadata in both.
const std = @import("std");
const Program = @import("Program.zig");

pub const dmem_len = 0x1000;
pub const imem_len = 0x1000;
pub const dma_imem_addr = 0x1000;
pub const max_id = 15;
pub const commands_per_id = 16;
/// DMEM address where the dispatcher loads the active overlay's block.
pub const header_dmem_offset = 0x1f8;
pub const program_data_offset = 0x0a00;
pub const backing_len = dmem_len - header_dmem_offset;

pub const Error = error{
    TextEmptyOrUnaligned,
    TextDoesNotFit,
    DataUnaligned,
    DataDoesNotFit,
    NoCommands,
    StateUnaligned,
    BlockDoesNotFit,
    HandlerNotEncodable,
};

const Message = struct { err: Error, text: []const u8 };

const messages = [_]Message{
    .{ .err = error.TextEmptyOrUnaligned, .text = "RSP overlay text must have a nonzero DMA-aligned size" },
    .{ .err = error.TextDoesNotFit, .text = "RSP overlay text does not fit in IMEM" },
    .{ .err = error.DataUnaligned, .text = "RSP overlay data must be DMA-aligned" },
    .{ .err = error.DataDoesNotFit, .text = "RSP overlay program data does not fit in DMEM" },
    .{ .err = error.NoCommands, .text = "RSP overlay does not define any commands" },
    .{ .err = error.StateUnaligned, .text = "RSP overlay persistent state must be DMA-aligned" },
    .{ .err = error.BlockDoesNotFit, .text = "RSP overlay data does not fit in DMEM" },
    .{ .err = error.HandlerNotEncodable, .text = "RSP overlay command metadata cannot be encoded" },
};

/// The runtime's panic message for a registration error.
pub fn errorMessage(err: Error) []const u8 {
    for (messages) |message| {
        if (message.err == err) return message.text;
    }
    unreachable;
}

pub const Header = struct {
    state_start: u16 = 0,
    state_size: u16 = 0,
    state_rdram: u32 = 0,
    command_base: u16,
    overlay_id: u16,
    text_rdram: u32,
    text_size: u16,
    text_start: u16,
    extra_rdram: u32 = 0,
    extra_size: u16 = 0,
    extra_start: u16 = 0,

    pub const byte_len = 28;

    pub fn write(self: Header, destination: *[byte_len]u8) void {
        std.mem.writeInt(u16, destination[0..2], self.state_start, .big);
        std.mem.writeInt(u16, destination[2..4], self.state_size, .big);
        std.mem.writeInt(u32, destination[4..8], self.state_rdram, .big);
        std.mem.writeInt(u16, destination[8..10], self.command_base, .big);
        std.mem.writeInt(u16, destination[10..12], self.overlay_id, .big);
        std.mem.writeInt(u32, destination[12..16], self.text_rdram, .big);
        std.mem.writeInt(u16, destination[16..18], self.text_size, .big);
        std.mem.writeInt(u16, destination[18..20], self.text_start, .big);
        std.mem.writeInt(u32, destination[20..24], self.extra_rdram, .big);
        std.mem.writeInt(u16, destination[24..26], self.extra_size, .big);
        std.mem.writeInt(u16, destination[26..28], self.extra_start, .big);
    }
};

/// Where the program's initialized data lives in DMEM.
pub fn dataAddress(program: Program) u16 {
    return program.data_address orelse program_data_offset;
}

/// Registration geometry derived from a program, independent of addresses.
pub const Shape = struct {
    slot_count: u8,
    /// Length of the DMEM descriptor block loaded at `header_dmem_offset`.
    block_len: usize,
    data_address: u16,
    /// DMEM range of the initialized data/state image restored on load.
    image_start: u16,
    image_end: u16,
    has_image: bool,
};

pub fn shape(program: Program) Error!Shape {
    try validateText(program);
    try validateData(program);
    try validateState(program);
    const highest = try highestCommandIndex(program);
    const block_len = std.mem.alignForward(usize, Header.byte_len + (@as(usize, highest) + 1) * @sizeOf(u16), 16);
    if (block_len > backing_len) return error.BlockDoesNotFit;
    const data_address = dataAddress(program);
    return .{
        .slot_count = highest / commands_per_id + 1,
        .block_len = block_len,
        .data_address = data_address,
        .image_start = if (program.data.len == 0) program.state_offset else @min(data_address, program.state_offset),
        .image_end = @intCast(@max(@as(usize, data_address) + program.data.len, @as(usize, program.state_offset) + program.state_len)),
        .has_image = program.data.len != 0 or program.state_init.len != 0,
    };
}

fn validateText(program: Program) Error!void {
    if (program.text.len == 0 or program.text.len & 7 != 0) return error.TextEmptyOrUnaligned;
    if (program.text_offset > imem_len or program.text.len > imem_len - @as(usize, program.text_offset)) return error.TextDoesNotFit;
}

fn validateData(program: Program) Error!void {
    if (program.data.len & 7 != 0) return error.DataUnaligned;
    if (@as(usize, dataAddress(program)) + program.data.len > dmem_len) return error.DataDoesNotFit;
}

fn validateState(program: Program) Error!void {
    const misaligned = program.state_offset & 7 != 0 or program.state_len & 7 != 0;
    if (program.state_len != 0 and misaligned) return error.StateUnaligned;
    if (@as(u32, program.state_offset) + program.state_len > dmem_len) return error.StateUnaligned;
}

fn highestCommandIndex(program: Program) Error!u8 {
    if (program.commandCount() == 0) return error.NoCommands;
    var highest: u8 = 0;
    for (0..program.commandCount()) |index| highest = @max(highest, program.commandAt(index).index);
    return highest;
}

/// Physical RDRAM addresses chosen by the registering side.
pub const Placement = struct {
    id: u8,
    state_rdram: u32,
    text_rdram: u32,
    image_rdram: u32,
};

/// Fills the descriptor block. `dmem_image` is the overlay's DMEM-sized
/// data/state image; bytes of it that the block overlaps are preserved.
pub fn writeBlock(program: Program, s: Shape, placement: Placement, dmem_image: *const [dmem_len]u8, block: []u8) Error!void {
    @memset(block, 0);
    copyImageOverlap(s, dmem_image, block);
    headerFor(program, s, placement).write(block[0..Header.byte_len]);
    for (0..program.commandCount()) |index| try writeDescriptor(program.commandAt(index), block);
}

fn copyImageOverlap(s: Shape, dmem_image: *const [dmem_len]u8, block: []u8) void {
    if (!s.has_image) return;
    const overlap_start = @max(header_dmem_offset, s.image_start);
    const overlap_end = @min(header_dmem_offset + block.len, s.image_end);
    if (overlap_end <= overlap_start) return;
    @memcpy(block[overlap_start - header_dmem_offset ..][0 .. overlap_end - overlap_start], dmem_image[overlap_start..overlap_end]);
}

fn headerFor(program: Program, s: Shape, placement: Placement) Header {
    const image_flag: u32 = if (s.has_image) 0x80000000 else 0;
    return .{
        .state_start = program.state_offset,
        .state_size = if (program.state_len == 0) std.math.maxInt(u16) else program.state_len - 1,
        .state_rdram = placement.state_rdram,
        .command_base = @as(u16, placement.id) << 5,
        .overlay_id = @as(u16, placement.id) << 2,
        .text_rdram = placement.text_rdram | image_flag,
        .text_size = @intCast(program.text.len - 1),
        .text_start = dma_imem_addr + program.text_offset,
        .extra_rdram = if (s.has_image) placement.image_rdram else 0,
        .extra_size = if (s.has_image) @intCast(s.image_end - s.image_start - 1) else 0,
        .extra_start = if (s.has_image) s.image_start else 0,
    };
}

fn writeDescriptor(command: Program.Command, block: []u8) Error!void {
    if (command.handler_offset & 3 != 0 or command.handler_offset >> 2 > 0x3ff) return error.HandlerNotEncodable;
    const descriptor = @as(u16, command.size) << 8 | command.handler_offset >> 2;
    const offset = Header.byte_len + @as(usize, command.index) * @sizeOf(u16);
    std.mem.writeInt(u16, block[offset..][0..2], descriptor, .big);
}

/// Resident overlay-table word: block address plus its length in 16-byte units.
pub fn tableEntry(block_rdram: u32, block_len: usize) u32 {
    return block_rdram & 0x00ffffff | @as(u32, @intCast((block_len - 1) >> 4)) << 24;
}

/// Overlay-id map byte for each slot of an overlay.
pub fn idmapValue(id: u8) u8 {
    return id << 2;
}

const testing = std.testing;

fn testProgram(commands: []const u8, text: []const u8) Program {
    return .{ .text = text, .commands = commands, .state_offset = 0x230, .state_len = 8, .state_init = &(@as([8]u8, @splat(0x11))) };
}

test "shape derives slots, block length, and image range" {
    const text: [16]u8 = @splat(0);
    // Commands 0 and 17 (size 8 at handler 0x40 and 0x80).
    const commands = [_]u8{ 0, 8, 0, 0x40, 17, 8, 0, 0x80 };
    const s = try shape(testProgram(&commands, &text));
    try testing.expectEqual(@as(u8, 2), s.slot_count);
    try testing.expectEqual(@as(usize, 64), s.block_len);
    try testing.expectEqual(@as(u16, 0x230), s.image_start);
    // Without initialized data the image still extends to the default data address.
    try testing.expectEqual(@as(u16, program_data_offset), s.image_end);
    try testing.expect(s.has_image);
}

test "shape rejects invalid programs" {
    const text: [16]u8 = @splat(0);
    const commands = [_]u8{ 0, 8, 0, 0x40 };
    try testing.expectError(error.TextEmptyOrUnaligned, shape(testProgram(&commands, text[0..4])));
    var far = testProgram(&commands, &text);
    far.text_offset = 0xff8;
    try testing.expectError(error.TextDoesNotFit, shape(far));
    var data = testProgram(&commands, &text);
    data.data = text[0..4];
    try testing.expectError(error.DataUnaligned, shape(data));
    data.data = &text;
    data.data_address = 0xff8;
    try testing.expectError(error.DataDoesNotFit, shape(data));
    try testing.expectError(error.NoCommands, shape(testProgram(&.{}, &text)));
    var state = testProgram(&commands, &text);
    state.state_offset = 0x231;
    try testing.expectError(error.StateUnaligned, shape(state));
    state.state_offset = 0xff8;
    state.state_len = 16;
    try testing.expectError(error.StateUnaligned, shape(state));
    try testing.expectEqualStrings("RSP overlay text does not fit in IMEM", errorMessage(error.TextDoesNotFit));
    for (messages) |message| try testing.expectEqualStrings(message.text, errorMessage(message.err));
}

test "descriptor block encodes header, descriptors, and table entry" {
    const text: [16]u8 = @splat(0);
    const commands = [_]u8{ 0, 8, 0, 0x40, 2, 12, 0, 0x80 };
    var program = testProgram(&commands, &text);
    program.text_offset = 0x10;
    var image: [dmem_len]u8 = @splat(0);
    image[0x230] = 0x11;
    const s = try shape(program);
    var block: [64]u8 = @splat(0xee);
    try writeBlock(program, s, .{ .id = 3, .state_rdram = 0x1000, .text_rdram = 0x2000, .image_rdram = 0x3000 }, &image, block[0..s.block_len]);
    try testing.expectEqual(@as(u16, 0x0230), std.mem.readInt(u16, block[0..2], .big));
    try testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, block[2..4], .big));
    try testing.expectEqual(@as(u16, 3 << 5), std.mem.readInt(u16, block[8..10], .big));
    try testing.expectEqual(@as(u32, 0x8000_2000), std.mem.readInt(u32, block[12..16], .big));
    try testing.expectEqual(@as(u16, 0x1010), std.mem.readInt(u16, block[18..20], .big));
    try testing.expectEqual(@as(u16, 0x0810), std.mem.readInt(u16, block[28..30], .big));
    try testing.expectEqual(@as(u16, 0x0c20), std.mem.readInt(u16, block[32..34], .big));
    try testing.expectEqual(@as(u32, 0x0300_1000), tableEntry(0x8000_1000, 64));
    try testing.expectEqual(@as(u8, 12), idmapValue(3));
    const bad = [_]u8{ 0, 8, 0, 0x41 };
    try testing.expectError(error.HandlerNotEncodable, writeBlock(testProgram(&bad, &text), s, .{ .id = 1, .state_rdram = 0, .text_rdram = 0, .image_rdram = 0 }, &image, block[0..s.block_len]));
}

test "image overlapping the descriptor block is preserved" {
    const text: [16]u8 = @splat(0);
    const commands = [_]u8{ 9, 8, 0, 0x40 };
    const data: [16]u8 = @splat(0);
    const program: Program = .{ .text = &text, .commands = &commands, .data = &data, .data_address = 0x218, .state_offset = 0x218 };
    var image: [dmem_len]u8 = @splat(0);
    image[0x221] = 0x5a;
    const s = try shape(program);
    var block: [48]u8 = undefined;
    try writeBlock(program, s, .{ .id = 1, .state_rdram = 0, .text_rdram = 0, .image_rdram = 0 }, &image, block[0..s.block_len]);
    try testing.expectEqual(@as(u8, 0x5a), block[0x221 - header_dmem_offset]);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), std.mem.readInt(u16, block[2..4], .big));
    try testing.expect(!(try shape(.{ .text = &text, .commands = &commands })).has_image);
}
