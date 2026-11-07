//! Drives the resident command dispatcher and its overlays the way the CPU
//! runtime does, so real command streams execute in the interpreter.
//!
//! RDRAM addresses are byte offsets into the machine's RDRAM slice. Overlay
//! registration uses the runtime's own `overlay_layout`, so the dispatcher
//! sees the same metadata it does on hardware.
const std = @import("std");
const abi = @import("rsp_abi");
const Machine = @import("Machine.zig");

const Program = abi.Program;
const layout = abi.overlay_layout;
const Session = @This();

/// DMEM addresses of resident dispatcher state written by the CPU.
pub const ResidentSymbols = struct {
    overlay_table: u16,
    overlay_idmap: u16,
    queue_rdram_address: u16,
    rdp_target_bitdepth: u16,
};

pub const Error = Machine.Error || layout.Error || error{ RdramExhausted, CommandBufferFull, DispatcherFault };

/// BREAK code raised by the dispatcher's invalid-command handler.
const invalid_command_break = 0xba;
/// SP status signal the CPU raises to tell the dispatcher more work exists.
const signal_more = 1 << 7;
/// Leave low RDRAM unused so a zero address never aliases live data.
const first_allocation = 0x1000;

machine: Machine,
symbols: ResidentSymbols,
resident_pc: u32,
cursor: u32 = first_allocation,

/// Loads the resident program into a cleared machine. `rdram` must be zeroed.
pub fn init(rdram: []u8, resident: Program, symbols: ResidentSymbols) Session {
    var session: Session = .{ .machine = Machine.init(rdram), .symbols = symbols, .resident_pc = resident.pc_start };
    session.machine.load(resident);
    return session;
}

pub fn allocate(self: *Session, len: usize, alignment: u32) Error!u32 {
    const address = std.mem.alignForward(u32, self.cursor, alignment);
    if (address + len > self.machine.rdram.len) return error.RdramExhausted;
    self.cursor = address + @as(u32, @intCast(len));
    return address;
}

pub fn bytes(self: *Session, address: u32, len: usize) Error![]u8 {
    return self.machine.rdramSlice(address, len);
}

/// Copies `data` into newly allocated RDRAM and returns its address.
pub fn place(self: *Session, data: []const u8, alignment: u32) Error!u32 {
    const address = try self.allocate(data.len, alignment);
    @memcpy(try self.bytes(address, data.len), data);
    return address;
}

pub const Overlay = struct {
    id: u8,
    slot_count: u8,
    /// RDRAM copy of the overlay's DMEM image; persistent state is saved here.
    image_rdram: u32,
    /// RDRAM copy of the overlay's text, as the dispatcher DMAs it.
    text_rdram: u32,

    pub fn commandId(self: Overlay, index: u8) u8 {
        return (self.id << 4) +% index;
    }

    pub fn stateAddress(self: Overlay, dmem_address: u16) u32 {
        return self.image_rdram + dmem_address;
    }
};

/// Registers `program` at overlay `id`, mirroring the runtime's static registration.
pub fn registerOverlay(self: *Session, program: Program, id: u8) Error!Overlay {
    const shape = try layout.shape(program);
    var image: [layout.dmem_len]u8 = @splat(0);
    @memcpy(image[shape.data_address..][0..program.data.len], program.data);
    @memcpy(image[program.state_offset..][0..program.state_init.len], program.state_init);
    const image_rdram = try self.place(&image, 16);
    const block_rdram = try self.allocate(shape.block_len, 16);
    const text_rdram = try self.place(program.text, 8);
    try layout.writeBlock(program, shape, .{
        .id = id,
        .state_rdram = image_rdram + program.state_offset,
        .text_rdram = text_rdram,
        .image_rdram = image_rdram + shape.image_start,
    }, &image, try self.bytes(block_rdram, shape.block_len));
    const entry = layout.tableEntry(block_rdram, shape.block_len);
    for (0..shape.slot_count) |slot| {
        const slot_id: u32 = id + @as(u32, @intCast(slot));
        self.machine.writeDmem(u32, self.symbols.overlay_table + slot_id * 4, entry);
        self.machine.setDmemByte(self.symbols.overlay_idmap + slot_id, layout.idmapValue(id));
    }
    return .{ .id = id, .slot_count = shape.slot_count, .image_rdram = image_rdram, .text_rdram = text_rdram };
}

/// Appends command words to a fetch-window-aligned RDRAM buffer.
pub const CommandWriter = struct {
    session: *Session,
    address: u32,
    capacity: usize,
    index: usize = 0,

    pub fn command(self: *CommandWriter, id: u8, inline_argument: u24, arguments: []const u32) Error!void {
        // Keep room for the invalid terminator that ends the stream.
        if (self.index + 1 + arguments.len >= self.capacity) return error.CommandBufferFull;
        try self.word(@as(u32, id) << 24 | inline_argument);
        for (arguments) |argument| try self.word(argument);
    }

    pub fn internal(self: *CommandWriter, kind: abi.InternalCommand, inline_argument: u24, arguments: []const u32) Error!void {
        return self.command(@intFromEnum(kind), inline_argument, arguments);
    }

    pub fn overlayCommand(self: *CommandWriter, overlay: Overlay, index: u8, inline_argument: u24, arguments: []const u32) Error!void {
        return self.command(overlay.commandId(index), inline_argument, arguments);
    }

    fn word(self: *CommandWriter, value: u32) Error!void {
        const destination = try self.session.bytes(self.address + @as(u32, @intCast(self.index * 4)), 4);
        std.mem.writeInt(u32, destination[0..4], value, .big);
        self.index += 1;
    }
};

/// Allocates a zeroed command buffer; a zero header word ends the stream.
pub fn commands(self: *Session, word_capacity: usize) Error!CommandWriter {
    const byte_len = std.mem.alignForward(usize, word_capacity * 4, abi.fetch_window_byte_len);
    const address = try self.allocate(byte_len, abi.fetch_window_byte_len);
    return .{ .session = self, .address = address, .capacity = byte_len / 4 };
}

/// Points the dispatcher at `queue_address`, signals it, and runs until it
/// halts again. Returns `DispatcherFault` if it rejected a command.
pub fn submit(self: *Session, queue_address: u32, limit: u64) Error!Machine.RunResult {
    const m = &self.machine;
    m.writeDmem(u32, self.symbols.queue_rdram_address, queue_address);
    m.setDmemByte(self.symbols.rdp_target_bitdepth, 0);
    m.sp.signals |= signal_more;
    m.start(self.resident_pc);
    const result = try m.run(limit);
    if (result.stop == .broke and self.lastBreakCode() == invalid_command_break) return error.DispatcherFault;
    return result;
}

fn lastBreakCode(self: *const Session) u32 {
    const pc = (self.machine.pc -% 4) & 0xffc;
    return std.mem.readInt(u32, self.machine.imem[pc..][0..4], .big) >> 6 & 0xfffff;
}

const testing = std.testing;
const encode = @import("encode.zig");

/// A miniature resident program: on submit it stores the first command word
/// of the queue (fetched by DMA) into DMEM 0x10 and breaks.
fn miniatureResident(text: *[64]u8) Program {
    const words = [_]u32{
        encode.lw(16, 0, 0x20), // $s0 = queue address
        encode.ori(20, 0, 0x40), // $s4 = DMEM destination
        encode.cop0Move(true, 20, 0),
        encode.cop0Move(true, 16, 1),
        encode.ori(8, 0, 7),
        encode.cop0Move(true, 8, 2),
        encode.cop0Move(false, 10, 6), // wait for the DMA
        encode.bne(10, 0, -2),
        encode.nop,
        encode.lw(9, 0, 0x40),
        encode.sw(9, 0, 0x10),
        encode.brk,
    };
    @memset(text, 0);
    for (words, 0..) |word, index| std.mem.writeInt(u32, text[index * 4 ..][0..4], word, .big);
    return .{ .text = text };
}

const test_symbols: ResidentSymbols = .{ .overlay_table = 0x100, .overlay_idmap = 0x140, .queue_rdram_address = 0x20, .rdp_target_bitdepth = 0x24 };

test "commands are written big-endian and submitted to the resident" {
    var rdram: [0x4000]u8 = @splat(0);
    var text: [64]u8 = undefined;
    var session = Session.init(&rdram, miniatureResident(&text), test_symbols);
    var writer = try session.commands(4);
    try testing.expectEqual(@as(u32, 0x1000), writer.address);
    try writer.internal(.write_word, 0x30, &.{0x1234_5678});
    try testing.expectError(error.CommandBufferFull, writer.command(1, 0, &(@as([63]u32, @splat(0)))));
    const result = try session.submit(writer.address, 100);
    try testing.expectEqual(Machine.Stop.broke, result.stop);
    try testing.expectEqual(@as(u32, 0x0100_0030), session.machine.readDmem(u32, 0x10));
    try testing.expect(session.machine.sp.signals & signal_more != 0);
}

test "invalid-command breaks are reported as dispatcher faults" {
    var rdram: [0x2000]u8 = @splat(0);
    var text: [64]u8 = @splat(0);
    std.mem.writeInt(u32, text[0..4], (invalid_command_break << 6) | 0x0d, .big);
    var session = Session.init(&rdram, .{ .text = &text }, test_symbols);
    try testing.expectError(error.DispatcherFault, session.submit(0x1000, 10));
}

test "overlay registration writes the table, id map, and descriptor block" {
    var rdram: [0x4000]u8 = @splat(0);
    var resident_text: [64]u8 = undefined;
    var session = Session.init(&rdram, miniatureResident(&resident_text), test_symbols);
    const text: [16]u8 = @splat(0xab);
    const commands_metadata = [_]u8{ 17, 8, 0, 0x40 };
    const overlay = try session.registerOverlay(.{ .text = &text, .commands = &commands_metadata, .state_offset = 0x230, .state_len = 8 }, 2);
    try testing.expectEqual(@as(u8, 2), overlay.slot_count);
    try testing.expectEqual(@as(u8, 0x31), overlay.commandId(17));
    try testing.expectEqual(overlay.image_rdram + 0x230, overlay.stateAddress(0x230));
    try testing.expectEqualSlices(u8, &text, try session.bytes(overlay.text_rdram, text.len));
    const entry = session.machine.readDmem(u32, test_symbols.overlay_table + 3 * 4);
    try testing.expectEqual(session.machine.readDmem(u32, test_symbols.overlay_table + 2 * 4), entry);
    try testing.expectEqual(@as(u8, 8), session.machine.dmemByte(test_symbols.overlay_idmap + 3));
    const block = try session.bytes(entry & 0x00ff_ffff, 64);
    try testing.expectEqual(@as(u16, 2 << 5), std.mem.readInt(u16, block[8..10], .big));
    try testing.expectError(error.RdramExhausted, session.allocate(0x10000, 8));
}
