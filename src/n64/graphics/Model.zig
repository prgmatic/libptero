//! A model is stored as already-packed vertex batches. Strip entries contain
//! vertex-buffer-relative byte offsets plus the RSP strip control flags; the
//! linked geometry overlay relocates them to its actual DMEM vertex buffer.
//! The asset compiler splits primitives so every part fits in that workspace.

const drawing = @import("model/draw.zig");
const animation = @import("animation.zig");
const SkinnedModel = @import("SkinnedModel.zig");
const MutableModel = @import("MutableModel.zig");
const math = @import("../math.zig");
const geometry = @import("geometry.zig");
const Material = @import("Material.zig");

const Model = @This();

parts: []const Part,
nodes: []const animation.Node = &.{},
skins: []const animation.Skin = &.{},
animations: []const animation.Clip = &.{},

pub fn findAnimation(self: Model, name: []const u8) ?*const animation.Clip {
    for (self.animations) |*clip| {
        if (@import("std").mem.eql(u8, clip.name, name)) return clip;
    }
    return null;
}

/// Cache-coherency contract for model geometry. Immutable data must already be
/// coherent in RDRAM; dynamic data is written back on every draw.
pub const DataUsage = enum { immutable, dynamic };

pub const Part = struct {
    vertices: []const geometry.VertexPair,
    material_index: u16,
    vertex_offset: u8 = 0,
    vertex_count: u8,
    strip_indices: []const i16 = &.{},
    data_usage: DataUsage = .immutable,
    /// Global node index for bind-local RSP skinning; the pose is set on Context.
    bone: ?u16 = null,
    skin: ?u16 = null,
    influences: []const animation.Influence = &.{},
};

test "model applies changed materials and submits packed batches" {
    const Testing = struct {
        const Context = struct {
            matrix: ?*const math.FixedMat4 = null,
            saved_matrix: ?*const math.FixedMat4 = null,
            expected_matrix: ?*const math.FixedMat4 = null,
            wrong_matrix: bool = false,
            pushes: usize = 0,
            pops: usize = 0,
            loads: usize = 0,
            draws: usize = 0,
            syncs: usize = 0,
            dynamic_loads: usize = 0,
            dynamic_draws: usize = 0,

            pub fn pushMatrix(self: *@This(), matrix: *const math.FixedMat4) void {
                self.saved_matrix = self.matrix;
                self.matrix = matrix;
                self.pushes += 1;
            }
            pub fn popMatrix(self: *@This()) void {
                self.matrix = self.saved_matrix;
                self.pops += 1;
            }
            pub fn loadVertices(self: *@This(), _: []const geometry.VertexPair, _: u8, count: u8) void {
                self.loads += count;
                self.dynamic_loads += 1;
            }
            pub fn loadStaticVertices(self: *@This(), vertices: []const geometry.VertexPair, offset: u8, count: u8) void {
                _ = vertices;
                _ = offset;
                self.loads += count;
            }
            pub fn drawStaticTriangleStrip(self: *@This(), indices: []const i16, _: bool) void {
                if (self.expected_matrix) |expected| {
                    if (self.matrix != expected) self.wrong_matrix = true;
                }
                self.draws += indices.len / 3;
                self.syncs += 1;
            }
            pub fn drawTriangleStrip(self: *@This(), indices: []const i16, sync: bool) void {
                self.dynamic_draws += 1;
                self.drawStaticTriangleStrip(indices, sync);
            }
            pub fn setBoneMatrix(_: *@This(), _: u16, _: bool) void {
                unreachable;
            }
            pub fn beginModelMaterial(_: *@This()) void {}
        };
        const Materials = struct {
            applications: *usize,
            pub fn apply(self: @This(), _: *Context, _: u16) void {
                self.applications.* += 1;
            }
        };
    };
    const vertices = [_]geometry.VertexPair{.{
        .pos_a = .{ 0, 0, 0 },
        .normal_a = 0,
        .pos_b = .{ 1, 0, 0 },
        .normal_b = 0,
        .color_a = .fromBytes(255, 255, 255, 255),
        .color_b = .fromBytes(255, 255, 255, 255),
    }};
    const strip_indices = [_]i16{ 0, 0x0024, 0x4000 };
    const parts = [_]Part{
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 2, .vertex_count = 2 },
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 2, .vertex_count = 2 },
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 7, .vertex_count = 2, .data_usage = .dynamic },
    };
    var context: Testing.Context = .{};
    var applications: usize = 0;
    drawing.draw(&context, .{ .parts = &parts }, Testing.Materials{ .applications = &applications });
    try @import("std").testing.expectEqual(@as(usize, 6), context.loads);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), applications);
    try @import("std").testing.expectEqual(@as(usize, 3), context.syncs);
    try @import("std").testing.expectEqual(@as(usize, 1), context.dynamic_loads);
    try @import("std").testing.expectEqual(@as(usize, 1), context.dynamic_draws);

    const previous: math.FixedMat4 align(16) = .identity;
    var transform: math.FixedMat4 align(16) = .identity;
    transform.set(3, 0, 4);
    context = .{ .matrix = &previous, .expected_matrix = &transform };
    applications = 0;
    const asset: @import("model_asset.zig").ModelAsset(Testing.Materials) = .{
        .model = .{ .parts = &parts },
        .materials = .{ .applications = &applications },
    };
    drawing.drawWithTransform(&context, asset, &transform);
    try @import("std").testing.expect(!context.wrong_matrix);
    try @import("std").testing.expect(context.matrix == &previous);
    try @import("std").testing.expectEqual(@as(usize, 1), context.pushes);
    try @import("std").testing.expectEqual(@as(usize, 1), context.pops);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), applications);
    var empty = asset;
    empty.model.parts = &.{};
    drawing.drawWithTransform(&context, empty, &transform);
    try @import("std").testing.expect(context.matrix == &previous);
    try @import("std").testing.expectEqual(@as(usize, 2), context.pushes);
    try @import("std").testing.expectEqual(@as(usize, 2), context.pops);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), applications);
}

test "asset overrides preserve embedded bindings, compose, and bind typed textures" {
    const std = @import("std");
    const rdp = @import("../rdp.zig");
    const colors = @import("pixel.zig");
    const image = @import("image.zig");
    const Fixture = struct {
        const pixels = [_]colors.Rgba16{.white} ** 4;
        const other_pixels = [_]colors.Rgba16{.red} ** 4;
        const texture: image.ConstImage(colors.Rgba16) = .{ .width = 2, .height = 2, .texel_data = &pixels };
        const other: image.ConstImage(colors.Rgba16) = .{ .width = 2, .height = 2, .texel_data = &other_pixels };
        const Context = struct {
            render: rdp.RenderEncoder(rdp.backend.Direct),
            fog_enabled: bool = true,
            flags: geometry.DrawFlags = .{},
            fallback_bindings: usize = 0,
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
        const Materials = struct {
            pub fn get(_: @This(), _: u16) Material {
                return .{ .flags = .{ .depth = true, .textured = true }, .sampler = .{ .mask_t = 3 }, .combine = .shade };
            }
            pub fn bind(_: @This(), context: *Context, _: u16, material: Material) void {
                context.fallback_bindings += 1;
                material.bind(context, texture);
            }
        };
    };
    const original: @import("model_asset.zig").ModelAsset(Fixture.Materials) = .{ .model = .{ .parts = &.{} }, .materials = .{} };
    const overridden = original.withOverrides(.{
        .{ .fog = false, .no_light = true },
        .{ .index = 1, .texture = Fixture.other, .sampler = rdp.Sampler{ .mask_s = 1 } },
    }).withOverrides(.{.{ .index = 1, .no_light = false, .primitive = colors.Rgba32.red }});
    try std.testing.expect(overridden.material(0).flags.no_light);
    try std.testing.expect(!overridden.material(1).flags.no_light);
    try std.testing.expectEqual(colors.Rgba32.red, overridden.material(1).primitive.?);
    try std.testing.expectEqual(@as(?bool, null), original.material(0).fog);
    const literal_override = original.withOverrides(.{.{ .sampler = .{ .mask_s = 2 }, .flags = .{ .shaded = true }, .primitive = colors.Rgba32.blue }});
    try std.testing.expectEqual(@as(u4, 2), literal_override.material(0).sampler.mask_s);
    try std.testing.expectEqual(@as(u4, 3), literal_override.material(0).sampler.mask_t);
    try std.testing.expect(literal_override.material(0).flags.depth);
    try std.testing.expect(literal_override.material(0).flags.shaded);
    try std.testing.expectEqual(colors.Rgba32.blue, literal_override.material(0).primitive.?);
    var commands: [256]u64 = undefined;
    var context: Fixture.Context = .{ .render = .init(.{ .buffer = &commands }) };
    overridden.materials.apply(&context, 0);
    try std.testing.expectEqual(@as(usize, 1), context.fallback_bindings);
    try std.testing.expectEqual(@intFromPtr(Fixture.pixels[0..].ptr), context.render.tex_cache[0].ptr);
    overridden.materials.apply(&context, 1);
    try std.testing.expectEqual(@as(usize, 1), context.fallback_bindings);
    try std.testing.expectEqual(@intFromPtr(Fixture.other_pixels[0..].ptr), context.render.tex_cache[1].ptr);
    try std.testing.expectEqual(@as(u4, 1), context.render.tex_cache[1].sampler.mask_s);
    try std.testing.expect(!context.fog_enabled);
    const pair = original.withOverrides(.{.{ .texture = Fixture.texture, .second_texture = Fixture.other }});
    pair.materials.apply(&context, 0);
    try std.testing.expectEqual(@as(usize, 1), context.fallback_bindings);
    const replacement: Model = .{ .parts = &.{}, .animations = &.{.{ .name = "idle", .duration = 1, .tracks = &.{} }} };
    try std.testing.expect(overridden.withModel(replacement).model.findAnimation("idle") != null);
    try std.testing.expect(replacement.findAnimation("missing") == null);
}

test {
    _ = @import("model/material_ids.zig");
}
