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

    fn translucentGeometry() State {
        var result = opaque_geometry.withBlend(.alpha);
        result.modes.z_update_en = false;
        result.modes.z_mode = .transparent;
        result.modes.cvg_dest = .wrap;
        result.modes.write_on_cvg_overflow = true;
        return result;
    }
};
