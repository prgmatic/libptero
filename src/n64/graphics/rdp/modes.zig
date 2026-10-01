const bm = @import("blender.zig");

// Packed layout for Set Other Modes (0xEF).
pub const OtherModes = packed struct(u64) {
    alpha_compare:         AlphaCompare    = .disabled,
    z_source:              ZSource         = .per_pixel,
    antialias_en:          bool            = false,
    z_compare_en:          bool            = false,
    z_update_en:           bool            = false,
    image_read_en:         bool            = false,
    write_on_cvg_overflow: bool            = false,
    cvg_dest:              CoverageDest    = .full,
    z_mode:                ZMode           = .opaque_surface,
    blender_alpha:         BlenderAlphaSrc = .combiner,
    force_blend:           bool            = false,
    _pad0:                 u1              = 0,

    blend_b1: bm.BlendInvSrc   = .inv_a,
    blend_b0: bm.BlendInvSrc   = .inv_a,
    blend_m1: bm.BlendColorSrc = .pixel,
    blend_m0: bm.BlendColorSrc = .pixel,
    blend_a1: bm.BlendAlphaSrc = .pixel_alpha,
    blend_a0: bm.BlendAlphaSrc = .pixel_alpha,
    blend_p1: bm.BlendColorSrc = .pixel,
    blend_p0: bm.BlendColorSrc = .pixel,

    _pad1:                u4            = 0,
    alpha_dither:         AlphaDither   = .disabled,
    rgb_dither:           RgbDither     = .disabled,
    chroma_key_en:        bool          = false,
    tex_filter_use_tex0:  bool          = false,
    tex_filter_1:         TexFilter     = .bilinear,
    tex_filter_0:         TexFilter     = .bilinear,
    texture_sample:       TextureSample = .point,
    tlut_format:          TlutFormat    = .rgba16,
    tlut_en:              bool          = false,
    tex_lod_en:           bool          = false,
    sharpen_tex_en:       bool          = false,
    detail_tex_en:        bool          = false,
    persp_tex_en:         bool          = false,
    cycle_type:           CycleType     = .one_cycle,
    _pad2:                u1            = 0,
    atomic_prim:          bool          = false,
    _command:             u8            = 0xEF,
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

pub const ZSource = enum(u1) {
    per_pixel = 0,
    primitive = 1,
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

/// Texel sampling pattern. Combines sample_type (bit 45) and mid_texel (bit 44).
pub const TextureSample = enum(u2) {
    point    = 0,
    bilinear = 2,
    median   = 3,
};

/// Texture filter mode per pipeline cycle (bi_lerp).
pub const TexFilter = enum(u1) {
    yuv_to_rgb = 0,
    bilinear   = 1,
};

/// Alpha source for the blender's A input.
pub const BlenderAlphaSrc = enum(u2) {
    combiner     = 0,
    coverage     = 1,
    cvg_times_cc = 2,
};

pub const AlphaCompare = enum(u2) {
    disabled  = 0,
    threshold = 1,
    noise     = 2,
};

test "standard other modes match the reference renderer defaults" {
    const standard = OtherModes{};
    try @import("std").testing.expectEqual(CoverageDest.full, standard.cvg_dest);
    try @import("std").testing.expectEqual(RgbDither.disabled, standard.rgb_dither);
    try @import("std").testing.expectEqual(AlphaDither.disabled, standard.alpha_dither);
}

test "texture sampling encodes sample type and mid-texel in their hardware bits" {
    const std = @import("std");
    const bilinear: u64 = @bitCast(OtherModes{ .texture_sample = .bilinear });
    const median: u64 = @bitCast(OtherModes{ .texture_sample = .median });
    try std.testing.expectEqual(@as(u64, 2), (bilinear >> 44) & 3);
    try std.testing.expectEqual(@as(u64, 3), (median >> 44) & 3);
}
