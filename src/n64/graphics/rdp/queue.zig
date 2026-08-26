const io = @import("io.zig");
const std = @import("std");
const cache = @import("../../cpu/cache.zig");
const rsp = @import("../../rsp/rsp.zig");
const ColorFormat = @import("../color.zig").Format;
const BitDepth = @import("../color.zig").BitDepth;
const cc = @import("combiner.zig");
const blender = @import("blender.zig");
const modes = @import("modes.zig");

const CombineMode = cc.CombineMode;
const OtherModes = modes.OtherModes;
const Rgba32 = @import("../color.zig").Rgba32;

pub const FixedQueue = struct {
    buffer: []u64,
    index: usize = 0,

    pub fn push(self: *FixedQueue, value: u64) void {
        if (self.index >= self.buffer.len) @panic("RDP Queue Full");
        self.buffer[self.index] = value;
        self.index += 1;
    }

    pub fn execute(self: *FixedQueue) void {
        if (self.index == 0) return;
        const commands = self.buffer[0..self.index];
        cache.writebackData(commands);
        const addr: u32 = @intFromPtr(self.buffer.ptr) & 0xFFFFFF;
        io.status_write.* = 1;
        io.dma_start_addr.* = addr;
        io.dma_end_addr.* = addr + @sizeOf(u64) * commands.len;
    }

    pub fn clear(self: *FixedQueue) void {
        self.index = 0;
    }
};

// CPU-side raw RDP command sink submitted through the resident RSP queue.
// The two dynamic buffers are shared with overlays that emit additional RDP
// commands after this static CPU-generated buffer has been scheduled.
pub const RspQueue = struct {
    buffer: []align(8) u64,
    dynamic_buffers: [2][]align(16) u8,
    rsp_queue: *rsp.Queue,
    index: usize = 0,
    configured: bool = false,

    pub fn init(
        rsp_queue: *rsp.Queue,
        buffer: []align(8) u64,
        dynamic_buffers: [2][]align(16) u8,
    ) RspQueue {
        if (buffer.len == 0) @panic("RSP-backed RDP queue buffer must not be empty");
        if (dynamic_buffers[0].len != rsp.rdp_dynamic_buffer_len or
            dynamic_buffers[1].len != rsp.rdp_dynamic_buffer_len)
        {
            @panic("RSP-backed RDP dynamic buffers must each be 64 KiB");
        }
        return .{
            .buffer = buffer,
            .dynamic_buffers = dynamic_buffers,
            .rsp_queue = rsp_queue,
        };
    }

    pub fn push(self: *RspQueue, value: u64) void {
        if (self.index >= self.buffer.len) @panic("RSP-backed RDP queue is full");
        self.buffer[self.index] = value;
        self.index += 1;
    }

    pub fn execute(self: *RspQueue) void {
        if (self.index == 0) return;
        if (!self.configured) {
            self.rsp_queue.configureRdpBuffers(self.dynamic_buffers[0], self.dynamic_buffers[1]);
            self.configured = true;
        }
        const commands = self.buffer[0..self.index];
        cache.writebackData(commands);
        const start: u32 = @truncate(@intFromPtr(commands.ptr) & 0x00ffffff);
        const end = start + @as(u32, @intCast(commands.len * @sizeOf(u64)));
        self.rsp_queue.setRdpBuffer(end, start, end);
        rsp.flush(self.rsp_queue);
    }

    pub fn clear(self: *RspQueue) void {
        self.index = 0;
    }
};

// Prefer these names in new code. The older names remain aliases so existing
// applications do not need to migrate all at once.
pub const DirectQueue = FixedQueue;
pub const RspSubmittedQueue = RspQueue;

// Raw RDP command sink which preserves ordering through the resident RSP queue
// and lets the RDP overlay perform its state/address fixups. Use a dedicated
// rsp.Queue so unrelated RSP work cannot be discarded at render boundaries.
pub const OverlayQueue = struct {
    rsp_queue: *rsp.Queue,
    overlay: *rsp.Overlay,
    dynamic_buffers: [2][]align(16) u8,
    syncpoint_source: [2]u32 align(8) = .{ 0, 0 },
    sync_state_output: [4]u32 align(8) = .{ 0, 0, 0, 0 },
    packet: [22]u64 = undefined,
    packet_len: usize = 0,
    packet_expected: usize = 0,
    full_sync_pending: bool = false,
    needs_publication_hold: bool = false,
    configured: bool = false,

    pub fn init(
        rsp_queue: *rsp.Queue,
        overlay: *rsp.Overlay,
        dynamic_buffers: [2][]align(16) u8,
    ) OverlayQueue {
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

    pub inline fn push(self: *OverlayQueue, value: u64) void {
        self.ensureConfigured();
        if (self.packet_len == 0) {
            const opcode: u8 = @truncate(value >> 56);
            if (opcode == 0xe9) self.full_sync_pending = true;
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

    pub fn execute(self: *OverlayQueue) void {
        if (self.packet_len != 0) @panic("incomplete RDP command packet");
        if (!self.full_sync_pending) self.rsp_queue.releaseRdpPublication();
        rsp.flush(self.rsp_queue);
        self.full_sync_pending = false;
        self.needs_publication_hold = true;
    }

    pub fn clear(self: *OverlayQueue) void {
        // Overlay commands are written directly into the resident queue, so
        // they cannot be discarded like a CPU-side command buffer. At a frame
        // boundary there must only be complete packets; rsp.flush handles the
        // resident queue's double-buffered reuse on the next execute().
        if (self.packet_len != 0) @panic("cannot clear an incomplete RDP command packet");
    }

    pub fn rotateBuffers(self: *OverlayQueue) void {
        self.ensureConfigured();
        // Rotate at the frame boundary, while the previous full-sync fence is
        // complete. This keeps native geometry from hitting its fragile
        // mid-primitive dynamic-buffer rollover path.
        self.rsp_queue.setRdpBuffer(0, 0, 0);
    }

    // Submit compact vertices to the overlay's native triangle generator.
    // This follows libdragon's RDPQ_CMD_TRIANGLE_DATA / RDPQ_CMD_TRIANGLE ABI
    // instead of asking the CPU to construct and then repack a 96-byte TRI_TEX
    // RDP packet.
    pub fn nativeTexturedTriangle(self: *OverlayQueue, tile: u3, vertices: anytype) void {
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

    pub fn nativeTexturedQuad(self: *OverlayQueue, tile: u3, vertices: anytype) void {
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
        self: *OverlayQueue,
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

    fn emitPacket(self: *OverlayQueue) void {
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
        self.rsp_queue.writeOverlayCommand(
            self.overlay,
            overlayCommandIndex(opcode),
            @as(u32, @truncate(first >> 32)) & 0x00ffffff,
            arguments[0..argument_len],
        );
        self.packet_len = 0;
        self.packet_expected = 0;
    }

    fn configureOverlayState(self: *OverlayQueue) void {
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

    inline fn ensureConfigured(self: *OverlayQueue) void {
        if (!self.configured) {
            self.configureOverlayState();
            self.rsp_queue.configureRdpBuffers(self.dynamic_buffers[0], self.dynamic_buffers[1]);
            self.rsp_queue.holdRdpPublication();
            self.configured = true;
        } else if (self.needs_publication_hold) {
            self.rsp_queue.holdRdpPublication();
            self.needs_publication_hold = false;
        }
    }
};

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

pub const TextureRectangleOptions = struct {
    lrx: u12,
    lry: u12,
    tile: u3 = 0,
    ulx: u12,
    uly: u12,
    s: i16 = 0,
    t: i16 = 0,
    dsdx: i16,
    dtdy: i16,
};

pub const LoadBlockOptions = struct {
    upper_left_s: u12 = 0,
    upper_left_t: u12 = 0,
    tile: u3 = 0,
    lower_right_s: u12,
    dxt: u12,
};

pub const SetTileSizeOptions = struct {
    upper_left_s: u12 = 0,
    upper_left_t: u12 = 0,
    tile: u3 = 0,
    lower_right_s: u12,
    lower_right_t: u12,
};

pub const SetTileOptions = struct {
    color_format: ColorFormat,
    bit_depth: BitDepth,
    line_length: u9,
    tmem_addr: usize,
    tile_index: u3 = 0,
    palette_index: u4 = 0,
    shift_s: u4 = 0,
    shift_t: u4 = 0,
    mask_s: u4 = 0,
    mask_t: u4 = 0,
    clamp_s: bool = false,
    clamp_t: bool = false,
    mirror_s: bool = false,
    mirror_t: bool = false,
};

// Thin command emitter. Every method pushes exactly the command(s) documented —
// no hidden syncs, no state tracking. Callers are responsible for issuing
// pipeSync/loadSync/tileSync at the right points.
pub fn CommandQueue(comptime QueueType: type) type {
    if (!@hasDecl(QueueType, "push"))
        @compileError("Type must implement push(u64)");
    if (!@hasDecl(QueueType, "execute"))
        @compileError("Type must implement execute()");
    if (!@hasDecl(QueueType, "clear"))
        @compileError("Type must implement clear()");

    return struct {
        const Self = @This();
        queue: QueueType,

        pub fn init(queue: QueueType) Self {
            return .{ .queue = queue };
        }

        pub fn clear(cq: *Self) void {
            cq.queue.clear();
        }

        pub fn execute(cq: *Self) void {
            cq.queue.execute();
        }

        // 0xE4
        pub fn textureRectangle(cq: *Self, options: TextureRectangleOptions) void {
            const words = buildTextureRectangleWords(0xE4, options);
            cq.queue.push(words[0]);
            cq.queue.push(words[1]);
        }

        // 0xE5
        pub fn textureRectangleFlip(cq: *Self, options: TextureRectangleOptions) void {
            const words = buildTextureRectangleWords(0xE5, options);
            cq.queue.push(words[0]);
            cq.queue.push(words[1]);
        }

        // 0xE6
        pub fn loadSync(cq: *Self) void {
            cq.queue.push(@as(u64, 0xE6) << 56);
        }

        // 0xE7
        pub fn pipeSync(cq: *Self) void {
            cq.queue.push(@as(u64, 0xE7) << 56);
        }

        // 0xE8
        pub fn tileSync(cq: *Self) void {
            cq.queue.push(@as(u64, 0xE8) << 56);
        }

        // 0xE9
        pub fn fullSync(cq: *Self) void {
            cq.queue.push(@as(u64, 0xE9) << 56);
        }

        // 0xEE
        pub fn setPrimDepth(cq: *Self, z: u16, dz: u16) void {
            cq.queue.push((@as(u64, 0xEE) << 56) | (@as(u64, z) << 16) | @as(u64, dz));
        }

        // 0xFE
        pub fn setDepthImage(cq: *Self, image: anytype) void {
            cq.queue.push((@as(u64, 0xFE) << 56) | lowBits(@intFromPtr(image.texel_data.ptr), 24));
        }

        // 0xED
        pub fn setScissor(cq: *Self, upper_left_x: u16, upper_left_y: u16, lower_right_x: u16, lower_right_y: u16) void {
            const cmd: u64 =
                (@as(u64, 0xED) << 56) |
                (@as(u64, lowBits(upper_left_x, 12)) << 44) |
                (@as(u64, lowBits(upper_left_y, 12)) << 32) |
                (@as(u64, lowBits(lower_right_x, 12)) << 12) |
                (@as(u64, lowBits(lower_right_y, 12)));
            cq.queue.push(cmd);
        }

        // 0xEF
        pub fn setOtherModes(cq: *Self, settings: OtherModes) void {
            cq.queue.push(@bitCast(settings));
        }

        // 0xF2
        pub fn setTileSize(cq: *Self, options: SetTileSizeOptions) void {
            const cmd: u64 =
                (@as(u64, 0xF2) << 56) |
                (@as(u64, options.upper_left_s) << 44) |
                (@as(u64, options.upper_left_t) << 32) |
                (@as(u64, options.tile) << 24) |
                (@as(u64, options.lower_right_s) << 12) |
                (@as(u64, options.lower_right_t));
            cq.queue.push(cmd);
        }

        // 0xF3
        pub fn loadBlock(cq: *Self, options: LoadBlockOptions) void {
            const cmd: u64 =
                (@as(u64, 0xF3) << 56) |
                (@as(u64, options.upper_left_s) << 44) |
                (@as(u64, options.upper_left_t) << 32) |
                (@as(u64, options.tile) << 24) |
                (@as(u64, options.lower_right_s) << 12) |
                (@as(u64, options.dxt));
            cq.queue.push(cmd);
        }

        // 0xF4 — same bit layout as SetTileSize; coordinates are u10.2 (pixel * 4)
        pub fn loadTile(cq: *Self, options: SetTileSizeOptions) void {
            const cmd: u64 =
                (@as(u64, 0xF4) << 56) |
                (@as(u64, options.upper_left_s) << 44) |
                (@as(u64, options.upper_left_t) << 32) |
                (@as(u64, options.tile) << 24) |
                (@as(u64, options.lower_right_s) << 12) |
                (@as(u64, options.lower_right_t));
            cq.queue.push(cmd);
        }

        // 0xF5
        pub fn setTile(cq: *Self, options: SetTileOptions) void {
            const cmd: u64 =
                (@as(u64, 0xF5) << 56) |
                (@as(u64, @intFromEnum(options.color_format)) << 53) |
                (@as(u64, @intFromEnum(options.bit_depth)) << 51) |
                (@as(u64, options.line_length) << 41) |
                (@as(u64, lowBits(options.tmem_addr, 9)) << 32) |
                (@as(u64, options.tile_index) << 24) |
                (@as(u64, options.palette_index) << 20) |
                (@as(u64, @intFromBool(options.clamp_t)) << 19) |
                (@as(u64, @intFromBool(options.mirror_t)) << 18) |
                (@as(u64, options.mask_t) << 14) |
                (@as(u64, options.shift_t) << 10) |
                (@as(u64, @intFromBool(options.clamp_s)) << 9) |
                (@as(u64, @intFromBool(options.mirror_s)) << 8) |
                (@as(u64, options.mask_s) << 4) |
                (@as(u64, options.shift_s));
            cq.queue.push(cmd);
        }

        // 0xF6
        pub fn fillRect(cq: *Self, upper_left_x: u16, upper_left_y: u16, lower_right_x: u16, lower_right_y: u16) void {
            const cmd: u64 =
                (@as(u64, 0xF6) << 56) |
                (@as(u64, lowBits(lower_right_x, 12)) << 44) |
                (@as(u64, lowBits(lower_right_y, 12)) << 32) |
                (@as(u64, lowBits(upper_left_x, 12)) << 12) |
                (@as(u64, lowBits(upper_left_y, 12)));
            cq.queue.push(cmd);
        }

        // 0xF7
        pub fn setFillColor(cq: *Self, color: anytype) void {
            const bit_depth: BitDepth = @TypeOf(color).bit_depth;
            const packed_color: u64 = switch (bit_depth) {
                .@"32" => @as(u64, @as(u32, @bitCast(color))),
                .@"16" => blk: {
                    const c = @as(u64, @as(u16, @bitCast(color)));
                    break :blk c << 16 | c;
                },
                .@"8" => blk: {
                    const c: u64 = @bitCast(color);
                    break :blk c << 24 | c << 16 | c << 8 | c;
                },
                else => @compileError("Unsupported fill color type"),
            };
            cq.queue.push((@as(u64, 0xF7) << 56) | packed_color);
        }

        // 0xF9
        pub fn setBlendColor(cq: *Self, color: Rgba32) void {
            const cmd: u64 =
                (@as(u64, 0xF9) << 56) |
                (@as(u64, @as(u32, @bitCast(color))));
            cq.queue.push(cmd);
        }

        // 0xFA
        pub fn setPrimColor(cq: *Self, color: Rgba32) void {
            const cmd: u64 =
                (@as(u64, 0xFA) << 56) |
                (@as(u64, @as(u32, @bitCast(color))));
            cq.queue.push(cmd);
        }

        // 0xFC
        pub fn setCombiner(cq: *Self, mode: CombineMode) void {
            cq.queue.push(buildCombineCmd(mode));
        }

        // 0xFD
        pub fn setTextureImage(cq: *Self, format: ColorFormat, bit_depth: BitDepth, width: u32, addr: usize) void {
            cq.queue.push((@as(u64, 0xFD) << 56) |
                (@as(u64, @intFromEnum(format)) << 53) |
                (@as(u64, @intFromEnum(bit_depth)) << 51) |
                (@as(u64, lowBits(width - 1, 10)) << 32) |
                lowBits(addr, 24));
        }

        // 0xFF
        pub fn setColorFrame(cq: *Self, image: anytype) void {
            if (@intFromPtr(image.texel_data.ptr) & 63 != 0) {
                @panic("RDP color image must be 64-byte aligned");
            }
            cq.queue.push(buildImageCmd(0xFF, image));
        }
    };
}

pub const FixedCommandQueue = CommandQueue(FixedQueue);
pub const RspCommandQueue = CommandQueue(RspQueue);
pub const DirectCommandQueue = CommandQueue(DirectQueue);
pub const RspSubmittedCommandQueue = CommandQueue(RspSubmittedQueue);
pub const OverlayCommandQueue = CommandQueue(OverlayQueue);

fn packetWordCount(opcode: u8) usize {
    return switch (opcode & 0x3f) {
        0x24, 0x25 => 2,
        0x08 => 4,
        0x09 => 6,
        0x0a => 12,
        0x0b => 14,
        0x0c => 12,
        0x0d => 14,
        0x0e => 20,
        0x0f => 22,
        else => 1,
    };
}

fn overlayCommandIndex(opcode: u8) u8 {
    // SET_SCISSOR must update the resident scissor shadow. SET_OTHER_MODES
    // (slot 47 / opcode EF) re-emits that shadow, so routing ED through its
    // raw slot would append an all-zero, invalid RDP command afterward.
    if (opcode == 0xed) return 18;
    // Raw RDP packets use the direct command slots. The overlay's lower-numbered
    // stateful helpers have different argument ABIs and are only for callers
    // that deliberately construct those higher-level commands.
    return opcode & 0x3f;
}

test "overlay routes raw opcodes to direct command slots" {
    try std.testing.expectEqual(@as(u8, 18), overlayCommandIndex(0xed));
    try std.testing.expectEqual(@as(u8, 55), overlayCommandIndex(0xf7));
    try std.testing.expectEqual(@as(u8, 63), overlayCommandIndex(0xff));
    try std.testing.expectEqual(@as(u8, 39), overlayCommandIndex(0xe7));
}

test "overlay packet sizing covers rectangles and every triangle variant" {
    try std.testing.expectEqual(@as(usize, 2), packetWordCount(0xe4));
    try std.testing.expectEqual(@as(usize, 2), packetWordCount(0xe5));
    const triangle_words = [_]usize{ 4, 6, 12, 14, 12, 14, 20, 22 };
    for (triangle_words, 0..) |expected, index| {
        try std.testing.expectEqual(expected, packetWordCount(@intCast(0xc8 + index)));
        try std.testing.expectEqual(expected, packetWordCount(@intCast(0x08 + index)));
    }
    try std.testing.expectEqual(@as(usize, 1), packetWordCount(0xe7));
}

fn buildTextureRectangleWords(opcode: u8, options: TextureRectangleOptions) [2]u64 {
    return .{
        (@as(u64, opcode) << 56) |
            (@as(u64, options.lrx) << 44) |
            (@as(u64, options.lry) << 32) |
            (@as(u64, options.tile) << 24) |
            (@as(u64, options.ulx) << 12) |
            (@as(u64, options.uly)),
        (@as(u64, @as(u16, @bitCast(options.s))) << 48) |
            (@as(u64, @as(u16, @bitCast(options.t))) << 32) |
            (@as(u64, @as(u16, @bitCast(options.dsdx))) << 16) |
            (@as(u64, @as(u16, @bitCast(options.dtdy)))),
    };
}

fn buildImageCmd(opcode: u8, image: anytype) u64 {
    const T = @TypeOf(image);
    return (@as(u64, opcode) << 56) |
        (@as(u64, @intFromEnum(T.format)) << 53) |
        (@as(u64, @intFromEnum(T.bit_depth)) << 51) |
        (@as(u64, lowBits(image.width - 1, 10)) << 32) |
        (@as(u64, lowBits(@intFromPtr(image.texel_data.ptr), 24)));
}

fn buildCombineCmd(mode: CombineMode) u64 {
    const c1 = mode.cycle0;
    const c2 = mode.cycle1;
    return (@as(u64, 0xFC) << 56) |
        (@as(u64, @intFromEnum(c1.rgb_a)) << 52) |
        (@as(u64, @intFromEnum(c1.rgb_c)) << 47) |
        (@as(u64, @intFromEnum(c1.alpha_a)) << 44) |
        (@as(u64, @intFromEnum(c1.alpha_c)) << 41) |
        (@as(u64, @intFromEnum(c2.rgb_a)) << 37) |
        (@as(u64, @intFromEnum(c2.rgb_c)) << 32) |
        (@as(u64, @intFromEnum(c1.rgb_b)) << 28) |
        (@as(u64, @intFromEnum(c2.rgb_b)) << 24) |
        (@as(u64, @intFromEnum(c2.alpha_a)) << 21) |
        (@as(u64, @intFromEnum(c2.alpha_c)) << 18) |
        (@as(u64, @intFromEnum(c1.rgb_d)) << 15) |
        (@as(u64, @intFromEnum(c1.alpha_b)) << 12) |
        (@as(u64, @intFromEnum(c1.alpha_d)) << 9) |
        (@as(u64, @intFromEnum(c2.rgb_d)) << 6) |
        (@as(u64, @intFromEnum(c2.alpha_b)) << 3) |
        (@as(u64, @intFromEnum(c2.alpha_d)));
}

fn lowBits(value: anytype, bitCount: u6) u64 {
    const mask = (@as(u64, 1) << bitCount) - 1;
    return @as(u64, @intCast(value)) & mask;
}
