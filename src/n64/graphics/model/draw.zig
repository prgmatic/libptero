//! Borrowed model traversal shared by geometry encoding and recorded draws.
const Model = @import("../Model.zig");
const math = @import("../../math.zig");

pub fn draw(context: anytype, model: Model, materials: anytype) void {
    var active_material: ?u16 = null;
    var bone_active = false;
    defer if (bone_active) context.popMatrix();
    for (model.parts) |part| {
        if (active_material == null or active_material.? != part.material_index) {
            materials.apply(context, part.material_index);
            context.beginModelMaterial();
            active_material = part.material_index;
        }
        if (part.bone) |bone| {
            if (bone_active) context.setBoneMatrix(bone, false) else context.setBoneMatrix(bone, true);
            bone_active = true;
        } else if (bone_active) {
            context.popMatrix();
            bone_active = false;
        }
        switch (part.data_usage) {
            .immutable => {
                context.loadStaticVertices(part.vertices, part.vertex_offset, part.vertex_count);
                if (part.strip_indices.len != 0) context.drawStaticTriangleStrip(part.strip_indices, true);
            },
            .dynamic => {
                context.loadVertices(part.vertices, part.vertex_offset, part.vertex_count);
                if (part.strip_indices.len != 0) context.drawTriangleStrip(part.strip_indices, true);
            },
        }
    }
}

pub fn drawWithTransform(context: anytype, asset: anytype, matrix: *const math.FixedMat4) void {
    context.pushMatrix(matrix);
    defer context.popMatrix();
    draw(context, asset.model, asset.materials);
}
