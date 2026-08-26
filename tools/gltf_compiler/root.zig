const compiler = @import("compiler.zig");

pub const Glb = compiler.Glb;
pub const Document = compiler.Document;
pub const ConvertOptions = compiler.ConvertOptions;
pub const ConvertedModel = compiler.ConvertedModel;
pub const Generated = compiler.Generated;

pub const parseGlb = compiler.parseGlb;
pub const parseDocument = compiler.parseDocument;
pub const convert = compiler.convert;
pub const generate = compiler.generate;

test {
    _ = compiler;
}
