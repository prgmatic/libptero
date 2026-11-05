//! Representative command streams for every shipped RSP program, executed
//! through the resident dispatcher in the host RSP interpreter.
//!
//! Each workload reports the retired instructions and estimated cycles of its
//! measured submission plus a digest of everything the microcode produced
//! (DMEM results, RDRAM outputs, RDP command bytes). The checked-in baseline
//! (`baseline.zon`) pins both: rewrites must reproduce identical outputs and
//! should not regress cycles beyond the documented tolerance.
const std = @import("std");
const n64 = @import("n64");
const interp = @import("rsp_interp");

const programs = n64.rsp.programs;
const dispatcher_symbols = programs.command_dispatcher_symbols;
const Session = interp.Session;

pub const Outcome = struct {
    instructions: u64,
    cycles: u64,
    digest: [16]u8,
};

pub const Symbol = interp.Profile.Symbol;

/// The overlay a workload drives, for handler-coverage accounting.
pub const OverlayKind = enum { rdp, audio_mixer, audio_vadpcm, geometry };

pub const Workload = struct {
    name: []const u8,
    overlay: ?OverlayKind = null,
    description: []const u8,
    run: *const fn (*Harness) anyerror!Outcome,
    /// IMEM symbols of the programs this workload executes, for profiles.
    symbols: SymbolSource = resident_symbols,
};

/// Collects IMEM symbols from generated symbol modules for profiling,
/// skipping compiler-generated block labels so costs land on functions.
pub fn collectSymbols(allocator: std.mem.Allocator, comptime modules: anytype) ![]Symbol {
    var list: std.ArrayList(Symbol) = .empty;
    errdefer list.deinit(allocator);
    inline for (modules) |module| {
        for (module.zsp_imem_symbols) |symbol| {
            if (std.mem.startsWith(u8, symbol.name, "LABEL_")) continue;
            try list.append(allocator, .{ .name = symbol.name, .offset = symbol.offset });
        }
    }
    return list.toOwnedSlice(allocator);
}

pub const SymbolSource = *const fn (std.mem.Allocator) anyerror![]Symbol;

/// A `SymbolSource` for the given generated symbol modules.
pub fn symbolTable(comptime modules: anytype) SymbolSource {
    return struct {
        fn collect(allocator: std.mem.Allocator) anyerror![]Symbol {
            return collectSymbols(allocator, modules);
        }
    }.collect;
}

const resident_symbols = symbolTable(.{dispatcher_symbols});

pub const all = [_]Workload{
    .{ .name = "dispatcher", .description = "internal commands: DMEM writes, call/return, jump, DMA", .run = dispatcher },
    .{
        .name = "rdp_state",
        .overlay = .rdp,
        .description = "RDP overlay state commands: mode stack, combiner/blend/fog, fixups, AutoTMEM, rectangles, Z clear",
        .run = rdpState,
        .symbols = symbolTable(.{ dispatcher_symbols, programs.rdp_overlay_symbols }),
    },
    .{
        .name = "rdp",
        .overlay = .rdp,
        .description = "RDP overlay: buffers, modes, fills, scissor, triangles, full sync",
        .run = rdp,
        .symbols = symbolTable(.{ dispatcher_symbols, programs.rdp_overlay_symbols }),
    },
} ++ @import("audio_workloads.zig").all ++ @import("geometry_workloads.zig").all;

pub const rdram_size = 8 << 20;
pub const instruction_limit = 50_000_000;

/// Owns the RDRAM, interpreter session, RDP capture, and optional profile.
/// Initialize in place: the machine keeps a pointer to `rdp_bytes`.
pub const Harness = struct {
    allocator: std.mem.Allocator,
    rdram: []u8,
    session: Session,
    rdp_bytes: std.Io.Writer.Allocating,
    profile: ?*interp.Profile = null,

    pub fn init(self: *Harness, allocator: std.mem.Allocator) !void {
        const rdram = try allocator.alloc(u8, rdram_size);
        @memset(rdram, 0);
        self.* = .{
            .allocator = allocator,
            .rdram = rdram,
            .session = Session.init(rdram, programs.command_dispatcher, .{
                .overlay_table = dispatcher_symbols.overlay_data_rdram,
                .overlay_idmap = dispatcher_symbols.overlay_idmap,
                .queue_rdram_address = dispatcher_symbols.queue_rdram_address,
                .rdp_target_bitdepth = dispatcher_symbols.rdp_target_bitdepth,
            }),
            .rdp_bytes = .init(allocator),
        };
        self.session.machine.rdp_output = &self.rdp_bytes.writer;
    }

    pub fn deinit(self: *Harness) void {
        self.rdp_bytes.deinit();
        self.allocator.free(self.rdram);
    }

    /// Runs a setup submission that is not part of the measurement.
    pub fn prepare(self: *Harness, writer: Session.CommandWriter) !void {
        _ = try self.session.submit(writer.address, instruction_limit);
    }

    /// Runs the measured submission with profiling attached.
    pub fn measure(self: *Harness, writer: Session.CommandWriter) !Measurement {
        const machine = &self.session.machine;
        const before = Measurement{ .instructions = machine.instructions, .cycles = machine.pipeline.cycles };
        machine.profile = self.profile;
        defer machine.profile = null;
        _ = try self.session.submit(writer.address, instruction_limit);
        return .{ .instructions = machine.instructions - before.instructions, .cycles = machine.pipeline.cycles - before.cycles };
    }

    pub fn dmem(self: *Harness, start: u16, end: u16) []const u8 {
        return self.session.machine.dmem[start..end];
    }

    pub fn rdramBytes(self: *Harness, address: u32, len: usize) ![]const u8 {
        return self.session.bytes(address, len);
    }
};

pub const Measurement = struct { instructions: u64, cycles: u64 };

pub fn outcome(measurement: Measurement, parts: []const []const u8) Outcome {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, part.len, .little);
        hash.update(&len);
        hash.update(part);
    }
    const full = hash.finalResult();
    return .{ .instructions = measurement.instructions, .cycles = measurement.cycles, .digest = full[0..16].* };
}

fn dispatcher(h: *Harness) !Outcome {
    const s = &h.session;
    const source = try s.place(&(@as([16]u8, .{ 0xde, 0xad, 0xbe, 0xef } ++ @as([12]u8, @splat(0x5a)))), 8);
    var block = try s.commands(64);
    for (0..8) |index| try block.internal(.write_word, @intCast(0x880 + index * 4), &.{@intCast(0xb000 + index)});
    try block.internal(.ret, 0, &.{});
    var tail = try s.commands(64);
    for (0..8) |index| try tail.internal(.write_word, @intCast(0x8a0 + index * 4), &.{@intCast(0xc000 + index)});
    try tail.internal(.dma, @intCast(source), &.{ 0x8c0, 15, 0x0c });
    var alternate = try s.commands(64);
    try alternate.internal(.write_word, 0x8d0, &.{0xa1a1_a1a1});
    try alternate.internal(.swap_buffers, 8 * 4, &.{ 9 * 4, 0 });
    var main = try s.commands(256);
    for (0..32) |index| try main.internal(.write_word, @intCast(0x800 + index * 4), &.{@as(u32, @intCast(index)) *% 0x0101_0101});
    try main.internal(.call, @intCast(block.address), &.{0});
    // SP_STATUS writes: set signal 2, then (with signal 4 clear) set signal 3.
    try main.internal(.write_status, 1 << 14, &.{});
    try main.internal(.wait_then_write_status, 1 << 16, &.{1 << 11});
    try main.internal(.write_word, dispatcher_symbols.pointer_stack + 9 * 4, &.{alternate.address});
    try main.internal(.swap_buffers, 9 * 4, &.{ 8 * 4, 0 });
    try main.internal(.write_word, 0x8d4, &.{0xb2b2_b2b2});
    try main.internal(.jump, @intCast(tail.address), &.{});
    const measured = try h.measure(main);
    const signals = [_]u8{h.session.machine.sp.signals};
    return outcome(measured, &.{ h.dmem(0x800, 0x8d8), &signals });
}

/// Forwards complete raw RDP packets to the RDP overlay through a command
/// writer, mirroring the runtime's overlay backend.
pub const RdpQueue = struct {
    writer: *Session.CommandWriter,
    overlay: Session.Overlay,
    packet: [22]u64 = undefined,
    len: usize = 0,
    failure: ?anyerror = null,

    pub fn push(self: *RdpQueue, value: u64) void {
        self.packet[self.len] = value;
        self.len += 1;
        const expected = n64.rdp.command_encoder.packetWordCount(@truncate(self.packet[0] >> 56));
        if (self.len == expected) self.emit();
    }

    fn emit(self: *RdpQueue) void {
        var storage: [43]u32 = undefined;
        const command = n64.rdp.command_encoder.overlayPacket(self.packet[0..self.len], &storage);
        self.len = 0;
        self.writer.overlayCommand(self.overlay, command.index, @intCast(command.inline_argument), command.arguments) catch |err| {
            self.failure = err;
        };
    }

    pub fn execute(_: *RdpQueue) void {}
    pub fn clear(_: *RdpQueue) void {}

    pub fn check(self: *const RdpQueue) !void {
        if (self.failure) |err| return err;
    }
};

pub const RdpSetup = struct {
    overlay: Session.Overlay,
    sync_output: u32,
    buffers: [2]u32,
};

/// Registers the RDP overlay and attaches its two dynamic RDP buffers the
/// way `Queue.configureRdpBuffers` does.
pub fn setUpRdp(h: *Harness, id: u8) !RdpSetup {
    const s = &h.session;
    const overlay = try s.registerOverlay(programs.rdp_overlay, id);
    const sync_output = try s.allocate(16, 8);
    const syncpoint_source = try s.allocate(8, 8);
    const state = try s.bytes(overlay.stateAddress(programs.rdp_overlay.state_offset), 24);
    std.mem.writeInt(u32, state[16..20], sync_output, .big);
    std.mem.writeInt(u32, state[20..24], syncpoint_source, .big);
    const len = n64.rsp.rdp_dynamic_buffer_len;
    const buffers = [2]u32{ try s.allocate(len, 16), try s.allocate(len, 16) };
    var setup = try s.commands(16);
    try setup.internal(.write_word, dispatcher_symbols.rdp_current, &.{buffers[0]});
    try setup.internal(.write_word, dispatcher_symbols.rdp_sentinel, &.{buffers[0] + len});
    try setup.internal(.write_word, dispatcher_symbols.rdp_buffers, &.{buffers[0]});
    try setup.internal(.write_word, dispatcher_symbols.rdp_buffers + 4, &.{buffers[1]});
    const dp = &s.machine.dp;
    dp.* = .{ .start = @intCast(buffers[0]), .end = @intCast(buffers[0]), .current = @intCast(buffers[0]) };
    try h.prepare(setup);
    return .{ .overlay = overlay, .sync_output = sync_output, .buffers = buffers };
}

/// One native triangle vertex in the RDP overlay's setTriangleData layout.
pub fn nativeVertex(x: i16, y: i16, s_coordinate: i16, t: i16, w: u32) [6]u32 {
    return .{ pair(x * 4, y * 4), 0, 0, pair(s_coordinate * 32, t * 32), w, @intCast((@as(u64, 1) << 32) / w) };
}

fn pair(high: i16, low: i16) u32 {
    return @as(u32, @as(u16, @bitCast(high))) << 16 | @as(u16, @bitCast(low));
}

fn rdp(h: *Harness) !Outcome {
    const setup = try setUpRdp(h, n64.rsp.Runtime.rdp_overlay_id);
    const color_image = try h.session.allocate(320 * 240 * 2, 64);
    var writer = try h.session.commands(1024);
    var encoder = n64.rdp.CommandEncoder(RdpQueue).init(.{ .writer = &writer, .overlay = setup.overlay });
    encoder.queue.push(@as(u64, 0xff10_013f_0000_0000) | color_image);
    encoder.setScissor(0, 0, 320, 240);
    encoder.setOtherModes(.{});
    encoder.setFillColor(n64.graphics.pixel.Rgba32{ .r = 10, .g = 20, .b = 30, .a = 255 });
    for (0..8) |index| encoder.fillRect(@intCast(index * 8), 4, @intCast(index * 8 + 30), 60);
    encoder.setPrimColor(.{ .r = 200, .g = 100, .b = 50, .a = 255 });
    encoder.setEnvironmentColor(.{ .r = 1, .g = 2, .b = 3, .a = 4 });
    encoder.pipeSync();
    for (0..6) |index| {
        const offset: i16 = @intCast(index * 20);
        const corners = [3][6]u32{
            nativeVertex(10 + offset, 10, 0, 0, 0x0001_0000),
            nativeVertex(60 + offset, 30, 16, 0, 0x0002_0000),
            nativeVertex(20 + offset, 90, 0, 16, 0x0001_8000),
        };
        for (corners, 0..) |corner, vertex| try writer.overlayCommand(setup.overlay, 31, @intCast(vertex * 32), &corner);
        try writer.overlayCommand(setup.overlay, 30, 0xca00, &.{});
    }
    encoder.fullSync();
    try encoder.queue.check();
    const len = n64.rsp.rdp_dynamic_buffer_len;
    try writer.internal(.rdp_set_buffer, @intCast(setup.buffers[1]), &.{ setup.buffers[1], setup.buffers[1] + len });
    encoder.fillRect(0, 0, 8, 8);
    try encoder.queue.check();
    const measured = try h.measure(writer);
    return outcome(measured, &.{ h.rdp_bytes.written(), try h.rdramBytes(setup.sync_output, 16) });
}

fn sequence(count: usize, base: u32) [64]u32 {
    var words: [64]u32 = @splat(0);
    for (words[0..count], 0..) |*word, index| word.* = base + @as(u32, @intCast(index));
    return words;
}

/// Command sequences mirroring the hardware RDP-overlay tests in
/// `zsp_tests.zig` (mode stack, reset, fixups, AutoTMEM, passthrough
/// triangles, exclusive rectangles, Z clear), so rewrites keep their outputs.
fn rdpState(h: *Harness) !Outcome {
    const setup = try setUpRdp(h, n64.rsp.Runtime.rdp_overlay_id);
    const s = &h.session;
    const o = setup.overlay;
    const lookup_base = try s.allocate(0x100, 64);
    const z_target = try s.allocate(4096 * 2, 8);
    const z_temporary = try s.allocate(0x200, 8);
    var w = try s.commands(1024);
    try w.internal(.write_word, dispatcher_symbols.rdp_mode + 24, &.{0x0020_0000});
    try w.overlayCommand(o, 18, 0x001002, &.{0x003004});
    try w.overlayCommand(o, 6, 0, &.{});
    try w.overlayCommand(o, 58, 0x001122, &.{0xaabbccdd});
    try w.overlayCommand(o, 19, (2 << 16) | 0x55, &.{0});
    try w.overlayCommand(o, 47, 0x00200000, &.{0x12345678});
    try w.overlayCommand(o, 27, 0x123456, &.{ 0x89abcdef, 0, 0 });
    try w.overlayCommand(o, 25, 0, &.{0});
    try w.overlayCommand(o, 24, 0, &.{0});
    try w.overlayCommand(o, 5, 0x654321, &.{0x01234567});
    try w.overlayCommand(o, 20, 4, &.{ 0xfffffff7, 8 });
    try w.overlayCommand(o, 7, 0, &.{});
    try w.overlayCommand(o, 4, 0x123456, &.{ 0x89abcdef, 0, 0 });
    try w.overlayCommand(o, 22, 0, &.{0x11223344});
    try w.overlayCommand(o, 36, 0x000102, &.{ 0x03040506, 0x0708090a, 0x0b0c0d0e });
    try w.overlayCommand(o, 1, 3 << 2, &.{lookup_base});
    try w.overlayCommand(o, 62, 0, &.{(@as(u32, 3) << 26) | 0x40});
    try w.overlayCommand(o, 39, 0, &.{0});
    try w.overlayCommand(o, 28, 0, &.{});
    try w.overlayCommand(o, 28, 24, &.{});
    try w.overlayCommand(o, 29, 3 << 19, &.{0x76543210});
    try w.overlayCommand(o, 39, 0, &.{0});
    try w.overlayCommand(o, 28, 0x00ffffff, &.{});
    try w.internal(.write_word, dispatcher_symbols.rdp_mode + 24, &.{0x3800_0000});
    try w.overlayCommand(o, 8, 1, sequence(7, 0x1000_0001)[0..7]);
    try w.overlayCommand(o, 15, 2, sequence(43, 0x2000_0001)[0..43]);
    try w.internal(.write_word, dispatcher_symbols.rdp_mode + 24, &.{0x0020_0000});
    try w.overlayCommand(o, 2, 0x00abcdef, &.{0x01234567});
    try w.overlayCommand(o, 16, 0x00123456, &.{ 0x89abcdef, 0x0badcafe, 0x12345678 });
    try w.overlayCommand(o, 3, @intCast(z_target), &.{ (1 << 12) | (4096 - 1), z_temporary, 0x7fff });
    try w.overlayCommand(o, 17, 1, &.{});
    try w.overlayCommand(o, 17, 0, &.{});
    try w.overlayCommand(o, 26, 0, &.{});
    const measured = try h.measure(w);
    return outcome(measured, &.{ h.rdp_bytes.written(), try h.rdramBytes(z_target, 4096 * 2), h.dmem(dispatcher_symbols.rdp_mode, dispatcher_symbols.rdp_mode + 32) });
}

test "rdp state workload clears Z and restores pushed modes" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    _ = try rdpState(&h);
    const counts = countOpcodes(h.rdp_bytes.written());
    try std.testing.expect(counts[0x2d] >= 2);
    try std.testing.expectEqual(@as(u32, 0x7c123456), h.session.machine.readDmem(u32, dispatcher_symbols.rdp_mode));
}

test "every workload's symbol table names its programs' functions" {
    for (all) |workload| {
        const symbols = try workload.symbols(std.testing.allocator);
        defer std.testing.allocator.free(symbols);
        try std.testing.expect(symbols.len > 0);
        for (symbols) |symbol| try std.testing.expect(!std.mem.startsWith(u8, symbol.name, "LABEL_"));
    }
}

test "dispatcher workload applies every internal command" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    _ = try dispatcher(&h);
    const m = &h.session.machine;
    try std.testing.expectEqual(@as(u32, 0x1f1f_1f1f), m.readDmem(u32, 0x800 + 31 * 4));
    try std.testing.expectEqual(@as(u32, 0xb007), m.readDmem(u32, 0x880 + 7 * 4));
    try std.testing.expectEqual(@as(u32, 0xc007), m.readDmem(u32, 0x8a0 + 7 * 4));
    try std.testing.expectEqual(@as(u32, 0xdead_beef), m.readDmem(u32, 0x8c0));
    try std.testing.expectEqual(@as(u32, 0xa1a1_a1a1), m.readDmem(u32, 0x8d0));
    try std.testing.expectEqual(@as(u32, 0xb2b2_b2b2), m.readDmem(u32, 0x8d4));
    try std.testing.expectEqual(@as(u8, 0b1100), m.sp.signals & 0b1100);
}

/// Counts RDP commands by opcode in a captured stream.
fn countOpcodes(stream: []const u8) [64]u32 {
    var counts: [64]u32 = @splat(0);
    var offset: usize = 0;
    while (offset + 8 <= stream.len) {
        const opcode = stream[offset] & 0x3f;
        counts[opcode] += 1;
        offset += 8 * n64.rdp.command_encoder.packetWordCount(opcode);
    }
    return counts;
}

fn setup_second_buffer(h: *Harness) u24 {
    return @intCast(h.session.machine.readDmem(u32, dispatcher_symbols.rdp_buffers + 4));
}

test "triangles move to the other RDP buffer when the current one fills" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    const setup = try setUpRdp(&h, n64.rsp.Runtime.rdp_overlay_id);
    var writer = try h.session.commands(512);
    // Room for one shaded, textured, Z-buffered triangle (176 bytes).
    try writer.internal(.write_word, dispatcher_symbols.rdp_sentinel, &.{setup.buffers[0] + 200});
    for (0..3) |index| {
        const offset: i16 = @intCast(index * 20);
        const corners = [3][6]u32{
            nativeVertex(10 + offset, 10, 0, 0, 0x0001_0000),
            nativeVertex(60 + offset, 30, 16, 0, 0x0002_0000),
            nativeVertex(20 + offset, 90, 0, 16, 0x0001_8000),
        };
        for (corners, 0..) |corner, vertex| try writer.overlayCommand(setup.overlay, 31, @intCast(vertex * 32), &corner);
        try writer.overlayCommand(setup.overlay, 30, 0xca00, &.{});
    }
    _ = try h.measure(writer);
    const counts = countOpcodes(h.rdp_bytes.written());
    var triangles: u32 = 0;
    for (counts[0x08..0x10]) |count| triangles += count;
    try std.testing.expectEqual(@as(u32, 3), triangles);
    try std.testing.expectEqual(setup.buffers[1], h.session.machine.dp.start);
    const current = h.session.machine.readDmem(u32, dispatcher_symbols.rdp_current);
    try std.testing.expect(current > setup.buffers[1] and current < setup.buffers[1] + 2 * 176);
}

test "rdp workload emits fills, shaded triangles, and a full sync" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    _ = try rdp(&h);
    const counts = countOpcodes(h.rdp_bytes.written());
    try std.testing.expectEqual(@as(u32, 9), counts[0x36]);
    try std.testing.expectEqual(setup_second_buffer(&h), h.session.machine.dp.start);
    try std.testing.expectEqual(@as(u32, 1), counts[0x29]);
    try std.testing.expectEqual(@as(u32, 1), counts[0x3f]);
    var triangles: u32 = 0;
    for (counts[0x08..0x10]) |count| triangles += count;
    try std.testing.expectEqual(@as(u32, 6), triangles);
}
