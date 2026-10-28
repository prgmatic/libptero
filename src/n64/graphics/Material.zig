//! Native model material state, independent of how textures are supplied.
//! Generated assets expose these values for external-texture callbacks too.

const geometry = @import("geometry.zig");
const rdp = @import("../rdp.zig");
const modes = @import("../rdp/modes.zig");
const texture = @import("../rdp/texture.zig");
const Rgba32 = @import("pixel.zig").Rgba32;

const Material = @This();

flags: geometry.DrawFlags = .{ .depth = true, .shaded = true },
sampler: texture.Sampler = .{},
second_sampler: texture.Sampler = .{},
filter: modes.TextureSample = .point,
translucent: bool = false,
z_mode: ?rdp.ZMode = null,
alpha_cutoff: ?u8 = null,
/// null inherits the context's fog default (the pass fog). Translucent
/// materials whose combiner reads vertex (shade) alpha inherit no fog: the
/// RSP stores fog in shade alpha, so the two cannot be combined.
fog: ?bool = null,
cycle_type: rdp.CycleType = .one_cycle,
combine: rdp.CombineMode = .shade,
primitive: ?Rgba32 = null,
environment: ?Rgba32 = null,
vertex_effect: geometry.VertexEffect = .none,
/// Explicit blender override, e.g. blending against the blend-color register.
/// An override disables `edge_antialias`, which would replace its alpha.
blend: ?rdp.BlendMode = null,
/// Blend partially covered edges of an opaque surface with the framebuffer
/// so the VI filter smooths them. This reads the framebuffer for every pixel,
/// so it is off by default. It applies only while the pass enables
/// `antialias_en`; fogged surfaces switch to two-cycle mode for it.
edge_antialias: bool = false,
/// RDP Z compare/update overrides; null derives them from `flags.depth` and
/// `translucent`. Unlike clearing `flags.depth`, these leave the RSP's
/// triangle format and lighting unchanged: use them to skip the Z read and
/// write for a surface drawn in painter's order, such as a ground plane.
depth_test: ?bool = null,
depth_write: ?bool = null,

pub fn apply(self: Material, context: anytype) void {
    const fog = self.resolvedFog(context);
    self.applyGeometry(context, fog);
    const rq = if (@typeInfo(@TypeOf(context.render)) == .pointer) context.render else &context.render;
    // Material registers can be read by primitives still in the pipeline.
    rq.cmd_queue.pipeSync();
    self.applyDepth(rq);
    self.applyPipeline(rq, fog);
    self.applyCombiner(rq, fog);
    self.applyColors(rq);
}

/// Fog this material draws with in `context`.
pub fn resolvedFog(self: Material, context: anytype) bool {
    if (self.fog) |enabled| return enabled;
    if (self.translucent and self.usesShadeAlpha()) return false;
    return if (@hasField(@TypeOf(context.*), "fog_default")) context.fog_default else context.fog_enabled;
}

/// Whether the combiner reads per-vertex alpha, which fog would replace.
pub fn usesShadeAlpha(self: Material) bool {
    for ([_]rdp.CycleMode{ self.combine.cycle0, self.combine.cycle1 }) |cycle| {
        if (cycle.alpha_a == .shade or cycle.alpha_b == .shade or cycle.alpha_c == .shade or cycle.alpha_d == .shade or cycle.rgb_c == .shade_alpha)
            return true;
    }
    return false;
}

fn applyGeometry(self: Material, context: anytype, fog: bool) void {
    context.setDrawFlags(self.flags);
    context.setVertexEffect(self.vertex_effect);
    // Inheriting materials restore the default after an explicit override.
    if (@hasDecl(@TypeOf(context.*), "setMaterialFog")) {
        context.setMaterialFog(fog);
    } else if (self.fog != null or fog != context.fog_enabled) context.setFogEnabled(fog);
}

fn applyDepth(self: Material, rq: anytype) void {
    rq.setDepthState(self.depth_test orelse self.flags.depth, self.depth_write orelse (self.flags.depth and !self.translucent));
    rq.setSurfaceType(self.translucent);
    if (self.z_mode) |z_mode| {
        var mode = rq.getModes();
        mode.z_mode = z_mode;
        rq.setModes(mode);
    }
}

fn applyPipeline(self: Material, rq: anytype, fog: bool) void {
    rq.setPerspectiveTexture(self.flags.textured);
    rq.setTextureFilter(self.filter);
    const edges = self.antialiasesEdges(rq.getModes().antialias_en);
    rq.setCycleType(if (fog and (self.translucent or edges)) .two_cycle else self.cycle_type);
    self.applyBlend(rq, fog, edges);
    rq.setAlphaCompare(if (self.alpha_cutoff != null) .threshold else .disabled);
    if (self.alpha_cutoff) |cutoff| rq.setBlendColor(.fromBytes(0, 0, 0, cutoff));
}

fn applyBlend(self: Material, rq: anytype, fog: bool, edges: bool) void {
    if (self.blend) |blend| return rq.setBlendMode(blend);
    if (!edges) return rq.setBlendMode(self.blendMode(fog));
    const cutout = self.alpha_cutoff != null;
    const state = rq.getState();
    rq.setState(if (fog) state.withBlend(.antialiased_opaque_fog).withEdgeCoverage(cutout) else state.withEdgeAntialias(cutout));
}

/// Whether this material blends its edges in a pass with `antialias_en`.
fn antialiasesEdges(self: Material, pass_antialias: bool) bool {
    return self.edge_antialias and pass_antialias and !self.translucent and self.blend == null;
}

fn applyCombiner(self: Material, rq: anytype, fog: bool) void {
    var combine = self.combine;
    // Fog that forces two-cycle mode needs the combined color passed on.
    if (fog and rq.getModes().cycle_type == .two_cycle and self.cycle_type == .one_cycle)
        combine.cycle1 = .{ .rgb_d = .combined, .alpha_d = .combined };
    rq.setCombineMode(combine);
}

fn applyColors(self: Material, rq: anytype) void {
    if (self.primitive) |color| rq.setPrimColor(color);
    if (self.environment) |color| rq.setEnvironmentColor(color);
}

fn blendMode(self: Material, fog: bool) rdp.BlendMode {
    if (fog) return rdp.BlendMode.fogVisibility(self.translucent);
    if (!self.translucent) return if (self.cycle_type == .two_cycle) .opaque_two_cycle else .opaque_surface;
    return if (self.cycle_type == .two_cycle) .alpha_two_cycle else .alpha;
}

/// Apply state and bind an externally supplied, typed texture.
pub fn bind(self: Material, context: anytype, image: anytype) void {
    var resolved = self;
    if (self.vertex_effect == .spherical)
        resolved.vertex_effect = .{ .spherical = .{ .width = @intCast(image.width), .height = @intCast(image.height) } };
    resolved.sampler.mask_s = boundedMask(self.sampler.mask_s, image.width);
    resolved.sampler.mask_t = boundedMask(self.sampler.mask_t, image.height);
    resolved.apply(context);
    _ = context.render.useTextureSampler(image, resolved.sampler);
}

test "fogged alpha materials restore opaque state and preserve combiner alpha" {
    const std = @import("std");
    const TestContext = struct {
        render: rdp.RenderEncoder(rdp.backend.Direct),
        fog_enabled: bool = true,
        flags: geometry.DrawFlags = .{},
        pub fn setDrawFlags(self: *@This(), flags: geometry.DrawFlags) void {
            self.flags = flags;
        }
        pub fn setVertexEffect(self: *@This(), _: geometry.VertexEffect) void {
            _ = self;
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
    try std.testing.expectEqual(rdp.BlendAlphaSrc.pixel_alpha, context.render.mode.blend_a0);
    (Material{ .cycle_type = .two_cycle, .combine = .shade }).apply(&context);
    try std.testing.expect(!context.render.mode.force_blend);
    try std.testing.expect(context.render.mode.z_update_en);
    try std.testing.expectEqual(rdp.BlendAlphaSrc.pixel_alpha, context.render.mode.blend_a0);
    try std.testing.expectEqual(rdp.BlendColorSrc.pixel, context.render.mode.blend_m0);
    try std.testing.expectEqual(rdp.BlendInvSrc.inv_a, context.render.mode.blend_b0);
    (Material{ .depth_test = false, .depth_write = false }).apply(&context);
    try std.testing.expect(context.flags.depth);
    try std.testing.expect(!context.render.mode.z_compare_en);
    try std.testing.expect(!context.render.mode.z_update_en);
    (Material{ .translucent = true, .depth_write = true }).apply(&context);
    try std.testing.expect(context.render.mode.z_compare_en);
    try std.testing.expect(context.render.mode.z_update_en);
    (Material{ .translucent = true, .z_mode = .decal }).apply(&context);
    try std.testing.expectEqual(rdp.ZMode.decal, context.render.mode.z_mode);
    try std.testing.expect(!context.render.mode.z_update_en);
}

test "edge antialiasing is opt-in and keeps cutouts, overrides and fog" {
    const std = @import("std");
    const TestContext = struct {
        render: rdp.RenderEncoder(rdp.backend.Direct),
        fog_enabled: bool = false,
        pub fn setDrawFlags(_: *@This(), _: geometry.DrawFlags) void {}
        pub fn setVertexEffect(_: *@This(), _: geometry.VertexEffect) void {}
        pub fn setFogEnabled(self: *@This(), enabled: bool) void {
            self.fog_enabled = enabled;
        }
    };
    var commands: [64]u64 = undefined;
    var context: TestContext = .{ .render = .init(.{ .buffer = &commands }) };
    context.render.setState(.opaque_geometry);
    const mode = &context.render.mode;

    // The default opaque material never reads the framebuffer.
    (Material{}).apply(&context);
    try std.testing.expect(!mode.image_read_en);
    try std.testing.expectEqual(rdp.CoverageDest.full, mode.cvg_dest);
    try std.testing.expectEqual(rdp.BlenderAlphaSrc.combiner, mode.blender_alpha);

    (Material{ .edge_antialias = true }).apply(&context);
    try std.testing.expect(mode.image_read_en);
    try std.testing.expectEqual(rdp.CoverageDest.clamp, mode.cvg_dest);
    try std.testing.expectEqual(rdp.BlenderAlphaSrc.coverage, mode.blender_alpha);
    try std.testing.expectEqual(rdp.BlendInvSrc.memory_cvg, mode.blend_b0);

    // Cutouts multiply coverage by texture alpha (AA_ZB_TEX_EDGE).
    (Material{ .edge_antialias = true, .alpha_cutoff = 128 }).apply(&context);
    try std.testing.expectEqual(rdp.BlenderAlphaSrc.cvg_times_cc, mode.blender_alpha);
    try std.testing.expectEqual(rdp.AlphaCompare.threshold, mode.alpha_compare);

    // Two-cycle materials blend edges in the second cycle with image reads.
    (Material{ .edge_antialias = true, .cycle_type = .two_cycle }).apply(&context);
    try std.testing.expect(mode.image_read_en);
    try std.testing.expectEqual(rdp.BlendColorSrc.pixel, mode.blend_m0);
    try std.testing.expectEqual(rdp.BlendInvSrc.memory_cvg, mode.blend_b1);

    // Fog moves the edge blend to the second cycle and passes color on.
    (Material{ .edge_antialias = true, .fog = true }).apply(&context);
    try std.testing.expectEqual(rdp.CycleType.two_cycle, mode.cycle_type);
    try std.testing.expectEqual(rdp.BlendAlphaSrc.shade_alpha, mode.blend_a0);
    try std.testing.expectEqual(rdp.BlendInvSrc.memory_cvg, mode.blend_b1);
    try std.testing.expectEqual(@as(@TypeOf(context.render.combine_mode.cycle1.rgb_d), .combined), context.render.combine_mode.cycle1.rgb_d);

    // An explicit blend keeps combiner alpha.
    (Material{ .edge_antialias = true, .blend = .additive }).apply(&context);
    try std.testing.expectEqual(rdp.BlenderAlphaSrc.combiner, mode.blender_alpha);
    try std.testing.expectEqual(rdp.CoverageDest.full, mode.cvg_dest);

    // A pass without antialiasing disables it, as does translucency.
    context.render.setAntialias(false);
    (Material{ .edge_antialias = true }).apply(&context);
    try std.testing.expect(!mode.image_read_en);
    try std.testing.expect(!mode.antialias_en);
    context.render.setAntialias(true);
    (Material{ .edge_antialias = true, .translucent = true }).apply(&context);
    try std.testing.expectEqual(rdp.CoverageDest.wrap, mode.cvg_dest);
    try std.testing.expectEqual(rdp.BlenderAlphaSrc.combiner, mode.blender_alpha);
}

fn boundedMask(mask: u4, size: u32) u4 {
    const std = @import("std");
    if (!std.math.isPowerOfTwo(size)) return mask;
    return @min(mask, @as(u4, @intCast(std.math.log2_int(u32, size))));
}

test "external images bound legacy wrap masks to actual texel dimensions" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u4, 5), boundedMask(6, 32));
    try std.testing.expectEqual(@as(u4, 4), boundedMask(4, 32));
    try std.testing.expectEqual(@as(u4, 0), boundedMask(0, 32));
    try std.testing.expectEqual(@as(u4, 6), boundedMask(6, 44));
}

test "inheriting materials use the fog default and vertex alpha disables fog" {
    const std = @import("std");
    const TestContext = struct {
        render: rdp.RenderEncoder(rdp.backend.Direct),
        fog_enabled: bool = true,
        fog_default: bool = true,
        fog_commands: u32 = 0,
        pub fn setDrawFlags(_: *@This(), _: geometry.DrawFlags) void {}
        pub fn setVertexEffect(_: *@This(), _: geometry.VertexEffect) void {}
        pub fn setMaterialFog(self: *@This(), enabled: bool) void {
            if (enabled == self.fog_enabled) return;
            self.fog_enabled = enabled;
            self.fog_commands += 1;
        }
    };
    var commands: [64]u64 = undefined;
    var context: TestContext = .{ .render = .init(.{ .buffer = &commands }) };
    (Material{ .fog = false }).apply(&context);
    try std.testing.expect(!context.fog_enabled);
    // The next inheriting material returns to the pass default.
    (Material{}).apply(&context);
    try std.testing.expect(context.fog_enabled);

    const shadow: Material = .{ .translucent = true, .combine = .shade };
    try std.testing.expect(shadow.usesShadeAlpha());
    try std.testing.expect(!shadow.resolvedFog(&context));
    shadow.apply(&context);
    try std.testing.expect(!context.fog_enabled);
    try std.testing.expectEqual(rdp.BlendAlphaSrc.pixel_alpha, context.render.mode.blend_a0);
    try std.testing.expectEqual(rdp.CycleType.one_cycle, context.render.mode.cycle_type);

    const glass: Material = .{ .translucent = true, .combine = .single(.{ .rgb_d = .shade, .alpha_d = .primitive }) };
    try std.testing.expect(!glass.usesShadeAlpha());
    try std.testing.expect(glass.resolvedFog(&context));
    try std.testing.expect((Material{ .translucent = true, .combine = .shade, .fog = true }).resolvedFog(&context));
    try std.testing.expectEqual(@as(u32, 3), context.fog_commands);
}
