const bm = @import("blend.zig");


// Packed layout for Set Other Modes (0xEF).
pub const OtherModes = packed struct(u64) {
    alpha_compare_en: bool         = false,
    alpha_noise_en:   bool         = false,
    z_source_sel:     bool         = true,
    antialias_en:     bool         = false,
    z_compare_en:     bool         = false,
    z_update_en:      bool         = false,
    image_read_en:    bool         = false,
    color_on_cvg:     bool         = false,
    cvg_dest:         CoverageDest = .clamp,
    z_mode:           ZMode        = .opaque_surface,
    cvg_x_alpha:      bool         = false,
    alpha_cvg_select: bool         = false,
    force_blend:      bool         = false,
    _pad0:            u1           = 0,

    blend_b1: bm.BlendInvSrc   = .inv_a,
    blend_b0: bm.BlendInvSrc   = .inv_a,
    blend_m1: bm.BlendColorSrc = .pixel,
    blend_m0: bm.BlendColorSrc = .pixel,
    blend_a1: bm.BlendAlphaSrc = .pixel_alpha,
    blend_a0: bm.BlendAlphaSrc = .pixel_alpha,
    blend_p1: bm.BlendColorSrc = .pixel,
    blend_p0: bm.BlendColorSrc = .pixel,

    _pad1:             u4          = 0,
    alpha_dither:      AlphaDither = .same_as_rgb,
    rgb_dither:        RgbDither   = .magic_square,
    key_en:            bool        = false,
    convert_one:       bool        = false,
    bilinear_filter_1: bool        = true,
    bilinear_filter_0: bool        = true,
    average_texel:     bool        = false,
    sample_type:       SampleType  = .point,
    tlut_format:       TlutFormat  = .rgba16,
    tlut_en:           bool        = false,
    tex_lod_en:        bool        = false,
    sharpen_tex_en:    bool        = false,
    detail_tex_en:     bool        = false,
    persp_tex_en:      bool        = false,
    cycle_type:        CycleType   = .one_cycle,
    _pad2:             u1          = 0,
    atomic_prim:       bool        = false,
    _command:          u8          = 0xEF,
};

pub const CycleType = enum(u2) {
    one_cycle = 0,
    two_cycle = 1,
    copy      = 2,
    fill      = 3,
};

pub const ZMode = enum(u2) {
    opaque_surface   = 0,
    interpenetrating = 1,
    transparent      = 2,
    decal            = 3,
};

pub const CoverageDest = enum(u2) {
    clamp = 0,
    wrap  = 1,
    full  = 2,
    save  = 3,
};

pub const RgbDither = enum(u2) {
    magic_square = 0,
    bayer        = 1,
    noise        = 2,
    disabled     = 3,
};

pub const AlphaDither = enum(u2) {
    same_as_rgb    = 0,
    inverse_of_rgb = 1,
    noise          = 2,
    disabled       = 3,
};

pub const TlutFormat = enum(u1) {
    rgba16 = 0,
    ia16   = 1,
};

pub const SampleType = enum(u1) {
    point    = 0,
    bilinear = 1,
};
