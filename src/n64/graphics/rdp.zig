const io = @import("../interfaces/rdp.zig");
const Img16 = @import("../graphics.zig").Img16;
const Img32 = @import("../graphics.zig").Img32;
const Rgba5551 = @import("../graphics.zig").Rgba5551;
const Rgba32 = @import("../graphics.zig").Rgba32;

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
            const x0: u64 = upper_left_x & 0xFFF;
            const y0: u64 = upper_left_y & 0xFFF;
            const x1: u64 = lower_right_x & 0xFFF;
            const y1: u64 = lower_right_y & 0xFFF;

            const cmd = 0xED << 56 | x0 << 44 | y0 << 32 | x1 << 12 | y1;
            cq.queue.push(cmd);
        }
        // 0xEF
        pub fn setOtherModes(cq: *Self, settings: CmdModeSettings) void {
            cq.queue.push(@bitCast(settings));
        }

        // 0xF6
        pub fn fillRect(cq: *Self, upper_left_x: u16, upper_left_y: u16, lower_right_x: u16, lower_right_y: u16) void {
            const x0: u64 = upper_left_x & 0xFFF;
            const y0: u64 = upper_left_y & 0xFFF;
            const x1: u64 = lower_right_x & 0xFFF;
            const y1: u64 = lower_right_y & 0xFFF;

            const cmd = 0xF6 << 56 | x1 << 44 | y1 << 32 | x0 << 12 | y0;
            cq.queue.push(cmd);
        }

        // 0xF7
        pub fn setFillColor(cq: *Self, color: anytype) void {
            const T = @TypeOf(color);
            var c: u64 =@as(u16, @bitCast(color));
            switch(T) {
                Rgba5551 => c |= c << 16,
                Rgba32 => {},
                else => @compileError("Unsupported Type\n")
            }
            const cmd = 0xF7 << 56 | c;
            cq.queue.push(cmd);
        }

        // 0xF3
        pub fn loadBlock(cq: *Self, upper_left_s: u12, upper_left_t: u12, 
            lower_right_s: u12, tile_index: u3, dxt: u12) void {
            const Cmd = packed struct(u64) {
                dxt: u12,
                lower_right_s: u12,
                tile_index: u3,
                _pad0: u5 = 0,
                upper_left_t: u12,
                upper_left_s: u12,
                _commnad: u8 = 0xF3,
            };
            cq.queue.push(@bitCast(Cmd{
                .dxt = dxt,
                .lower_right_s = lower_right_s,
                .tile_index = tile_index,
                .upper_left_t = upper_left_t,
                .upper_left_s = upper_left_s,
            }));
        }

        // 0xF5
        pub fn setTile(cq: *Self, format: Format, texel_size: TexelSize, line_len: u9, 
            tmem_addr: u9, tileIndex: u3, paletteIndex: u4, 
            clamp_t: bool, mirror_t: bool, mask_t: u4, shift_t: u4,
            clamp_s: bool, mirror_s: bool, mask_s: u4, shift_s: u4) void {
            
            const Cmd = packed struct(u64) {
                shift_s: u4,
                mask_s: u4,
                mirror_s: bool,
                clamp_s: bool,
                shift_t: u4,
                mask_t: u4,
                mirror_t: bool,
                clamp_t: bool,
                paletteIndex: u4,
                tileIndex: u3,
                _pad0: u5 = 0,
                tmem_addr: u9,
                line_len: u9,
                _pad1: u1 = 0,
                texel_size: TexelSize,
                format: Format,
                command: u8 = 0xF5
            };
            cq.queue.push(@bitCast(Cmd{
                .shift_s = shift_s,
                .mask_s =  mask_s,
                .mirror_s = mirror_s,
                .clamp_s = clamp_s,
                .shift_t = shift_t,
                .mask_t = mask_t,
                .mirror_t = mirror_t,
                .clamp_t = clamp_t,
                .paletteIndex = paletteIndex,
                .tileIndex = tileIndex,
                .tmem_addr = tmem_addr,
                .line_len = line_len,
                .texel_size = texel_size,
                .format = format,
            }));
        }

        // 0xFD
        pub fn setTextureImage(cq: * Self, image: anytype) void {
            const width: u64 = (image.width - 1) & 0x3FF;
            const addr: u64 = @intFromPtr(image.pixel_data.ptr) & 0xFFFFFF;
            const size: u64 = getImageBitDepth(image);
            const format: u64 = getImageFormat(image);
            const cmd = 0xFD << 56 | format << 53 | size << 51 | width << 32 | addr;
            cq.queue.push(cmd);
        }

        // 0xFF
        pub fn setColorFrame(cq: *Self, image: anytype) void {
            const width: u64 = (image.width - 1) & 0x3FF;
            const addr: u64 = @intFromPtr(image.pixel_data.ptr) & 0xFFFFFF;
            const size: u64 = getImageBitDepth(image);
            const format: u64 = getImageFormat(image);
            const cmd = 0xFF << 56 | format << 53 | size << 51 | width << 32 | addr;
            cq.queue.push(cmd);
        }

        fn getImageBitDepth(image: anytype) u64 {
            const T = @TypeOf(image);
            switch(T) {
                Img16 => {
                    return 2;
                },
                Img32 => {
                    return 3;
                },
                else => @compileError("Type not supported\n")
            }
        }

        fn getImageFormat(image: anytype) u64 {
            const T = @TypeOf(image);
            switch (T) {
                Img16, Img32 => {
                    return 0;
                },
                else => @compileError("Type not supported\n")
            }
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
    cycle_type: CycleType = .OneCycle,

    _pad2: u1 = 0,

    // --- top bits ---
    atomic_prim: bool = false,
    _command: u8 = 0xEF,
};

const CycleType = enum(u2) {
    OneCycle = 0,
    TwoCycle = 1,
    Copy      = 2,
    Fill      = 3,
};

const Format = enum(u3) {
    rgba,
    yuv,
    color_indexed,
    intensity_alpha,
    intnsity,
};

const TexelSize = enum(u2) {
    @"4",
    @"8",
    @"16",
    @"32"
};
