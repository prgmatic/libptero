const geometry = @import("geometry.zig");
const rdp = @import("rdp.zig");
const modes = @import("rdp/modes.zig");
const texture = @import("rdp/texture.zig");
const Rgba32 = @import("color.zig").Rgba32;

/// Native model material state, independent of how textures are supplied.
/// Generated assets expose these values for external-texture callbacks too.
pub const Material = struct {
    flags: geometry.DrawFlags = .{ .depth = true, .shaded = true },
    sampler: texture.Sampler = .{},
    second_sampler: texture.Sampler = .{},
    filter: modes.TextureSample = .point,
    translucent: bool = false,
    alpha_cutoff: ?u8 = null,
    /// null inherits the context's current geometry fog setting.
    fog: ?bool = null,
    cycle_type: rdp.CycleType = .one_cycle,
    combine: rdp.CombineMode = .shade,
    primitive: ?Rgba32 = null,
    environment: ?Rgba32 = null,

    pub fn apply(self: Material, context: anytype) void {
        context.setDrawFlags(self.flags);
        if (self.fog) |enabled| context.setFogEnabled(enabled);
        const fog = self.fog orelse context.fog_enabled;
        const rq = &context.render;
        // Material registers can be read by primitives still in the pipeline.
        rq.cmd_queue.pipeSync();
        rq.setDepthState(self.flags.depth, self.flags.depth and !self.translucent);
        rq.setPerspectiveTexture(self.flags.textured);
        rq.setTextureFilter(self.filter);
        rq.setCycleType(if (fog and self.translucent) .two_cycle else self.cycle_type);
        rq.setBlendMode(self.blendMode(fog));
        rq.setSurfaceType(self.translucent);
        rq.setAlphaCompare(if (self.alpha_cutoff != null) .threshold else .disabled);
        if (self.alpha_cutoff) |cutoff| rq.setBlendColor(.fromBytes(0, 0, 0, cutoff));
        var combine = self.combine;
        if (fog and self.translucent and self.cycle_type == .one_cycle)
            combine.cycle1 = .{ .rgb_d = .combined, .alpha_d = .combined };
        rq.setCombineMode(combine);
        if (self.primitive) |color| rq.setPrimColor(color);
        if (self.environment) |color| rq.setEnvironmentColor(color);
    }

    fn blendMode(self: Material, fog: bool) rdp.BlendMode {
        if (fog) return rdp.BlendMode.fogVisibility(self.translucent);
        if (!self.translucent) return .opaque_surface;
        return if (self.cycle_type == .two_cycle) .alpha_two_cycle else .alpha;
    }

    /// Apply state and bind an externally supplied, typed texture.
    pub fn bind(self: Material, context: anytype, image: anytype) void {
        self.apply(context);
        _ = context.render.useTextureSampler(image, self.sampler);
    }
};

test "fogged alpha materials restore opaque state and preserve combiner alpha" {
    const std = @import("std");
    const TestContext = struct {
        render: rdp.FixedRenderQueue,
        fog_enabled: bool = true,
        flags: geometry.DrawFlags = .{},
        pub fn setDrawFlags(self: *@This(), flags: geometry.DrawFlags) void {
            self.flags = flags;
        }
        pub fn setFogEnabled(self: *@This(), enabled: bool) void {
            self.fog_enabled = enabled;
        }
    };
    var commands: [64]u64 = undefined;
    var context: TestContext = .{ .render = .init(.{ .buffer = &commands }) };
    const alpha: Material = .{
        .flags = .{ .depth = true, .textured = true, .shaded = true },
        .translucent = true,
        .combine = .single(.{ .rgb_a = .tex0, .rgb_c = .shade, .alpha_d = .tex0 }),
    };
    alpha.apply(&context);
    try std.testing.expectEqual(rdp.CycleType.two_cycle, context.render.mode.cycle_type);
    try std.testing.expect(context.render.mode.image_read_en);
    try std.testing.expect(!context.render.mode.z_update_en);
    try std.testing.expectEqual(rdp.ZMode.transparent, context.render.mode.z_mode);
    try std.testing.expectEqual(rdp.BlendAlphaSrc.shade_alpha, context.render.mode.blend_a0);
    try std.testing.expectEqual(rdp.BlendColorSrc.memory, context.render.mode.blend_m1);
    try std.testing.expectEqual(@as(@TypeOf(context.render.combine_mode.cycle0.alpha_d), .tex0), context.render.combine_mode.cycle0.alpha_d);
    try std.testing.expectEqual(@as(@TypeOf(context.render.combine_mode.cycle1.alpha_d), .combined), context.render.combine_mode.cycle1.alpha_d);
    (Material{ .alpha_cutoff = 32, .fog = false }).apply(&context);
    try std.testing.expect(!context.fog_enabled);
    try std.testing.expect(!context.render.mode.image_read_en);
    try std.testing.expect(context.render.mode.z_update_en);
    try std.testing.expectEqual(rdp.ZMode.opaque_surface, context.render.mode.z_mode);
    try std.testing.expectEqual(rdp.AlphaCompare.threshold, context.render.mode.alpha_compare);
    (Material{}).apply(&context);
    try std.testing.expectEqual(rdp.AlphaCompare.disabled, context.render.mode.alpha_compare);
    var two_cycle = alpha;
    two_cycle.cycle_type = .two_cycle;
    two_cycle.apply(&context);
    try std.testing.expectEqual(rdp.BlendColorSrc.memory, context.render.mode.blend_m1);
    try std.testing.expectEqual(rdp.BlendAlphaSrc.zero, context.render.mode.blend_a0);
}
