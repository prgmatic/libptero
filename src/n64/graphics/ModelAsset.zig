//! A model's packed geometry paired with its material table. Every generated
//! or loaded model has this one type, so assets can be stored in variables,
//! arrays, and struct fields and chosen at runtime.
const std = @import("std");
const Model = @import("Model.zig");
const Material = @import("Material.zig");
const material_ids = @import("model/material_ids.zig");
const overrides = @import("model/material_overrides.zig");

const ModelAsset = @This();

/// Part index for geometry without a source material; draws with `Material{}`.
pub const unassigned_material: u16 = 0xffff;

model: Model,
/// Indexed by `Model.Part.material_index`. Read on the CPU while encoding;
/// only texture storage must outlive GPU completion.
materials: []const Material = &.{},
/// Source material names, parallel to `materials`.
material_names: []const []const u8 = &.{},

/// Resolve an exact source material name at compile time, without runtime
/// lookup. The asset must be comptime-known; use `findMaterial` otherwise.
// Inline rather than `comptime self`: Zig 0.16 crashes on a runtime receiver there.
pub inline fn materialIndex(self: ModelAsset, comptime name: []const u8) u16 {
    return comptime material_ids.index(self.material_names, name);
}

/// Runtime lookup of an exact source material name.
pub fn findMaterial(self: ModelAsset, name: []const u8) ?u16 {
    for (self.material_names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(index);
    }
    return null;
}

/// Read a material without drawing or binding it.
pub fn material(self: ModelAsset, index: u16) Material {
    return materialAt(self.materials, index).*;
}

/// Matrices a pose for this model needs: one per skeleton node, which
/// includes non-joint nodes such as a skinned mesh's own node. Size
/// pose buffers with this (comptime-known for generated assets).
pub fn poseLen(self: ModelAsset) usize {
    return self.model.nodes.len;
}

/// Replace borrowed geometry while retaining this asset's materials.
pub fn withModel(self: ModelAsset, model: Model) ModelAsset {
    var result = self;
    result.model = model;
    return result;
}

/// Replace the material table, for example with an edited copy.
pub fn withMaterials(self: ModelAsset, materials: []const Material) ModelAsset {
    var result = self;
    result.materials = materials;
    return result;
}

/// Compile-time material overrides for a comptime-known asset, stored in
/// static memory. Entries form a tuple; omit index to affect every material.
/// Later entries win. Use `withOverridesInto` for runtime assets or values.
// Inline rather than `comptime self`: Zig 0.16 crashes on a runtime receiver there.
pub inline fn withOverrides(self: ModelAsset, comptime entries: anytype) ModelAsset {
    const materials = comptime blk: {
        // Each material visits every entry and Material field.
        @setEvalBranchQuota(10_000 + self.materials.len * 4_000);
        var copy: [self.materials.len]Material = self.materials[0..self.materials.len].*;
        overrides.applyAll(&copy, entries);
        break :blk copy;
    };
    return self.withMaterials(&materials);
}

/// Copy the materials into caller storage and apply overrides with runtime
/// values. `storage` must hold at least as many materials as this asset and
/// stay alive while the result is drawn or recorded.
pub fn withOverridesInto(self: ModelAsset, storage: []Material, entries: anytype) error{BufferTooSmall}!ModelAsset {
    if (storage.len < self.materials.len) return error.BufferTooSmall;
    const copy = storage[0..self.materials.len];
    @memcpy(copy, self.materials);
    overrides.applyAll(copy, entries);
    return self.withMaterials(copy);
}

const default_material: Material = .{};

/// The material for a part's index; unassigned geometry uses the default.
pub fn materialAt(materials: []const Material, index: u16) *const Material {
    if (index == unassigned_material) return &default_material;
    if (index >= materials.len) @panic("invalid model material index");
    return &materials[index];
}

test "assets look up materials by name and treat unassigned geometry as default" {
    const materials = [_]Material{ .{ .fog = true }, .{ .alpha_cutoff = 4 } };
    const names = [_][]const u8{ "body", "visor" };
    const asset: ModelAsset = .{ .model = .{ .parts = &.{} }, .materials = &materials, .material_names = &names };
    try std.testing.expectEqual(@as(u16, 1), comptime asset.materialIndex("visor"));
    try std.testing.expectEqual(@as(?u16, 0), asset.findMaterial("body"));
    try std.testing.expectEqual(@as(?u16, null), asset.findMaterial("missing"));
    try std.testing.expectEqual(@as(?u8, 4), asset.material(1).alpha_cutoff);
    try std.testing.expectEqual(@as(?bool, null), asset.material(unassigned_material).fog);
    const replacement: Model = .{ .parts = &.{}, .animations = &.{.{ .name = "idle", .duration = 1, .tracks = &.{} }} };
    try std.testing.expect(asset.withModel(replacement).model.findAnimation("idle") != null);
    try std.testing.expectEqual(@as(usize, 2), asset.withModel(replacement).materials.len);
}

test "compile-time and caller-storage overrides leave the source table unchanged" {
    const materials = [_]Material{ .{}, .{} };
    const asset: ModelAsset = comptime .{ .model = .{ .parts = &.{} }, .materials = &materials };
    const fogless = comptime asset.withOverrides(.{.{ .index = 1, .fog = false }});
    try std.testing.expectEqual(@as(?bool, false), fogless.material(1).fog);
    try std.testing.expectEqual(@as(?bool, null), fogless.material(0).fog);
    try std.testing.expectEqual(@as(?bool, null), asset.material(1).fog);

    var storage: [2]Material = undefined;
    var cutoff: u8 = 7;
    _ = &cutoff;
    const runtime = try asset.withOverridesInto(&storage, .{.{ .alpha_cutoff = cutoff }});
    try std.testing.expectEqual(@as(?u8, 7), runtime.material(0).alpha_cutoff);
    try std.testing.expectEqual(@as(?u8, null), asset.material(0).alpha_cutoff);
    try std.testing.expectError(error.BufferTooSmall, asset.withOverridesInto(storage[0..1], .{}));
}
