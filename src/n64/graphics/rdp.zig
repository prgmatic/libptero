const io = @import("../interfaces/rdp.zig");
const Img16 = @import("../graphics.zig").Img16;
const Img32 = @import("../graphics.zig").Img32;
const Rgba5551 = @import("../graphics.zig").Rgba5551;
const Rgba32 = @import("../graphics.zig").Rgba32;
const ColorFormat = @import("color.zig").Format;
const BitDepth = @import("color.zig").BitDepth;

pub const FixedQueue = struct {
    buffer: []u64,
    index: usize = 0,

    pub fn push(self: *FixedQueue, value: u64) void {
        self.buffer[self.index] = value;
        self.index += 1;
    }

    pub fn execute(self: *FixedQueue) void {
        const addr:u32 = @intFromPtr(self.buffer.ptr) & 0xFFFFFF;
        const s: *volatile u32 = @ptrCast(io.status);
        s.* = 1;
        io.dma_start_addr.* = addr;
        io.dma_end_addr.* = addr + @sizeOf(u64) * self.index;
    }

    pub fn clear(self: *FixedQueue) void {
        self.index = 0;
    }
};


pub fn CommandQueue(comptime QueueType: type) type {
    if(!@hasDecl(QueueType, "push"))
        @compileError("Type must implement push(u64)");
    if(!@hasDecl(QueueType, "execute"))
        @compileError("Type must implement execute()");
    if(!@hasDecl(QueueType, "clear"))
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

        const TextureRectangleOptions = struct {
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

        // 0xE4
        pub fn textureRectangle(cq: *Self, options: TextureRectangleOptions) void {
            const word0: u64 =
                (@as(u64, 0xE4) << 56) |
                (@as(u64, options.lrx) << 44) |
                (@as(u64, options.lry) << 32) |
                (@as(u64, options.tile) << 24) |
                (@as(u64, options.ulx) << 12) |
                (@as(u64, options.uly));
            const word1: u64 =
                (@as(u64, @as(u16, @bitCast(options.s))) << 48) |
                (@as(u64, @as(u16, @bitCast(options.t))) << 32) |
                (@as(u64, @as(u16, @bitCast(options.dsdx))) << 16) |
                (@as(u64, @as(u16, @bitCast(options.dtdy))));
            cq.queue.push(word0);
            cq.queue.push(word1);
        }

        // 0xE5
        pub fn textureRectangleFlip(cq: *Self, options: TextureRectangleOptions) void {
            const word0: u64 =
                (@as(u64, 0xE5) << 56) |
                (@as(u64, options.lrx) << 44) |
                (@as(u64, options.lry) << 32) |
                (@as(u64, options.tile) << 24) |
                (@as(u64, options.ulx) << 12) |
                (@as(u64, options.uly));
            const word1: u64 =
                (@as(u64, @as(u16, @bitCast(options.s))) << 48) |
                (@as(u64, @as(u16, @bitCast(options.t))) << 32) |
                (@as(u64, @as(u16, @bitCast(options.dsdx))) << 16) |
                (@as(u64, @as(u16, @bitCast(options.dtdy))));
            cq.queue.push(word0);
            cq.queue.push(word1);
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

        // 0xEF
        pub fn setOtherModes(cq: *Self, settings: CmdModeSettings) void {
            cq.queue.push(@bitCast(settings));
        }

        const LoadBlockOptions = struct {
            upper_left_s: u12 = 0,
            upper_left_t: u12 = 0,
            tile: u3 = 0,
            lower_right_s: u12,
            dxt: u12,
        };

        const SetTileSizeOptions = struct {
            upper_left_s: u12 = 0,
            upper_left_t: u12 = 0,
            tile: u3 = 0,
            lower_right_s: u12,
            lower_right_t: u12,
        };

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

        const SetTileOptions = struct {
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

            const cmd: u64 = (@as(u64, 0xF7) << 56) | packed_color;
            cq.queue.push(cmd);
        }

        // 0xFD
        pub fn setTextureImage(cq: *Self, image: anytype) void {
            const cmd: u64 =
                (@as(u64, 0xFD) << 56) |
                (@as(u64, @intFromEnum(image.getFormat())) << 53) |
                (@as(u64, @intFromEnum(image.getBitDepth())) << 51) |
                (@as(u64, lowBits(image.width - 1, 10)) << 32) |
                (@as(u64, lowBits(@intFromPtr(image.texel_data.ptr), 24)));

            cq.queue.push(cmd);
        }

        // 0xFF
        pub fn setColorFrame(cq: *Self, image: anytype) void {
            const cmd: u64 =
                (@as(u64, 0xFF) << 56) |
                (@as(u64, @intFromEnum(image.getFormat())) << 53) |
                (@as(u64, @intFromEnum(image.getBitDepth())) << 51) |
                (@as(u64, lowBits(image.width - 1, 10)) << 32) |
                (@as(u64, lowBits(@intFromPtr(image.texel_data.ptr), 24)));

            cq.queue.push(cmd);
        }
    };
}

pub const FixedCommandQueue = CommandQueue(FixedQueue);

const CmdModeSettings = packed struct(u64) {
    alpha_compare_en: bool = false,
    dither_alpha_en: bool = false,
    z_source_sel: bool = false,
    antialias_en: bool = false,
    z_compare_en: bool = false,
    z_update_en: bool = false,
    image_read_en: bool = false,
    color_on_cvg: bool = false,
    cvg_dest: u2 = 0,
    z_mode: u2 = 0,
    cvg_x_alpha: bool = false,
    alpha_cvg_select: bool = false,
    force_blend: bool = false,
    _pad0: u1 = 0,

    bl_m2b_1: u2 = 0,
    bl_m2b_0: u2 = 0,
    bl_m2a_1: u2 = 0,
    bl_m2a_0: u2 = 0,
    bl_m1b_1: u2 = 0,
    bl_m1b_0: u2 = 0,
    bl_m1a_1: u2 = 0,
    bl_m1a_0: u2 = 0,

    _pad1: u4 = 0,

    alpha_dither_sel: u2 = 0,
    rgb_dither_sel: u2 = 0,
    key_en: bool = false,
    convert_one: bool = false,
    bi_lerp_1: bool = false,
    bi_lerp_0: bool = false,
    mid_texel: bool = false,
    sample_type: bool = false,
    tlut_type: bool = false,
    tlut_en: bool = false,
    tex_lod_en: bool = false,
    sharpen_tex_en: bool = false,
    detail_tex_en: bool = false,
    persp_tex_en: bool = false,
    cycle_type: CycleType = .one_cycle,

    _pad2: u1 = 0,

    // --- top bits ---
    atomic_prim: bool = false,
    _command: u8 = 0xEF,
};

const CycleType = enum(u2) {
    one_cycle = 0,
    two_cycle = 1,
    copy      = 2,
    fill      = 3,
};




fn lowBits(value: anytype, bitCount: u6) u64 {
    const mask = (@as(u64, 1) << bitCount) - 1;
    return @as(u64, @intCast(value)) & mask;
}
