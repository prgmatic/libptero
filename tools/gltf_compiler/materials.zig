//! Legacy Fast64 metadata and native material source emission.
const std = @import("std");

/// Fast64 versions serialize checkboxes as either booleans or 0/1 numbers.
pub const Flag = enum(u1) {
    off,
    on,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Flag {
        return jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
    }
    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Flag {
        return switch (value) {
            .bool => |enabled| @enumFromInt(@intFromBool(enabled)),
            .integer => |number| numericFlag(number),
            else => error.UnexpectedToken,
        };
    }
};

pub const Extras = struct { f3d_mat: ?Fast64 = null };
fn numericFlag(number: i64) !Flag {
    return switch (number) {
        0 => .off,
        1 => .on,
        else => error.InvalidNumber,
    };
}
pub const Fast64 = struct {
    tex0: ?Texture = null,
    tex1: ?Texture = null,
    combiner1: ?Cycle = null,
    combiner2: ?Cycle = null,
    rdp_settings: Settings = .{},
    set_prim: Flag = .off,
    set_env: Flag = .off,
    prim_color: [4]f32 = .{ 1, 1, 1, 1 },
    env_color: [4]f32 = .{ 1, 1, 1, 1 },
};
pub const Texture = struct { S: ?Axis = null, T: ?Axis = null };
pub const Axis = struct {
    low: f32 = 0,
    high: f32,
    mask: u8 = 0,
    shift: i8 = 0,
    clamp: Flag = .off,
    mirror: Flag = .off,
};
pub const Settings = struct {
    g_zbuffer: Flag = .on,
    g_shade: Flag = .on,
    g_cull_front: Flag = .off,
    g_cull_back: Flag = .off,
    g_lighting: Flag = .on,
    g_fog: ?Flag = null,
    g_mdsft_text_filt: u8 = 2,
    g_mdsft_cycletype: u8 = 0,
};
pub const Cycle = struct {
    A: u8 = 8,
    B: u8 = 8,
    C: u8 = 16,
    D: u8 = 4,
    A_alpha: u8 = 7,
    B_alpha: u8 = 7,
    C_alpha: u8 = 7,
    D_alpha: u8 = 6,
};

pub const Sampler = struct {
    clamp_s: bool = false,
    clamp_t: bool = false,
    mirror_s: bool = false,
    mirror_t: bool = false,
    mask_s: u4 = 0,
    mask_t: u4 = 0,
    shift_s: u4 = 0,
    shift_t: u4 = 0,
};

pub fn legacy(material: anytype) ?Fast64 {
    return if (material.extras) |extras| extras.f3d_mat else null;
}

pub fn sampler(tex: ?Texture) !Sampler {
    const value = tex orelse return .{};
    var result: Sampler = .{};
    try axisSampler(value.S, &result.clamp_s, &result.mirror_s, &result.mask_s, &result.shift_s);
    try axisSampler(value.T, &result.clamp_t, &result.mirror_t, &result.mask_t, &result.shift_t);
    return result;
}

fn axisSampler(axis: ?Axis, clamp: *bool, mirror: *bool, mask: *u4, shift: *u4) !void {
    const value = axis orelse return;
    if (value.mask > 15 or value.shift < -5 or value.shift > 10) return error.UnsupportedFast64Sampler;
    clamp.* = value.clamp == .on;
    mirror.* = value.mirror == .on;
    mask.* = @intCast(value.mask);
    shift.* = @intCast(if (value.shift < 0) @as(i16, value.shift) + 16 else value.shift);
}

pub fn filter(material: anytype, point: bool) ![]const u8 {
    const f = legacy(material) orelse return if (point) "point" else "bilinear";
    const names = [_][]const u8{ "point", "median", "bilinear" };
    const index = f.rdp_settings.g_mdsft_text_filt;
    if (index >= names.len) return error.UnsupportedFast64Filter;
    return names[index];
}

pub fn emit(allocator: std.mem.Allocator, output: *std.ArrayList(u8), material: anytype, culling: anytype, blended: bool, has_image: bool, image_sampler: Sampler, filtering: []const u8) !void {
    const f = legacy(material);
    const flags = nativeFlags(f, culling, has_image);
    try validateFlags(flags);
    const first_sampler = if (f) |value| try sampler(value.tex0) else image_sampler;
    const second_sampler = if (f) |value| try sampler(value.tex1) else Sampler{};
    try append(allocator, output, ".{{ .flags = .{{ .depth = {}, .textured = {}, .shaded = {}, .cull_front = {}, .cull_back = {}, .no_light = {} }}, .translucent = {}, .filter = .{s}, ", .{
        flags.depth, flags.textured, flags.shaded, flags.cull_front, flags.cull_back, flags.no_light,
        blended,     filtering,
    });
    try emitSampler(allocator, output, "sampler", first_sampler);
    try emitSampler(allocator, output, "second_sampler", second_sampler);
    try emitMask(allocator, output, material);
    try emitCombiner(allocator, output, f, flags.textured, blended or material.alphaMode == .MASK);
    if (f) |value| try emitRegisters(allocator, output, value);
    try output.appendSlice(allocator, "}");
}

const NativeFlags = struct { depth: bool = true, textured: bool, shaded: bool = true, cull_front: bool, cull_back: bool, no_light: bool = false };
fn validateFlags(flags: NativeFlags) !void {
    if (flags.cull_front and flags.cull_back) return error.InvalidMaterialCulling;
}
fn nativeFlags(f: ?Fast64, culling: anytype, image: bool) NativeFlags {
    const value = f orelse return .{ .textured = image, .cull_front = culling.front, .cull_back = culling.back };
    const flags = value.rdp_settings;
    return .{ .depth = flags.g_zbuffer == .on, .textured = image or value.tex0 != null, .shaded = flags.g_shade == .on, .cull_front = flags.g_cull_front == .on, .cull_back = flags.g_cull_back == .on, .no_light = flags.g_lighting == .off };
}

fn emitMask(allocator: std.mem.Allocator, output: *std.ArrayList(u8), material: anytype) !void {
    if (material.alphaMode != .MASK) return;
    if (!std.math.isFinite(material.alphaCutoff)) return error.InvalidAlphaCutoff;
    const cutoff: u8 = @intFromFloat(@round(std.math.clamp(material.alphaCutoff, 0, 1) * 255));
    try append(allocator, output, ".alpha_cutoff = {d}, ", .{cutoff});
}

fn emitSampler(allocator: std.mem.Allocator, output: *std.ArrayList(u8), name: []const u8, value: Sampler) !void {
    try append(allocator, output, ".{s} = .{{ .clamp_s = {}, .clamp_t = {}, .mirror_s = {}, .mirror_t = {}, .mask_s = {d}, .mask_t = {d}, .shift_s = {d}, .shift_t = {d} }}, ", .{
        name,         value.clamp_s, value.clamp_t, value.mirror_s, value.mirror_t,
        value.mask_s, value.mask_t,  value.shift_s, value.shift_t,
    });
}

fn emitCombiner(allocator: std.mem.Allocator, output: *std.ArrayList(u8), fast64: ?Fast64, textured: bool, blended: bool) !void {
    const f = fast64 orelse return emitDefaultCombiner(allocator, output, textured, blended);
    const first = f.combiner1 orelse return emitDefaultCombiner(allocator, output, textured, blended);
    if (f.rdp_settings.g_mdsft_cycletype > 1) return error.UnsupportedFast64CycleType;
    const two = f.rdp_settings.g_mdsft_cycletype == 1;
    try append(allocator, output, ".cycle_type = .{s}, .combine = .{{ .cycle0 = ", .{if (two) "two_cycle" else "one_cycle"});
    try emitCycle(allocator, output, first);
    try output.appendSlice(allocator, ", .cycle1 = ");
    try emitCycle(allocator, output, try secondCycle(f, first));
    try output.appendSlice(allocator, " }, ");
}

fn emitDefaultCombiner(allocator: std.mem.Allocator, output: *std.ArrayList(u8), textured: bool, blended: bool) !void {
    try append(allocator, output, ".combine = .single(.{{ .rgb_a = .{s}, .rgb_c = .{s}, .alpha_d = .{s} }}), ", .{
        if (textured) "tex0" else "shade",                                                     if (textured) "shade" else "primitive",
        if (textured) (if (blended) "tex0" else "one") else (if (blended) "shade" else "one"),
    });
}

fn secondCycle(f: Fast64, first: Cycle) !Cycle {
    if (f.rdp_settings.g_mdsft_cycletype == 0) return first;
    return f.combiner2 orelse error.MissingFast64SecondCombiner;
}

fn emitCycle(allocator: std.mem.Allocator, output: *std.ArrayList(u8), cycle: Cycle) !void {
    const values = [_]u8{ cycle.A, cycle.B, cycle.C, cycle.D, cycle.A_alpha, cycle.B_alpha, cycle.C_alpha, cycle.D_alpha };
    const maxima = [_]u8{ 8, 8, 16, 7, 7, 7, 7, 7 };
    for (values, maxima) |value, maximum| if (value > maximum) return error.UnsupportedFast64Combiner;
    // These values are the hardware input selectors, not a translated C ABI.
    try append(allocator, output, ".{{ .rgb_a = @enumFromInt({d}), .rgb_b = @enumFromInt({d}), .rgb_c = @enumFromInt({d}), .rgb_d = @enumFromInt({d}), .alpha_a = @enumFromInt({d}), .alpha_b = @enumFromInt({d}), .alpha_c = @enumFromInt({d}), .alpha_d = @enumFromInt({d}) }}", .{
        cycle.A, cycle.B, cycle.C, cycle.D, cycle.A_alpha, cycle.B_alpha, cycle.C_alpha, cycle.D_alpha,
    });
}

fn emitRegisters(allocator: std.mem.Allocator, output: *std.ArrayList(u8), f: Fast64) !void {
    if (f.rdp_settings.g_fog) |fog| try append(allocator, output, ".fog = {}, ", .{fog == .on});
    if (f.set_prim == .on) try emitColor(allocator, output, "primitive", f.prim_color);
    if (f.set_env == .on) try emitColor(allocator, output, "environment", f.env_color);
}

fn emitColor(allocator: std.mem.Allocator, output: *std.ArrayList(u8), name: []const u8, color: [4]f32) !void {
    var bytes: [4]u8 = undefined;
    for (color, 0..) |component, index| {
        if (!std.math.isFinite(component)) return error.InvalidMaterialColor;
        const linear = std.math.clamp(component, 0, 1);
        bytes[index] = @intFromFloat((if (index < 3) std.math.pow(f32, linear, 0.4545) else linear) * 255);
    }
    try append(allocator, output, ".{s} = .fromBytes({d}, {d}, {d}, {d}), ", .{ name, bytes[0], bytes[1], bytes[2], bytes[3] });
}

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

test "Fast64 checkbox versions and signed shifts reject invalid metadata" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "true", "1", "false", "0" }, [_]Flag{ .on, .on, .off, .off }) |json, expected| {
        const parsed = try std.json.parseFromSlice(Flag, allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(expected, parsed.value);
    }
    try std.testing.expectError(error.InvalidNumber, std.json.parseFromSlice(Flag, allocator, "2", .{}));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Flag, allocator, "\"true\"", .{}));
    const result = try sampler(.{ .S = .{ .high = 31, .mask = 5, .shift = -1, .mirror = .on }, .T = .{ .high = 63, .mask = 6, .clamp = .on } });
    try std.testing.expectEqual(@as(u4, 15), result.shift_s);
    try std.testing.expect(result.mirror_s and result.clamp_t);
    try std.testing.expectError(error.UnsupportedFast64Sampler, sampler(.{ .S = .{ .high = 31, .mask = 16 } }));
    try std.testing.expectError(error.UnsupportedFast64Sampler, sampler(.{ .T = .{ .high = 31, .shift = -6 } }));
}

test "unsupported material states fail during conversion rather than generating bad Zig" {
    const allocator = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try std.testing.expectError(error.UnsupportedFast64Combiner, emitCycle(allocator, &output, .{ .C = 31 }));
    try std.testing.expectError(error.MissingFast64SecondCombiner, secondCycle(.{ .rdp_settings = .{ .g_mdsft_cycletype = 1 } }, .{}));
    try std.testing.expectError(error.UnsupportedFast64CycleType, emitCombiner(allocator, &output, .{ .combiner1 = .{}, .rdp_settings = .{ .g_mdsft_cycletype = 2 } }, true, false));
    try std.testing.expectError(error.InvalidMaterialColor, emitColor(allocator, &output, "primitive", .{ std.math.nan(f32), 0, 0, 1 }));
    const Mask = struct { alphaMode: enum { MASK } = .MASK, alphaCutoff: f32 = std.math.nan(f32) };
    try std.testing.expectError(error.InvalidAlphaCutoff, emitMask(allocator, &output, Mask{}));
    try std.testing.expectError(error.InvalidMaterialCulling, validateFlags(.{ .textured = true, .cull_front = true, .cull_back = true }));
    const fixture = struct { extras: ?Extras = .{ .f3d_mat = .{ .rdp_settings = .{ .g_mdsft_text_filt = 3 } } } }{};
    try std.testing.expectError(error.UnsupportedFast64Filter, filter(fixture, false));
}
