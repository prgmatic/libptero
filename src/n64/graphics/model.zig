const animation = @import("animation.zig");
pub const SkinnedModel = @import("skinned_model.zig").SkinnedModel;
const math = @import("../math.zig");
const geometry = @import("geometry.zig");
pub const Material = @import("material.zig").Material;

/// A model is stored as already-packed vertex batches. Strip entries contain
/// vertex-buffer-relative byte offsets plus the RSP strip control flags; the
/// linked geometry overlay relocates them to its actual DMEM vertex buffer.
/// The asset compiler splits primitives so every part fits in that workspace.
pub const Model = struct {
    parts: []const Part,
    nodes: []const animation.Node = &.{},
    skins: []const animation.Skin = &.{},
    animations: []const animation.Clip = &.{},
};

/// Borrowed model geometry and a typed material provider. Drawing lives on the
/// geometry context; providers retain compile-time texture types without vtables.
pub fn Asset(comptime Materials: type) type {
    return struct {
        model: Model,
        materials: Materials,

        /// Read native material metadata without drawing or binding it.
        pub fn material(_: @This(), index: u16) Material {
            return Materials.get(index);
        }
    };
}

/// Submit packed parts through a context with a caller-supplied material provider.
/// Providers implement apply(context, index); geometry and materials are borrowed.
pub fn draw(context: anytype, model: Model, materials: anytype) void {
    var active_material: ?u16 = null;
    for (model.parts) |part| {
        if (active_material == null or active_material.? != part.material_index) {
            materials.apply(context, part.material_index);
            context.beginModelMaterial();
            active_material = part.material_index;
        }
        switch (part.data_usage) {
            .immutable => {
                context.loadStaticVertices(part.vertices, part.vertex_offset, part.vertex_count);
                context.drawStaticTriangleStrip(part.strip_indices, true);
            },
            .dynamic => {
                context.loadVertices(part.vertices, part.vertex_offset, part.vertex_count);
                context.drawTriangleStrip(part.strip_indices, true);
            },
        }
    }
}

/// Scope a model draw to a borrowed transform, restoring the previous matrix.
/// The matrix must remain unchanged and alive until GPU completion. This does
/// not allocate, copy the matrix, wait, or restore material/pipeline state.
pub fn drawWithTransform(context: anytype, asset: anytype, matrix: *const math.FixedMat4) void {
    context.pushMatrix(matrix);
    defer context.popMatrix();
    draw(context, asset.model, asset.materials);
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
    draw(&context, .{ .parts = &parts }, Testing.Materials{ .applications = &applications });
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
    const asset: Asset(Testing.Materials) = .{
        .model = .{ .parts = &parts },
        .materials = .{ .applications = &applications },
    };
    drawWithTransform(&context, asset, &transform);
    try @import("std").testing.expect(!context.wrong_matrix);
    try @import("std").testing.expect(context.matrix == &previous);
    try @import("std").testing.expectEqual(@as(usize, 1), context.pushes);
    try @import("std").testing.expectEqual(@as(usize, 1), context.pops);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), applications);
    var empty = asset;
    empty.model.parts = &.{};
    drawWithTransform(&context, empty, &transform);
    try @import("std").testing.expect(context.matrix == &previous);
    try @import("std").testing.expectEqual(@as(usize, 2), context.pushes);
    try @import("std").testing.expectEqual(@as(usize, 2), context.pops);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), applications);
}
