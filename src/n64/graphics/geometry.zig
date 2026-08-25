const std = @import("std");
const cache = @import("../cpu/cache.zig");
const math = @import("../math.zig");
const rsp = @import("../rsp/rsp.zig");
const rdp = @import("rdp.zig");
const Rgba32 = @import("color.zig").Rgba32;

const state_start = 0x0230;
const vertex_buffer = state_start + 0x01d8;
const vertex_output_size = 36;
const matrix_stack_pointer_offset = 0x01c4;
const vertex_effect_function_offset = 0x01cc;
const clipping_code_size_offset = 0x01ce;
const clipping_code_address_offset = 0x01d0;
const original_code_address_offset = 0x01d4;
const clipping_imem_start = 0x08b0;
const vertex_input_end = 0x0f40;
const ambient_color = state_start + 0x0148;
const directional_light_color = state_start + 0x0150;
const active_light_size = state_start + 0x01ca;

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
        cache.writebackData(&self.matrix_stack);
        var state = rsp.overlayState(&self.geometry_overlay);
        std.mem.writeInt(u32, state[matrix_stack_pointer_offset..][0..4], physical(&self.matrix_stack), .big);
        const vertex_command = self.geometry_overlay.program.commandAt(4);
        std.mem.writeInt(u16, state[vertex_effect_function_offset..][0..2], vertex_command.handler_offset + 0x2bc, .big);
        rsp.writebackOverlayState(&self.geometry_overlay);

        // Enter the main overlay once while its lazy-code pointer is zero.
        // Its entry stub uses that pointer during the initial load.
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 3, 0x8000 | state_start + 0x01ca, &.{0});
        rsp.flush(&self.queue);
        rsp.wait(&self.queue);

        const clipping = rsp.programs.geometry_clipping;
        const clipping_payload_offset = clipping_imem_start - clipping.text_offset;
        const geometry_restore_offset = clipping_imem_start - self.geometry_overlay.program.text_offset;
        const clipping_size: u16 = @intCast(clipping.text.len - clipping_payload_offset);
        const clipping_address = physical(clipping.text.ptr + clipping_payload_offset);
        const original_address = physical(self.geometry_overlay.program.text.ptr + geometry_restore_offset);
        state = rsp.overlayState(&self.geometry_overlay);
        std.mem.writeInt(u16, state[clipping_code_size_offset..][0..2], clipping_size, .big);
        std.mem.writeInt(u32, state[clipping_code_address_offset..][0..4], clipping_address, .big);
        std.mem.writeInt(u32, state[original_code_address_offset..][0..4], original_address, .big);
        rsp.writebackOverlayState(&self.geometry_overlay);
        rsp.io.readDmem(u16, state_start + clipping_code_size_offset).* = clipping_size;
        rsp.io.readDmem(u32, state_start + clipping_code_address_offset).* = clipping_address;
        rsp.io.readDmem(u32, state_start + original_code_address_offset).* = original_address;
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

    pub fn beginFrame(self: *Context) void {
        self.render.cmd_queue.queue.rotateBuffers();
    }

    pub fn setAmbientLight(self: *Context, color: Rgba32) void {
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 5, ambient_color, &.{ @as(u32, @bitCast(color)), 0, 0 });
    }
    pub fn setDirectionalLight(self: *Context, color: Rgba32, direction: math.Vec3) void {
        const n = self.view_matrix.transformDirection(direction).normalized();
        const x: u8 = @bitCast(@as(i8, @intFromFloat(n.x * 127.0)));
        const y: u8 = @bitCast(@as(i8, @intFromFloat(n.y * 127.0)));
        const z: u8 = @bitCast(@as(i8, @intFromFloat(n.z * 127.0)));
        const packed_direction = @as(u32, x) << 24 | @as(u32, y) << 16 | @as(u32, z) << 8;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 5, directional_light_color, &.{ @as(u32, @bitCast(color)), packed_direction, packed_direction });
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 3, active_light_size | 0x8000, &.{0x1000});
    }
    pub fn setDrawFlags(self: *Context, flags: DrawFlags) void {
        if (flags.cull_front and flags.cull_back) @panic("cannot cull both triangle faces");
        const culling: u32 = if (flags.cull_front) 1 else if (flags.cull_back) 0 else 2;
        var bits: u32 = @as(u17, @bitCast(flags));
        bits &= ~@as(u32, (1 << 3) | (1 << 4));
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 6, culling, &.{0xc000 | ((bits | 8) << 8)});
    }
    pub fn pushMatrix(self: *Context, matrix: *const math.FixedMat4) void {
        cache.writebackData(matrix);
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, (64 << 8) | 1, &.{physical(matrix)});
    }
    pub fn popMatrix(self: *Context) void {
        const stack_advance = @as(u32, @bitCast(@as(i32, -64 << 8))) & 0x00ff_ff00;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 2, stack_advance, &.{0});
    }
    pub fn loadVertices(self: *Context, vertices: []const VertexPair, offset: u8, count: u8) void {
        if (count == 0 or count > vertices.len * 2) @panic("invalid geometry vertex count");
        cache.writebackData(vertices);
        const input_size: u32 = ((@as(u32, count) + 1) & ~@as(u32, 1)) * 16;
        const temp_address = (vertex_input_end - input_size) & ~@as(u32, 0xf);
        const output_address = vertex_buffer + @as(u32, offset) * vertex_output_size;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 4, input_size, &.{ physical(vertices.ptr), temp_address << 16 | output_address });
    }
    pub fn drawTriangle(self: *Context, a: u8, b: u8, c: u8) void {
        const va = vertex_buffer + @as(u32, a) * vertex_output_size;
        const vb = vertex_buffer + @as(u32, b) * vertex_output_size;
        const vc = vertex_buffer + @as(u32, c) * vertex_output_size;
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 0, va, &.{vb << 16 | vc});
    }
    pub fn syncTriangles(self: *Context) void {
        self.queue.writeOverlayCommandKnown(&self.geometry_overlay, 10, 0, &.{});
    }
};

fn physical(pointer: anytype) u32 {
    return @truncate(@intFromPtr(pointer) & 0x00ff_ffff);
}

comptime {
    if (@sizeOf(VertexPair) != 32 or @alignOf(VertexPair) < 8) @compileError("geometry vertex ABI mismatch");
}
