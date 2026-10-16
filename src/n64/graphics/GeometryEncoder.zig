const std = @import("std");
const cache = @import("../cpu/cache.zig");
const math = @import("../math.zig");
const rsp = @import("../rsp.zig");
const rdp = @import("../rdp.zig");
const RdpRenderer = @import("../rdp/Renderer.zig");
const Rgba32 = @import("pixel.zig").Rgba32;
const RecordedModel = @import("RecordedModel.zig");
const geometry = @import("geometry.zig");
const DrawFlags = geometry.DrawFlags;
const VertexEffect = geometry.VertexEffect;
const VertexPair = geometry.VertexPair;
const Viewport = geometry.Viewport;
const max_lights = geometry.max_lights;
const vertex_output_size = 36;

const GeometryEncoder = @This();

renderer: *RdpRenderer,
queue: *rsp.Queue,
geometry_overlay: rsp.Overlay,
render: *rdp.RenderEncoder(rdp.backend.Overlay),
matrix_stack: [8]math.FixedMat4 align(16),
view_matrix: math.Mat4,
draw_flags: DrawFlags = .{},
/// Fog state currently selected on the RSP.
fog_enabled: bool = false,
/// Fog state materials inherit when their `fog` is null (set by setFogEnabled).
fog_default: bool = false,
/// A strip drawn with `sync = false` may have left the clipping code loaded
/// over the geometry microcode; it must be synced before any other command.
triangles_pending: bool = false,
vertex_effect: VertexEffect = .none,
last_draw_flags: ?DrawFlags = null,
last_material_tile: u3 = 0,
/// Matrices in the pose bound by setPose; model bones index into it.
pose_len: usize = 0,

/// Attach geometry to an idle renderer. Borrows its RSP queue and RDP state,
/// registering geometry only when needed. Keep both at stable addresses.
/// Only one geometry context may attach to a renderer at a time.
pub fn init(self: *GeometryEncoder, renderer: *RdpRenderer) void {
    std.debug.assert(!renderer.geometry_attached);
    std.debug.assert(!renderer.queue.storage.syncpoint_pending);
    self.renderer = renderer;
    self.queue = &renderer.queue;
    self.render = &renderer.render;
    self.geometry_overlay.init(rsp.programs.geometry_overlay);
    rsp.registerOverlayStatic(&self.geometry_overlay, 1);
    renderer.geometry_attached = true;
    @memset(&self.matrix_stack, math.FixedMat4.identity);
    self.view_matrix = .identity;
    self.draw_flags = .{};
    self.fog_enabled = false;
    self.fog_default = false;
    self.triangles_pending = false;
    self.vertex_effect = .none;
    self.last_draw_flags = null;
    self.pose_len = 0;
    self.last_material_tile = 0;
    cache.writebackData(&self.matrix_stack);
    const program = self.geometry_overlay.program;
    const symbols = rsp.programs.geometry_overlay_symbols;
    const state_start = program.state_offset;
    var state = rsp.overlayState(&self.geometry_overlay);
    const matrix_stack_pointer_offset = symbols.matrix_stack_pointer - state_start;
    std.mem.writeInt(u32, state[matrix_stack_pointer_offset..][0..4], physical(&self.matrix_stack), .big);
    const vertex_effect_none = symbols.VertexFX_None;
    const vertex_effect_function_offset = symbols.vertex_effect_function - state_start;
    std.mem.writeInt(u16, state[vertex_effect_function_offset..][0..2], vertex_effect_none, .big);
    rsp.writebackOverlayState(&self.geometry_overlay);

    // Enter the main overlay once while its lazy-code pointer is zero.
    // Its entry stub uses that pointer during the initial load.
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 3, 0x8000 | symbols.active_light_size, &.{0});
    rsp.flush(self.queue);
    rsp.wait(self.queue);

    const clipping = rsp.programs.geometry_clipping;
    const clipping_imem_start = symbols._start;
    if (symbols.geometry_RDPQ_Triangle_Send_Async != 0x400 or
        symbols.geometry_RDPQ_Triangle_Send_End != 0x85c or
        clipping_imem_start != 0x880)
    {
        @panic("geometry clipping payload jump targets need relocation");
    }
    if (rsp.programs.geometry_clipping_symbols.geometry_clipping_code_start != clipping_imem_start)
        @panic("geometry clipping overlays disagree on their linked IMEM target");
    const clipping_payload_offset = clipping_imem_start - clipping.text_offset;
    const geometry_restore_offset = clipping_imem_start - self.geometry_overlay.program.text_offset;
    const clipping_size: u16 = @intCast(clipping.text.len - clipping_payload_offset);
    const clipping_address = physical(clipping.text.ptr + clipping_payload_offset);
    const original_address = physical(self.geometry_overlay.program.text.ptr + geometry_restore_offset);
    state = rsp.overlayState(&self.geometry_overlay);
    const clipping_code_size_offset = symbols.clipping_code_size - state_start;
    const clipping_code_address_offset = symbols.clipping_code_address - state_start;
    const original_code_address_offset = symbols.original_code_address - state_start;
    std.mem.writeInt(u16, state[clipping_code_size_offset..][0..2], clipping_size, .big);
    std.mem.writeInt(u32, state[clipping_code_address_offset..][0..4], clipping_address, .big);
    std.mem.writeInt(u32, state[original_code_address_offset..][0..4], original_address, .big);
    rsp.writebackOverlayState(&self.geometry_overlay);
    @import("../hw/sp.zig").readDmem(u32, state_start + clipping_code_address_offset).* = clipping_address;
    @import("../hw/sp.zig").readDmem(u32, state_start + original_code_address_offset).* = original_address;
    if (symbols.clipping_code_size != symbols.vertex_effect_function + @sizeOf(u16)) {
        @panic("geometry clipping metadata layout changed");
    }
    // Publish the adjacent halfwords with one aligned DMEM write. A lone
    // CPU halfword write to clipping_code_size was lost on N64 hardware,
    // leaving the restore DMA length at zero when clipping first ran.
    @import("../hw/sp.zig").readDmem(u32, symbols.vertex_effect_function).* =
        @as(u32, vertex_effect_none) << 16 | clipping_size;
}

/// Complete all geometry work and recorded calls before detaching. Does
/// not deinitialize the borrowed renderer; it remains usable for 2D work.
pub fn deinit(self: *GeometryEncoder) void {
    std.debug.assert(!self.queue.storage.syncpoint_pending);
    rsp.unregisterOverlay(&self.geometry_overlay);
    self.renderer.geometry_attached = false;
    self.render.invalidateState();
    self.* = undefined;
}

pub fn attachViewport(self: *GeometryEncoder, viewport: *const Viewport) void {
    self.settleTriangles();
    self.view_matrix = viewport.camera_float;
    cache.writebackData(viewport);
    const normalized_w: u16 = @intFromFloat(@round(65535.0 * viewport.w_normalization));
    const normalized_w_float = @as(f32, @floatFromInt(normalized_w)) / 65535.0;
    const scale_x: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(viewport.width)) * normalized_w_float * 1024.0));
    const scale_y: i32 = @intFromFloat(@ceil(-@as(f32, @floatFromInt(viewport.height)) * normalized_w_float * 1024.0));
    const offset = (@as(u32, viewport.width) << 17) | (@as(u32, viewport.height) << 1);
    const scale = (@as(u32, @bitCast(scale_x)) & 0xffff) << 16 |
        (@as(u32, @bitCast(scale_y)) & 0xffff);
    const depth_scale: u16 = @intFromFloat(@min(
        @round(65535.0 * normalized_w_float * 128.0),
        32767.0,
    ));
    const depth_and_w_scale = @as(u32, depth_scale) << 16 | normalized_w;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 1, 2 | (0x2a00 / viewport.width) << 8, &.{ offset, scale, depth_and_w_scale });
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 7, physical(&viewport.projection), &.{});
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, 0, &.{physical(&viewport.camera)});
}

/// Bind borrowed frame targets and perform explicitly requested clears.
/// Previous frame work must be complete. Geometry and pipeline state persist.
pub fn beginFrame(self: *GeometryEncoder, image: anytype, options: rdp.FrameOptions(@TypeOf(image).Pixel)) void {
    self.render.beginFrame(image, options);
}

/// Submit geometry and RDP work together. Keep this context and borrowed
/// vertex/matrix storage alive until the returned completion finishes.
pub fn submit(self: *GeometryEncoder) rdp.Completion {
    self.syncTriangles();
    return self.render.submit();
}

/// Draw a model asset with its typed material provider. Does not submit or wait.
pub fn drawModel(self: *GeometryEncoder, asset: anytype) void {
    self.drawModelWithMaterials(asset.model, asset.materials);
}

/// Draw packed model geometry using custom material bindings.
pub fn drawModelWithMaterials(self: *GeometryEncoder, model: @import("Model.zig"), materials: anytype) void {
    @import("model/draw.zig").draw(self, model, materials);
}

/// Push a borrowed transform, draw an asset, and restore the previous matrix.
/// Keep the transform and asset storage alive until submission completes.
pub fn drawModelWithTransform(self: *GeometryEncoder, asset: anytype, matrix: *const math.FixedMat4) void {
    @import("model/draw.zig").drawWithTransform(self, asset, matrix);
}

/// Record a typed asset's immutable geometry and material commands.
pub fn recordModel(self: *GeometryEncoder, recorded: *RecordedModel, asset: anytype) void {
    recorded.record(self, asset.model, asset.materials);
}

/// Replay recorded commands with a borrowed transform, restoring the matrix stack.
pub fn drawRecordedWithTransform(self: *GeometryEncoder, recorded: *const RecordedModel, matrix: *const math.FixedMat4) void {
    self.pushMatrix(matrix);
    recorded.draw(self);
    self.popMatrix();
}

pub fn setAmbientLight(self: *GeometryEncoder, color: Rgba32) void {
    self.settleTriangles();
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 5, rsp.programs.geometry_overlay_symbols.ambient_color, &.{ @as(u32, @bitCast(color)), 0, 0 });
}
pub fn setLightCount(self: *GeometryEncoder, count: u8) void {
    if (count > max_lights) @panic("too many lights");
    self.settleTriangles();
    self.queue.writeOverlayCommandKnown(
        &self.geometry_overlay,
        3,
        rsp.programs.geometry_overlay_symbols.active_light_size | 0x8000,
        &.{@as(u32, count) << 12},
    );
}
/// Set the first directional light and make it active.
pub fn setDirectionalLight(self: *GeometryEncoder, color: Rgba32, direction: math.Vec3) void {
    self.setDirectionalLightAt(0, color, direction);
    self.setLightCount(1);
}
/// Configure a directional-light slot. Call `setLightCount` to select how
/// many consecutively numbered slots participate in lighting.
pub fn setDirectionalLightAt(self: *GeometryEncoder, index: u8, color: Rgba32, direction: math.Vec3) void {
    if (index >= max_lights) @panic("invalid light index");
    self.settleTriangles();
    const n = self.view_matrix.transformDirection(direction).normalized();
    const x: u8 = @bitCast(@as(i8, @intFromFloat(n.x * 127.0)));
    const y: u8 = @bitCast(@as(i8, @intFromFloat(n.y * 127.0)));
    const z: u8 = @bitCast(@as(i8, @intFromFloat(n.z * 127.0)));
    const packed_direction = @as(u32, x) << 24 | @as(u32, y) << 16 | @as(u32, z) << 8;
    const light_address = rsp.programs.geometry_overlay_symbols.directional_light_color + @as(u32, index) * 16;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 5, light_address, &.{ @as(u32, @bitCast(color)), packed_direction, packed_direction });
}
/// Enable fog for following draws, and as the default for materials whose
/// `fog` is null.
pub fn setFogEnabled(self: *GeometryEncoder, enabled: bool) void {
    self.fog_default = enabled;
    self.emitFog(enabled);
}

/// Select fog for one material without changing the inherited default.
/// Emits nothing when the RSP already has this state (outside recording).
pub fn setMaterialFog(self: *GeometryEncoder, enabled: bool) void {
    if (enabled == self.fog_enabled and self.queue.recording == null) return;
    self.emitFog(enabled);
}

fn emitFog(self: *GeometryEncoder, enabled: bool) void {
    self.settleTriangles();
    self.fog_enabled = enabled;
    // The vertex loader stores a halfword at this attribute offset. When
    // enabled its high byte replaces shade alpha; otherwise UV is scratch
    // until the vertex effect writes the final texture coordinates.
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 9, if (enabled) 0x0b else 0x0c, &.{});
}
/// Configure a shared light slot using a world-space position. Strength is
/// Tiny3D's distance/falloff parameter, clamped to 0..4096. Ignoring normals
/// produces a spherical light field, useful for alpha reveals. Attach the
/// viewport first and activate slots with setLightCount.
pub fn setPointLightAt(self: *GeometryEncoder, index: u8, color: Rgba32, position: math.Vec3, strength: f32, ignore_normals: bool) void {
    if (index >= max_lights) @panic("invalid light index");
    self.settleTriangles();
    const words = @import("lighting.zig").point(&self.view_matrix, position, strength, ignore_normals);
    const address = rsp.programs.geometry_overlay_symbols.directional_light_color + @as(u32, index) * 16;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 5, address, &.{ @as(u32, @bitCast(color)), words[0], words[1] });
    // The shared light command treats a zero first position word as a
    // color-only update. Preserve points on the view-space Z axis too.
    if (words[0] == 0) {
        self.queue.writeDmem(address + 8, 0);
        self.queue.writeDmem(address + 12, words[1]);
    }
}

pub fn setVertexEffect(self: *GeometryEncoder, effect: VertexEffect) void {
    self.settleTriangles();
    self.vertex_effect = effect;
    const symbols = rsp.programs.geometry_overlay_symbols;
    const function: u16 = switch (effect) {
        .none => symbols.VertexFX_None,
        .spherical => symbols.VertexFX_Spherical,
    };
    const args: u32 = switch (effect) {
        .none => 0,
        .spherical => |size| @as(u32, size.width) * 16 << 16 | @as(u16, @bitCast(-@as(i16, size.height) * 16)),
    };
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 3, 0x8000 | symbols.vertex_effect_function, &.{function});
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 3, symbols.uv_generation_parameters, &.{args});
}
pub fn setFogRange(self: *GeometryEncoder, near: f32, far: f32) void {
    self.settleTriangles();
    const address = rsp.programs.geometry_overlay_symbols.fog_scale_offset;
    if (near == 0 and far == 0) {
        self.queue.writeDmem(address, 0);
        self.queue.writeDmem(address + 4, 0x7fff0000);
        return;
    }
    var difference = far - near;
    if (@abs(difference) < 1.5) difference = 1.5;
    const scale_float = std.math.clamp(math.fast.floor(16384.0 / difference), -32768.0, 32767.0);
    const scale: u16 = @bitCast(@as(i16, @intFromFloat(scale_float)));
    const offset: i32 = @intFromFloat(-near * 2.0 * 65536.0);
    self.queue.writeDmem(address, @bitCast(offset));
    // The upper halfword is the full-intensity constant used by both fog
    // and unlit vertex colors. Only the lower halfword is the fog scale.
    self.queue.writeDmem(address + 4, 0x7fff0000 | @as(u32, scale));
}
pub fn setDrawFlags(self: *GeometryEncoder, flags: DrawFlags) void {
    // Material changes are followed by RDP state commands.
    self.settleTriangles();
    self.draw_flags = flags;
    self.emitDrawFlags();
}

fn emitDrawFlags(self: *GeometryEncoder) void {
    const flags = self.draw_flags;
    if (flags.cull_front and flags.cull_back) @panic("cannot cull both triangle faces");
    if (self.last_draw_flags) |previous| {
        if (std.meta.eql(previous, flags) and self.last_material_tile == self.render.material_tile) return;
    }
    self.settleTriangles();
    self.last_draw_flags = flags;
    self.last_material_tile = self.render.material_tile;
    // Match Tiny3D's host-side ABI (the triangle include's historical
    // comment describes these two selector values in reverse).
    const culling: u32 = if (flags.cull_front) 1 else if (flags.cull_back) 0 else 2;
    var bits: u32 = @as(u17, @bitCast(flags));
    bits &= ~@as(u32, (1 << 3) | (1 << 4));
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 6, culling, &.{0xc000 | ((bits | 8) << 8) | @as(u32, self.render.material_tile)});
}
/// Bind fixed global bone matrices for first-joint assets. Borrowed until
/// submission completes. Segmented addresses keep recorded model blocks
/// independent of the current pose buffer.
pub fn setPose(self: *GeometryEncoder, matrices: []const math.FixedMat4) void {
    cache.writebackData(matrices);
    self.settleTriangles();
    self.pose_len = matrices.len;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 3, rsp.programs.geometry_overlay_symbols.segment_table + 4, &.{physical(matrices.ptr)});
}

pub const pose_panic = "model bone is outside the bound pose; bind one matrix per skeleton node";

pub fn setBoneMatrix(self: *GeometryEncoder, node: u16, push: bool) void {
    // The RSP reads pose[node] without bounds; a short pose draws garbage.
    // Recorded blocks bind their pose at replay, so RecordedModel checks then.
    if (self.queue.recording == null and node >= self.pose_len) @panic(pose_panic);
    self.settleTriangles();
    const address = (@as(u32, 4) << 24) | @as(u32, node) * 64;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, (if (push) @as(u32, 64 << 8) else 0) | 1, &.{address});
}

pub fn pushMatrix(self: *GeometryEncoder, matrix: *const math.FixedMat4) void {
    cache.writebackData(matrix);
    self.settleTriangles();
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, (64 << 8) | 1, &.{physical(matrix)});
}
/// Load a matrix, optionally multiplying it by the current matrix.
pub fn setMatrix(self: *GeometryEncoder, matrix: *const math.FixedMat4, multiply: bool) void {
    cache.writebackData(matrix);
    self.settleTriangles();
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, @intFromBool(multiply), &.{physical(matrix)});
}
/// Reserve matrix-stack slots without loading matrices into them.
pub fn advanceMatrixStack(self: *GeometryEncoder, count: u8) void {
    const advance = @as(u32, count) * 64;
    if (advance > std.math.maxInt(i16)) @panic("matrix stack advance is too large");
    self.settleTriangles();
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, (advance << 8) | 2, &.{0});
}
pub fn popMatrix(self: *GeometryEncoder) void {
    self.settleTriangles();
    const stack_advance = @as(u32, @bitCast(@as(i32, -64 << 8))) & 0x00ff_ff00;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, stack_advance, &.{0});
}
pub fn loadVertices(self: *GeometryEncoder, vertices: []const VertexPair, offset: u8, count: u8) void {
    cache.writebackData(vertices);
    self.loadStaticVertices(vertices, offset, count);
}
/// Load immutable asset vertices which are already coherent in RDRAM.
pub fn loadStaticVertices(self: *GeometryEncoder, vertices: []const VertexPair, offset: u8, count: u8) void {
    if (count == 0 or count > vertices.len * 2) @panic("invalid geometry vertex count");
    self.settleTriangles();
    const symbols = rsp.programs.geometry_overlay_symbols;
    const vertex_buffer = symbols.vertex_buffer;
    const vertex_input_end = symbols.clipping_buffer_result + 6 * 16;
    const input_size: u32 = ((@as(u32, count) + 1) & ~@as(u32, 1)) * 16;
    const temp_address = (vertex_input_end - input_size) & ~@as(u32, 0xf);
    const output_address = vertex_buffer + @as(u32, offset) * vertex_output_size;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 4, input_size, &.{ physical(vertices.ptr), temp_address << 16 | output_address });
}
/// Draw one triangle from loaded vertices and sync it. Clipping replaces
/// part of the geometry microcode until the next sync, so an unsynced
/// immediate triangle would corrupt the following command. To draw many
/// triangles, prefer `drawTriangles` (one command and one sync per batch).
pub fn drawTriangle(self: *GeometryEncoder, a: u8, b: u8, c: u8) void {
    self.beginModelMaterial();
    const vertex_buffer = rsp.programs.geometry_overlay_symbols.vertex_buffer;
    const va = vertex_buffer + @as(u32, a) * vertex_output_size;
    const vb = vertex_buffer + @as(u32, b) * vertex_output_size;
    const vc = vertex_buffer + @as(u32, c) * vertex_output_size;
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 0, va, &.{vb << 16 | vc});
    self.syncTriangles();
}

/// Most triangles one `drawTriangles` call can draw.
pub const max_batch_triangles = 420;

/// Encode independent triangles (indices into loaded vertices) as strip
/// commands in `storage`, which needs three entries per triangle and must
/// stay alive until submission completes, then draw and sync them once.
pub fn drawTriangles(self: *GeometryEncoder, triangles: []const [3]u8, storage: []i16) void {
    if (triangles.len == 0) return;
    self.drawTriangleStrip(encodeTriangles(triangles, storage), true);
}

/// Encode independent triangles in the strip format used by
/// `drawTriangleStrip`: each triangle is a three-vertex strip, with the
/// restart bit on the first index of every strip after the first.
pub fn encodeTriangles(triangles: []const [3]u8, storage: []i16) []i16 {
    if (triangles.len > max_batch_triangles or storage.len < triangles.len * 3) @panic("invalid triangle batch");
    for (triangles, 0..) |triangle, index| {
        for (triangle, 0..) |vertex, corner| {
            if (vertex >= geometry.max_loaded_vertices) @panic("triangle vertex is outside the vertex buffer");
            var encoded: u16 = @as(u16, vertex) * vertex_output_size;
            if (index != 0 and corner == 0) encoded |= 0x8000;
            storage[index * 3 + corner] = @bitCast(encoded);
        }
    }
    return storage[0 .. triangles.len * 3];
}

/// Draw a caller-built index strip. With `sync = false` consecutive strips
/// keep the clipping code resident; the encoder syncs before the next
/// non-strip geometry command, material change or submission.
pub fn drawTriangleStrip(self: *GeometryEncoder, indices: []const i16, sync: bool) void {
    cache.writebackData(indices);
    self.drawStaticTriangleStrip(indices, sync);
}
/// Draw an immutable asset index strip which is already coherent in RDRAM.
pub fn drawStaticTriangleStrip(self: *GeometryEncoder, indices: []const i16, sync: bool) void {
    self.beginModelMaterial();
    const symbols = rsp.programs.geometry_overlay_symbols;
    const vertex_buffer = symbols.vertex_buffer;
    const strip_buffer_end = symbols.clipping_buffer_temporary;
    if (indices.len < 3 or indices.len * @sizeOf(i16) > strip_buffer_end - vertex_buffer) @panic("invalid geometry strip");
    const byte_count: u32 = @intCast(indices.len * @sizeOf(i16));
    var dmem_address = (strip_buffer_end - byte_count) & ~@as(u32, 7);
    if (sync) dmem_address |= 0x8000;
    self.queue.writeOverlayCommandKnown(
        &self.geometry_overlay,
        11,
        physical(indices.ptr),
        &.{dmem_address << 16 | (byte_count - 1)},
    );
    self.triangles_pending = !sync;
}
/// Wait for queued triangles and restore microcode replaced by clipping.
pub fn syncTriangles(self: *GeometryEncoder) void {
    self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 10, 0, &.{});
    self.triangles_pending = false;
}
/// Sync only if an unsynced strip is outstanding.
pub fn settleTriangles(self: *GeometryEncoder) void {
    if (self.triangles_pending) self.syncTriangles();
}
pub fn beginModelMaterial(self: *GeometryEncoder) void {
    // Textures can be bound after draw flags and can live on any cached tile.
    // Emit at submission time, including inside recorded model blocks.
    self.emitDrawFlags();
    if (self.render.modesPending()) self.settleTriangles();
    self.render.flushModes();
}

fn physical(pointer: anytype) u32 {
    return @truncate(@intFromPtr(pointer) & 0x00ff_ffff);
}
