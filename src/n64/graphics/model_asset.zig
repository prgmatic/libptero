const Model = @import("Model.zig");
const Material = @import("Material.zig");
pub fn ModelAsset(comptime Materials: type) type {
    return struct {
        model: Model,
        materials: Materials,
        pub const material_names = if (@hasDecl(Materials, "material_names")) Materials.material_names else [_][]const u8{};

        /// Resolve an exact source material name at compile time, without runtime lookup.
        pub fn materialIndex(_: @This(), comptime name: []const u8) u16 {
            return @import("model/material_ids.zig").index(&material_names, name);
        }

        /// Read native material metadata without drawing or binding it.
        pub fn material(self: @This(), index: u16) Material {
            return self.materials.get(index);
        }

        /// Replace borrowed geometry while retaining this asset's materials.
        pub fn withModel(self: @This(), model: Model) @This() {
            return .{ .model = model, .materials = self.materials };
        }

        /// Declarative material/texture overrides. Entries form a heterogeneous
        /// tuple; omit index to affect every material. Later entries win.
        pub fn withOverrides(self: @This(), entries: anytype) ModelAsset(@import("model/material_overrides.zig").Provider(Materials, @TypeOf(entries))) {
            return .{ .model = self.model, .materials = .{ .base = self.materials, .entries = entries } };
        }
    };
}
