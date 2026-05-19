// Color Combiner inputs for Set Combine Mode (0x3C).
// The combiner computes (A - B) * C + D per cycle for both RGB and alpha.

pub const CycleMode = struct {
    rgb_a: RgbA   = .zero,
    rgb_b: RgbB   = .zero,
    rgb_c: RgbC   = .zero,
    rgb_d: RgbD   = .zero,
    alpha_a: AlphaA = .zero,
    alpha_b: AlphaB = .zero,
    alpha_c: AlphaC = .zero,
    alpha_d: AlphaD = .zero,
};

pub const CombineMode = struct {
    cycle0: CycleMode,
    cycle1: CycleMode,

    pub fn single(cycle: CycleMode) CombineMode {
        return .{ .cycle0 = cycle, .cycle1 = cycle };
    }

    pub const primitive = single(.{ .rgb_d = .primitive, .alpha_d = .primitive });
    pub const shade = single(.{ .rgb_d = .shade, .alpha_d = .shade });
    pub const decal_rgb = single(.{ .rgb_d = .tex0, .alpha_d = .shade });
    pub const decal_rgba = single(.{ .rgb_d = .tex0, .alpha_d = .tex0 });
};

pub const RgbA = enum(u4) {
    combined    = 0,
    tex0        = 1,
    tex1        = 2,
    primitive   = 3,
    shade       = 4,
    environment = 5,
    one         = 6,
    noise       = 7,
    zero        = 8,
};

pub const RgbB = enum(u4) {
    combined    = 0,
    tex0        = 1,
    tex1        = 2,
    primitive   = 3,
    shade       = 4,
    environment = 5,
    center      = 6,
    k4          = 7,
    zero        = 8,
};

pub const RgbC = enum(u5) {
    combined          = 0,
    tex0              = 1,
    tex1              = 2,
    primitive         = 3,
    shade             = 4,
    environment       = 5,
    scale             = 6,
    combined_alpha    = 7,
    tex0_alpha        = 8,
    tex1_alpha        = 9,
    primitive_alpha   = 10,
    shade_alpha       = 11,
    environment_alpha = 12,
    lod_fraction      = 13,
    prim_lod_frac     = 14,
    k5                = 15,
    zero              = 16,
};

pub const RgbD = enum(u3) {
    combined    = 0,
    tex0        = 1,
    tex1        = 2,
    primitive   = 3,
    shade       = 4,
    environment = 5,
    one         = 6,
    zero        = 7,
};

pub const AlphaA = enum(u3) {
    combined    = 0,
    tex0        = 1,
    tex1        = 2,
    primitive   = 3,
    shade       = 4,
    environment = 5,
    one         = 6,
    zero        = 7,
};

pub const AlphaB = enum(u3) {
    combined    = 0,
    tex0        = 1,
    tex1        = 2,
    primitive   = 3,
    shade       = 4,
    environment = 5,
    one         = 6,
    zero        = 7,
};

pub const AlphaC = enum(u3) {
    lod_fraction  = 0,
    tex0          = 1,
    tex1          = 2,
    primitive     = 3,
    shade         = 4,
    environment   = 5,
    prim_lod_frac = 6,
    zero          = 7,
};

pub const AlphaD = enum(u3) {
    combined    = 0,
    tex0        = 1,
    tex1        = 2,
    primitive   = 3,
    shade       = 4,
    environment = 5,
    one         = 6,
    zero        = 7,
};
