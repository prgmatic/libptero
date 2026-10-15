const std = @import("std");
const cache = @import("../../cpu/cache.zig");
const rsp = @import("../../rsp.zig");
const BitDepth = @import("../../graphics/pixel.zig").BitDepth;
const cc = @import("../combiner.zig");
const blender = @import("../blender.zig");
const modes = @import("../modes.zig");

const CombineMode = cc.CombineMode;
const OtherModes = modes.OtherModes;
const Rgba32 = @import("../../graphics/pixel.zig").Rgba32;

const encoding = @import("../command_encoder.zig");
const packetWordCount = encoding.packetWordCount;
const overlayCommandIndex = encoding.overlayCommandIndex;

const Overlay = @This();
rsp_queue: *rsp.Queue,
overlay: *rsp.Overlay,
dynamic_buffers: [2][]align(16) u8,
syncpoint_source: [2]u32 align(8) = .{ 0, 0 },
sync_state_output: [4]u32 align(8) = .{ 0, 0, 0, 0 },
packet: [22]u64 = undefined,
packet_len: usize = 0,
packet_expected: usize = 0,
configured: bool = false,

pub fn init(
    rsp_queue: *rsp.Queue,
    overlay: *rsp.Overlay,
    dynamic_buffers: [2][]align(16) u8,
) Overlay {
    if (dynamic_buffers[0].len != rsp.rdp_dynamic_buffer_len or
        dynamic_buffers[1].len != rsp.rdp_dynamic_buffer_len)
    {
        @panic("overlay-backed RDP dynamic buffers must each be 64 KiB");
    }
    return .{
        .rsp_queue = rsp_queue,
        .overlay = overlay,
        .dynamic_buffers = dynamic_buffers,
    };
}

pub inline fn push(self: *Overlay, value: u64) void {
    self.ensureConfigured();
    if (self.packet_len == 0) {
        const opcode: u8 = @truncate(value >> 56);
        self.packet_expected = packetWordCount(opcode);
        if (self.packet_expected == 1) {
            self.rsp_queue.writeOverlayCommandKnown(
                self.overlay,
                overlayCommandIndex(opcode),
                @as(u32, @truncate(value >> 32)) & 0x00ffffff,
                &.{@as(u32, @truncate(value))},
            );
            return;
        }
    }
    self.packet[self.packet_len] = value;
    self.packet_len += 1;
    if (self.packet_len == self.packet_expected) self.emitPacket();
}

/// One complete single-word RDP command. Callers know the packet size, so
/// this skips packet assembly; the opcode usually folds at compile time.
pub inline fn push1(self: *Overlay, value: u64) void {
    self.ensureConfigured();
    std.debug.assert(self.packet_len == 0);
    const opcode: u8 = @truncate(value >> 56);
    self.rsp_queue.writeOverlayCommandFixed(self.overlay, overlayCommandIndex(opcode), @as(u32, @truncate(value >> 32)) & 0x00ffffff, 1, .{@truncate(value)});
}

/// One complete two-word RDP command (texture rectangles).
pub inline fn push2(self: *Overlay, first: u64, second: u64) void {
    self.ensureConfigured();
    std.debug.assert(self.packet_len == 0);
    const opcode: u8 = @truncate(first >> 56);
    self.rsp_queue.writeOverlayCommandFixed(self.overlay, overlayCommandIndex(opcode), @as(u32, @truncate(first >> 32)) & 0x00ffffff, 3, .{ @truncate(first), @truncate(second >> 32), @truncate(second) });
}

pub fn execute(self: *Overlay) void {
    if (self.packet_len != 0) @panic("incomplete RDP command packet");
    rsp.flush(self.rsp_queue);
}

/// Overlay packets are already streamed. Append the marker before flushing
/// so submission does not rotate the resident buffers twice.
pub fn submitSyncpoint(self: *Overlay) rsp.Syncpoint {
    if (self.packet_len != 0) @panic("incomplete RDP command packet");
    return self.rsp_queue.insertSyncpoint();
}

pub fn prepare(self: *Overlay) void {
    self.ensureConfigured();
}

pub fn clear(self: *Overlay) void {
    // Overlay commands are written directly into the resident queue, so
    // they cannot be discarded like a CPU-side command buffer. At a frame
    // boundary there must only be complete packets; rsp.flush handles the
    // resident queue's double-buffered reuse on the next execute().
    if (self.packet_len != 0) @panic("cannot clear an incomplete RDP command packet");
}

// Submit compact vertices to the overlay's native triangle generator.
// This follows libdragon's RDPQ_CMD_TRIANGLE_DATA / RDPQ_CMD_TRIANGLE ABI
// instead of asking the CPU to construct and then repack a 96-byte TRI_TEX
// RDP packet.
pub fn nativeTexturedTriangle(self: *Overlay, tile: u3, vertices: anytype) void {
    if (self.packet_len != 0) @panic("native triangle cannot split a raw RDP packet");
    self.ensureConfigured();
    inline for (0..3) |index| {
        const vertex = vertices[index];
        const xy = packI16Pair(toS13_2(vertex.x), toS13_2(vertex.y));
        const st = packI16Pair(toTexel5(vertex.s), toTexel5(vertex.t));
        self.rsp_queue.writeOverlayCommandKnown(
            self.overlay,
            31,
            index * 32,
            &.{ xy, 0, 0, st, toS16_16(1.0 / vertex.inv_w), toS16_16(vertex.inv_w) },
        );
    }
    self.rsp_queue.writeOverlayCommandKnown(self.overlay, 30, 0xca00 | @as(u32, tile), &.{});
}

pub fn nativeTexturedQuad(self: *Overlay, tile: u3, vertices: anytype) void {
    if (self.packet_len != 0) @panic("native quad cannot split a raw RDP packet");
    self.ensureConfigured();
    // Keep both triangles and their four unique vertices together so a
    // rollover cannot discard the shared vertex state between them.
    self.rsp_queue.reserveLowPriorityWords(30);
    inline for (0..3) |index| {
        self.writeNativeVertex(index, vertices[index]);
    }
    const triangle_bits = 0xca00 | @as(u32, tile);
    self.rsp_queue.writeOverlayCommandKnown(
        self.overlay,
        30,
        triangle_bits,
        &.{},
    );
    self.writeNativeVertex(1, vertices[3]);
    self.rsp_queue.writeOverlayCommandKnown(
        self.overlay,
        30,
        triangle_bits | 0x00020000,
        &.{},
    );
}

inline fn writeNativeVertex(
    self: *Overlay,
    comptime index: usize,
    vertex: anytype,
) void {
    const xy = packI16Pair(toS13_2(vertex.x), toS13_2(vertex.y));
    const st = packI16Pair(toTexel5(vertex.s), toTexel5(vertex.t));
    self.rsp_queue.writeOverlayCommandKnown(
        self.overlay,
        31,
        index * 32,
        &.{ xy, 0, 0, st, toS16_16(1.0 / vertex.inv_w), toS16_16(vertex.inv_w) },
    );
}

fn emitPacket(self: *Overlay) void {
    var arguments: [43]u32 = undefined;
    const first = self.packet[0];
    arguments[0] = @truncate(first);
    var argument_len: usize = 1;
    for (self.packet[1..self.packet_len]) |word| {
        arguments[argument_len] = @truncate(word >> 32);
        arguments[argument_len + 1] = @truncate(word);
        argument_len += 2;
    }
    const opcode: u8 = @truncate(first >> 56);
    // Packet size and command index are validated by the fixed RDP ABI
    // above; avoid scanning overlay metadata for every glyph rectangle.
    self.rsp_queue.writeOverlayCommandKnown(
        self.overlay,
        overlayCommandIndex(opcode),
        @as(u32, @truncate(first >> 32)) & 0x00ffffff,
        arguments[0..argument_len],
    );
    self.packet_len = 0;
    self.packet_expected = 0;
}

fn configureOverlayState(self: *Overlay) void {
    cache.writebackData(&self.syncpoint_source);
    cache.writebackData(&self.sync_state_output);
    var state = rsp.overlayState(self.overlay);
    if (state.len < 24) @panic("RDP overlay state is missing full-sync fields");
    std.mem.writeInt(
        u32,
        state[16..20],
        @truncate(@intFromPtr(&self.sync_state_output) & 0x00ffffff),
        .big,
    );
    std.mem.writeInt(
        u32,
        state[20..24],
        @truncate(@intFromPtr(&self.syncpoint_source) & 0x00ffffff),
        .big,
    );
    rsp.writebackOverlayState(self.overlay);
}

inline fn ensureConfigured(self: *Overlay) void {
    if (!self.configured) {
        self.configureOverlayState();
        self.rsp_queue.configureRdpBuffers(self.dynamic_buffers[0], self.dynamic_buffers[1]);
        self.configured = true;
    }
}

fn packI16Pair(high: i16, low: i16) u32 {
    return @as(u32, @as(u16, @bitCast(high))) << 16 | @as(u16, @bitCast(low));
}

fn toS13_2(value: f32) i16 {
    const scaled = value * 4.0;
    if (scaled <= -32768.0) return -32768;
    if (scaled >= 32767.0) return 32767;
    var fixed: i32 = @intFromFloat(scaled);
    if (scaled < 0.0 and @as(f32, @floatFromInt(fixed)) != scaled) fixed -= 1;
    return @intCast(fixed);
}

fn toTexel5(value: f32) i16 {
    if (value <= -1024.0) return -32768;
    if (value >= 1023.96875) return 32767;
    return @intFromFloat(value * 32.0);
}

fn toS16_16(value: f32) u32 {
    if (value >= 32768.0) return 0x7fffffff;
    if (value < -32768.0) return 0x80000000;
    const fixed: i32 = @intFromFloat(value * 65536.0);
    return @bitCast(fixed);
}

test "native triangle fixed-point conversion floors and saturates" {
    try std.testing.expectEqual(@as(i16, 4), toS13_2(1.0));
    try std.testing.expectEqual(@as(i16, -1), toS13_2(-0.1));
    try std.testing.expectEqual(@as(i16, 32767), toS13_2(9000.0));
    try std.testing.expectEqual(@as(i16, -32768), toS13_2(-9000.0));
    try std.testing.expectEqual(@as(i16, 32), toTexel5(1.0));
    try std.testing.expectEqual(@as(i16, -3), toTexel5(-0.1));
    try std.testing.expectEqual(@as(i16, 32767), toTexel5(2000.0));
    try std.testing.expectEqual(@as(i16, -32768), toTexel5(-2000.0));
}
