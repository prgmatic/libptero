// Color Combiner inputs for Set Combine Mode (0x3C).
// The combiner computes (A - B) * C + D per cycle for both RGB and alpha.

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

pub const CycleConfig = struct {
    color_a: RgbA   = .zero,
    color_b: RgbB   = .zero,
    color_c: RgbC   = .zero,
    color_d: RgbD   = .zero,
    alpha_a: AlphaA = .zero,
    alpha_b: AlphaB = .zero,
    alpha_c: AlphaC = .zero,
    alpha_d: AlphaD = .zero,
};

pub const CombineMode = union(enum) {
    multiply,
    custom: struct {
        cycle1: CycleConfig = .{},
        cycle2: CycleConfig,
    },

    pub fn toCycleConfigs(self: CombineMode) [2]CycleConfig {
        const zero = CycleConfig{};
        return switch (self) {
            .multiply => .{ zero, .{ .color_d = .tex0, .alpha_d = .tex0 } },
            .custom   => |c| .{ c.cycle1, c.cycle2 },
        };
    }
};
