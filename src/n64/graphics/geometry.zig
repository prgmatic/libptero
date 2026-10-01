const std = @import("std");
const cache = @import("../cpu/cache.zig");
const math = @import("../math.zig");
const rsp = @import("../rsp/rsp.zig");
const rdp = @import("rdp.zig");
const Rgba32 = @import("color.zig").Rgba32;

const vertex_output_size = 36;
pub const max_lights = 7;

/// An immutable, reusable RSP command block containing a model draw.
pub const RecordedModel = struct {
    buffer: [rsp.command_queue.rdram_buffer_word_count]u32 align(rsp.command_queue.fetch_window_byte_len) = undefined,
    commands: rsp.CommandQueue = undefined,
    final_state: MaterialState = undefined,

    /// Encode a model and its material setup once for later draws.
    pub fn record(self: *RecordedModel, context: *Context, model: anytype, materials: anytype) void {
        self.commands = rsp.CommandQueue.init(self.buffer[0..]);
        context.render.prepare();
        context.render.invalidateState();
        const previous = MaterialState.read(context);
        context.last_draw_flags = null;
        context.queue.beginBlock(&self.commands);
        model.draw(context, materials);
        context.queue.endBlock(&self.commands);
        self.final_state = MaterialState.read(context);
        previous.restore(context);
        context.render.invalidateState();
    }

    /// Append a call to this recorded model to the active render queue.
    pub fn draw(self: *const RecordedModel, context: *Context) void {
        context.queue.runBlock(&self.commands);
        self.final_state.restore(context);
        context.render.invalidateState();
    }
};

// Recording does not execute material commands. Replaying does: keep the CPU
// state tracker aligned with that distinction without caching recorded TMEM.
const MaterialState = struct {
    flags: DrawFlags,
    fog: bool,
    tile: u3,
    mode: rdp.OtherModes,
    combine: rdp.CombineMode,
    fn read(context: *const Context) MaterialState {
        return .{ .flags = context.draw_flags, .fog = context.fog_enabled, .tile = context.render.material_tile, .mode = context.render.mode, .combine = context.render.combine_mode };
    }
    fn restore(self: MaterialState, context: *Context) void {
        context.draw_flags = self.flags;
        context.fog_enabled = self.fog;
        context.render.material_tile = self.tile;
        context.render.mode = self.mode;
        context.render.combine_mode = self.combine;
        context.last_draw_flags = null;
    }
};

pub const DrawFlags = packed struct(u17) {
    depth: bool = false,
    textured: bool = false,
    shaded: bool = false,
    cull_front: bool = false,
    cull_back: bool = false,
    _padding: u11 = 0,
    no_light: bool = false,
};

pub const VertexPair = extern struct {
    pos_a: [3]i16,
    normal_a: u16,
    pos_b: [3]i16,
    normal_b: u16,
    color_a: Rgba32 align(8),
    color_b: Rgba32,
    uv_a: [2]i16 = .{ 0, 0 },
    uv_b: [2]i16 = .{ 0, 0 },
};

pub fn packNormal(value: math.Vec3) u16 {
    const normal = value.normalized();
    const x: i32 = std.math.clamp(@as(i32, @intFromFloat(@round(normal.x * 15.5))), -16, 15);
    const y: i32 = std.math.clamp(@as(i32, @intFromFloat(@round(normal.y * 31.5))), -32, 31);
    const z: i32 = std.math.clamp(@as(i32, @intFromFloat(@round(normal.z * 15.5))), -16, 15);
    return (@as(u16, @bitCast(@as(i16, @intCast(x)))) & 0x1f) << 11 |
        (@as(u16, @bitCast(@as(i16, @intCast(y)))) & 0x3f) << 5 |
        (@as(u16, @bitCast(@as(i16, @intCast(z)))) & 0x1f);
}

pub const Viewport = struct {
    width: u16,
    height: u16,
    projection: math.FixedMat4 align(16) = .identity,
    camera: math.FixedMat4 align(16) = .identity,
    camera_float: math.Mat4 = .identity,
    w_normalization: f32 = 1,

    pub fn init(width: u16, height: u16) Viewport {
        return .{ .width = width, .height = height };
    }
    pub fn setPerspective(self: *Viewport, fov: f32, near: f32, far: f32) void {
        const aspect = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
        self.projection = math.Mat4.perspective(fov, aspect, near, far).toFixed();
        self.w_normalization = 2.0 / (far + near);
    }
    pub fn lookAt(self: *Viewport, eye: math.Vec3, target: math.Vec3, up: math.Vec3) void {
        self.camera_float = math.Mat4.lookAt(eye, target, up);
        self.camera = self.camera_float.toFixed();
    }
};

pub const Context = struct {
    queue: rsp.Queue,
    rdp_overlay: rsp.Overlay,
    geometry_overlay: rsp.Overlay,
    rdp_buffers: [2][rsp.rdp_dynamic_buffer_len]u8 align(16),
    render: rdp.DefaultRenderQueue,
    matrix_stack: [8]math.FixedMat4 align(16),
    view_matrix: math.Mat4,
    draw_flags: DrawFlags = .{},
    fog_enabled: bool = false,
    last_draw_flags: ?DrawFlags = null,
    last_material_tile: u3 = 0,

    pub fn init(self: *Context) void {
        rsp.halt();
        rsp.waitHalted();
        rsp.loadResident(rsp.programs.command_dispatcher);
        self.rdp_overlay.init(rsp.programs.rdp_overlay);
        rsp.registerOverlayStatic(&self.rdp_overlay, 12);
        self.geometry_overlay.init(rsp.programs.geometry_overlay);
        rsp.registerOverlayStatic(&self.geometry_overlay, 1);
        self.queue.init(.low);
        @memset(&self.rdp_buffers[0], 0);
        @memset(&self.rdp_buffers[1], 0);
        cache.writebackData(&self.rdp_buffers);
        self.render = rdp.DefaultRenderQueue.init(rdp.OverlayQueue.init(
            &self.queue,
            &self.rdp_overlay,
            .{ self.rdp_buffers[0][0..], self.rdp_buffers[1][0..] },
        ));
        @memset(&self.matrix_stack, math.FixedMat4.identity);
        self.view_matrix = .identity;
        self.draw_flags = .{};
        self.fog_enabled = false;
        self.last_draw_flags = null;
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
        rsp.flush(&self.queue);
        rsp.wait(&self.queue);

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
        rsp.io.readDmem(u32, state_start + clipping_code_address_offset).* = clipping_address;
        rsp.io.readDmem(u32, state_start + original_code_address_offset).* = original_address;
        if (symbols.clipping_code_size != symbols.vertex_effect_function + @sizeOf(u16)) {
            @panic("geometry clipping metadata layout changed");
        }
        // Publish the adjacent halfwords with one aligned DMEM write. A lone
        // CPU halfword write to clipping_code_size was lost on N64 hardware,
        // leaving the restore DMA length at zero when clipping first ran.
        rsp.io.readDmem(u32, symbols.vertex_effect_function).* =
            @as(u32, vertex_effect_none) << 16 | clipping_size;
    }

    pub fn attachViewport(self: *Context, viewport: *Viewport) void {
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

    /// Compatibility hook. RDPQ buffers remain attached across frames and
    /// advance through their sentinels, matching libdragon/Tiny3D.
    pub fn beginFrame(_: *Context) void {}

    pub fn setAmbientLight(self: *Context, color: Rgba32) void {
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 5, rsp.programs.geometry_overlay_symbols.ambient_color, &.{ @as(u32, @bitCast(color)), 0, 0 });
    }
    pub fn setLightCount(self: *Context, count: u8) void {
        if (count > max_lights) @panic("too many lights");
        self.queue.writeOverlayCommandKnown(
            &self.geometry_overlay,
            3,
            rsp.programs.geometry_overlay_symbols.active_light_size | 0x8000,
            &.{@as(u32, count) << 12},
        );
    }
    /// Set the first directional light and make it active.
    pub fn setDirectionalLight(self: *Context, color: Rgba32, direction: math.Vec3) void {
        self.setDirectionalLightAt(0, color, direction);
        self.setLightCount(1);
    }
    /// Configure a directional-light slot. Call `setLightCount` to select how
    /// many consecutively numbered slots participate in lighting.
    pub fn setDirectionalLightAt(self: *Context, index: u8, color: Rgba32, direction: math.Vec3) void {
        if (index >= max_lights) @panic("invalid light index");
        const n = self.view_matrix.transformDirection(direction).normalized();
        const x: u8 = @bitCast(@as(i8, @intFromFloat(n.x * 127.0)));
        const y: u8 = @bitCast(@as(i8, @intFromFloat(n.y * 127.0)));
        const z: u8 = @bitCast(@as(i8, @intFromFloat(n.z * 127.0)));
        const packed_direction = @as(u32, x) << 24 | @as(u32, y) << 16 | @as(u32, z) << 8;
        const light_address = rsp.programs.geometry_overlay_symbols.directional_light_color + @as(u32, index) * 16;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 5, light_address, &.{ @as(u32, @bitCast(color)), packed_direction, packed_direction });
    }
    pub fn setFogEnabled(self: *Context, enabled: bool) void {
        self.fog_enabled = enabled;
        // The vertex loader stores a halfword at this attribute offset. When
        // enabled its high byte replaces shade alpha; otherwise UV is scratch
        // until the vertex effect writes the final texture coordinates.
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 9, if (enabled) 0x0b else 0x0c, &.{});
    }
    pub fn setFogRange(self: *Context, near: f32, far: f32) void {
        const address = rsp.programs.geometry_overlay_symbols.fog_scale_offset;
        if (near == 0 and far == 0) {
            self.queue.writeDmem(address, 0);
            self.queue.writeDmem(address + 4, 0x7fff0000);
            return;
        }
        var difference = far - near;
        if (@abs(difference) < 1.5) difference = 1.5;
        const scale_float = std.math.clamp(@floor(16384.0 / difference), -32768.0, 32767.0);
        const scale: u16 = @bitCast(@as(i16, @intFromFloat(scale_float)));
        const offset: i32 = @intFromFloat(-near * 2.0 * 65536.0);
        self.queue.writeDmem(address, @bitCast(offset));
        // The upper halfword is the full-intensity constant used by both fog
        // and unlit vertex colors. Only the lower halfword is the fog scale.
        self.queue.writeDmem(address + 4, 0x7fff0000 | @as(u32, scale));
    }
    pub fn setDrawFlags(self: *Context, flags: DrawFlags) void {
        self.draw_flags = flags;
        self.emitDrawFlags();
    }

    fn emitDrawFlags(self: *Context) void {
        const flags = self.draw_flags;
        if (flags.cull_front and flags.cull_back) @panic("cannot cull both triangle faces");
        if (self.last_draw_flags) |previous| {
            if (std.meta.eql(previous, flags) and self.last_material_tile == self.render.material_tile) return;
        }
        self.last_draw_flags = flags;
        self.last_material_tile = self.render.material_tile;
        // Match Tiny3D's host-side ABI (the triangle include's historical
        // comment describes these two selector values in reverse).
        const culling: u32 = if (flags.cull_front) 1 else if (flags.cull_back) 0 else 2;
        var bits: u32 = @as(u17, @bitCast(flags));
        bits &= ~@as(u32, (1 << 3) | (1 << 4));
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 6, culling, &.{0xc000 | ((bits | 8) << 8) | @as(u32, self.render.material_tile)});
    }
    pub fn pushMatrix(self: *Context, matrix: *const math.FixedMat4) void {
        cache.writebackData(matrix);
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, (64 << 8) | 1, &.{physical(matrix)});
    }
    /// Load a matrix, optionally multiplying it by the current matrix.
    pub fn setMatrix(self: *Context, matrix: *const math.FixedMat4, multiply: bool) void {
        cache.writebackData(matrix);
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, @intFromBool(multiply), &.{physical(matrix)});
    }
    /// Reserve matrix-stack slots without loading matrices into them.
    pub fn advanceMatrixStack(self: *Context, count: u8) void {
        const advance = @as(u32, count) * 64;
        if (advance > std.math.maxInt(i16)) @panic("matrix stack advance is too large");
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, (advance << 8) | 2, &.{0});
    }
    pub fn popMatrix(self: *Context) void {
        const stack_advance = @as(u32, @bitCast(@as(i32, -64 << 8))) & 0x00ff_ff00;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, stack_advance, &.{0});
    }
    pub fn loadVertices(self: *Context, vertices: []const VertexPair, offset: u8, count: u8) void {
        cache.writebackData(vertices);
        self.loadStaticVertices(vertices, offset, count);
    }
    /// Load immutable asset vertices which are already coherent in RDRAM.
    pub fn loadStaticVertices(self: *Context, vertices: []const VertexPair, offset: u8, count: u8) void {
        if (count == 0 or count > vertices.len * 2) @panic("invalid geometry vertex count");
        const symbols = rsp.programs.geometry_overlay_symbols;
        const vertex_buffer = symbols.vertex_buffer;
        const vertex_input_end = symbols.clipping_buffer_result + 6 * 16;
        const input_size: u32 = ((@as(u32, count) + 1) & ~@as(u32, 1)) * 16;
        const temp_address = (vertex_input_end - input_size) & ~@as(u32, 0xf);
        const output_address = vertex_buffer + @as(u32, offset) * vertex_output_size;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 4, input_size, &.{ physical(vertices.ptr), temp_address << 16 | output_address });
    }
    pub fn drawTriangle(self: *Context, a: u8, b: u8, c: u8) void {
        self.beginModelMaterial();
        const vertex_buffer = rsp.programs.geometry_overlay_symbols.vertex_buffer;
        const va = vertex_buffer + @as(u32, a) * vertex_output_size;
        const vb = vertex_buffer + @as(u32, b) * vertex_output_size;
        const vc = vertex_buffer + @as(u32, c) * vertex_output_size;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 0, va, &.{vb << 16 | vc});
    }
    pub fn drawTriangleStrip(self: *Context, indices: []const i16, sync: bool) void {
        cache.writebackData(indices);
        self.drawStaticTriangleStrip(indices, sync);
    }
    /// Draw an immutable asset index strip which is already coherent in RDRAM.
    pub fn drawStaticTriangleStrip(self: *Context, indices: []const i16, sync: bool) void {
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
    }
    pub fn syncTriangles(self: *Context) void {
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 10, 0, &.{});
    }
    pub fn beginModelMaterial(self: *Context) void {
        // Textures can be bound after draw flags and can live on any cached tile.
        // Emit at submission time, including inside recorded model blocks.
        self.emitDrawFlags();
        self.render.flushModes();
    }
};

fn physical(pointer: anytype) u32 {
    return @truncate(@intFromPtr(pointer) & 0x00ff_ffff);
}

comptime {
    if (@sizeOf(VertexPair) != 32 or @alignOf(VertexPair) < 8) @compileError("geometry vertex ABI mismatch");
}

test "recorded material snapshots restore CPU trackers without claiming TMEM residency" {
    var context: Context = undefined;
    context.draw_flags = .{ .textured = true, .no_light = true };
    context.fog_enabled = true;
    context.render.material_tile = 6;
    context.render.mode = .{ .cycle_type = .two_cycle, .z_update_en = false };
    context.render.combine_mode = .decal_rgba;
    const state = MaterialState.read(&context);
    context.draw_flags = .{};
    context.fog_enabled = false;
    context.render.material_tile = 0;
    context.last_draw_flags = .{};
    state.restore(&context);
    try std.testing.expect(context.draw_flags.textured and context.draw_flags.no_light);
    try std.testing.expect(context.fog_enabled);
    try std.testing.expectEqual(@as(u3, 6), context.render.material_tile);
    try std.testing.expectEqual(rdp.CycleType.two_cycle, context.render.mode.cycle_type);
    try std.testing.expect(std.meta.eql(rdp.CombineMode.decal_rgba, context.render.combine_mode));
    try std.testing.expect(context.last_draw_flags == null);
}
