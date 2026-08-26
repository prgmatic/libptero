pub const Sampler = struct {
    clamp_s: bool = false,
    clamp_t: bool = false,
    mirror_s: bool = false,
    mirror_t: bool = false,
    mask_s: u4 = 0,
    mask_t: u4 = 0,

    pub fn eql(a: Sampler, b: Sampler) bool {
        return a.clamp_s == b.clamp_s and a.clamp_t == b.clamp_t and
            a.mirror_s == b.mirror_s and a.mirror_t == b.mirror_t and
            a.mask_s == b.mask_s and a.mask_t == b.mask_t;
    }
};

pub inline fn loadTexture(cmd_queue: anytype, image: anytype, tile: u3, tmem_addr: u9, sampler: Sampler) void {
    const T = @TypeOf(image);
    const width: u32 = image.width;
    const height: u32 = image.height;

    const load_tile: u3 = tile +% 1;

    const bpp: u32 = switch (T.bit_depth) {
        .@"4" => 4,
        .@"8" => 8,
        .@"16" => 16,
        .@"32" => 32,
    };

    const words_per_row: u32 = (width * bpp + 63) / 64;

    // RGBA32 is stored across two TMEM banks, so effective words-per-row per bank is halved.
    const render_line_len: u9 = switch (T.bit_depth) {
        .@"32" => @intCast((width * 16 + 63) / 64),
        else => @intCast(words_per_row),
    };

    // dxt: ceil(2048 / words_per_row), 1.11 fixed point.
    const dxt: u12 = @intCast((2048 + words_per_row - 1) / words_per_row);

    // Sub-byte formats fake a wider RGBA16 image so LoadBlock sees at most 2048 "texels".
    const ColorFormat = @import("../color.zig").Format;
    const BitDepth = @import("../color.zig").BitDepth;
    const load_format: ColorFormat = switch (T.bit_depth) {
        .@"4", .@"8" => .rgba,
        else => T.format,
    };
    const load_bit_depth: BitDepth = switch (T.bit_depth) {
        .@"4", .@"8" => .@"16",
        else => T.bit_depth,
    };
    const load_width: u32 = switch (T.bit_depth) {
        .@"4" => (width + 3) / 4,
        .@"8" => width / 2,
        else => width,
    };

    cmd_queue.setTextureImage(load_format, load_bit_depth, load_width, @intFromPtr(image.texel_data.ptr));
    cmd_queue.setTile(.{
        .color_format = load_format,
        .bit_depth = load_bit_depth,
        .line_length = 0,
        .tmem_addr = tmem_addr,
        .tile_index = load_tile,
    });

    cmd_queue.loadSync();

    // LoadBlock texel count adjusted for sub-byte packing.
    const num_texels: u32 = switch (T.bit_depth) {
        .@"4" => (width * height + 3) / 4,
        .@"8" => (width * height + 1) / 2,
        else => width * height,
    };
    cmd_queue.loadBlock(.{
        .tile = load_tile,
        .lower_right_s = @intCast(num_texels - 1),
        .dxt = dxt,
    });

    // Rendering tile: real format and pitch, set after the load completes.
    cmd_queue.setTile(.{
        .color_format = T.format,
        .bit_depth = T.bit_depth,
        .line_length = render_line_len,
        .tmem_addr = tmem_addr,
        .tile_index = tile,
        .clamp_s = sampler.clamp_s,
        .clamp_t = sampler.clamp_t,
        .mirror_s = sampler.mirror_s,
        .mirror_t = sampler.mirror_t,
        .mask_s = sampler.mask_s,
        .mask_t = sampler.mask_t,
    });

    cmd_queue.loadSync();

    cmd_queue.setTileSize(.{
        .tile = tile,
        .lower_right_s = @intCast((width - 1) * 4),
        .lower_right_t = @intCast((height - 1) * 4),
    });
}

pub inline fn drawNonRotatedSprite(cmd_queue: anytype, tile: u3, x: f32, y: f32, s0: u8, t0: u8, width: f32, height: f32, flip_x: bool, flip_y: bool, scale_x: f32, scale_y: f32, cx: f32, cy: f32) void {
    // Screen rectangle in pixel*4 units (RDP 10.2 fixed-point): pivot maps to (x, y).
    var ulx_raw: i32 = @intFromFloat(@round((x - scale_x * cx) * 4));
    var uly_raw: i32 = @intFromFloat(@round((y - scale_y * cy) * 4));
    const lrx_raw: i32 = @intFromFloat(@round((x + scale_x * (width - cx)) * 4));
    const lry_raw: i32 = @intFromFloat(@round((y + scale_y * (height - cy)) * 4));

    // dsdx/dtdy in S5.10 format: 1024 = 1.0 texel/pixel; flip negates direction.
    const dsdx: i16 = @intFromFloat(if (flip_x) -(1024.0 / scale_x) else (1024.0 / scale_x));
    const dtdy: i16 = @intFromFloat(if (flip_y) -(1024.0 / scale_y) else (1024.0 / scale_y));

    // Texture S and T start in S10.5 format (texel * 32).
    var s: i16 = if (flip_x)
        @intCast((@as(i32, s0) + @as(i32, @intFromFloat(width)) - 1) * 32)
    else
        @intCast(@as(i32, s0) * 32);
    var t: i16 = if (flip_y)
        @intCast((@as(i32, t0) + @as(i32, @intFromFloat(height)) - 1) * 32)
    else
        @intCast(@as(i32, t0) * 32);

    // Clip left/top edges: adjust texture start for any off-screen columns/rows.
    // s_adjust = clipped_pixel4_count * dsdx / 128
    if (ulx_raw < 0) {
        s +%= @intCast(@divTrunc(-ulx_raw * @as(i32, dsdx), 128));
        ulx_raw = 0;
    }
    if (uly_raw < 0) {
        t +%= @intCast(@divTrunc(-uly_raw * @as(i32, dtdy), 128));
        uly_raw = 0;
    }

    if (lrx_raw <= ulx_raw or lry_raw <= uly_raw) return;

    cmd_queue.textureRectangle(.{
        .tile = tile,
        .ulx = @intCast(ulx_raw),
        .uly = @intCast(uly_raw),
        .lrx = @intCast(@min(lrx_raw, 0xFFF)),
        .lry = @intCast(@min(lry_raw, 0xFFF)),
        .s = s,
        .t = t,
        .dsdx = dsdx,
        .dtdy = dtdy,
    });
}

pub const SpriteDrawOptions = struct {
    tile_index: u3 = 0,
    s0: u8 = 0,
    t0: u8 = 0,
    width: u8 = 0, // 0 = full texture width
    height: u8 = 0, // 0 = full texture height
    flip_x: bool = false,
    flip_y: bool = false,
    pivot: Pivot = .top_left,
    scale_x: f32 = 1.0, // negative applies additional flip
    scale_y: f32 = 1.0,
    rotation: f32 = 0.0, // not yet implemented
};

pub const Pivot = union(enum) {
    top_left,
    top_middle,
    top_right,
    middle_left,
    center,
    middle_right,
    bottom_left,
    bottom_middle,
    bottom_right,

    custom: struct {
        x: u8,
        y: u8,
    },
};
