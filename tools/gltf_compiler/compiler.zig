const std = @import("std");
const texture_compiler = @import("texture_compiler");

pub const Glb = struct {
    json: []const u8,
    binary: []const u8,
};

pub const Document = struct {
    accessors: []const Accessor,
    bufferViews: []const BufferView,
    meshes: []const Mesh,
    materials: []const Material = &.{},
    textures: []const Texture = &.{},
    samplers: []const Sampler = &.{},
    images: []const Image = &.{},
};

pub const Accessor = struct {
    bufferView: u32,
    byteOffset: u32 = 0,
    componentType: u32,
    count: u32,
    type: []const u8,
    normalized: bool = false,
};

pub const BufferView = struct {
    buffer: u32,
    byteOffset: u32 = 0,
    byteLength: u32,
    byteStride: ?u32 = null,
};

pub const Mesh = struct {
    name: []const u8 = "",
    primitives: []const Primitive,
};

pub const Primitive = struct {
    attributes: Attributes,
    indices: u32,
    material: ?u32 = null,
    mode: u32 = 4,
};

pub const Attributes = struct {
    POSITION: u32,
    NORMAL: ?u32 = null,
    TEXCOORD_0: ?u32 = null,
    COLOR_0: ?u32 = null,
    JOINTS_0: ?u32 = null,
    WEIGHTS_0: ?u32 = null,
};

pub const Material = struct {
    name: []const u8 = "",
    pbrMetallicRoughness: ?Pbr = null,
    extensions: ?MaterialExtensions = null,
    alphaMode: AlphaMode = .OPAQUE,
};

pub const AlphaMode = enum { OPAQUE, MASK, BLEND };

pub const MaterialExtensions = struct {
    FAST64_materials_f3d: ?Fast64Material = null,
    FAST64_materials_n64: ?Fast64N64Material = null,
};

pub const Fast64N64Material = struct {
    otherModes: ?Fast64OtherModes = null,
    extensions: ?Fast64NestedExtensions = null,
};

pub const Fast64OtherModes = struct {
    renderMode: ?Fast64RenderMode = null,
};

pub const Fast64RenderMode = struct {
    presets: []const []const u8 = &.{},
};

pub const Fast64NestedExtensions = struct {
    FAST64_materials_f3d: ?Fast64Material = null,
};

pub const Fast64Material = struct {
    geometryMode: Fast64GeometryMode = .{},
};

pub const Fast64GeometryMode = struct {
    cullFront: bool = false,
    cullBack: bool = false,
};

pub const Pbr = struct {
    baseColorFactor: [4]f32 = .{ 1, 1, 1, 1 },
    baseColorTexture: ?TextureRef = null,
};

pub const TextureRef = struct { index: u32 };
pub const Texture = struct { source: u32, sampler: ?u32 = null, name: []const u8 = "" };
pub const Sampler = struct { wrapS: u32 = 10497, wrapT: u32 = 10497 };
pub const Image = struct { bufferView: u32, mimeType: []const u8 = "", name: []const u8 = "" };

pub fn parseDocument(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(Document) {
    return std.json.parseFromSlice(Document, allocator, json, .{ .ignore_unknown_fields = true });
}

pub const AccessorView = struct {
    bytes: []const u8,
    count: usize,
    stride: usize,
    component_type: u32,
    component_count: usize,
    normalized: bool,

    pub fn float(self: AccessorView, element: usize, component: usize) !f32 {
        try self.validateElement(element, component);
        const component_size = componentSize(self.component_type) orelse return error.UnsupportedComponentType;
        const bytes = self.bytes[element * self.stride + component * component_size ..][0..component_size];
        return switch (self.component_type) {
            5120, 5122 => signedFloat(bytes, self.component_type, self.normalized),
            5121, 5123, 5125 => unsignedFloat(bytes, self.component_type, self.normalized),
            5126 => @bitCast(readU32(bytes)),
            else => error.UnsupportedComponentType,
        };
    }

    pub fn index(self: AccessorView, element: usize) !u32 {
        try self.validateElement(element, 0);
        if (self.component_count != 1) return error.InvalidAccessor;
        const bytes = self.bytes[element * self.stride ..];
        return switch (self.component_type) {
            5121 => bytes[0],
            5123 => readU16(bytes[0..2]),
            5125 => readU32(bytes[0..4]),
            else => error.UnsupportedIndexType,
        };
    }

    fn validateElement(self: AccessorView, element: usize, component: usize) !void {
        if (element >= self.count) return error.InvalidAccessor;
        if (component >= self.component_count) return error.InvalidAccessor;
    }
};

fn signedFloat(bytes: []const u8, component_type: u32, normalized: bool) f32 {
    const value: f32 = if (component_type == 5120)
        @floatFromInt(@as(i8, @bitCast(bytes[0])))
    else
        @floatFromInt(readI16(bytes));
    if (!normalized) return value;
    const divisor: f32 = if (component_type == 5120) 127.0 else 32767.0;
    return @max(value / divisor, -1.0);
}

fn unsignedFloat(bytes: []const u8, component_type: u32, normalized: bool) f32 {
    const value = readUnsignedFloat(bytes, component_type);
    if (!normalized or component_type == 5125) return value;
    const divisor: f32 = if (component_type == 5121) 255.0 else 65535.0;
    return value / divisor;
}

fn readUnsignedFloat(bytes: []const u8, component_type: u32) f32 {
    return switch (component_type) {
        5121 => @floatFromInt(bytes[0]),
        5123 => @floatFromInt(readU16(bytes)),
        else => @floatFromInt(readU32(bytes)),
    };
}

pub fn accessorView(document: Document, binary: []const u8, index: u32) !AccessorView {
    const pair = try lookupAccessor(document, index);
    const layout = try accessorLayout(pair.accessor, pair.view);
    const bytes = try accessorBytes(binary, pair.accessor, pair.view, layout.stride, layout.packed_stride);
    return .{ .bytes = bytes, .count = pair.accessor.count, .stride = layout.stride, .component_type = pair.accessor.componentType, .component_count = layout.components, .normalized = pair.accessor.normalized };
}

const AccessorPair = struct { accessor: Accessor, view: BufferView };

fn lookupAccessor(document: Document, index: u32) !AccessorPair {
    if (index >= document.accessors.len) return error.InvalidAccessor;
    const accessor = document.accessors[index];
    if (accessor.bufferView >= document.bufferViews.len) return error.InvalidAccessor;
    const view = document.bufferViews[accessor.bufferView];
    if (view.buffer != 0) return error.ExternalBufferUnsupported;
    return .{ .accessor = accessor, .view = view };
}

const AccessorLayout = struct { components: usize, packed_stride: usize, stride: usize };

fn accessorLayout(accessor: Accessor, view: BufferView) !AccessorLayout {
    const components = componentCount(accessor.type) orelse return error.UnsupportedAccessorType;
    const size = componentSize(accessor.componentType) orelse return error.UnsupportedComponentType;
    const packed_stride = components * size;
    const stride: usize = view.byteStride orelse @intCast(packed_stride);
    if (stride < packed_stride) return error.InvalidAccessor;
    return .{ .components = components, .packed_stride = packed_stride, .stride = stride };
}

fn accessorBytes(binary: []const u8, accessor: Accessor, view: BufferView, stride: usize, packed_stride: usize) ![]const u8 {
    const start: usize = @as(usize, view.byteOffset) + accessor.byteOffset;
    const required = if (accessor.count == 0) 0 else (@as(usize, accessor.count) - 1) * stride + packed_stride;
    const view_end: usize = @as(usize, view.byteOffset) + view.byteLength;
    if (start > binary.len) return error.InvalidAccessor;
    if (required > binary.len - start) return error.InvalidAccessor;
    if (start + required > view_end) return error.InvalidAccessor;
    return binary[start .. start + required];
}

pub const Vertex = struct {
    position: [3]i16,
    normal: u16,
    color: [4]u8,
    uv: [2]i16,
};

pub const Triangle = [3]u8;

pub const Batch = struct {
    vertices: []Vertex,
    triangles: []Triangle,
    material_index: u16,
    preserve_order: bool = false,

    fn deinit(self: Batch, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.triangles);
    }
};

pub const ConvertedModel = struct {
    batches: []Batch,

    pub fn deinit(self: ConvertedModel, allocator: std.mem.Allocator) void {
        for (self.batches) |batch| batch.deinit(allocator);
        allocator.free(self.batches);
    }
};

pub const Generated = struct {
    data: []u8,
    source: []u8,
    pub fn deinit(self: Generated, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.source);
    }
};

/// Emit a native model module plus a compact hardware-endian vertex blob.
pub fn generate(allocator: std.mem.Allocator, model: ConvertedModel, document: Document, binary: []const u8, name: []const u8) !Generated {
    if (!std.zig.isValidId(name)) return error.InvalidAssetName;
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator,
        \\const std = @import("std");
        \\const n64 = @import("n64");
        \\const VertexPair = n64.graphics.geometry.VertexPair;
        \\const Part = n64.graphics.model.Part;
        \\var model_data align(8) = @embedFile("model_data").*;
        \\
    );
    try emitBatchData(allocator, &data, &source, model.batches);
    try emitImages(allocator, &data, &source, document, binary);
    try emitParts(allocator, &source, model.batches, name);
    try emitMaterials(allocator, &source, document, binary);
    return .{ .data = try data.toOwnedSlice(allocator), .source = try source.toOwnedSlice(allocator) };
}

fn emitBatchData(allocator: std.mem.Allocator, data: *std.ArrayList(u8), source: *std.ArrayList(u8), batches: []const Batch) !void {
    for (batches, 0..) |batch, batch_index| try emitBatch(allocator, data, source, batch, batch_index);
}

fn emitBatch(allocator: std.mem.Allocator, data: *std.ArrayList(u8), source: *std.ArrayList(u8), batch: Batch, batch_index: usize) !void {
    try alignData(allocator, data);
    const data_offset = data.items.len;
    try emitVertices(allocator, data, batch.vertices);
    const vertices_end = data.items.len;
    try alignData(allocator, data);
    const indices_offset = data.items.len;
    try emitIndices(allocator, data, batch.triangles, batch.preserve_order);
    try appendFormat(
        allocator,
        source,
        "const vertices_{d} = std.mem.bytesAsSlice(VertexPair, model_data[{d}..{d}]);\nconst indices_{d} = std.mem.bytesAsSlice(i16, model_data[{d}..{d}]);\n",
        .{ batch_index, data_offset, vertices_end, batch_index, indices_offset, data.items.len },
    );
}

fn alignData(allocator: std.mem.Allocator, data: *std.ArrayList(u8)) !void {
    while (data.items.len % 8 != 0) try data.append(allocator, 0);
}

fn emitVertices(allocator: std.mem.Allocator, data: *std.ArrayList(u8), vertices: []const Vertex) !void {
    for (0..(vertices.len + 1) / 2) |pair_index| {
        const a = vertices[pair_index * 2];
        const b = if (pair_index * 2 + 1 < vertices.len) vertices[pair_index * 2 + 1] else a;
        try writePair(allocator, data, a, b);
    }
}

fn emitIndices(allocator: std.mem.Allocator, data: *std.ArrayList(u8), triangles: []const Triangle, preserve_order: bool) !void {
    if (triangles.len == 0) return;
    const indices = if (preserve_order)
        try encodeTriangleList(allocator, triangles)
    else
        try stripifyTriangles(allocator, triangles);
    defer allocator.free(indices);
    for (indices) |index| try writeU16(allocator, data, index);
}

fn encodeTriangleList(allocator: std.mem.Allocator, triangles: []const Triangle) ![]u16 {
    const indices = try allocator.alloc(u16, triangles.len * 3);
    for (triangles, 0..) |triangle, triangle_index| for (triangle, 0..) |vertex, corner| {
        indices[triangle_index * 3 + corner] = encodedTriangleIndex(
            vertex,
            triangle_index != 0 and corner == 0,
            triangle_index + 1 == triangles.len and corner == 2,
        );
    };
    return indices;
}

fn encodedTriangleIndex(vertex: u8, restart: bool, end: bool) u16 {
    var encoded = @as(u16, vertex) * 36;
    if (restart) encoded |= 0x8000;
    if (end) encoded |= 0x4000;
    return encoded;
}

fn stripifyTriangles(allocator: std.mem.Allocator, triangles: []const Triangle) ![]u16 {
    var used = try allocator.alloc(bool, triangles.len);
    defer allocator.free(used);
    @memset(used, false);
    var indices: std.ArrayList(u16) = .empty;
    const candidate_used = try allocator.alloc(bool, triangles.len);
    defer allocator.free(candidate_used);
    var candidate_vertices: std.ArrayList(u8) = .empty;
    defer candidate_vertices.deinit(allocator);
    var candidate_triangles: std.ArrayList(usize) = .empty;
    defer candidate_triangles.deinit(allocator);
    var best_vertices: std.ArrayList(u8) = .empty;
    defer best_vertices.deinit(allocator);
    var best_triangles: std.ArrayList(usize) = .empty;
    defer best_triangles.deinit(allocator);
    var remaining = triangles.len;
    while (remaining != 0) {
        try findBestStrip(allocator, triangles, used, candidate_used, &candidate_vertices, &candidate_triangles, &best_vertices, &best_triangles);
        for (best_triangles.items) |index| used[index] = true;
        remaining -= best_triangles.items.len;
        try appendEncodedStrip(allocator, &indices, best_vertices.items);
    }
    indices.items[indices.items.len - 1] |= 0x4000;
    return indices.toOwnedSlice(allocator);
}

fn findBestStrip(allocator: std.mem.Allocator, triangles: []const Triangle, used: []const bool, candidate_used: []bool, candidate_vertices: *std.ArrayList(u8), candidate_triangles: *std.ArrayList(usize), best_vertices: *std.ArrayList(u8), best_triangles: *std.ArrayList(usize)) !void {
    best_vertices.clearRetainingCapacity();
    best_triangles.clearRetainingCapacity();
    for (triangles, used, 0..) |triangle, is_used, start| {
        if (is_used) continue;
        inline for (0..3) |rotation| {
            try buildStripCandidate(allocator, triangles, used, candidate_used, triangle, start, rotation, candidate_vertices, candidate_triangles);
            if (candidate_triangles.items.len > best_triangles.items.len) {
                best_vertices.clearRetainingCapacity();
                best_triangles.clearRetainingCapacity();
                try best_vertices.appendSlice(allocator, candidate_vertices.items);
                try best_triangles.appendSlice(allocator, candidate_triangles.items);
            }
        }
    }
}

fn buildStripCandidate(allocator: std.mem.Allocator, triangles: []const Triangle, used: []const bool, candidate_used: []bool, triangle: Triangle, start: usize, comptime rotation: usize, vertices: *std.ArrayList(u8), strip_triangles: *std.ArrayList(usize)) !void {
    @memcpy(candidate_used, used);
    vertices.clearRetainingCapacity();
    strip_triangles.clearRetainingCapacity();
    try vertices.appendSlice(allocator, &.{ triangle[rotation], triangle[(rotation + 1) % 3], triangle[(rotation + 2) % 3] });
    try strip_triangles.append(allocator, start);
    candidate_used[start] = true;
    while (findStripContinuation(triangles, candidate_used, vertices.items[vertices.items.len - 2], vertices.items[vertices.items.len - 1], strip_triangles.items.len)) |next| {
        candidate_used[next.triangle] = true;
        try vertices.append(allocator, next.vertex);
        try strip_triangles.append(allocator, next.triangle);
    }
}

fn appendEncodedStrip(allocator: std.mem.Allocator, indices: *std.ArrayList(u16), vertices: []const u8) !void {
    for (vertices, 0..) |vertex, index| {
        const restart: u16 = if (indices.items.len != 0 and index == 0) 0x8000 else 0;
        try indices.append(allocator, @as(u16, vertex) * 36 | restart);
    }
}

const StripContinuation = struct { triangle: usize, vertex: u8 };

fn findStripContinuation(triangles: []const Triangle, used: []const bool, a: u8, b: u8, triangle_count: usize) ?StripContinuation {
    const edge = if (triangle_count & 1 == 0) [2]u8{ a, b } else [2]u8{ b, a };
    for (triangles, used, 0..) |triangle, is_used, index| {
        if (is_used) continue;
        const vertex = continuationVertex(triangle, edge) orelse continue;
        return .{ .triangle = index, .vertex = vertex };
    }
    return null;
}

fn continuationVertex(triangle: Triangle, edge: [2]u8) ?u8 {
    inline for (0..3) |corner| {
        if (triangle[corner] == edge[0] and triangle[(corner + 1) % 3] == edge[1]) return triangle[(corner + 2) % 3];
    }
    return null;
}

fn emitImages(allocator: std.mem.Allocator, data: *std.ArrayList(u8), source: *std.ArrayList(u8), document: Document, binary: []const u8) !void {
    for (document.images, 0..) |image, image_index| {
        const png = try imageBytes(document, binary, image);
        const format = textureFormat(image.name) orelse return error.UnsupportedTextureFormat;
        const converted = try texture_compiler.convertPng(allocator, png, .{ .format = format });
        defer converted.deinit(allocator);
        while (data.items.len % 8 != 0) try data.append(allocator, 0);
        const offset = data.items.len;
        try data.appendSlice(allocator, converted.texels[0..converted.base_texel_bytes]);
        const image_type = imageType(converted.format) orelse return error.UnsupportedTextureFormat;
        try appendFormat(
            allocator,
            source,
            "const texture_{d}: n64.graphics.image.{s} = .{{ .width = {d}, .height = {d}, .texel_data = std.mem.bytesAsSlice(n64.graphics.image.{s}.Pixel, model_data[{d}..{d}]) }};\n",
            .{ image_index, image_type, converted.width, converted.height, image_type, offset, data.items.len },
        );
    }
}

fn emitParts(allocator: std.mem.Allocator, source: *std.ArrayList(u8), batches: []const Batch, name: []const u8) !void {
    try source.appendSlice(allocator, "const parts = [_]Part{\n");
    for (batches, 0..) |batch, batch_index| {
        try appendFormat(
            allocator,
            source,
            "    .{{ .vertices = vertices_{d}, .strip_indices = indices_{d}, .material_index = {d}, .vertex_count = {d} }},\n",
            .{ batch_index, batch_index, batch.material_index, batch.vertices.len },
        );
    }
    try appendFormat(allocator, source,
        \\}};
        \\pub const {s}: ModelAsset = .{{ .model = .{{ .parts = &parts }} }};
        \\pub const ModelAsset = struct {{
        \\    model: n64.graphics.model.Model,
        \\    pub fn draw(self: @This(), context: anytype) void {{ self.model.draw(context, Materials{{}}); }}
        \\}};
        \\pub const Materials = struct {{
        \\    pub fn apply(_: @This(), context: anytype, index: u16) void {{
        \\        switch (index) {{
        \\
    , .{name});
}

fn emitMaterials(allocator: std.mem.Allocator, source: *std.ArrayList(u8), document: Document, binary: []const u8) !void {
    for (document.materials, 0..) |material, material_index| {
        const texture_index = materialImageIndex(document, material);
        const culling = materialCulling(material);
        const is_blended = materialIsBlended(material);
        const depth_write = !is_blended;
        const blend_mode = if (is_blended) "alpha" else "opaque_surface";
        if (texture_index) |image_index| {
            const sampler = materialSampler(document, binary, material, image_index);
            try appendFormat(
                allocator,
                source,
                "            {d} => {{ context.setDrawFlags(.{{ .depth = true, .textured = true, .shaded = true, .cull_front = {}, .cull_back = {} }}); context.render.setDepthState(true, {}); context.render.setPerspectiveTexture(true); context.render.setBlendMode(.{s}); context.render.setCombineMode(.single(.{{ .rgb_a = .tex0, .rgb_c = .shade, .alpha_d = .{s} }})); _ = context.render.useTextureSampler(texture_{d}, .{{ .clamp_s = {}, .clamp_t = {}, .mirror_s = {}, .mirror_t = {}, .mask_s = {d}, .mask_t = {d} }}); }},\n",
                .{ material_index, culling.front, culling.back, depth_write, blend_mode, if (is_blended) "tex0" else "one", image_index, sampler.clamp_s, sampler.clamp_t, sampler.mirror_s, sampler.mirror_t, sampler.mask_s, sampler.mask_t },
            );
        } else {
            try appendFormat(
                allocator,
                source,
                "            {d} => {{ context.setDrawFlags(.{{ .depth = true, .shaded = true, .cull_front = {}, .cull_back = {} }}); context.render.setDepthState(true, {}); context.render.setBlendMode(.{s}); context.render.setCombineMode(.single(.{{ .rgb_a = .shade, .rgb_c = .primitive, .alpha_d = .{s} }})); }},\n",
                .{ material_index, culling.front, culling.back, depth_write, blend_mode, if (is_blended) "shade" else "one" },
            );
        }
    }
    try source.appendSlice(
        allocator,
        "            65535 => { context.setDrawFlags(.{ .depth = true, .shaded = true }); context.render.setDepthState(true, true); context.render.setBlendMode(.opaque_surface); context.render.setCombineMode(.shade); },\n",
    );
    try source.appendSlice(allocator,
        \\            else => @panic("invalid model material index"),
        \\        }
        \\    }
        \\};
        \\
    );
}

fn materialCulling(material: Material) struct { front: bool, back: bool } {
    const extension = material.extensions orelse return .{ .front = false, .back = false };
    const fast64 = extension.FAST64_materials_f3d orelse nested: {
        const n64 = extension.FAST64_materials_n64 orelse return .{ .front = false, .back = false };
        const nested_extensions = n64.extensions orelse return .{ .front = false, .back = false };
        break :nested nested_extensions.FAST64_materials_f3d orelse return .{ .front = false, .back = false };
    };
    return .{ .front = fast64.geometryMode.cullFront, .back = fast64.geometryMode.cullBack };
}

fn materialIsBlended(material: Material) bool {
    if (material.alphaMode != .BLEND) return false;
    const extension = material.extensions orelse return true;
    const fast64 = extension.FAST64_materials_n64 orelse return true;
    const other_modes = fast64.otherModes orelse return false;
    const render_mode = other_modes.renderMode orelse return false;
    for (render_mode.presets) |preset| {
        if (std.mem.indexOf(u8, preset, "XLU") != null or
            std.mem.indexOf(u8, preset, "TRANSPARENT") != null)
        {
            return true;
        }
    }
    return false;
}

const GeneratedSampler = struct { clamp_s: bool, clamp_t: bool, mirror_s: bool, mirror_t: bool, mask_s: u4, mask_t: u4 };

fn materialSampler(document: Document, binary: []const u8, material: Material, image_index: u32) GeneratedSampler {
    const size = pngSize(document, binary, document.images[image_index]) orelse default_texture_size;
    const texture_ref = material.pbrMetallicRoughness.?.baseColorTexture.?;
    const texture_info = document.textures[texture_ref.index];
    const sampler = if (texture_info.sampler) |index|
        if (index < document.samplers.len) document.samplers[index] else Sampler{}
    else
        Sampler{};
    const s = samplerAxis(sampler.wrapS, size[0]);
    const t = samplerAxis(sampler.wrapT, size[1]);
    return .{ .clamp_s = s.clamp, .clamp_t = t.clamp, .mirror_s = s.mirror, .mirror_t = t.mirror, .mask_s = s.mask, .mask_t = t.mask };
}

const SamplerAxis = struct { clamp: bool, mirror: bool, mask: u4 };

fn samplerAxis(wrap: u32, size: u32) SamplerAxis {
    if (wrap == 33071 or !std.math.isPowerOfTwo(size)) return .{ .clamp = true, .mirror = false, .mask = 0 };
    return .{ .clamp = false, .mirror = wrap == 33648, .mask = @intCast(std.math.log2_int(u32, size)) };
}

fn imageBytes(document: Document, binary: []const u8, image: Image) ![]const u8 {
    if (image.bufferView >= document.bufferViews.len) return error.InvalidImage;
    const view = document.bufferViews[image.bufferView];
    const start: usize = view.byteOffset;
    if (start > binary.len or view.byteLength > binary.len - start) return error.InvalidImage;
    return binary[start .. start + view.byteLength];
}

fn textureFormat(name: []const u8) ?texture_compiler.Format {
    const extension = std.fs.path.extension(name);
    if (extension.len >= 2) {
        if (texture_compiler.Format.parse(extension[1..])) |format| return format;
    }
    const stem = std.fs.path.stem(name);
    const format_extension = std.fs.path.extension(stem);
    if (format_extension.len < 2) return .rgba16;
    return texture_compiler.Format.parse(format_extension[1..]);
}

fn imageType(format: texture_compiler.Format) ?[]const u8 {
    const names = [_][]const u8{
        "", "", "ImgRgba16", "ImgRgba32", "",        "", "ImgYuv16", "",      "", "",
        "", "", "ImgIa4",    "ImgIa8",    "ImgIa16", "", "ImgI4",    "ImgI8",
    };
    const result = names[@intFromEnum(format)];
    return if (result.len == 0) null else result;
}

fn materialImageIndex(document: Document, material: Material) ?u32 {
    const pbr = material.pbrMetallicRoughness orelse return null;
    const reference = pbr.baseColorTexture orelse return null;
    if (reference.index >= document.textures.len) return null;
    const source = document.textures[reference.index].source;
    if (source >= document.images.len) return null;
    return source;
}

fn writePair(allocator: std.mem.Allocator, output: *std.ArrayList(u8), a: Vertex, b: Vertex) !void {
    try writeVertexHead(allocator, output, a);
    try writeVertexHead(allocator, output, b);
    try output.appendSlice(allocator, &a.color);
    try output.appendSlice(allocator, &b.color);
    try writeI16(allocator, output, a.uv[0]);
    try writeI16(allocator, output, a.uv[1]);
    try writeI16(allocator, output, b.uv[0]);
    try writeI16(allocator, output, b.uv[1]);
}

fn writeVertexHead(allocator: std.mem.Allocator, output: *std.ArrayList(u8), vertex: Vertex) !void {
    for (vertex.position) |component| try writeI16(allocator, output, component);
    try writeU16(allocator, output, vertex.normal);
}

fn writeI16(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: i16) !void {
    try writeU16(allocator, output, @bitCast(value));
}

fn writeU16(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    try output.appendSlice(allocator, &bytes);
}

fn appendFormat(allocator: std.mem.Allocator, output: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const value = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(value);
    try output.appendSlice(allocator, value);
}

pub const ConvertOptions = struct {
    scale: f32 = 64,
    max_vertices_per_batch: usize = 70,
};

pub fn convert(allocator: std.mem.Allocator, document: Document, binary: []const u8, options: ConvertOptions) !ConvertedModel {
    try validateConvertOptions(options);
    var batches: std.ArrayList(Batch) = .empty;
    errdefer {
        for (batches.items) |batch| batch.deinit(allocator);
        batches.deinit(allocator);
    }
    try convertMeshes(allocator, document, binary, options, &batches);
    return .{ .batches = try batches.toOwnedSlice(allocator) };
}

fn validateConvertOptions(options: ConvertOptions) !void {
    if (options.max_vertices_per_batch < 3) return error.InvalidBatchSize;
    if (options.max_vertices_per_batch > 70) return error.InvalidBatchSize;
}

fn convertMeshes(allocator: std.mem.Allocator, document: Document, binary: []const u8, options: ConvertOptions, batches: *std.ArrayList(Batch)) !void {
    for (document.meshes) |mesh| for (mesh.primitives) |primitive| {
        if (primitive.mode != 4) return error.UnsupportedPrimitiveMode;
        try convertPrimitive(allocator, document, binary, primitive, options, batches);
    };
}

const Remap = struct { source: u32, local: u8 };

fn convertPrimitive(
    allocator: std.mem.Allocator,
    document: Document,
    binary: []const u8,
    primitive: Primitive,
    options: ConvertOptions,
    output: *std.ArrayList(Batch),
) !void {
    const views = try PrimitiveViews.init(document, binary, primitive);
    var builder: BatchBuilder = .{
        .allocator = allocator,
        .views = views,
        .options = options,
        .material = primitive.material,
        .preserve_order = materialPreservesOrder(document, primitive.material),
        .output = output,
    };
    defer builder.deinit();
    const triangle_count = views.indices.count / 3;
    const used = try allocator.alloc(bool, triangle_count);
    defer allocator.free(used);
    @memset(used, false);
    try convertPrimitiveTriangles(&builder, used);
    try builder.finish();
}

fn convertPrimitiveTriangles(builder: *BatchBuilder, used: []bool) !void {
    if (builder.preserve_order) {
        for (used, 0..) |_, index| try builder.addTriangle(index * 3);
        return;
    }
    var remaining = used.len;
    while (remaining != 0) {
        const best = try selectBestTriangle(builder, used);
        if (best == null) {
            try builder.finish();
            builder.remap.clearRetainingCapacity();
            continue;
        }
        try builder.addTriangle(best.? * 3);
        used[best.?] = true;
        remaining -= 1;
    }
}

fn selectBestTriangle(builder: *const BatchBuilder, used: []const bool) !?usize {
    var best: ?usize = null;
    var best_new_vertices: usize = 4;
    for (used, 0..) |is_used, index| {
        if (is_used) continue;
        const source = try builder.sourceTriangle(index * 3);
        const new_vertices = builder.newVertexCount(source);
        if (!builder.fitsAdditional(new_vertices) or new_vertices >= best_new_vertices) continue;
        best = index;
        best_new_vertices = new_vertices;
        if (new_vertices == 0) break;
    }
    return best;
}

const PrimitiveViews = struct {
    positions: AccessorView,
    normals: ?AccessorView,
    colors: ?AccessorView,
    uvs: ?AccessorView,
    indices: AccessorView,
    texture_size: [2]u32,

    fn init(document: Document, binary: []const u8, primitive: Primitive) !PrimitiveViews {
        // Parse skinning attributes now so they cannot be silently discarded
        // by the otherwise permissive glTF JSON decoder. The packed runtime
        // vertex ABI does not support them yet.
        if (primitive.attributes.JOINTS_0 != null or primitive.attributes.WEIGHTS_0 != null)
            return error.UnsupportedSkinning;
        const positions = try accessorView(document, binary, primitive.attributes.POSITION);
        if (positions.component_count != 3 or positions.component_type != 5126) return error.InvalidPositionAccessor;
        const indices = try accessorView(document, binary, primitive.indices);
        if (indices.count % 3 != 0) return error.InvalidTriangleIndices;
        return .{
            .positions = positions,
            .normals = try optionalAccessor(document, binary, primitive.attributes.NORMAL),
            .colors = try optionalAccessor(document, binary, primitive.attributes.COLOR_0),
            .uvs = try optionalAccessor(document, binary, primitive.attributes.TEXCOORD_0),
            .indices = indices,
            .texture_size = materialTextureSize(document, binary, primitive.material),
        };
    }
};

fn optionalAccessor(document: Document, binary: []const u8, index: ?u32) !?AccessorView {
    return if (index) |value| try accessorView(document, binary, value) else null;
}

const BatchBuilder = struct {
    allocator: std.mem.Allocator,
    views: PrimitiveViews,
    options: ConvertOptions,
    material: ?u32,
    preserve_order: bool,
    output: *std.ArrayList(Batch),
    remap: std.ArrayList(Remap) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    triangles: std.ArrayList(Triangle) = .empty,

    fn deinit(self: *BatchBuilder) void {
        self.remap.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.triangles.deinit(self.allocator);
    }

    fn addTriangle(self: *BatchBuilder, triangle_index: usize) !void {
        const source = try self.sourceTriangle(triangle_index);
        try self.flushIfFull(source);
        var triangle: Triangle = undefined;
        for (source, 0..) |index, corner| triangle[corner] = try self.localIndex(index);
        try self.triangles.append(self.allocator, triangle);
    }

    fn sourceTriangle(self: *const BatchBuilder, triangle_index: usize) ![3]u32 {
        return .{
            try self.views.indices.index(triangle_index),
            try self.views.indices.index(triangle_index + 1),
            try self.views.indices.index(triangle_index + 2),
        };
    }

    fn flushIfFull(self: *BatchBuilder, source: [3]u32) !void {
        if (self.vertices.items.len == 0) return;
        const new_count = self.newVertexCount(source);
        if (batchFits(self.vertices.items.len + new_count, self.triangles.items.len + 1, self.options.max_vertices_per_batch)) return;
        try self.finish();
        self.remap.clearRetainingCapacity();
    }

    fn newVertexCount(self: *const BatchBuilder, source: [3]u32) usize {
        var count: usize = 0;
        for (source) |index| if (findRemap(self.remap.items, index) == null) {
            count += 1;
        };
        return count;
    }

    fn fitsAdditional(self: *const BatchBuilder, new_vertices: usize) bool {
        return batchFits(self.vertices.items.len + new_vertices, self.triangles.items.len + 1, self.options.max_vertices_per_batch);
    }

    fn localIndex(self: *BatchBuilder, index: u32) !u8 {
        if (index >= self.views.positions.count) return error.InvalidVertexIndex;
        if (findRemap(self.remap.items, index)) |local| return local;
        const local: u8 = @intCast(self.vertices.items.len);
        try self.vertices.append(self.allocator, try convertVertex(self.views.positions, self.views.normals, self.views.colors, self.views.uvs, index, self.views.texture_size, self.options.scale));
        try self.remap.append(self.allocator, .{ .source = index, .local = local });
        return local;
    }

    fn finish(self: *BatchBuilder) !void {
        try finishBatch(self.allocator, self.output, &self.vertices, &self.triangles, self.material, self.preserve_order);
    }
};

fn batchFits(unique_vertices: usize, triangle_count: usize, max_vertices: usize) bool {
    const vertex_workspace_size = 2520;
    const strip_end_padding = 16;
    const loaded_vertices = (unique_vertices + 1) & ~@as(usize, 1);
    if (loaded_vertices > max_vertices) return false;
    const vertex_end = loaded_vertices * 36;
    const index_bytes = triangle_count * 3 * @sizeOf(i16);
    if (index_bytes > vertex_workspace_size - strip_end_padding) return false;
    const index_start = (vertex_workspace_size - strip_end_padding - index_bytes) & ~@as(usize, 7);
    return vertex_end <= index_start;
}

fn finishBatch(allocator: std.mem.Allocator, output: *std.ArrayList(Batch), vertices: *std.ArrayList(Vertex), triangles: *std.ArrayList(Triangle), material: ?u32, preserve_order: bool) !void {
    if (triangles.items.len == 0) return;
    if (vertices.items.len % 2 != 0) try vertices.append(allocator, vertices.items[vertices.items.len - 1]);
    try output.append(allocator, .{
        .vertices = try vertices.toOwnedSlice(allocator),
        .triangles = try triangles.toOwnedSlice(allocator),
        .material_index = if (material) |index| @intCast(index) else std.math.maxInt(u16),
        .preserve_order = preserve_order,
    });
}

fn materialPreservesOrder(document: Document, material: ?u32) bool {
    const index = material orelse return false;
    if (index >= document.materials.len) return false;
    return materialIsBlended(document.materials[index]);
}

fn findRemap(remap: []const Remap, source: u32) ?u8 {
    for (remap) |entry| if (entry.source == source) return entry.local;
    return null;
}

fn convertVertex(positions: AccessorView, normals: ?AccessorView, colors: ?AccessorView, uvs: ?AccessorView, index: u32, texture_size: [2]u32, scale: f32) !Vertex {
    return .{
        .position = try convertPosition(positions, index, scale),
        .normal = if (normals) |view| try convertNormal(view, index) else 0,
        .color = if (colors) |view| try convertColor(view, index) else .{ 255, 255, 255, 255 },
        .uv = if (uvs) |view| try convertUv(view, index, texture_size) else .{ 0, 0 },
    };
}

fn convertPosition(view: AccessorView, index: u32, scale: f32) ![3]i16 {
    var result: [3]i16 = undefined;
    for (0..3) |component| {
        const scaled = @round(try view.float(index, component) * scale);
        if (scaled < -32768 or scaled > 32767) return error.PositionOutOfRange;
        result[component] = @intFromFloat(scaled);
    }
    return result;
}

fn convertNormal(view: AccessorView, index: u32) !u16 {
    if (view.component_count != 3 or index >= view.count) return error.InvalidNormalAccessor;
    return packNormal(.{ try view.float(index, 0), try view.float(index, 1), try view.float(index, 2) });
}

fn convertColor(view: AccessorView, index: u32) ![4]u8 {
    if ((view.component_count != 3 and view.component_count != 4) or index >= view.count) return error.InvalidColorAccessor;
    var result: [4]u8 = .{ 255, 255, 255, 255 };
    for (0..view.component_count) |component| {
        const linear = std.math.clamp(try view.float(index, component), 0, 1);
        const value = if (component < 3) std.math.pow(f32, linear, 0.4545) else linear;
        result[component] = @intFromFloat(@round(value * 255));
    }
    return result;
}

fn convertUv(view: AccessorView, index: u32, texture_size: [2]u32) ![2]i16 {
    if (view.component_count != 2 or index >= view.count) return error.InvalidUvAccessor;
    var result: [2]i16 = undefined;
    for (0..2) |component| {
        const value = try view.float(index, component) * @as(f32, @floatFromInt(texture_size[component])) * 32;
        if (value < -32768 or value > 32767) return error.UvOutOfRange;
        result[component] = @intFromFloat(value);
    }
    return result;
}

fn packNormal(value: [3]f32) u16 {
    const length = @sqrt(value[0] * value[0] + value[1] * value[1] + value[2] * value[2]);
    if (length == 0) return 0;
    const x: i16 = @intFromFloat(@round(std.math.clamp(value[0] / length * 15.5, -16, 15)));
    const y: i16 = @intFromFloat(@round(std.math.clamp(value[1] / length * 31.5, -32, 31)));
    const z: i16 = @intFromFloat(@round(std.math.clamp(value[2] / length * 15.5, -16, 15)));
    return (@as(u16, @bitCast(x)) & 0x1f) << 11 | (@as(u16, @bitCast(y)) & 0x3f) << 5 | (@as(u16, @bitCast(z)) & 0x1f);
}

fn materialTextureSize(document: Document, binary: []const u8, material_index: ?u32) [2]u32 {
    const index = material_index orelse return default_texture_size;
    if (index >= document.materials.len) return default_texture_size;
    const image_index = materialImageIndex(document, document.materials[index]) orelse return default_texture_size;
    return pngSize(document, binary, document.images[image_index]) orelse default_texture_size;
}

const default_texture_size = [2]u32{ 32, 32 };

fn pngSize(document: Document, binary: []const u8, image: Image) ?[2]u32 {
    if (image.bufferView >= document.bufferViews.len) return null;
    const view = document.bufferViews[image.bufferView];
    const start: usize = view.byteOffset;
    if (view.byteLength < 24 or start > binary.len or view.byteLength > binary.len - start) return null;
    const png = binary[start..][0..view.byteLength];
    if (!std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return null;
    return .{ std.mem.readInt(u32, png[16..20], .big), std.mem.readInt(u32, png[20..24], .big) };
}

fn componentCount(kind: []const u8) ?usize {
    if (std.mem.eql(u8, kind, "SCALAR")) return 1;
    if (std.mem.eql(u8, kind, "VEC2")) return 2;
    if (std.mem.eql(u8, kind, "VEC3")) return 3;
    if (std.mem.eql(u8, kind, "VEC4")) return 4;
    return null;
}

fn componentSize(kind: u32) ?usize {
    return switch (kind) {
        5120, 5121 => 1,
        5122, 5123 => 2,
        5125, 5126 => 4,
        else => null,
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}
fn readI16(bytes: []const u8) i16 {
    return @bitCast(readU16(bytes));
}

pub const Error = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidLength,
    MissingJson,
    MissingBinary,
    InvalidChunk,
};

/// Split a glTF 2.0 binary container without copying either payload.
pub fn parseGlb(bytes: []const u8) Error!Glb {
    try validateGlbHeader(bytes);
    return parseGlbChunks(bytes);
}

fn validateGlbHeader(bytes: []const u8) Error!void {
    if (bytes.len < 20) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..4], "glTF")) return error.InvalidMagic;
    if (readU32(bytes[4..8]) != 2) return error.UnsupportedVersion;
    if (readU32(bytes[8..12]) != bytes.len) return error.InvalidLength;
}

fn parseGlbChunks(bytes: []const u8) Error!Glb {
    var json: ?[]const u8 = null;
    var binary: ?[]const u8 = null;
    var offset: usize = 12;
    while (offset < bytes.len) {
        const chunk = try parseChunk(bytes, offset);
        const kind = bytes[offset + 4 ..][0..4];
        const payload = chunk.payload;
        if (std.mem.eql(u8, kind, "JSON")) json = payload else if (std.mem.eql(u8, kind, "BIN\x00")) binary = payload;
        offset = chunk.next;
    }
    return .{
        .json = json orelse return error.MissingJson,
        .binary = binary orelse return error.MissingBinary,
    };
}

const Chunk = struct { payload: []const u8, next: usize };

fn parseChunk(bytes: []const u8, offset: usize) Error!Chunk {
    if (bytes.len - offset < 8) return error.InvalidChunk;
    const length: usize = readU32(bytes[offset..][0..4]);
    const start = offset + 8;
    if (length > bytes.len - start) return error.InvalidChunk;
    return .{ .payload = bytes[start..][0..length], .next = start + length };
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

test "parse glb exposes JSON and binary chunks" {
    const bytes = [_]u8{
        'g', 'l', 'T', 'F', 2,   0,   0,   0,   32,  0,   0,   0,
        4,   0,   0,   0,   'J', 'S', 'O', 'N', '{', '}', ' ', ' ',
        0,   0,   0,   0,   'B', 'I', 'N', 0,
    };
    const glb = try parseGlb(&bytes);
    try std.testing.expectEqualStrings("{}  ", glb.json);
    try std.testing.expectEqual(@as(usize, 0), glb.binary.len);
}

test "parse glb rejects an out-of-bounds chunk" {
    var bytes = [_]u8{
        'g', 'l', 'T', 'F', 2,   0,   0,   0,   24,  0,   0,   0,
        8,   0,   0,   0,   'J', 'S', 'O', 'N', '{', '}', ' ', ' ',
    };
    try std.testing.expectError(error.InvalidChunk, parseGlb(&bytes));
}

test "document accessor views honor byte offsets and strides" {
    const json =
        \\{"accessors":[{"bufferView":0,"byteOffset":2,"componentType":5123,"count":2,"type":"VEC2"}],"bufferViews":[{"buffer":0,"byteOffset":1,"byteLength":12,"byteStride":6}],"meshes":[]}
    ;
    var parsed = try parseDocument(std.testing.allocator, json);
    defer parsed.deinit();
    const binary = [_]u8{ 99, 99, 99, 1, 0, 2, 0, 88, 88, 3, 0, 4, 0 };
    const view = try accessorView(parsed.value, &binary, 0);
    try std.testing.expectEqual(@as(f32, 1), try view.float(0, 0));
    try std.testing.expectEqual(@as(f32, 4), try view.float(1, 1));
}

test "generated model uses packed big-endian vertex data" {
    const vertices = try std.testing.allocator.dupe(Vertex, &.{
        .{ .position = .{ 1, -2, 3 }, .normal = 0x4567, .color = .{ 8, 9, 10, 11 }, .uv = .{ 12, 13 } },
        .{ .position = .{ 14, 15, 16 }, .normal = 0x1718, .color = .{ 19, 20, 21, 22 }, .uv = .{ 23, 24 } },
    });
    const triangles = try std.testing.allocator.dupe(Triangle, &.{.{ 0, 1, 0 }});
    const batches = try std.testing.allocator.dupe(Batch, &.{.{ .vertices = vertices, .triangles = triangles, .material_index = 3 }});
    const model: ConvertedModel = .{ .batches = batches };
    defer model.deinit(std.testing.allocator);
    const document: Document = .{ .accessors = &.{}, .bufferViews = &.{}, .meshes = &.{} };
    const generated = try generate(std.testing.allocator, model, document, &.{}, "fixture_model");
    defer generated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 38), generated.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0xff, 0xfe, 0, 3, 0x45, 0x67 }, generated.data[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 8, 9, 10, 11, 19, 20, 21, 22 }, generated.data[16..24]);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x24, 0x40, 0x00 }, generated.data[32..38]);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub const fixture_model") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, ".material_index = 3") != null);
}

test "stripifier preserves winding and marks disconnected strips" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try emitIndices(std.testing.allocator, &data, &.{ .{ 0, 1, 2 }, .{ 2, 1, 3 } }, false);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 36, 0, 72, 0x40, 108 }, data.items);

    data.clearRetainingCapacity();
    try emitIndices(std.testing.allocator, &data, &.{ .{ 0, 1, 2 }, .{ 3, 4, 5 } }, false);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 36, 0, 72, 0x80, 108, 0, 144, 0x40, 180 }, data.items);
}

test "ordered triangle encoding preserves translucent draw order" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try emitIndices(std.testing.allocator, &data, &.{ .{ 3, 4, 5 }, .{ 0, 1, 2 } }, true);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 108, 0, 144, 0, 180, 0x80, 0, 0, 36, 0x40, 72 },
        data.items,
    );
}

test "blend materials preserve order and skinning is explicit" {
    const blend_document: Document = .{
        .accessors = &.{},
        .bufferViews = &.{},
        .meshes = &.{},
        .materials = &.{.{ .alphaMode = .BLEND }},
    };
    try std.testing.expect(materialPreservesOrder(blend_document, 0));
    try std.testing.expect(!materialPreservesOrder(blend_document, null));

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try emitMaterials(std.testing.allocator, &source, blend_document, &.{});
    try std.testing.expect(std.mem.indexOf(u8, source.items, "setDepthState(true, false)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.items, "setBlendMode(.alpha)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.items, ".alpha_d = .shade") != null);

    const primitive: Primitive = .{
        .attributes = .{ .POSITION = 0, .JOINTS_0 = 1, .WEIGHTS_0 = 2 },
        .indices = 3,
    };
    try std.testing.expectError(error.UnsupportedSkinning, PrimitiveViews.init(blend_document, &.{}, primitive));
}

test "Fast64 blend wrapper uses its N64 render mode" {
    const document: Document = .{
        .accessors = &.{},
        .bufferViews = &.{},
        .meshes = &.{},
        .materials = &.{.{
            .alphaMode = .BLEND,
            .extensions = .{ .FAST64_materials_n64 = .{} },
        }},
    };
    try std.testing.expect(!materialPreservesOrder(document, 0));

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try emitMaterials(std.testing.allocator, &source, document, &.{});
    try std.testing.expect(std.mem.indexOf(u8, source.items, "setDepthState(true, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.items, "setBlendMode(.opaque_surface)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.items, ".alpha_d = .one") != null);

    const translucent = Material{
        .alphaMode = .BLEND,
        .extensions = .{ .FAST64_materials_n64 = .{
            .otherModes = .{ .renderMode = .{ .presets = &.{"AA_ZB_XLU_SURF"} } },
        } },
    };
    try std.testing.expect(materialIsBlended(translucent));
}

test "Fast64 nested material extension enables backface culling" {
    const json =
        \\{"accessors":[],"bufferViews":[],"meshes":[],"materials":[{"extensions":{"FAST64_materials_n64":{"extensions":{"FAST64_materials_f3d":{"geometryMode":{"cullBack":true}}}}}}]}
    ;
    var parsed = try parseDocument(std.testing.allocator, json);
    defer parsed.deinit();
    const culling = materialCulling(parsed.value.materials[0]);
    try std.testing.expect(!culling.front);
    try std.testing.expect(culling.back);
}

test "batch layout keeps strip indices separate from transformed vertices" {
    try std.testing.expect(batchFits(54, 18, 70));
    try std.testing.expect(!batchFits(70, 1, 70));
    try std.testing.expect(!batchFits(3, 600, 70));
    try std.testing.expect(!batchFits(72, 1, 70));
}

test "vertex conversion handles packed attributes and range errors" {
    const positions_bytes = std.mem.asBytes(&[_]f32{ 1.25, -2.5, 3.0 });
    const normals_bytes = std.mem.asBytes(&[_]f32{ 0, 1, 0 });
    const colors_bytes = [_]u8{ 64, 128, 255, 32 };
    const uv_bytes = std.mem.asBytes(&[_]f32{ 0.5, -0.25 });
    const position_view: AccessorView = .{ .bytes = positions_bytes, .count = 1, .stride = 12, .component_type = 5126, .component_count = 3, .normalized = false };
    const normal_view: AccessorView = .{ .bytes = normals_bytes, .count = 1, .stride = 12, .component_type = 5126, .component_count = 3, .normalized = false };
    const color_view: AccessorView = .{ .bytes = &colors_bytes, .count = 1, .stride = 4, .component_type = 5121, .component_count = 4, .normalized = true };
    const uv_view: AccessorView = .{ .bytes = uv_bytes, .count = 1, .stride = 8, .component_type = 5126, .component_count = 2, .normalized = false };
    const vertex = try convertVertex(position_view, normal_view, color_view, uv_view, 0, .{ 32, 16 }, 10);
    try std.testing.expectEqual([3]i16{ 13, -25, 30 }, vertex.position);
    try std.testing.expectEqual(packNormal(.{ 0, 1, 0 }), vertex.normal);
    try std.testing.expectEqual(@as(u8, 32), vertex.color[3]);
    try std.testing.expectEqual([2]i16{ 512, -128 }, vertex.uv);

    const huge_bytes = std.mem.asBytes(&[_]f32{ 40_000, 0, 0 });
    const huge: AccessorView = .{ .bytes = huge_bytes, .count = 1, .stride = 12, .component_type = 5126, .component_count = 3, .normalized = false };
    try std.testing.expectError(error.PositionOutOfRange, convertPosition(huge, 0, 1));
    try std.testing.expectError(error.InvalidNormalAccessor, convertNormal(uv_view, 0));
    try std.testing.expectError(error.InvalidColorAccessor, convertColor(uv_view, 0));
    try std.testing.expectError(error.InvalidUvAccessor, convertUv(normal_view, 0, .{ 1, 1 }));
    try std.testing.expectEqual(@as(u16, 0), packNormal(.{ 0, 0, 0 }));
}

test "accessor index decoding supports glTF unsigned integer types" {
    const u8_view: AccessorView = .{ .bytes = &.{7}, .count = 1, .stride = 1, .component_type = 5121, .component_count = 1, .normalized = false };
    const u16_view: AccessorView = .{ .bytes = &.{ 0x34, 0x12 }, .count = 1, .stride = 2, .component_type = 5123, .component_count = 1, .normalized = false };
    const u32_view: AccessorView = .{ .bytes = &.{ 0x78, 0x56, 0x34, 0x12 }, .count = 1, .stride = 4, .component_type = 5125, .component_count = 1, .normalized = false };
    try std.testing.expectEqual(@as(u32, 7), try u8_view.index(0));
    try std.testing.expectEqual(@as(u32, 0x1234), try u16_view.index(0));
    try std.testing.expectEqual(@as(u32, 0x12345678), try u32_view.index(0));
    try std.testing.expectError(error.InvalidAccessor, u8_view.index(1));
}

test "embedded PNG dimensions feed material UV conversion" {
    var png = [_]u8{0} ** 24;
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[16..20], 64, .big);
    std.mem.writeInt(u32, png[20..24], 32, .big);
    const document: Document = .{
        .accessors = &.{},
        .meshes = &.{},
        .bufferViews = &.{.{ .buffer = 0, .byteLength = png.len }},
        .materials = &.{.{ .pbrMetallicRoughness = .{ .baseColorTexture = .{ .index = 0 } } }},
        .textures = &.{.{ .source = 0, .sampler = 0 }},
        .samplers = &.{.{ .wrapS = 33071, .wrapT = 10497 }},
        .images = &.{.{ .bufferView = 0, .mimeType = "image/png", .name = "diffuse.i8.png" }},
    };
    try std.testing.expectEqual([2]u32{ 64, 32 }, materialTextureSize(document, &png, 0));
    try std.testing.expectEqual(default_texture_size, materialTextureSize(document, &png, 1));
    try std.testing.expectEqual(texture_compiler.Format.i8, textureFormat("diffuse.i8.png").?);
    try std.testing.expectEqual(texture_compiler.Format.i8, textureFormat("diffuse.i8").?);
    try std.testing.expectEqualStrings("ImgI8", imageType(.i8).?);
    try std.testing.expectEqual(@as(?[]const u8, null), imageType(.ci8));
    const sampler = materialSampler(document, &png, document.materials[0], 0);
    try std.testing.expect(sampler.clamp_s);
    try std.testing.expectEqual(@as(u4, 5), sampler.mask_t);
    try std.testing.expect(samplerAxis(33648, 32).mirror);
    try std.testing.expect(samplerAxis(10497, 96).clamp);
}

test "model conversion remaps vertices and splits hardware-safe batches" {
    const positions = [_]f32{
        0, 0, 0, 1, 0, 0, 0, 1, 0,
        2, 0, 0, 3, 0, 0, 2, 1, 0,
    };
    var binary: [positions.len * @sizeOf(f32) + 6]u8 = undefined;
    @memcpy(binary[0 .. positions.len * @sizeOf(f32)], std.mem.asBytes(&positions));
    @memcpy(binary[positions.len * @sizeOf(f32) ..], &[_]u8{ 0, 1, 2, 3, 4, 5 });
    const position_bytes = positions.len * @sizeOf(f32);
    const document: Document = .{
        .accessors = &.{
            .{ .bufferView = 0, .componentType = 5126, .count = 6, .type = "VEC3" },
            .{ .bufferView = 1, .componentType = 5121, .count = 6, .type = "SCALAR" },
        },
        .bufferViews = &.{
            .{ .buffer = 0, .byteLength = position_bytes },
            .{ .buffer = 0, .byteOffset = position_bytes, .byteLength = 6 },
        },
        .meshes = &.{.{ .primitives = &.{.{ .attributes = .{ .POSITION = 0 }, .indices = 1, .material = 2 }} }},
    };
    const model = try convert(std.testing.allocator, document, &binary, .{ .scale = 8, .max_vertices_per_batch = 4 });
    defer model.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), model.batches.len);
    try std.testing.expectEqual(@as(usize, 4), model.batches[0].vertices.len);
    try std.testing.expectEqual(@as(u16, 2), model.batches[1].material_index);
    try std.testing.expectEqual(Triangle{ 0, 1, 2 }, model.batches[1].triangles[0]);
    try std.testing.expectError(error.InvalidBatchSize, convert(std.testing.allocator, document, &binary, .{ .max_vertices_per_batch = 2 }));

    var unsupported = document;
    unsupported.meshes = &.{.{ .primitives = &.{.{ .attributes = .{ .POSITION = 0 }, .indices = 1, .mode = 5 }} }};
    try std.testing.expectError(error.UnsupportedPrimitiveMode, convert(std.testing.allocator, unsupported, &binary, .{}));
}

test "helper validation rejects invalid embedded ranges" {
    const document: Document = .{ .accessors = &.{}, .meshes = &.{}, .bufferViews = &.{.{ .buffer = 0, .byteOffset = 4, .byteLength = 8 }} };
    try std.testing.expectError(error.InvalidImage, imageBytes(document, &.{ 0, 1, 2 }, .{ .bufferView = 0 }));
    _ = signedFloat(&.{0xff}, 5120, true);
    _ = signedFloat(&.{ 0xff, 0x7f }, 5122, false);
}
