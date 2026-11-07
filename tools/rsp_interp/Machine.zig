//! Complete architectural state of one RSP plus the host-provided RDRAM it can
//! reach through DMA. `step` executes one instruction with MIPS delay-slot
//! semantics; `run` executes until the RSP halts or a budget is exhausted.
const std = @import("std");
const Program = @import("rsp_abi").Program;
const cop0 = @import("cop0.zig");
pub const dma_engine = @import("dma.zig");
const scalar = @import("scalar.zig");
const timing = @import("timing.zig");
const VuState = @import("vu_state.zig").State;
pub const Profile = @import("Profile.zig");

const Machine = @This();

pub const memory_size = 4096;
const address_mask = memory_size - 1;
const pc_mask = 0xffc;

pub const Error = error{
    InvalidInstruction,
    RdramOutOfBounds,
    RdpOutputFailed,
    Halted,
    /// Microcode touched RSP memory an unfinished DMA reads or fills; see
    /// `Machine.hazard`.
    DmaHazard,
    /// A DMA was started while one was already pending.
    DmaQueueFull,
};

pub const Stop = enum { broke, halted, instruction_limit };

pub const RunResult = struct {
    stop: Stop,
    instructions: u64,
    cycles: u64,
};

imem: [memory_size]u8 = @splat(0),
dmem: [memory_size]u8 = @splat(0),
gpr: [32]u32 = @splat(0),
pc: u32 = 0,
next_pc: u32 = 4,
/// Target recorded by a taken branch; becomes `next_pc` after its delay slot.
jump_target: ?u32 = null,
vu: VuState = .{},
sp: cop0.Sp = .{},
dp: cop0.Dp = .{},
dma: dma_engine.Queue = .{},
/// The first DMA hazard found, reported as `error.DmaHazard`.
hazard: ?dma_engine.Hazard = null,
/// Big-endian RDRAM visible to SP DMA and RDP command fetches.
rdram: []u8,
/// Receives RDP command bytes submitted through DP_START/DP_END.
rdp_output: ?*std.Io.Writer = null,
instructions: u64 = 0,
pipeline: timing.Pipeline = .{},
/// Optional per-instruction cost accumulator.
profile: ?*Profile = null,

pub fn init(rdram: []u8) Machine {
    return .{ .rdram = rdram };
}

/// Copies a packed program into IMEM/DMEM and leaves the RSP halted at its
/// entry point. Call `start` to release it.
pub fn load(self: *Machine, program: Program) void {
    copyWrapped(&self.imem, program.text_offset, program.text);
    copyWrapped(&self.dmem, program.data_address orelse 0, program.data);
    copyWrapped(&self.dmem, program.state_offset, program.state_init);
    self.setPc(program.pc_start);
}

fn copyWrapped(memory: *[memory_size]u8, offset: u32, bytes: []const u8) void {
    for (bytes, 0..) |value, index| memory[(offset + index) & address_mask] = value;
}

pub fn setPc(self: *Machine, pc: u32) void {
    self.pc = pc & pc_mask;
    self.next_pc = (pc + 4) & pc_mask;
    self.jump_target = null;
}

/// Releases the RSP at `pc`, as the CPU does by writing SP_PC and clearing halt.
pub fn start(self: *Machine, pc: u32) void {
    self.setPc(pc);
    self.sp.halted = false;
    self.sp.broken = false;
}

pub fn step(self: *Machine) Error!void {
    if (self.sp.halted) return error.Halted;
    self.retireDma();
    self.touch(0x1000 | self.pc, 4, .fetch);
    const op = std.mem.readInt(u32, self.imem[self.pc..][0..4], .big);
    self.jump_target = null;
    try scalar.execute(self, op);
    if (self.hazard != null) return error.DmaHazard;
    const cycles_before = self.pipeline.cycles;
    self.pipeline.issue(op, self.jump_target != null);
    if (self.profile) |profile| profile.record(self.pc, self.pipeline.cycles - cycles_before);
    self.instructions += 1;
    self.pc = self.next_pc;
    self.next_pc = self.jump_target orelse (self.next_pc + 4) & pc_mask;
}

pub fn run(self: *Machine, limit: u64) Error!RunResult {
    for (0..limit) |_| {
        try self.step();
        if (self.sp.halted) {
            // Transfers keep running after a halt; the CPU sees their results.
            self.drainDma();
            return self.result(if (self.sp.broken) .broke else .halted);
        }
    }
    return self.result(.instruction_limit);
}

fn retireDma(self: *Machine) void {
    while (self.dma.popFinished(self.pipeline.cycles)) |finished| cop0.complete(self, finished);
}

/// Completes every queued transfer at once, as when the CPU waits for idle.
pub fn drainDma(self: *Machine) void {
    while (self.dma.popFront()) |finished| cop0.complete(self, finished);
}

/// Records a hazard when microcode accesses `len` bytes of RSP memory at
/// `address` (bit 12 selects IMEM) that an unfinished transfer covers.
pub fn touch(self: *Machine, address: u32, len: u32, access: dma_engine.Access) void {
    if (!self.dma.busy() or self.hazard != null) return;
    for (0..len) |index| {
        const byte_address = (address & 0x1000) | ((address +% @as(u32, @intCast(index))) & address_mask);
        const transfer = self.dma.conflict(byte_address, access) orelse continue;
        self.hazard = .{ .pc = self.pc, .address = byte_address, .access = access, .direction = transfer.direction };
        return;
    }
}

fn result(self: *const Machine, stop: Stop) RunResult {
    return .{ .stop = stop, .instructions = self.instructions, .cycles = self.pipeline.cycles };
}

pub fn setReg(self: *Machine, index: u5, value: u32) void {
    self.gpr[index] = value;
    self.gpr[0] = 0;
}

/// Records a taken transfer. `target` is an IMEM byte address.
pub fn jump(self: *Machine, target: u32) void {
    self.jump_target = target & pc_mask;
}

/// Big-endian DMEM read; each byte address wraps independently like hardware.
pub fn readDmem(self: *const Machine, comptime T: type, address: u32) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    for (&bytes, 0..) |*value, index| value.* = self.dmem[(address +% index) & address_mask];
    return std.mem.readInt(T, &bytes, .big);
}

pub fn writeDmem(self: *Machine, comptime T: type, address: u32, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    for (bytes, 0..) |byte, index| self.dmem[(address +% index) & address_mask] = byte;
}

pub fn dmemByte(self: *const Machine, address: u32) u8 {
    return self.dmem[address & address_mask];
}

pub fn setDmemByte(self: *Machine, address: u32, value: u8) void {
    self.dmem[address & address_mask] = value;
}

/// Bounds-checked RDRAM window. Addresses use the 24-bit RCP address space.
pub fn rdramSlice(self: *Machine, address: u32, len: usize) Error![]u8 {
    const start_address: usize = address & 0x00ff_ffff;
    if (start_address + len > self.rdram.len) return error.RdramOutOfBounds;
    return self.rdram[start_address..][0..len];
}

const testing = std.testing;

test "DMEM accesses are big-endian and wrap per byte" {
    var machine = Machine.init(&.{});
    machine.writeDmem(u32, 0xffe, 0x11223344);
    try testing.expectEqual(@as(u8, 0x11), machine.dmem[0xffe]);
    try testing.expectEqual(@as(u8, 0x44), machine.dmem[0x001]);
    try testing.expectEqual(@as(u32, 0x11223344), machine.readDmem(u32, 0xffe));
    machine.setDmemByte(0x1003, 9);
    try testing.expectEqual(@as(u8, 9), machine.dmemByte(3));
}

test "register zero stays zero and RDRAM windows are bounds checked" {
    var rdram: [16]u8 = @splat(0);
    var machine = Machine.init(&rdram);
    machine.setReg(0, 5);
    machine.setReg(1, 6);
    try testing.expectEqual(@as(u32, 0), machine.gpr[0]);
    try testing.expectEqual(@as(u32, 6), machine.gpr[1]);
    try testing.expectEqual(@as(usize, 8), (try machine.rdramSlice(0xa000_0008, 8)).len);
    try testing.expectError(error.RdramOutOfBounds, machine.rdramSlice(12, 8));
}

test "profiles record each executed instruction" {
    var machine = Machine.init(&.{});
    var profile: Profile = .{};
    machine.profile = &profile;
    std.mem.writeInt(u32, machine.imem[0..4], 0x0000_000d, .big);
    machine.start(0);
    _ = try machine.run(4);
    try testing.expectEqual(@as(u64, 1), profile.instructions[0]);
    try testing.expectEqual(@as(u64, 1), profile.cycles[0]);
}

test "programs load into IMEM, DMEM, and persistent state" {
    var machine = Machine.init(&.{});
    machine.load(.{
        .text = &.{ 1, 2, 3, 4 },
        .data = &.{ 5, 6 },
        .data_address = 0x100,
        .pc_start = 0x10,
        .text_offset = 0x0c,
        .state_offset = 0x200,
        .state_len = 1,
        .state_init = &.{7},
    });
    try testing.expectEqual(@as(u8, 1), machine.imem[0x0c]);
    try testing.expectEqual(@as(u8, 6), machine.dmem[0x101]);
    try testing.expectEqual(@as(u8, 7), machine.dmem[0x200]);
    try testing.expectEqual(@as(u32, 0x10), machine.pc);
    try testing.expect(machine.sp.halted);
    try testing.expectError(error.Halted, machine.step());
}

fn loadWords(machine: *Machine, words: []const u32) void {
    for (words, 0..) |word, index| std.mem.writeInt(u32, machine.imem[index * 4 ..][0..4], word, .big);
}

test "reading a DMA destination before the transfer finishes is a hazard" {
    const encode = @import("encode.zig");
    var rdram: [64]u8 = @splat(7);
    var machine = Machine.init(&rdram);
    loadWords(&machine, &.{
        encode.ori(8, 0, 0x100),
        encode.cop0Move(true, 8, 0),
        encode.cop0Move(true, 0, 1),
        encode.ori(9, 0, 7),
        encode.cop0Move(true, 9, 2),
        encode.lw(10, 0, 0x104),
        encode.brk,
    });
    machine.start(0);
    try testing.expectError(error.DmaHazard, machine.run(16));
    const hazard = machine.hazard.?;
    try testing.expectEqual(@as(u32, 0x14), hazard.pc);
    try testing.expectEqual(@as(u32, 0x104), hazard.address);
    try testing.expectEqual(dma_engine.Direction.to_rsp, hazard.direction);
}

test "waiting for DMA busy avoids the hazard and a third transfer overflows" {
    const encode = @import("encode.zig");
    var rdram: [64]u8 = @splat(7);
    var machine = Machine.init(&rdram);
    loadWords(&machine, &.{
        encode.ori(8, 0, 0x100),
        encode.cop0Move(true, 8, 0),
        encode.cop0Move(true, 0, 1),
        encode.ori(9, 0, 7),
        encode.cop0Move(true, 9, 2),
        encode.cop0Move(false, 11, 6),
        encode.bne(11, 0, -2),
        encode.nop,
        encode.lw(10, 0, 0x104),
        encode.cop0Move(true, 9, 2),
        encode.cop0Move(true, 9, 2),
        encode.cop0Move(true, 9, 2),
        encode.brk,
    });
    machine.start(0);
    try testing.expectError(error.DmaQueueFull, machine.run(200));
    try testing.expectEqual(@as(u32, 0x0707_0707), machine.gpr[10]);
    try testing.expect(machine.pipeline.cycles > dma_engine.cost(.to_rsp, .{}));
}
