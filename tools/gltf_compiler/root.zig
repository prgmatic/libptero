const compiler = @import("compiler.zig");

pub const Glb = compiler.Glb;
pub const Document = compiler.Document;
pub const ConvertOptions = compiler.ConvertOptions;
pub const TextureSize = compiler.TextureSize;
pub const parseTextureSize = compiler.parseTextureSize;
pub const ConvertedModel = compiler.ConvertedModel;
pub const Generated = compiler.Generated;

pub const parseGlb = compiler.parseGlb;
pub const parseDocument = compiler.parseDocument;
pub const convert = compiler.convert;
pub const generate = compiler.generate;
pub const generateWithStorage = compiler.generateWithStorage;

test {
    _ = compiler;
    _ = @import("material_ids.zig");
    _ = @import("rigid_skin.zig");
    _ = @import("rig.zig");
    _ = @import("node_transforms.zig");
}
