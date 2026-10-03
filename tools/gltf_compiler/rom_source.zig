//! ROM-backed native model source. Data packing remains in compiler.zig.
const std = @import("std");
const compiler = @import("compiler.zig");
const rig = @import("rig.zig");

pub fn generate(allocator: std.mem.Allocator, model: compiler.ConvertedModel, document: compiler.Document, binary: []const u8, name: []const u8) !compiler.Generated {
    if (!std.zig.isValidId(name)) return error.InvalidAssetName;
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    var bindings: std.ArrayList(u8) = .empty;
    defer bindings.deinit(allocator);
    try source.appendSlice(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\const VertexPair = n64.graphics.geometry.VertexPair;
        \\const Part = n64.graphics.model.Part;
        \\
    );
    try compiler.emitInfluences(allocator, &source, model.batches);
    try compiler.emitBatchData(allocator, &data, &bindings, model.batches);
    try markGroupSlices(allocator, &bindings, model.batches);
    try compiler.emitImagesWithStorage(allocator, &data, &source, document, binary, true);
    try rig.emit(allocator, &source, document, binary, model.scale);
    try emitBinding(allocator, &source, bindings.items, model.batches, name, data.items.len);
    try emitMaterialPrefix(allocator, &source, document);
    try compiler.emitMaterialsWithStorage(allocator, &source, document, binary, true);
    const payload = try data.toOwnedSlice(allocator);
    errdefer allocator.free(payload);
    return .{ .data = payload, .source = try source.toOwnedSlice(allocator) };
}

fn emitBinding(allocator: std.mem.Allocator, source: *std.ArrayList(u8), bindings: []const u8, batches: []const compiler.Batch, name: []const u8, byte_len: usize) !void {
    try compiler.appendFormat(allocator, source,
        \\pub const {s}: n64.rom.TypedAsset(Definition) = .{{ .asset = @import("rom_data").{s} }};
        \\pub const Definition = struct {{
        \\    pub const byte_len = {d};
        \\    pub const Value = n64.graphics.model.Asset(Materials);
        \\    pub const Storage = struct {{ parts: [{d}]Part }};
        \\    pub fn bind(model_data: []align(16) const u8, metadata: *Storage, content_id: u64) Value {{
        \\
    , .{ name, name, byte_len, partCount(batches) });
    try source.appendSlice(allocator, bindings);
    try source.appendSlice(allocator, "metadata.parts = .{\n");
    try compiler.emitPartEntries(allocator, source, batches);
    try source.appendSlice(allocator,
        \\};
        \\return .{ .model = .{ .parts = &metadata.parts, .nodes = &nodes, .skins = &skins, .animations = &animations }, .materials = .{ .data = model_data, .content_id = content_id } };
        \\    }
        \\};
    );
}

fn emitMaterialPrefix(allocator: std.mem.Allocator, source: *std.ArrayList(u8), document: compiler.Document) !void {
    try source.appendSlice(allocator,
        \\pub const Materials = struct {
        \\    data: []align(16) const u8,
        \\    content_id: u64,
        \\    pub fn apply(self: @This(), context: anytype, index: u16) void {
        \\        self.bind(context, index, self.get(index));
        \\    }
        \\    pub fn bind(self: @This(), context: anytype, index: u16, material: n64.graphics.model.Material) void {
        \\
    );
    // emitMaterials also writes the closing switch and native material accessor.
    const has_textures = for (document.materials) |material| {
        if (compiler.materialImageIndex(document, material) != null) break true;
    } else false;
    if (!has_textures) try source.appendSlice(allocator, "        _ = self;\n");
    try source.appendSlice(allocator, "        switch (index) {\n");
}

fn partCount(batches: []const compiler.Batch) usize {
    var count: usize = 0;
    for (batches) |batch| count += @max(1, batch.groups.len);
    return count;
}

fn markGroupSlices(allocator: std.mem.Allocator, bindings: *std.ArrayList(u8), batches: []const compiler.Batch) !void {
    // Joint-grouped parts reference group slices rather than the full slice.
    for (batches, 0..) |batch, index| if (batch.groups.len != 0) {
        try compiler.appendFormat(allocator, bindings, "_ = vertices_{d};\n", .{index});
    };
}
