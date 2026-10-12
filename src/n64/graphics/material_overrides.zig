const std = @import("std");
const Material = @import("material.zig").Material;

/// Providers expose get(index) and bind(context, index, material), allowing
/// ordinary overrides to preserve a generated provider's embedded textures.
pub fn Provider(comptime Base: type, comptime Entries: type) type {
    comptime validateEntries(Entries);
    return struct {
        base: Base,
        entries: Entries,
        pub const material_names = if (@hasDecl(Base, "material_names")) Base.material_names else [_][]const u8{};

        pub fn get(self: @This(), index: u16) Material {
            var material = self.base.get(index);
            inline for (self.entries) |entry| {
                if (matches(entry, index)) applyFields(&material, entry);
            }
            return material;
        }

        pub fn apply(self: @This(), context: anytype, index: u16) void {
            self.bind(context, index, self.get(index));
        }

        pub fn bind(self: @This(), context: anytype, index: u16, material: Material) void {
            // Find the last texture binding, just as get applies the last state
            // override. State-only entries retain preceding texture bindings.
            inline for (0..std.meta.fields(Entries).len) |i| {
                const entry = self.entries[std.meta.fields(Entries).len - 1 - i];
                if (comptime @hasField(@TypeOf(entry), "texture")) {
                    if (matches(entry, index)) {
                        bindTextures(material, context, entry);
                        return;
                    }
                }
            }
            self.base.bind(context, index, material);
        }
    };
}

fn matches(entry: anytype, index: u16) bool {
    return if (@hasField(@TypeOf(entry), "index")) entry.index == index else true;
}

fn applyFields(material: *Material, entry: anytype) void {
    if (@hasField(@TypeOf(entry), "material")) material.* = entry.material;
    inline for (std.meta.fields(Material)) |field| {
        if (@hasField(@TypeOf(entry), field.name)) overrideValue(&@field(material, field.name), @field(entry, field.name));
    }
    if (@hasField(@TypeOf(entry), "no_light")) material.flags.no_light = entry.no_light;
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

fn bindTextures(material: Material, context: anytype, entry: anytype) void {
    if (@hasField(@TypeOf(entry), "second_texture")) {
        material.apply(context);
        context.render.useTexturePair(entry.texture, entry.second_texture, material.sampler, material.second_sampler);
    } else material.bind(context, entry.texture);
}

const special_fields = std.StaticStringMap(void).initComptime(.{
    .{ "index", {} },          .{ "material", {} }, .{ "texture", {} },
    .{ "second_texture", {} }, .{ "no_light", {} },
});

fn validateEntries(comptime Entries: type) void {
    // Iteration in get/bind enforces the tuple contract; validate each entry's
    // keys separately so misspellings cannot silently leave imported state.
    inline for (std.meta.fields(Entries)) |field| validateEntry(field.type);
}

fn validateEntry(comptime Entry: type) void {
    inline for (std.meta.fields(Entry)) |field| validateField(field.name);
    validateTexturePair(Entry);
}

fn validateField(comptime name: []const u8) void {
    if (!allowedField(name)) @compileError("unknown material override: " ++ name);
}

fn allowedField(comptime name: []const u8) bool {
    return @hasField(Material, name) or special_fields.has(name);
}

fn validateTexturePair(comptime Entry: type) void {
    if (@hasField(Entry, "second_texture")) requireTexture(Entry);
}

fn requireTexture(comptime Entry: type) void {
    if (!@hasField(Entry, "texture")) @compileError("second_texture requires texture in the same entry");
}
