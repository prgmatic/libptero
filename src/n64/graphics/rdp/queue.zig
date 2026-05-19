const io = @import("io.zig");
const ColorFormat = @import("../color.zig").Format;
const BitDepth = @import("../color.zig").BitDepth;
const cc = @import("combiner.zig");
const bm = @import("blend.zig");
const m = @import("modes.zig");

const CycleConfig = cc.CycleConfig;
const CombineMode = cc.CombineMode;
const BlendMode = bm.BlendMode;
const CycleType = m.CycleType;
const OtherModes  = m.OtherModes;
const Rgba32 = @import("../color.zig").Rgba32;

pub const FixedQueue = struct {
    buffer: []u64,
    index: usize = 0,

    pub fn push(self: *FixedQueue, value: u64) void {
        self.buffer[self.index] = value;
        self.index += 1;
    }

    pub fn execute(self: *FixedQueue) void {
        const addr: u32 = @intFromPtr(self.buffer.ptr) & 0xFFFFFF;
        const s: *volatile u32 = @ptrCast(io.status);
        s.* = 1;
        io.dma_start_addr.* = addr;
        io.dma_end_addr.* = addr + @sizeOf(u64) * self.index;
    }

    pub fn clear(self: *FixedQueue) void {
        self.index = 0;
    }
};

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
        mode: OtherModes = .{},
        mode_dirty: bool = true,
        combine_mode: CombineMode = .primitive,
        combine_dirty: bool = false,

        pub fn init(queue: QueueType) Self {
            return .{ .queue = queue };
        }

        pub fn clear(cq: *Self) void {
            cq.queue.clear();
        }

        pub fn execute(cq: *Self) void {
            cq.queue.execute();
        }

        fn flushMode(cq: *Self) void {
            if (!cq.mode_dirty and !cq.combine_dirty) return;
            cq.queue.push(@as(u64, 0xE7) << 56);
            if (cq.mode_dirty) {
                cq.queue.push(@bitCast(cq.mode));
                cq.mode_dirty = false;
            }
            if (cq.combine_dirty) {
                cq.queue.push(buildCombineCmd(cq.combine_mode));
                cq.combine_dirty = false;
            }
        }

        pub fn setCycleType(cq: *Self, cycle_type: CycleType) void {
            cq.mode.cycle_type = cycle_type;
            cq.mode_dirty = true;
        }

        pub fn setBlendMode(cq: *Self, blend: BlendMode) void {
            cq.mode.force_blend = blend.force_blend;
            cq.mode.image_read_en = blend.image_read_en;
            cq.mode.blend_p0 = blend.pass1.p;
            cq.mode.blend_a0 = blend.pass1.a;
            cq.mode.blend_m0 = blend.pass1.m;
            cq.mode.blend_b0 = blend.pass1.b;
            cq.mode.blend_p1 = blend.pass2.p;
            cq.mode.blend_a1 = blend.pass2.a;
            cq.mode.blend_m1 = blend.pass2.m;
            cq.mode.blend_b1 = blend.pass2.b;
            cq.mode_dirty = true;
        }

        pub fn setCombineMode(cq: *Self, mode: CombineMode) void {
            cq.combine_mode = mode;
            cq.combine_dirty = true;
        }

        // 0xE4
        pub fn textureRectangle(cq: *Self, options: TextureRectangleOptions) void {
            cq.flushMode();
            const words = buildTextureRectangleWords(0xE4, options);
            cq.queue.push(words[0]);
            cq.queue.push(words[1]);
        }

        // 0xE5
        pub fn textureRectangleFlip(cq: *Self, options: TextureRectangleOptions) void {
            cq.flushMode();
            const words = buildTextureRectangleWords(0xE5, options);
            cq.queue.push(words[0]);
            cq.queue.push(words[1]);
        }

        // 0xE6
        pub fn loadSync(cq: *Self) void {
            cq.queue.push(0xE6 << 56);
        }

        // 0xE7
        pub fn pipeSync(cq: *Self) void {
            cq.queue.push(0xE7 << 56);
        }

        // 0xE8
        pub fn tileSync(cq: *Self) void {
            cq.queue.push(0xE8 << 56);
        }

        // 0xE9
        pub fn fullSync(cq: *Self) void {
            cq.queue.push(0xE9 << 56);
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

        // 0xEF — escape hatch; prefer setCycleType/setBlendMode for automatic pipeSync
        pub fn setOtherModes(cq: *Self, settings: OtherModes) void {
            cq.mode = settings;
            cq.mode_dirty = false;
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
            cq.flushMode();
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

        // 0xFD
        pub fn setTextureImage(cq: *Self, image: anytype) void {
            cq.queue.push(buildImageCmd(0xFD, image));
        }

        // 0xFF
        pub fn setColorFrame(cq: *Self, image: anytype) void {
            cq.queue.push(buildImageCmd(0xFF, image));
        }
    };
}

pub const FixedCommandQueue = CommandQueue(FixedQueue);

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
        (@as(u64, @intFromEnum(c1.alpha_d)) << 9)  |
        (@as(u64, @intFromEnum(c2.rgb_d)) << 6)  |
        (@as(u64, @intFromEnum(c2.alpha_b)) << 3)  |
        (@as(u64, @intFromEnum(c2.alpha_d)));
}

fn lowBits(value: anytype, bitCount: u6) u64 {
    const mask = (@as(u64, 1) << bitCount) - 1;
    return @as(u64, @intCast(value)) & mask;
}
