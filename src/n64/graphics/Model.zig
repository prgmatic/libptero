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
    strip_indices: []align(8) const i16 = &.{},
    data_usage: DataUsage = .immutable,
    /// Global node index for bind-local RSP skinning; the pose is set on Context.
    bone: ?u16 = null,
    skin: ?u16 = null,
    influences: []const animation.Influence = &.{},
};

test "model applies changed materials and submits packed batches" {
    const Testing = struct {
        const Context = struct {
            render: @import("../rdp.zig").RenderEncoder(@import("../rdp.zig").backend.Direct) = undefined,
            fog_enabled: bool = false,
            applications: usize = 0,
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
            pub fn drawStaticTriangleStrip(self: *@This(), indices: []align(8) const i16, _: bool) void {
                if (self.expected_matrix) |expected| {
                    if (self.matrix != expected) self.wrong_matrix = true;
                }
                self.draws += indices.len / 3;
                self.syncs += 1;
            }
            pub fn drawTriangleStrip(self: *@This(), indices: []align(8) const i16, sync: bool) void {
                self.dynamic_draws += 1;
                self.drawStaticTriangleStrip(indices, sync);
            }
            pub fn setBoneMatrix(_: *@This(), _: u16, _: bool) void {
                unreachable;
            }
            pub fn beginModelMaterial(_: *@This()) void {}
            pub fn setDrawFlags(self: *@This(), _: geometry.DrawFlags) void {
                self.applications += 1;
            }
            pub fn setVertexEffect(_: *@This(), _: geometry.VertexEffect) void {}
            pub fn setFogEnabled(self: *@This(), enabled: bool) void {
                self.fog_enabled = enabled;
            }
        };
        const materials = [_]Material{.{}} ** 8;
    };
    var commands: [64]u64 = undefined;
    const vertices = [_]geometry.VertexPair{.{
        .pos_a = .{ 0, 0, 0 },
        .normal_a = 0,
        .pos_b = .{ 1, 0, 0 },
        .normal_b = 0,
        .color_a = .fromBytes(255, 255, 255, 255),
        .color_b = .fromBytes(255, 255, 255, 255),
    }};
    const strip_indices align(8) = [_]i16{ 0, 0x0024, 0x4000 };
    const parts = [_]Part{
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 2, .vertex_count = 2 },
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 2, .vertex_count = 2 },
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 7, .vertex_count = 2, .data_usage = .dynamic },
    };
    var context: Testing.Context = .{ .render = .init(.{ .buffer = &commands }) };
    drawing.draw(&context, .{ .parts = &parts }, &Testing.materials);
    try @import("std").testing.expectEqual(@as(usize, 6), context.loads);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), context.applications);
    try @import("std").testing.expectEqual(@as(usize, 3), context.syncs);
    try @import("std").testing.expectEqual(@as(usize, 1), context.dynamic_loads);
    try @import("std").testing.expectEqual(@as(usize, 1), context.dynamic_draws);

    const previous: math.FixedMat4 align(16) = .identity;
    var transform: math.FixedMat4 align(16) = .identity;
    transform.set(3, 0, 4);
    context = .{ .render = .init(.{ .buffer = &commands }), .matrix = &previous, .expected_matrix = &transform };
    const asset: @import("ModelAsset.zig") = .{ .model = .{ .parts = &parts }, .materials = &Testing.materials };
    drawing.drawWithTransform(&context, asset, &transform);
    try @import("std").testing.expect(!context.wrong_matrix);
    try @import("std").testing.expect(context.matrix == &previous);
    try @import("std").testing.expectEqual(@as(usize, 1), context.pushes);
    try @import("std").testing.expectEqual(@as(usize, 1), context.pops);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), context.applications);
    var empty = asset;
    empty.model.parts = &.{};
    drawing.drawWithTransform(&context, empty, &transform);
    try @import("std").testing.expect(context.matrix == &previous);
    try @import("std").testing.expectEqual(@as(usize, 2), context.pushes);
    try @import("std").testing.expectEqual(@as(usize, 2), context.pops);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), context.applications);
}

test "materials bind their own single and paired textures" {
    const std = @import("std");
    const rdp = @import("../rdp.zig");
    const colors = @import("pixel.zig");
    const Texture = @import("Texture.zig");
    const pixels = [_]colors.Rgba16{.white} ** 4;
    const other_pixels = [_]colors.Rgba16{.red} ** 4;
    const image = @import("image.zig");
    const texture: Texture = .from(image.ConstImage(colors.Rgba16){ .width = 2, .height = 2, .texel_data = &pixels });
    const other: Texture = .from(image.ConstImage(colors.Rgba16){ .width = 2, .height = 2, .texel_data = &other_pixels });
    const Context = struct {
        render: rdp.RenderEncoder(rdp.backend.Direct),
        fog_enabled: bool = true,
        pub fn setDrawFlags(_: *@This(), _: geometry.DrawFlags) void {}
        pub fn setVertexEffect(_: *@This(), _: geometry.VertexEffect) void {}
        pub fn setFogEnabled(self: *@This(), enabled: bool) void {
            self.fog_enabled = enabled;
        }
    };
    var commands: [256]u64 = undefined;
    var context: Context = .{ .render = .init(.{ .buffer = &commands }) };
    (Material{ .sampler = .{ .mask_s = 6 }, .texture = texture, .fog = false }).apply(&context);
    try std.testing.expect(!context.fog_enabled);
    try std.testing.expectEqual(@intFromPtr(&pixels), context.render.tex_cache[0].ptr);
    // Wrap masks are bounded by the bound texture's power-of-two size.
    try std.testing.expectEqual(@as(u4, 1), context.render.tex_cache[0].sampler.mask_s);
    (Material{ .texture = texture, .second_texture = other, .second_sampler = .{ .shift_s = 2 } }).apply(&context);
    try std.testing.expectEqual(@as(u3, 0), context.render.material_tile);
    try std.testing.expectEqual(@as(u10, 4), context.render.tmem_next);
    const before = context.render.cmd_queue.queue.index;
    (Material{}).apply(&context);
    try std.testing.expectEqual(@as(u10, 4), context.render.tmem_next);
    try std.testing.expect(context.render.cmd_queue.queue.index > before);
}

test {
    _ = @import("model/material_ids.zig");
}
