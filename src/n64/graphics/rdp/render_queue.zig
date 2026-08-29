const q = @import("queue.zig");
const std = @import("std");
const blender = @import("blender.zig");
const modes = @import("modes.zig");
const cc = @import("combiner.zig");
const tri = @import("triangles.zig");
const texture = @import("texture.zig");

pub const SpriteDrawOptions = texture.SpriteDrawOptions;
pub const Pivot = texture.Pivot;

const CommandQueue = q.CommandQueue;
const FixedQueue = q.FixedQueue;
const TextureRectangleOptions = q.TextureRectangleOptions;
const LoadTextureOptions = q.LoadTextureOptions;
pub const TexVertex = tri.TexVertex;

const CombineMode = cc.CombineMode;
const BlendMode = blender.BlendMode;
const CycleType = modes.CycleType;
const OtherModes = modes.OtherModes;
const Rgba32 = @import("../color.zig").Rgba32;

pub const FixedRenderQueue = RenderQueue(FixedQueue);
pub const RspRenderQueue = RenderQueue(q.RspQueue);
pub const DirectRenderQueue = RenderQueue(q.DirectQueue);
pub const RspSubmittedRenderQueue = RenderQueue(q.RspSubmittedQueue);
pub const OverlayRenderQueue = RenderQueue(q.OverlayQueue);

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
        tmem_next: u10 = 0, // next free TMEM word offset (8-byte words, max 512)
        next_tile: u3 = 0, // next render tile; load tile = next_tile +% 1

        pub fn init(queue: QueueType) Self {
            var result: Self = .{ .cmd_queue = TCmdQueue.init(queue) };
            result.setCycleType(.one_cycle);
            return result;
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

        pub fn flushModes(rq: *Self) void {
            rq.flushPendingModes();
        }

        fn flushPendingModes(rq: *Self) void {
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
            if (rq.mode.cycle_type == cycle_type) return;
            rq.mode.cycle_type = cycle_type;
            rq.mode_dirty = true;
        }

        pub fn setBlendMode(rq: *Self, blend: BlendMode) void {
            const previous: u64 = @bitCast(rq.mode);
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
            if (@as(u64, @bitCast(rq.mode)) != previous) rq.mode_dirty = true;
        }

        pub fn setCombineMode(rq: *Self, mode: CombineMode) void {
            if (std.meta.eql(rq.combine_mode, mode)) return;
            rq.combine_mode = mode;
            rq.combine_dirty = true;
        }

        /// Make a texture resident with explicit sampler state and return its render tile.
        pub fn useTextureSampler(rq: *Self, image: anytype, sampler: texture.Sampler) u3 {
            return rq.ensureTexture(image, sampler);
        }

        pub fn setDepthState(rq: *Self, compare: bool, update: bool) void {
            if (rq.mode.z_compare_en == compare and rq.mode.z_update_en == update) return;
            rq.mode.z_compare_en = compare;
            rq.mode.z_update_en = update;
            rq.mode_dirty = true;
        }

        pub fn setPerspectiveTexture(rq: *Self, enabled: bool) void {
            if (rq.mode.persp_tex_en == enabled) return;
            rq.mode.persp_tex_en = enabled;
            rq.mode_dirty = true;
        }

        pub fn setFrameBuffer(rq: *Self, image: anytype) void {
            rq.fb_width = @intCast(image.width);
            rq.fb_height = @intCast(image.height);
            rq.cmd_queue.setColorFrame(image);
            rq.cmd_queue.setScissor(0, 0, rq.fb_width * 4, rq.fb_height * 4);
        }

        pub fn setPrimColor(rq: *Self, color: Rgba32) void {
            rq.cmd_queue.setPrimColor(color);
        }

        pub fn clearScreen(rq: *Self, color: anytype) void {
            rq.cmd_queue.pipeSync();
            rq.cmd_queue.setOtherModes(.{ .cycle_type = .fill });
            rq.cmd_queue.setFillColor(color);
            rq.cmd_queue.fillRect(0, 0, (rq.fb_width - 1) * 4, (rq.fb_height - 1) * 4);
            rq.mode_dirty = true;
        }

        /// Clear a 16-bit depth image through the RDP and restore the active
        /// color image. The depth buffer uses the same packed all-ones value
        /// as an RGBA16 white fill.
        pub fn clearDepth(rq: *Self, depth_image: anytype, color_image: anytype) void {
            rq.cmd_queue.pipeSync();
            rq.cmd_queue.setOtherModes(.{ .cycle_type = .fill });
            rq.cmd_queue.setColorFrame(depth_image);
            rq.cmd_queue.setFillColor(@import("../color.zig").Rgba16.white);
            rq.cmd_queue.fillRect(0, 0, (rq.fb_width - 1) * 4, (rq.fb_height - 1) * 4);
            rq.cmd_queue.pipeSync();
            rq.cmd_queue.setColorFrame(color_image);
            rq.mode_dirty = true;
        }

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

        // Explicit texture load into TMEM (bypasses cache).
        fn loadTexture(rq: *Self, image: anytype, tile: u3, tmem_addr: u9, sampler: texture.Sampler) void {
            texture.loadTexture(&rq.cmd_queue, image, tile, tmem_addr, sampler);
        }

        // Returns the render tile for `image`, loading it into TMEM if not cached.
        // Emits a tileSync when a load occurs. TMEM cache is evicted when full.
        fn ensureTexture(rq: *Self, image: anytype, sampler: texture.Sampler) u3 {
            const ptr = @intFromPtr(image.texel_data.ptr);
            for (rq.tex_cache[0..rq.tex_cache_len]) |entry| {
                if (entry.ptr == ptr and entry.sampler.eql(sampler)) return entry.tile;
            }
            // Compute TMEM size: (w * h * bpp) bits rounded up to 64-bit words.
            const T = @TypeOf(image);
            const bpp: u16 = switch (T.bit_depth) {
                .@"4" => 4,
                .@"8" => 8,
                .@"16" => 16,
                .@"32" => 32,
            };
            const required_words = (@as(u32, image.width) * image.height * bpp + 63) / 64;
            if (required_words > 512) @panic("texture exceeds TMEM capacity");
            const tmem_words: u10 = @intCast(required_words);
            // Evict entire cache when TMEM is full or all 4 render slots are used.
            if (rq.tex_cache_len >= 4 or @as(u32, rq.tmem_next) + required_words > 512) {
                rq.tex_cache_len = 0;
                rq.tmem_next = 0;
                rq.next_tile = 0;
            }
            const tile = rq.next_tile;
            const tmem_addr: u9 = @intCast(rq.tmem_next);
            rq.loadTexture(image, tile, tmem_addr, sampler);
            rq.cmd_queue.tileSync();
            rq.tex_cache[rq.tex_cache_len] = .{ .ptr = ptr, .tile = tile, .tmem_addr = tmem_addr, .sampler = sampler };
            rq.tex_cache_len += 1;
            rq.tmem_next += tmem_words;
            rq.next_tile +%= 2;
            return tile;
        }

        pub fn drawSprite(rq: *Self, image: anytype, x: f32, y: f32, opts: SpriteDrawOptions) void {
            const src_width: f32 = if (opts.width != 0) @floatFromInt(opts.width) else @floatFromInt(image.width);
            const src_height: f32 = if (opts.height != 0) @floatFromInt(opts.height) else @floatFromInt(image.height);

            // Negative scale toggles flip; work with magnitudes.
            var flip_x = opts.flip_x;
            var flip_y = opts.flip_y;
            var scale_x: f32 = opts.scale_x;
            var scale_y: f32 = opts.scale_y;
            if (scale_x < 0.0) {
                flip_x = !flip_x;
                scale_x = -scale_x;
            }
            if (scale_y < 0.0) {
                flip_y = !flip_y;
                scale_y = -scale_y;
            }

            // Pivot in source-rect-local coordinates (0,0 = top-left of sub-rect).
            const cx: f32 = switch (opts.pivot) {
                .top_left, .middle_left, .bottom_left => 0.0,
                .top_middle, .center, .bottom_middle => src_width / 2.0,
                .top_right, .middle_right, .bottom_right => src_width,
                .custom => |p| @floatFromInt(p.x),
            };
            const cy: f32 = switch (opts.pivot) {
                .top_left, .top_middle, .top_right => 0.0,
                .middle_left, .center, .middle_right => src_height / 2.0,
                .bottom_left, .bottom_middle, .bottom_right => src_height,
                .custom => |p| @floatFromInt(p.y),
            };

            const tile = rq.ensureTexture(image, .{});

            if (opts.rotation == 0.0) {
                rq.flushPendingModes();
                texture.drawNonRotatedSprite(&rq.cmd_queue, tile, x, y, opts.s0, opts.t0, src_width, src_height, flip_x, flip_y, scale_x, scale_y, cx, cy);
            } else {
                rq.flushPendingModes();
                tri.drawRotatedSprite(&rq.cmd_queue, tile, x, y, opts.s0, opts.t0, src_width, src_height, flip_x, flip_y, opts.rotation, scale_x, scale_y, cx, cy);
            }
        }

        pub fn drawTexturedTriangle(rq: *Self, image: anytype, v1: TexVertex, v2: TexVertex, v3: TexVertex) void {
            const tile = rq.ensureTexture(image, .{});
            rq.flushPendingModes();
            tri.emitTexturedTriangle(&rq.cmd_queue, tile, v1, v2, v3);
        }
    };
}

const TexCacheEntry = struct {
    ptr: usize = 0,
    tile: u3 = 0,
    tmem_addr: usize = 0,
    sampler: texture.Sampler = .{},
};
