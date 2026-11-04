//! Declarative material overrides applied to plain `Material` data.
//! Entries form a tuple of anonymous structs whose keys are validated at
//! compile time; their values may be runtime data.
const std = @import("std");
const Material = @import("../Material.zig");
const Texture = @import("../Texture.zig");

/// Apply every matching entry to `materials` in order, so later entries win.
/// Entries without `index` affect every material.
pub fn applyAll(materials: []Material, entries: anytype) void {
    comptime validateEntries(@TypeOf(entries));
    for (materials, 0..) |*material, index| {
        inline for (entries) |entry| {
            if (matches(entry, index)) applyEntry(material, entry);
        }
    }
}

fn matches(entry: anytype, index: usize) bool {
    return if (@hasField(@TypeOf(entry), "index")) entry.index == index else true;
}

fn applyEntry(material: *Material, entry: anytype) void {
    const Entry = @TypeOf(entry);
    if (@hasField(Entry, "material")) replaceState(material, entry.material);
    inline for (std.meta.fields(Material)) |field| {
        if (comptime isTextureField(field.name)) continue;
        if (@hasField(Entry, field.name)) overrideValue(&@field(material, field.name), @field(entry, field.name));
    }
    if (@hasField(Entry, "no_light")) material.flags.no_light = entry.no_light;
    if (@hasField(Entry, "texture")) {
        material.texture = .from(entry.texture);
        // A texture without a partner replaces any earlier pair.
        material.second_texture = if (@hasField(Entry, "second_texture")) Texture.from(entry.second_texture) else null;
    }
}

/// `.material` replaces render state; textures are kept unless it names its own.
fn replaceState(material: *Material, replacement: Material) void {
    const texture = material.texture;
    const second_texture = material.second_texture;
    material.* = replacement;
    if (replacement.texture == null) {
        material.texture = texture;
        material.second_texture = second_texture;
    }
}

fn overrideValue(destination: anytype, value: anytype) void {
    const Value = @TypeOf(value);
    const Target = @TypeOf(destination.*);
    if (comptime Value != Target and isStruct(Value) and isStruct(Target)) {
        inline for (std.meta.fields(Value)) |field| {
            if (!@hasField(Target, field.name)) @compileError("unknown material override field: " ++ field.name);
            overrideValue(&@field(destination, field.name), @field(value, field.name));
        }
    } else destination.* = value;
}

fn isStruct(comptime Value: type) bool {
    return std.meta.activeTag(@typeInfo(Value)) == .@"struct";
}

fn isTextureField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "texture") or std.mem.eql(u8, name, "second_texture");
}

const special_fields = std.StaticStringMap(void).initComptime(.{
    .{ "index", {} }, .{ "material", {} }, .{ "no_light", {} },
});

fn validateEntries(comptime Entries: type) void {
    // Validate each entry's keys so misspellings cannot silently leave imported state.
    inline for (std.meta.fields(Entries)) |field| validateEntry(field.type);
}

fn validateEntry(comptime Entry: type) void {
    inline for (std.meta.fields(Entry)) |field| validateField(field.name);
    if (@hasField(Entry, "second_texture") and !@hasField(Entry, "texture"))
        @compileError("second_texture requires texture in the same entry");
}

fn validateField(comptime name: []const u8) void {
    if (!@hasField(Material, name) and !special_fields.has(name)) @compileError("unknown material override: " ++ name);
}

test "entries compose in order, merge nested state and keep earlier textures" {
    const pixel = @import("../pixel.zig");
    const image = @import("../image.zig");
    const texels = [_]pixel.Rgba16{.white} ** 4;
    const other_texels = [_]pixel.Rgba16{.red} ** 4;
    const crate: image.ConstImage(pixel.Rgba16) = .{ .width = 2, .height = 2, .texel_data = &texels };
    const other: image.ConstImage(pixel.Rgba16) = .{ .width = 2, .height = 2, .texel_data = &other_texels };
    const base: Material = .{ .flags = .{ .depth = true, .textured = true }, .sampler = .{ .mask_t = 3 }, .texture = .from(crate) };
    var materials = [_]Material{ base, base };
    applyAll(&materials, .{
        .{ .fog = false, .no_light = true },
        .{ .index = 1, .texture = other, .sampler = .{ .mask_s = 1 } },
        .{ .index = 1, .no_light = false, .primitive = pixel.Rgba32.red },
    });
    try std.testing.expect(materials[0].flags.no_light);
    try std.testing.expect(!materials[1].flags.no_light);
    try std.testing.expectEqual(@as(?bool, false), materials[0].fog);
    try std.testing.expectEqual(pixel.Rgba32.red, materials[1].primitive.?);
    try std.testing.expectEqual(@as(u4, 1), materials[1].sampler.mask_s);
    try std.testing.expectEqual(@as(u4, 3), materials[1].sampler.mask_t);
    try std.testing.expectEqual(@intFromPtr(&texels), @intFromPtr(materials[0].texture.?.texels));
    try std.testing.expectEqual(@intFromPtr(&other_texels), @intFromPtr(materials[1].texture.?.texels));

    applyAll(&materials, .{.{ .index = 0, .texture = crate, .second_texture = other }});
    try std.testing.expectEqual(@intFromPtr(&other_texels), @intFromPtr(materials[0].second_texture.?.texels));
    applyAll(&materials, .{.{ .index = 0, .texture = other }});
    try std.testing.expect(materials[0].second_texture == null);
}

test "material replacement keeps textures unless the replacement supplies one" {
    const texels = [_]u8{0} ** 16;
    const texture: Texture = .{ .format = .intensity, .bit_depth = .@"8", .width = 4, .height = 4, .texels = &texels };
    var materials = [_]Material{.{ .texture = texture, .fog = true }};
    applyAll(&materials, .{.{ .material = Material{ .alpha_cutoff = 9 } }});
    try std.testing.expectEqual(@as(?u8, 9), materials[0].alpha_cutoff);
    try std.testing.expectEqual(@as(?bool, null), materials[0].fog);
    try std.testing.expect(materials[0].texture != null);
    var replaced = texture;
    replaced.width = 2;
    applyAll(&materials, .{.{ .material = Material{ .texture = replaced } }});
    try std.testing.expectEqual(@as(u16, 2), materials[0].texture.?.width);
}
