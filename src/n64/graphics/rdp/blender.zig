// Blender configuration for Set Other Modes (0xEF).
// The blender computes: (P * A + M * B) / (A + B).

/// Blend Cycle Sources (P * A + M * B)
pub const BlendCycle = struct {
    p: BlendColorSrc = .pixel,
    a: BlendAlphaSrc = .pixel_alpha,
    m: BlendColorSrc = .memory,
    b: BlendInvSrc   = .inv_a,
};

pub const BlendMode = struct {
    force_blend:   bool = false,
    image_read_en: bool = false,
    pass1: BlendCycle = .{},
    pass2: BlendCycle = .{},

    // Preset BlendModes

    /// Pixel color passes straight through; blender is disabled.
    pub const opaque_surface: BlendMode = .{};
    /// Standard src-alpha blend against the framebuffer.
    pub const alpha: BlendMode = .{ .force_blend = true, .image_read_en = true };
    /// Blend pixel with the fog color register using fog alpha.
    pub const fog: BlendMode = .{
                .force_blend   = true,
                .image_read_en = false,
                .pass1 = .{ .p = .fog, .a = .fog_alpha, .m = .pixel, .b = .inv_a },
    };
};

/// Color source for blender P and M inputs.
pub const BlendColorSrc = enum(u2) {
    pixel  = 0,
    memory = 1,
    blend  = 2,
    fog    = 3,
};

/// Alpha source for blender A input (first multiplier).
pub const BlendAlphaSrc = enum(u2) {
    pixel_alpha = 0,
    fog_alpha   = 1,
    shade_alpha = 2,
    zero        = 3,
};

/// Alpha source for blender B input (second multiplier).
pub const BlendInvSrc = enum(u2) {
    inv_a      = 0,
    memory_cvg = 1,
    one        = 2,
    zero       = 3,
};
