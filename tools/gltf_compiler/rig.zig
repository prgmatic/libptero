//! glTF skeleton and animation metadata. Vertex packing remains in compiler.zig.
const std = @import("std");
const compiler = @import("compiler.zig");
const Allocator = std.mem.Allocator;
const Source = std.ArrayList(u8);

pub const Node = struct {
    name: []const u8 = "",
    children: []const u16 = &.{},
    mesh: ?u32 = null,
    skin: ?u16 = null,
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
    matrix: ?[16]f32 = null,
};
pub const Skin = struct { joints: []const u16, inverseBindMatrices: ?u32 = null };
pub const Animation = struct { name: []const u8 = "", samplers: []const Sampler, channels: []const Channel };
pub const Sampler = struct { input: u32, output: u32, interpolation: Interpolation = .LINEAR };
pub const Interpolation = enum { LINEAR, STEP, CUBICSPLINE };
pub const Channel = struct { sampler: u32, target: Target };
pub const Target = struct { node: u16, path: Path };
pub const Path = enum { translation, rotation, scale, weights };
pub const Influence = struct { joints: [4]u16 = @splat(0), weights: [4]f32 = @splat(0) };

pub fn meshSkin(document: compiler.Document, mesh: usize) !?u16 {
    var found: ?u16 = null;
    var occurrences: usize = 0;
    for (document.nodes) |node| if (node.mesh == @as(u32, @intCast(mesh))) {
        occurrences += 1;
        found = node.skin;
    };
    // Instanced meshes need separate geometry records and distinct bindings.
    if (occurrences > 1) return error.InstancedMeshUnsupported;
    return found;
}

pub fn readInfluence(joints: ?compiler.AccessorView, weights: ?compiler.AccessorView, index: u32) !Influence {
    const j = joints orelse return .{};
    const w = weights orelse return error.InvalidSkinAttributes;
    try validateInfluenceViews(j, w);
    var result: Influence = .{};
    var total: f32 = 0;
    for (0..4) |component| {
        const joint = try j.float(index, component);
        const weight = safeScalar(try readWeight(w, index, component));
        result.joints[component] = @intFromFloat(joint);
        result.weights[component] = weight;
        total += weight;
    }
    if (total <= 0) return error.InvalidSkinWeights;
    for (&result.weights) |*weight| weight.* /= total;
    return result;
}

fn validateInfluenceViews(joints: compiler.AccessorView, weights: compiler.AccessorView) !void {
    if (joints.component_count != 4 or weights.component_count != 4 or joints.normalized) return error.InvalidSkinAttributes;
    try validateInfluenceTypes(joints, weights);
}

fn validateInfluenceTypes(joints: compiler.AccessorView, weights: compiler.AccessorView) !void {
    if (joints.component_type != 5121 and joints.component_type != 5123) return error.InvalidSkinAttributes;
    if (weights.component_type != 5126 and !weights.normalized) return error.InvalidSkinAttributes;
}

fn readWeight(weights: compiler.AccessorView, index: u32, component: usize) !f32 {
    const value = try weights.float(index, component);
    if (!std.math.isFinite(value) or value < 0) return error.InvalidSkinWeights;
    return value;
}

pub fn validate(document: compiler.Document, binary: []const u8) !void {
    try validateNodes(document);
    try validateSkins(document, binary);
    for (document.meshes, 0..) |mesh, index| {
        const skin_index = try meshSkin(document, index);
        for (mesh.primitives) |primitive| try validatePrimitiveSkin(document, binary, primitive, skin_index);
    }
}

fn validateNodes(document: compiler.Document) !void {
    if (document.nodes.len > std.math.maxInt(u16)) return error.TooManyNodes;
    for (document.nodes, 0..) |node, index| {
        try validateNodeBinding(document, node);
        try validateAncestry(document.nodes, @intCast(index));
    }
}

fn validateNodeBinding(document: compiler.Document, node: Node) !void {
    if (node.matrix != null) return error.NodeMatrixUnsupported;
    if (node.mesh) |mesh| if (mesh >= document.meshes.len) return error.InvalidMesh;
    if (node.skin) |skin| if (skin >= document.skins.len) return error.InvalidSkin;
}

fn validateAncestry(nodes: []const Node, index: u16) !void {
    var current: ?u16 = index;
    var depth: usize = 0;
    while (current) |value| {
        if (depth >= nodes.len) return error.CyclicNodes;
        current = try parent(nodes, value);
        depth += 1;
    }
}

fn validateSkins(document: compiler.Document, binary: []const u8) !void {
    for (document.skins) |skin| {
        if (skin.joints.len == 0) return error.InvalidSkin;
        for (skin.joints) |joint| if (joint >= document.nodes.len) return error.InvalidSkin;
        _ = try inverseBindView(document, binary, skin);
    }
}

pub fn inverseBindView(document: compiler.Document, binary: []const u8, skin: Skin) !?compiler.AccessorView {
    const accessor = skin.inverseBindMatrices orelse return null;
    const view = try compiler.accessorView(document, binary, accessor);
    if (view.component_count != 16 or view.count < skin.joints.len or view.component_type != 5126) return error.InvalidInverseBindMatrices;
    return view;
}

fn validatePrimitiveSkin(document: compiler.Document, binary: []const u8, primitive: compiler.Primitive, skin_index: ?u16) !void {
    const accessor = primitive.attributes.JOINTS_0 orelse {
        if (primitive.attributes.WEIGHTS_0 != null) return error.InvalidSkinAttributes;
        return;
    };
    const skin = skin_index orelse return error.MissingSkin;
    const joints = try compiler.accessorView(document, binary, accessor);
    const weights = try primitiveWeights(document, binary, primitive, joints);
    const positions = try compiler.accessorView(document, binary, primitive.attributes.POSITION);
    for (0..positions.count) |vertex| {
        const influence = try readInfluence(joints, weights, @intCast(vertex));
        try validateJointRange(influence, document.skins[skin].joints.len);
    }
}

fn primitiveWeights(document: compiler.Document, binary: []const u8, primitive: compiler.Primitive, joints: compiler.AccessorView) !compiler.AccessorView {
    const weights = try compiler.accessorView(document, binary, primitive.attributes.WEIGHTS_0 orelse return error.InvalidSkinAttributes);
    const positions = try compiler.accessorView(document, binary, primitive.attributes.POSITION);
    if (joints.count != positions.count or weights.count != positions.count) return error.InvalidSkinAttributes;
    return weights;
}

fn validateJointRange(influence: Influence, count: usize) !void {
    for (influence.joints, influence.weights) |joint, weight| if (weight > 0 and joint >= count) return error.InvalidSkinJoint;
}

pub fn parent(nodes: []const Node, child: u16) !?u16 {
    var result: ?u16 = null;
    for (nodes, 0..) |node, index| for (node.children) |value| {
        if (value >= nodes.len) return error.InvalidNode;
        if (value == child) {
            if (result != null) return error.MultipleNodeParents;
            result = @intCast(index);
        }
    };
    return result;
}

pub fn emit(allocator: Allocator, source: *Source, document: compiler.Document, binary: []const u8, scale: f32) !void {
    try emitNodes(allocator, source, document.nodes, scale);
    try emitSkins(allocator, source, document, binary, scale);
    try emitAnimations(allocator, source, document, binary, scale);
}

fn format(allocator: Allocator, source: *Source, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try source.appendSlice(allocator, text);
}

fn quote(allocator: Allocator, source: *Source, value: []const u8) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try source.appendSlice(allocator, text);
}

fn emitNodes(allocator: Allocator, source: *Source, nodes: []const Node, scale: f32) !void {
    try source.appendSlice(allocator, "const nodes = [_]n64.graphics.animation.Node{\n");
    for (nodes, 0..) |node, index| {
        try source.appendSlice(allocator, ".{ .name = ");
        try quote(allocator, source, node.name);
        if (try parent(nodes, @intCast(index))) |value| try format(allocator, source, ", .parent = {d}", .{value});
        try format(allocator, source, ", .transform = .{{ .translation = .init({e}, {e}, {e}), .rotation = .{{ .x = {e}, .y = {e}, .z = {e}, .w = {e} }}, .scale = .init({e}, {e}, {e}) }} }},\n", .{
            safeScalar(node.translation[0] * scale), safeScalar(node.translation[1] * scale), safeScalar(node.translation[2] * scale),
            safeScalar(node.rotation[0]),            safeScalar(node.rotation[1]),            safeScalar(node.rotation[2]),
            safeScalar(node.rotation[3]),            safeScalar(node.scale[0]),               safeScalar(node.scale[1]),
            safeScalar(node.scale[2]),
        });
    }
    try source.appendSlice(allocator, "};\n");
}

fn emitSkins(allocator: Allocator, source: *Source, document: compiler.Document, binary: []const u8, scale: f32) !void {
    try source.appendSlice(allocator, "const skins = [_]n64.graphics.animation.Skin{\n");
    for (document.skins) |skin| try emitSkin(allocator, source, document, binary, skin, scale);
    try source.appendSlice(allocator, "};\n");
}

fn emitSkin(allocator: Allocator, source: *Source, document: compiler.Document, binary: []const u8, skin: Skin, scale: f32) !void {
    try source.appendSlice(allocator, ".{ .joints = &.{");
    for (skin.joints) |joint| try format(allocator, source, "{d},", .{joint});
    try source.appendSlice(allocator, "}, .inverse_bind_matrices = &.{\n");
    const view = try inverseBindView(document, binary, skin);
    for (0..skin.joints.len) |joint| try emitInverseBind(allocator, source, view, joint, scale);
    try source.appendSlice(allocator, "} },\n");
}

fn emitInverseBind(allocator: Allocator, source: *Source, view: ?compiler.AccessorView, joint: usize, scale: f32) !void {
    try source.appendSlice(allocator, ".{ .m = .{");
    for (0..4) |column| {
        try source.appendSlice(allocator, ".{");
        for (0..4) |row| try format(allocator, source, "{e},", .{try inverseBindCoefficient(view, joint, column, row, scale)});
        try source.appendSlice(allocator, "},");
    }
    try source.appendSlice(allocator, "} },\n");
}

pub fn inverseBindCoefficient(view: ?compiler.AccessorView, joint: usize, column: usize, row: usize, scale: f32) !f32 {
    var value = if (view) |v| try v.float(joint, column * 4 + row) else @as(f32, @floatFromInt(@intFromBool(column == row)));
    if (column == 3 and row < 3) value *= scale;
    if (!std.math.isFinite(value)) return error.InvalidInverseBindMatrices;
    return safeScalar(value);
}

fn emitAnimations(allocator: Allocator, source: *Source, document: compiler.Document, binary: []const u8, scale: f32) !void {
    for (document.animations, 0..) |animation, clip| {
        try format(allocator, source, "const tracks_{d} = [_]n64.graphics.animation.Track{{\n", .{clip});
        for (animation.channels) |channel| try emitTrack(allocator, source, document, binary, animation, channel, scale);
        try source.appendSlice(allocator, "};\n");
    }
    try source.appendSlice(allocator, "const animations = [_]n64.graphics.animation.Clip{\n");
    for (document.animations, 0..) |animation, clip| {
        var duration: f32 = 0;
        for (animation.samplers) |sampler| {
            const times = try compiler.accessorView(document, binary, sampler.input);
            if (times.count > 0) duration = @max(duration, try times.float(times.count - 1, 0));
        }
        try source.appendSlice(allocator, ".{ .name = ");
        try quote(allocator, source, animation.name);
        try format(allocator, source, ", .duration = {e}, .tracks = &tracks_{d} }},\n", .{ duration, clip });
    }
    try source.appendSlice(allocator, "};\n");
}

const TrackViews = struct { times: compiler.AccessorView, values: compiler.AccessorView };

fn emitTrack(allocator: Allocator, source: *Source, document: compiler.Document, binary: []const u8, animation: Animation, channel: Channel, scale: f32) !void {
    const sampler = try trackSampler(document, animation, channel);
    const views = try trackViews(document, binary, sampler, channel.target.path);
    const interpolation = switch (sampler.interpolation) {
        .LINEAR => "linear",
        .STEP => "step",
        .CUBICSPLINE => "cubic_spline",
    };
    try format(allocator, source, ".{{ .node = {d}, .path = .{s}, .interpolation = .{s}, .times = &.{{", .{ channel.target.node, @tagName(channel.target.path), interpolation });
    try emitTimes(allocator, source, views.times);
    try source.appendSlice(allocator, "}, .values = &.{\n");
    for (0..views.values.count) |key| try emitTrackValue(allocator, source, views.values, key, channel.target.path, scale);
    try source.appendSlice(allocator, "} },\n");
}

fn trackSampler(document: compiler.Document, animation: Animation, channel: Channel) !Sampler {
    if (channel.sampler >= animation.samplers.len or channel.target.node >= document.nodes.len) return error.InvalidAnimation;
    if (channel.target.path == .weights) return error.MorphTargetsUnsupported;
    return animation.samplers[channel.sampler];
}

fn trackViews(document: compiler.Document, binary: []const u8, sampler: Sampler, path: Path) !TrackViews {
    const times = try compiler.accessorView(document, binary, sampler.input);
    const values = try compiler.accessorView(document, binary, sampler.output);
    try validateTimeView(times);
    try validateValueView(values, times.count, sampler.interpolation, path);
    return .{ .times = times, .values = values };
}

fn validateTimeView(times: compiler.AccessorView) !void {
    if (times.count == 0 or times.component_count != 1 or times.component_type != 5126) return error.InvalidAnimation;
}

fn validateValueView(values: compiler.AccessorView, time_count: usize, interpolation: Interpolation, path: Path) !void {
    const components: usize = if (path == .rotation) 4 else 3;
    const multiplier: usize = if (interpolation == .CUBICSPLINE) 3 else 1;
    if (!validAnimationValueType(values) or values.component_count != components or values.count != time_count * multiplier) return error.InvalidAnimation;
}

fn emitTimes(allocator: Allocator, source: *Source, times: compiler.AccessorView) !void {
    var previous: f32 = -1;
    for (0..times.count) |key| {
        const value = try times.float(key, 0);
        if (!std.math.isFinite(value) or value < 0 or value <= previous) return error.InvalidAnimationTime;
        previous = value;
        try format(allocator, source, "{e},", .{value});
    }
}

fn emitTrackValue(allocator: Allocator, source: *Source, values: compiler.AccessorView, key: usize, path: Path, scale: f32) !void {
    try source.appendSlice(allocator, ".{");
    for (0..4) |component| {
        var value: f32 = if (component < values.component_count) try values.float(key, component) else 0;
        if (!std.math.isFinite(value)) return error.InvalidAnimation;
        value = safeScalar(value);
        if (path == .translation) value *= scale;
        value = safeScalar(value);
        try format(allocator, source, "{e},", .{value});
    }
    try source.appendSlice(allocator, "},\n");
}

/// Blender exports occasionally contain ~1e-21 quaternion components. Their
/// products become subnormal, which the VR4300 FPU cannot process. Canonicalize
/// negligible values before placing floating point metadata in the ROM.
fn safeScalar(value: f32) f32 {
    return if (@abs(value) < 1e-18) 0 else value;
}

fn validAnimationValueType(view: compiler.AccessorView) bool {
    return view.component_type == 5126 or (view.normalized and (view.component_type == 5120 or view.component_type == 5121 or view.component_type == 5122 or view.component_type == 5123));
}

test "normalized weights retain all four influences" {
    const j = [_]u8{ 1, 2, 3, 4 };
    const w = [_]u8{ 64, 64, 64, 63 };
    const joints: compiler.AccessorView = .{ .bytes = &j, .count = 1, .stride = 4, .component_type = 5121, .component_count = 4, .normalized = false };
    const weights: compiler.AccessorView = .{ .bytes = &w, .count = 1, .stride = 4, .component_type = 5121, .component_count = 4, .normalized = true };
    const influence = try readInfluence(joints, weights, 0);
    try std.testing.expectEqual([4]u16{ 1, 2, 3, 4 }, influence.joints);
    try std.testing.expectApproxEqAbs(@as(f32, 1), influence.weights[0] + influence.weights[1] + influence.weights[2] + influence.weights[3], 0.00001);
    try std.testing.expect(influence.weights[3] > 0);
}

test "hierarchy emission handles children before parents and escapes names" {
    const nodes = [_]Node{ .{ .name = "child\"", .translation = .{ 1, 2, 3 } }, .{ .name = "root", .children = &.{0} } };
    var source: Source = .empty;
    defer source.deinit(std.testing.allocator);
    try emitNodes(std.testing.allocator, &source, &nodes, 64);
    try std.testing.expect(std.mem.indexOf(u8, source.items, ".parent = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.items, "child\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.items, "6.4e1") != null);
    try std.testing.expectError(error.MultipleNodeParents, parent(&.{ .{ .children = &.{2} }, .{ .children = &.{2} }, .{} }, 2));
}

fn fixtureDocument() compiler.Document {
    return .{ .accessors = &.{}, .bufferViews = &.{}, .meshes = &.{} };
}

test "skeleton validation rejects invalid hierarchy and skin bindings" {
    var document = fixtureDocument();
    document.nodes = &.{ .{ .children = &.{1} }, .{ .children = &.{0} } };
    try std.testing.expectError(error.CyclicNodes, validate(document, &.{}));
    document.nodes = &.{.{ .children = &.{1} }};
    try std.testing.expectError(error.InvalidNode, validate(document, &.{}));
    document.nodes = &.{.{ .mesh = 0 }};
    try std.testing.expectError(error.InvalidMesh, validate(document, &.{}));
    document.nodes = &.{.{ .skin = 0 }};
    try std.testing.expectError(error.InvalidSkin, validate(document, &.{}));
    document.nodes = &.{.{}};
    document.skins = &.{.{ .joints = &.{1} }};
    try std.testing.expectError(error.InvalidSkin, validate(document, &.{}));
    document.skins = &.{.{ .joints = &.{} }};
    try std.testing.expectError(error.InvalidSkin, validate(document, &.{}));
    document.skins = &.{.{ .joints = &.{0} }};
    try validate(document, &.{});
}

fn appendFloats(allocator: Allocator, binary: *Source, values: []const f32) !void {
    for (values) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
        try binary.appendSlice(allocator, &bytes);
    }
}

test "animation metadata preserves step linear cubic tracks and translation scale" {
    const allocator = std.testing.allocator;
    var binary: Source = .empty;
    defer binary.deinit(allocator);
    try appendFloats(allocator, &binary, &.{ 0, 1 });
    try appendFloats(allocator, &binary, &.{ 1, 2, 3, 4, 5, 6 });
    try appendFloats(allocator, &binary, &.{ 0, 0, 0, 1, 0, 0, 1, 0 });
    try appendFloats(allocator, &binary, &.{ 0, 0, 0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 4, 5, 6, 0, 0, 0 });
    var document = fixtureDocument();
    document.nodes = &.{.{ .name = "bone" }};
    document.accessors = &.{
        .{ .bufferView = 0, .componentType = 5126, .count = 2, .type = "SCALAR" },
        .{ .bufferView = 1, .componentType = 5126, .count = 2, .type = "VEC3" },
        .{ .bufferView = 2, .componentType = 5126, .count = 2, .type = "VEC4" },
        .{ .bufferView = 3, .componentType = 5126, .count = 6, .type = "VEC3" },
    };
    document.bufferViews = &.{
        .{ .buffer = 0, .byteOffset = 0, .byteLength = 8 },
        .{ .buffer = 0, .byteOffset = 8, .byteLength = 24 },
        .{ .buffer = 0, .byteOffset = 32, .byteLength = 32 },
        .{ .buffer = 0, .byteOffset = 64, .byteLength = 72 },
    };
    const animation: Animation = .{
        .name = "pose",
        .samplers = &.{ .{ .input = 0, .output = 1, .interpolation = .STEP }, .{ .input = 0, .output = 2 }, .{ .input = 0, .output = 3, .interpolation = .CUBICSPLINE } },
        .channels = &.{ .{ .sampler = 0, .target = .{ .node = 0, .path = .translation } }, .{ .sampler = 1, .target = .{ .node = 0, .path = .rotation } }, .{ .sampler = 2, .target = .{ .node = 0, .path = .scale } } },
    };
    document.animations = &.{animation};
    var source: Source = .empty;
    defer source.deinit(allocator);
    try emit(allocator, &source, document, binary.items, 64);
    for ([_][]const u8{ ".interpolation = .step", ".interpolation = .linear", ".interpolation = .cubic_spline", ".duration = 1e0", "6.4e1,1.28e2,1.92e2", ".path = .rotation" }) |fragment|
        try std.testing.expect(std.mem.indexOf(u8, source.items, fragment) != null);
    source.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidAnimation, emitTrack(allocator, &source, document, binary.items, animation, .{ .sampler = 99, .target = .{ .node = 0, .path = .translation } }, 64));
    try std.testing.expectError(error.MorphTargetsUnsupported, emitTrack(allocator, &source, document, binary.items, animation, .{ .sampler = 0, .target = .{ .node = 0, .path = .weights } }, 64));
    std.mem.writeInt(u32, binary.items[4..8], @bitCast(@as(f32, 0)), .little);
    try std.testing.expectError(error.InvalidAnimationTime, emitTrack(allocator, &source, document, binary.items, animation, animation.channels[0], 64));
}

test "inverse bind matrices scale translations and allow surplus entries" {
    const allocator = std.testing.allocator;
    var binary: Source = .empty;
    defer binary.deinit(allocator);
    try appendFloats(allocator, &binary, &.{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, -2, -3, 1 });
    try appendFloats(allocator, &binary, &.{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 });
    var document = fixtureDocument();
    document.nodes = &.{.{}};
    document.skins = &.{.{ .joints = &.{0}, .inverseBindMatrices = 0 }};
    document.accessors = &.{.{ .bufferView = 0, .componentType = 5126, .count = 2, .type = "MAT4" }};
    document.bufferViews = &.{.{ .buffer = 0, .byteLength = 128 }};
    try validate(document, binary.items);
    var source: Source = .empty;
    defer source.deinit(allocator);
    try emitSkins(allocator, &source, document, binary.items, 64);
    try std.testing.expect(std.mem.indexOf(u8, source.items, "-6.4e1,-1.28e2,-1.92e2,1e0") != null);
    document.accessors = &.{.{ .bufferView = 0, .componentType = 5126, .count = 0, .type = "MAT4" }};
    try std.testing.expectError(error.InvalidInverseBindMatrices, validate(document, binary.items));
}

test "negligible imported quaternion components cannot form VR4300 subnormals" {
    const allocator = std.testing.allocator;
    var source: Source = .empty;
    defer source.deinit(allocator);
    try emitNodes(allocator, &source, &.{.{ .rotation = .{ 1e-21, -1e-21, 0, 1 } }}, 64);
    try std.testing.expect(std.mem.indexOf(u8, source.items, ".rotation = .{ .x = 0e0, .y = 0e0, .z = 0e0, .w = 1e0 }") != null);
    try std.testing.expectEqual(@as(f32, 0), safeScalar(1e-21));
    try std.testing.expectEqual(@as(f32, 1e-8), safeScalar(1e-8));
}

test "positive influences must address the selected skin and unused slots are ignored" {
    try validateJointRange(.{ .joints = .{ 0, 99, 99, 99 }, .weights = .{ 1, 0, 0, 0 } }, 1);
    try std.testing.expectError(error.InvalidSkinJoint, validateJointRange(.{ .joints = .{ 0, 1, 0, 0 }, .weights = .{ 0.5, 0.5, 0, 0 } }, 1));
}

test "primitive skin validation matches vertex counts and checks active joints" {
    var binary: [60]u8 = @splat(0);
    binary[48] = 255;
    binary[52] = 255;
    binary[56] = 255;
    var document = fixtureDocument();
    document.nodes = &.{.{ .mesh = 0, .skin = 0 }};
    document.skins = &.{.{ .joints = &.{0} }};
    document.meshes = &.{.{ .primitives = &.{.{ .attributes = .{ .POSITION = 0, .JOINTS_0 = 1, .WEIGHTS_0 = 2 }, .indices = 0 }} }};
    document.accessors = &.{
        .{ .bufferView = 0, .componentType = 5126, .count = 3, .type = "VEC3" },
        .{ .bufferView = 1, .componentType = 5121, .count = 3, .type = "VEC4" },
        .{ .bufferView = 2, .componentType = 5121, .normalized = true, .count = 3, .type = "VEC4" },
    };
    document.bufferViews = &.{ .{ .buffer = 0, .byteLength = 36 }, .{ .buffer = 0, .byteOffset = 36, .byteLength = 12 }, .{ .buffer = 0, .byteOffset = 48, .byteLength = 12 } };
    try validate(document, &binary);
    binary[36] = 1;
    try std.testing.expectError(error.InvalidSkinJoint, validate(document, &binary));
    binary[36] = 0;
    var accessors = document.accessors[0..3].*;
    accessors[2].count = 2;
    document.accessors = &accessors;
    try std.testing.expectError(error.InvalidSkinAttributes, validate(document, &binary));
}
