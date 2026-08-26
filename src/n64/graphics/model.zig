const geometry = @import("geometry.zig");

/// A model is stored as already-packed, hardware-ready vertex batches.  The
/// asset compiler is responsible for splitting a glTF primitive so every part
/// fits in the RSP vertex cache.
pub const Model = struct {
    parts: []const Part,

    /// Draw all model parts. `materials` may be any value exposing
    /// `apply(context, material_index)`; this keeps texture types known at
    /// compile time in generated asset modules.
    pub fn draw(self: Model, context: anytype, materials: anytype) void {
        var active_material: ?u16 = null;
        for (self.parts, 0..) |part, part_index| {
            if (active_material == null or active_material.? != part.material_index) {
                materials.apply(context, part.material_index);
                context.beginModelMaterial();
                active_material = part.material_index;
            }
            context.loadVertices(part.vertices, part.vertex_offset, part.vertex_count);
            context.drawTriangleStrip(part.strip_indices, true);
            context.finishModelPart(part_index + 1 != self.parts.len);
        }
    }
};

pub const Part = struct {
    vertices: []const geometry.VertexPair,
    material_index: u16,
    vertex_offset: u8 = 0,
    vertex_count: u8,
    strip_indices: []const i16 = &.{},
};

test "model applies changed materials and submits packed batches" {
    const Testing = struct {
        const Context = struct {
            loads: usize = 0,
            draws: usize = 0,
            syncs: usize = 0,

            pub fn loadVertices(self: *@This(), _: []const geometry.VertexPair, _: u8, count: u8) void {
                self.loads += count;
            }
            pub fn drawTriangleStrip(self: *@This(), indices: []const i16, _: bool) void {
                self.draws += indices.len / 3;
                self.syncs += 1;
            }
            pub fn finishModelPart(self: *@This(), _: bool) void {
                self.syncs += 1;
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
    const strip_indices = [_]i16{ 0x0408, 0x042c, 0x4408 };
    const parts = [_]Part{
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 2, .vertex_count = 2 },
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 2, .vertex_count = 2 },
        .{ .vertices = &vertices, .strip_indices = &strip_indices, .material_index = 7, .vertex_count = 2 },
    };
    var context: Testing.Context = .{};
    var applications: usize = 0;
    (Model{ .parts = &parts }).draw(&context, Testing.Materials{ .applications = &applications });
    try @import("std").testing.expectEqual(@as(usize, 6), context.loads);
    try @import("std").testing.expectEqual(@as(usize, 3), context.draws);
    try @import("std").testing.expectEqual(@as(usize, 2), applications);
    try @import("std").testing.expectEqual(@as(usize, 6), context.syncs);
}
