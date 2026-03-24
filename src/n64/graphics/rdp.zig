const io = @import("../io/rdp.zig");
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
        pub fn setOtherModes(cq: *Self, settings: ModeSettings) void {
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

        // 0xFF
        pub fn setColorFrame(cq: *Self, image: anytype) void {
            const T = @TypeOf(image);
            const width: u64 = (image.width - 1) & 0x3FF;
            const addr: u64 = @intFromPtr(image.pixel_data.ptr) & 0xFFFFFF;
            var size: u64 = 0;
            const format: u64 = 0;
            switch(T) {
                Img16 => {
                    size = 2;
                },
                Img32 => {
                    size = 3;
                },
                else => @compileError("Type not supported\n")
            }
            const cmd = 0xFF << 56 | format << 53 | size << 51 | width << 32 | addr;
            cq.queue.push(cmd);
        }
    };
}

pub const FixedCommandQueue = CommandQueue(FixedQueue);

const ModeSettings = packed struct(u64) {
    // --- low bits (0 → 15) ---
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

    // --- blender ---
    bl_m2b_1: u2 = 0,
    bl_m2b_0: u2 = 0,
    bl_m2a_1: u2 = 0,
    bl_m2a_0: u2 = 0,
    bl_m1b_1: u2 = 0,
    bl_m1b_0: u2 = 0,
    bl_m1a_1: u2 = 0,
    bl_m1a_0: u2 = 0,

    // --- mid padding ---
    _pad1: u4 = 0,

    // --- upper pipeline controls ---
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
    command: u8 = 0xEF,
};

const CycleType = enum(u2) {
    OneCycle = 0,
    TwoCycle = 1,
    Copy      = 2,
    Fill      = 3,
};
