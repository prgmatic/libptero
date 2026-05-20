const q = @import("queue.zig");
const blender = @import("blender.zig");
const modes = @import("modes.zig");
const cc = @import("combiner.zig");
const sprite_mod = @import("sprite.zig");

pub const SpriteDrawOptions = sprite_mod.SpriteDrawOptions;
pub const Pivot = sprite_mod.Pivot;

const CommandQueue = q.CommandQueue;
const FixedQueue = q.FixedQueue;
const TextureRectangleOptions = q.TextureRectangleOptions;
const LoadTextureOptions = q.LoadTextureOptions;

const CombineMode = cc.CombineMode;
const BlendMode = blender.BlendMode;
const CycleType = modes.CycleType;
const OtherModes = modes.OtherModes;
const Rgba32 = @import("../color.zig").Rgba32;

pub const FixedRenderQueue = RenderQueue(FixedQueue);


// State-tracking layer over CommandQueue. Manages OtherModes/combiner dirty state,
// texture caching in TMEM, and provides high-level draw calls.
// Access the underlying CommandQueue via the `cmd_queue` field for direct control.
pub fn RenderQueue(comptime QueueType: type) type {
    return struct {
        const Self = @This();
        const TCmdQueue = CommandQueue(QueueType);

        cmd_queue: TCmdQueue,
        mode: OtherModes = .{},
        combine_mode: CombineMode = .primitive,

        mode_dirty: bool = true,
        combine_dirty: bool = false,
        fb_width: u16 = 0,
        fb_height: u16 = 0,

        tex_cache: [8]TexCacheEntry = [_]TexCacheEntry{.{}} ** 8,
        tex_cache_len: usize = 0,
        tmem_next: usize = 0,  // next free TMEM word offset (8-byte words, max 512)
        next_tile: u3 = 0,     // next render tile; load tile = next_tile +% 1

        pub fn init(queue: QueueType) Self {
            return .{ .cmd_queue = TCmdQueue.init(queue) };
        }

        pub fn clear(rq: *Self) void {
            rq.cmd_queue.clear();
        }

        pub fn execute(rq: *Self) void {
            rq.cmd_queue.execute();
        }

        pub fn fullSync(rq: *Self) void {
            rq.cmd_queue.fullSync();
        }

        pub fn setPrimDepth(rq: *Self, z: u16, dz: u16) void {
            rq.cmd_queue.setPrimDepth(z, dz);
        }

        fn flushModes(rq: *Self) void {
            if (!rq.mode_dirty and !rq.combine_dirty) return;
            rq.cmd_queue.pipeSync();
            if (rq.mode_dirty) {
                rq.cmd_queue.setOtherModes(rq.mode);
                rq.mode_dirty = false;
            }
            if (rq.combine_dirty) {
                rq.cmd_queue.setCombiner(rq.combine_mode);
                rq.combine_dirty = false;
            }
        }

        pub fn setCycleType(rq: *Self, cycle_type: CycleType) void {
            rq.mode.cycle_type = cycle_type;
            rq.mode_dirty = true;
        }

        pub fn setBlendMode(rq: *Self, blend: BlendMode) void {
            rq.mode.force_blend = blend.force_blend;
            rq.mode.image_read_en = blend.image_read_en;
            rq.mode.blend_p0 = blend.pass1.p;
            rq.mode.blend_a0 = blend.pass1.a;
            rq.mode.blend_m0 = blend.pass1.m;
            rq.mode.blend_b0 = blend.pass1.b;
            rq.mode.blend_p1 = blend.pass2.p;
            rq.mode.blend_a1 = blend.pass2.a;
            rq.mode.blend_m1 = blend.pass2.m;
            rq.mode.blend_b1 = blend.pass2.b;
            rq.mode_dirty = true;
        }

        pub fn setCombineMode(rq: *Self, mode: CombineMode) void {
            rq.combine_mode = mode;
            rq.combine_dirty = true;
        }

        pub fn setFrameBuffer(rq: *Self, image: anytype) void {
            rq.fb_width = @intCast(image.width);
            rq.fb_height = @intCast(image.height);
            rq.cmd_queue.setColorFrame(image);
        }


        pub fn setPrimColor(rq: *Self, color: Rgba32) void {
            rq.cmd_queue.setPrimColor(color);
        }


        // Clears the entire framebuffer to `color`. Requires setColorFrame() first.
        // Emits a standalone fill-mode OtherModes without touching rq.mode, then marks
        // mode_dirty so the next texture draw re-emits the full texture pipeline state.
        pub fn clearScreen(rq: *Self, color: anytype) void {
            rq.cmd_queue.pipeSync();
            rq.cmd_queue.setOtherModes(.{ .cycle_type = .fill });
            rq.cmd_queue.setFillColor(color);
            rq.cmd_queue.setScissor(0, 0, (rq.fb_width - 1) * 4, (rq.fb_height - 1) * 4);
            rq.cmd_queue.fillRect(0, 0, (rq.fb_width - 1) * 4, (rq.fb_height - 1) * 4);
            rq.mode_dirty = true;
        }

        // Fills a pixel-coordinate rectangle (upper-left pixel inclusive, w/h in pixels).
        // Same bypass as clearScreen — fill mode is a separate hardware pipeline.
        pub fn drawRect(rq: *Self, x: u16, y: u16, w: u16, h: u16, color: anytype) void {
            rq.cmd_queue.pipeSync();
            rq.cmd_queue.setOtherModes(.{ .cycle_type = .fill });
            rq.cmd_queue.setFillColor(color);
            rq.cmd_queue.fillRect(
                @truncate(@as(u32, x) * 4),
                @truncate(@as(u32, y) * 4),
                @truncate((@as(u32, x) + w - 1) * 4),
                @truncate((@as(u32, y) + h - 1) * 4),
            );
            rq.mode_dirty = true;
        }

        fn textureRectangle(rq: *Self, options: TextureRectangleOptions) void {
            rq.flushModes();
            rq.cmd_queue.textureRectangle(options);
        }

        fn textureRectangleFlip(rq: *Self, options: TextureRectangleOptions) void {
            rq.flushModes();
            rq.cmd_queue.textureRectangleFlip(options);
        }

        // Explicit texture load into TMEM (bypasses cache).
        pub fn loadTexture(rq: *Self, image: anytype, opts: LoadTextureOptions) void {
            const T = @TypeOf(image);
            const width: u32 = image.width;
            const height: u32 = image.height;

            const load_tile: u3 = opts.tile +% 1;

            const bpp: u32 = switch (T.bit_depth) {
                .@"4"  => 4,
                .@"8"  => 8,
                .@"16" => 16,
                .@"32" => 32,
            };

            const words_per_row: u32 = (width * bpp + 63) / 64;

            // RGBA32 is stored across two TMEM banks, so effective words-per-row per bank is halved.
            const render_line_len: u9 = switch (T.bit_depth) {
                .@"32" => @intCast((width * 16 + 63) / 64),
                else   => @intCast(words_per_row),
            };

            // dxt: ceil(2048 / words_per_row), 1.11 fixed point.
            const dxt: u12 = @intCast((2048 + words_per_row - 1) / words_per_row);

            // Sub-byte formats fake a wider RGBA16 image so LoadBlock sees at most 2048 "texels".
            const ColorFormat = @import("../color.zig").Format;
            const BitDepth = @import("../color.zig").BitDepth;
            const load_format: ColorFormat = switch (T.bit_depth) {
                .@"4", .@"8" => .rgba,
                else          => T.format,
            };
            const load_bit_depth: BitDepth = switch (T.bit_depth) {
                .@"4", .@"8" => .@"16",
                else          => T.bit_depth,
            };
            const load_width: u32 = switch (T.bit_depth) {
                .@"4" => (width + 3) / 4,
                .@"8" => width / 2,
                else  => width,
            };

            rq.cmd_queue.setTextureImage(load_format, load_bit_depth, load_width, @intFromPtr(image.texel_data.ptr));
            rq.cmd_queue.setTile(.{
                .color_format = load_format,
                .bit_depth    = load_bit_depth,
                .line_length  = 0,
                .tmem_addr    = opts.tmem_addr,
                .tile_index   = load_tile,
            });

            rq.cmd_queue.loadSync();

            // LoadBlock texel count adjusted for sub-byte packing.
            const num_texels: u32 = switch (T.bit_depth) {
                .@"4" => (width * height + 3) / 4,
                .@"8" => (width * height + 1) / 2,
                else  => width * height,
            };
            rq.cmd_queue.loadBlock(.{
                .tile          = load_tile,
                .lower_right_s = @intCast(num_texels - 1),
                .dxt           = dxt,
            });

            // Rendering tile: real format and pitch, set after the load completes.
            rq.cmd_queue.setTile(.{
                .color_format = T.format,
                .bit_depth    = T.bit_depth,
                .line_length  = render_line_len,
                .tmem_addr    = opts.tmem_addr,
                .tile_index   = opts.tile,
            });

            rq.cmd_queue.loadSync();

            rq.cmd_queue.setTileSize(.{
                .tile          = opts.tile,
                .lower_right_s = @intCast((width  - 1) * 4),
                .lower_right_t = @intCast((height - 1) * 4),
            });
        }

        // Returns the render tile for `image`, loading it into TMEM if not cached.
        // Emits a tileSync when a load occurs. TMEM cache is evicted when full.
        fn ensureTexture(rq: *Self, image: anytype) u3 {
            const ptr = @intFromPtr(image.texel_data.ptr);
            for (rq.tex_cache[0..rq.tex_cache_len]) |entry| {
                if (entry.ptr == ptr) return entry.tile;
            }
            // Compute TMEM size: (w * h * bpp) bits rounded up to 64-bit words.
            const T = @TypeOf(image);
            const bpp: usize = switch (T.bit_depth) {
                .@"4" => 4, .@"8" => 8, .@"16" => 16, .@"32" => 32,
            };
            const tmem_words: usize = (@as(usize, image.width) * image.height * bpp + 63) / 64;
            // Evict entire cache when TMEM is full or all 4 render slots are used.
            if (rq.tex_cache_len >= 4 or rq.tmem_next + tmem_words > 512) {
                rq.tex_cache_len = 0;
                rq.tmem_next = 0;
                rq.next_tile = 0;
            }
            const tile = rq.next_tile;
            const tmem_addr = rq.tmem_next;
            rq.loadTexture(image, .{ .tile = tile, .tmem_addr = tmem_addr });
            rq.cmd_queue.tileSync();
            rq.tex_cache[rq.tex_cache_len] = .{ .ptr = ptr, .tile = tile, .tmem_addr = tmem_addr };
            rq.tex_cache_len += 1;
            rq.tmem_next += tmem_words;
            rq.next_tile +%= 2;
            return tile;
        }

        // --- Sprite drawing ---

        // Draws `image` in one-cycle mode at screen position (x, y).
        // The opts.pivot field determines what point of the sprite lands at (x, y).
        // Supports source sub-rect, scaling (via dsdx/dtdy), and flip.
        // Rotation is not yet implemented (requires triangle commands).
        pub fn drawSprite(rq: *Self, image: anytype, x: f32, y: f32, opts: SpriteDrawOptions) void {
            const src_width: f32  = if (opts.width  != 0) @floatFromInt(opts.width)  else @floatFromInt(image.width);
            const src_height: f32 = if (opts.height != 0) @floatFromInt(opts.height) else @floatFromInt(image.height);

            // Negative scale toggles flip; work with magnitudes.
            var flip_x = opts.flip_x;
            var flip_y = opts.flip_y;
            var scale_x: f32 = opts.scale_x;
            var scale_y: f32 = opts.scale_y;
            if (scale_x < 0.0) { flip_x = !flip_x; scale_x = -scale_x; }
            if (scale_y < 0.0) { flip_y = !flip_y; scale_y = -scale_y; }

            // Pivot in source-rect-local coordinates (0,0 = top-left of sub-rect).
            const cx: f32 = switch (opts.pivot) {
                .top_left, .middle_left, .bottom_left       => 0.0,
                .top_middle, .center, .bottom_middle         => src_width / 2.0,
                .top_right, .middle_right, .bottom_right    => src_width,
                .custom => |p| @floatFromInt(p.x),
            };
            const cy: f32 = switch (opts.pivot) {
                .top_left, .top_middle, .top_right           => 0.0,
                .middle_left, .center, .middle_right         => src_height / 2.0,
                .bottom_left, .bottom_middle, .bottom_right  => src_height,
                .custom => |p| @floatFromInt(p.y),
            };

            // Screen rectangle in pixel*4 units (RDP 10.2 fixed-point): pivot maps to (x, y).
            var ulx_raw: i32 = @intFromFloat(@round((x - scale_x * cx) * 4));
            var uly_raw: i32 = @intFromFloat(@round((y - scale_y * cy) * 4));
            const lrx_raw: i32 = @intFromFloat(@round((x + scale_x * (src_width  - cx)) * 4));
            const lry_raw: i32 = @intFromFloat(@round((y + scale_y * (src_height - cy)) * 4));

            // dsdx/dtdy in S5.10 format: 1024 = 1.0 texel/pixel; flip negates direction.
            const dsdx: i16 = @intFromFloat(if (flip_x) -(1024.0 / scale_x) else (1024.0 / scale_x));
            const dtdy: i16 = @intFromFloat(if (flip_y) -(1024.0 / scale_y) else (1024.0 / scale_y));

            // Texture S and T start in S10.5 format (texel * 32).
            // For flip, begin at the last texel of the sub-rect.
            var s: i16 = if (flip_x)
                @intCast((@as(i32, opts.s0) + @as(i32, @intFromFloat(src_width))  - 1) * 32)
            else
                @intCast(@as(i32, opts.s0) * 32);
            var t: i16 = if (flip_y)

                @intCast((@as(i32, opts.t0) + @as(i32, @intFromFloat(src_height)) - 1) * 32)
            else
                @intCast(@as(i32, opts.t0) * 32);

            // Clip left/top edges: adjust texture start for any off-screen columns/rows.
            // Formula: s_adjust = clipped_pixels*4 * dsdx / 128  (both in their fixed-point units)
            if (ulx_raw < 0) {
                s +%= @intCast(@divTrunc(-ulx_raw * @as(i32, dsdx), 128));
                ulx_raw = 0;
            }
            if (uly_raw < 0) {
                t +%= @intCast(@divTrunc(-uly_raw * @as(i32, dtdy), 128));
                uly_raw = 0;
            }

            // Skip if sprite is entirely off-screen.
            if (lrx_raw <= ulx_raw or lry_raw <= uly_raw) return;

            rq.setCycleType(.one_cycle);
            const tile = rq.ensureTexture(image);
            rq.textureRectangle(.{
                .tile = tile,
                .ulx  = @intCast(ulx_raw),
                .uly  = @intCast(uly_raw),
                .lrx  = @intCast(@min(lrx_raw, 0xFFF)),
                .lry  = @intCast(@min(lry_raw, 0xFFF)),
                .s    = s,
                .t    = t,
                .dsdx = dsdx,
                .dtdy = dtdy,
            });
        }

        // Draws `image` in copy mode at pixel position (x, y).
        // Copy mode skips the color combiner and blender — fastest path for opaque sprites.
        // Bypasses mode dirty state for the same reason as clearScreen: blend flags like
        // image_read_en must not bleed into copy mode OtherModes or the RDP stalls.
        // N.B. copy mode lrx is inclusive (+width-1), and dsdx has a 4x internal scale.
        pub fn blitSprite(rq: *Self, image: anytype, x: u16, y: u16) void {
            const tile = rq.ensureTexture(image);
            rq.cmd_queue.pipeSync();
            rq.cmd_queue.setOtherModes(.{ 
                .cycle_type = .copy, 
            });
            rq.cmd_queue.textureRectangle(.{
                .tile = tile,
                .ulx = @truncate(@as(u32, x) * 4),
                .uly = @truncate(@as(u32, y) * 4),
                .lrx = @truncate((@as(u32, x) + image.width - 1) * 4),
                .lry = @truncate((@as(u32, y) + image.height - 1) * 4),
                .s = 0, .t = 0,
                .dsdx = 4 << 10,
                .dtdy = 1 << 10,
            });
            rq.mode_dirty = true;
        }
    };
}

const TexCacheEntry = struct {
    ptr: usize = 0,
    tile: u3 = 0,
    tmem_addr: usize = 0,
};
