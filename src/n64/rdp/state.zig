const modes = @import("modes.zig");
const blender = @import("blender.zig");
const combiner = @import("combiner.zig");

/// Tracked RDP pipeline state. Color registers, targets, scissor and textures
/// remain independently controlled. Presets are ordinary, editable values.
pub const State = struct {
    modes: modes.OtherModes = .{},
    combine: combiner.CombineMode = .primitive,

    pub const opaque_geometry: State = .{
        .modes = .{ .antialias_en = true, .z_compare_en = true, .z_update_en = true, .persp_tex_en = true },
        .combine = .shade,
    };
    /// Opaque geometry with edge antialiasing. Costs a framebuffer read for
    /// every pixel; `opaque_geometry` only computes coverage for the VI.
    pub const antialiased_opaque_geometry: State = opaque_geometry.withEdgeAntialias(false);
    pub const translucent_geometry: State = translucentGeometry();
    pub const textured_sprite: State = (State{
        .combine = .single(.{ .rgb_a = .tex0, .rgb_c = .primitive, .alpha_d = .tex0 }),
    }).withBlend(.alpha);

    pub fn withBlend(self: State, blend: blender.BlendMode) State {
        var result = self;
        result.modes.force_blend = blend.force_blend;
        result.modes.image_read_en = blend.image_read_en;
        result.modes.blend_p0 = blend.pass1.p;
        result.modes.blend_a0 = blend.pass1.a;
        result.modes.blend_m0 = blend.pass1.m;
        result.modes.blend_b0 = blend.pass1.b;
        result.modes.blend_p1 = blend.pass2.p;
        result.modes.blend_a1 = blend.pass2.a;
        result.modes.blend_m1 = blend.pass2.m;
        result.modes.blend_b1 = blend.pass2.b;
        return result;
    }

    /// Blend partially covered opaque edges with the framebuffer (libultra's
    /// AA_ZB_OPA_SURF, or AA_ZB_TEX_EDGE for a `cutout`). The edge blend uses
    /// the second blender cycle in two-cycle mode, so apply this after the
    /// cycle type. A cutout multiplies coverage by combiner alpha, so alpha
    /// compare tests that product and zero-alpha texels draw nothing.
    pub fn withEdgeAntialias(self: State, cutout: bool) State {
        const two_cycle = self.modes.cycle_type == .two_cycle;
        return self.withBlend(if (two_cycle) .antialiased_opaque_two_cycle else .antialiased_opaque).withEdgeCoverage(cutout);
    }

    /// The coverage half of `withEdgeAntialias`, for callers that build the
    /// edge blend into their own mode such as `BlendMode.antialiased_opaque_fog`.
    pub fn withEdgeCoverage(self: State, cutout: bool) State {
        var result = self;
        result.modes.antialias_en = true;
        result.modes.cvg_dest = .clamp;
        result.modes.blender_alpha = if (cutout) .cvg_times_cc else .coverage;
        return result;
    }

    fn translucentGeometry() State {
        var result = opaque_geometry.withBlend(.alpha);
        result.modes.z_update_en = false;
        result.modes.z_mode = .transparent;
        result.modes.cvg_dest = .wrap;
        result.modes.write_on_cvg_overflow = true;
        return result;
    }
};
