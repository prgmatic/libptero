//! Geometry overlay workloads: transform, light, and rasterize-setup a mesh,
//! once fully on screen and once crossing the near plane so the clipping
//! payload is swapped in. Setup mirrors `GeometryEncoder.init`/`attachViewport`
//! and uses its pure command builders.
const std = @import("std");
const n64 = @import("n64");
const workloads = @import("workloads.zig");

const programs = n64.rsp.programs;
const symbols = programs.geometry_overlay_symbols;
const Encoder = n64.graphics.GeometryEncoder;
const graphics = n64.graphics;
const math = n64.math;
const Harness = workloads.Harness;
const Session = @import("rsp_interp").Session;

const all_symbols = workloads.symbolTable(.{ programs.command_dispatcher_symbols, symbols, programs.geometry_clipping_symbols });

pub const all = [_]workloads.Workload{
    .{
        .name = "geometry_lit_mesh",
        .overlay = .geometry,
        .description = "load 36 lit, fogged vertices; draw a 50-triangle strip batch and one immediate triangle",
        .run = litMesh,
        .symbols = all_symbols,
    },
    .{
        .name = "geometry_clipped_mesh",
        .overlay = .geometry,
        .description = "the same mesh crossing the near plane, exercising the clipping payload",
        .run = clippedMesh,
        .symbols = all_symbols,
    },
};

const grid = 6;
const vertex_count = grid * grid;
const triangle_count = (grid - 1) * (grid - 1) * 2;

pub const Scene = struct {
    eye: math.Vec3,
    target: math.Vec3,
};

const on_screen: Scene = .{ .eye = .init(0, 0, 600), .target = .zero };
const crossing_near_plane: Scene = .{ .eye = .init(0, -260, 40), .target = .init(0, 200, 0) };

fn writeU16s(destination: []u8, values: []const u16) void {
    for (values, 0..) |value, index| std.mem.writeInt(u16, destination[index * 2 ..][0..2], value, .big);
}

/// Places a fixed-point matrix in RDRAM in the RSP's big-endian layout.
fn placeMatrix(s: *Session, matrix: math.FixedMat4) !u32 {
    const address = try s.allocate(64, 16);
    const halves: *const [32]u16 = @ptrCast(&matrix);
    writeU16s(try s.bytes(address, 64), halves);
    return address;
}

/// Writes persistent overlay state both to its RDRAM image and to DMEM, as
/// `overlayState`/`writebackOverlayState` do while the overlay is resident.
fn writeState(s: *Session, overlay: Session.Overlay, comptime T: type, dmem_address: u16, value: T) !void {
    std.mem.writeInt(T, (try s.bytes(overlay.stateAddress(dmem_address), @sizeOf(T)))[0..@sizeOf(T)], value, .big);
    s.machine.writeDmem(T, dmem_address, value);
}

fn color(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) << 24 | @as(u32, g) << 16 | @as(u32, b) << 8 | 0xff;
}

/// A grid of vertex pairs in the z=0 plane spanning ±200 units.
fn placeMesh(s: *Session) !u32 {
    const address = try s.allocate(vertex_count / 2 * @sizeOf(graphics.VertexPair), 8);
    const bytes = try s.bytes(address, vertex_count / 2 * @sizeOf(graphics.VertexPair));
    const normal = graphics.packNormal(.init(0.2, 0.3, 1));
    for (0..vertex_count) |index| {
        const pair = bytes[(index / 2) * 32 ..][0..32];
        const half = index % 2;
        const x: i16 = @intCast(@as(i32, @intCast(index % grid)) * 80 - 200);
        const y: i16 = @intCast(@as(i32, @intCast(index / grid)) * 80 - 200);
        writeU16s(pair[half * 8 ..][0..8], &.{ @bitCast(x), @bitCast(y), 0, normal });
        std.mem.writeInt(u32, pair[16 + half * 4 ..][0..4], color(@intCast(index * 7), 128, @intCast(255 - index * 5)), .big);
        writeU16s(pair[24 + half * 4 ..][0..4], &.{ @intCast(index * 32), @intCast(index * 16) });
    }
    return address;
}

fn placeTriangles(s: *Session) !u32 {
    var triangles: [triangle_count][3]u8 = undefined;
    var index: usize = 0;
    for (0..grid - 1) |row| for (0..grid - 1) |column| {
        const corner: u8 = @intCast(row * grid + column);
        triangles[index] = .{ corner, corner + 1, corner + grid };
        triangles[index + 1] = .{ corner + 1, corner + grid + 1, corner + grid };
        index += 2;
    };
    var storage: [triangle_count * 3]i16 align(8) = undefined;
    const encoded = Encoder.encodeTriangles(&triangles, &storage);
    const address = try s.allocate(encoded.len * 2, 8);
    writeU16s(try s.bytes(address, encoded.len * 2), @ptrCast(encoded));
    return address;
}

/// Registers geometry and prepares its state the way `GeometryEncoder.init` does.
pub fn setUpGeometry(h: *Harness) !Session.Overlay {
    const s = &h.session;
    _ = try workloads.setUpRdp(h, n64.rsp.Runtime.rdp_overlay_id);
    const overlay = try s.registerOverlay(programs.geometry_overlay, Encoder.overlay_id);
    const matrix_stack = try s.allocate(8 * 64, 16);
    for (0..8) |slot| {
        const halves: *const [32]u16 = @ptrCast(&math.FixedMat4.identity);
        writeU16s(try s.bytes(matrix_stack + @as(u32, @intCast(slot)) * 64, 64), halves);
    }
    try writeState(s, overlay, u32, symbols.matrix_stack_pointer, matrix_stack);
    try writeState(s, overlay, u16, symbols.vertex_effect, Encoder.vertexEffectCode(.none));
    var enter = try s.commands(8);
    try enter.overlayCommand(overlay, 3, 0x8000 | symbols.active_light_size, &.{0});
    try h.prepare(enter);
    const patch = Encoder.clippingPatch(overlay.text_rdram, try s.place(programs.geometry_clipping.text, 8));
    try writeState(s, overlay, u16, symbols.clipping_code_size, patch.size);
    try writeState(s, overlay, u32, symbols.clipping_code_address, patch.clipping_address);
    try writeState(s, overlay, u32, symbols.original_code_address, patch.original_address);
    return overlay;
}

fn queueScene(s: *Session, writer: *Session.CommandWriter, overlay: Session.Overlay, scene: Scene) !void {
    var viewport: n64.graphics.Viewport = .init(320, 240);
    viewport.setPerspective(1.0, 20, 2000);
    viewport.lookAt(scene.eye, scene.target, .init(0, 1, 0));
    const screen = Encoder.screenSizeCommand(&viewport);
    try writer.overlayCommand(overlay, 1, @intCast(screen.inline_argument), &screen.arguments);
    try writer.overlayCommand(overlay, 7, @intCast(try placeMatrix(s, viewport.projection)), &.{});
    try writer.overlayCommand(overlay, 2, 0, &.{try placeMatrix(s, viewport.camera)});
    try writer.overlayCommand(overlay, 5, symbols.ambient_color, &.{ color(40, 40, 60), 0, 0 });
    const direction: u32 = 0x00_00_7f_00;
    try writer.overlayCommand(overlay, 5, symbols.directional_light_color, &.{ color(220, 200, 180), direction, direction });
    try writer.overlayCommand(overlay, 3, symbols.active_light_size | 0x8000, &.{1 << 12});
    const mode = Encoder.renderModeCommand(.{ .depth = true, .shaded = true }, 0);
    try writer.overlayCommand(overlay, 6, @intCast(mode.inline_argument), &mode.arguments);
    const model = math.Mat4.fromSrtEuler(.init(1, 1, 1), .init(0.3, 0.2, 0.1), .zero).toFixed();
    try writer.overlayCommand(overlay, 2, (64 << 8) | 1, &.{try placeMatrix(s, model)});
}

pub const MeshRun = struct { outcome: workloads.Outcome, triangles: u32 };

pub fn runMesh(h: *Harness, scene: Scene) !MeshRun {
    return runMeshWith(h, scene, false);
}

/// `extras` adds fog and a single synced triangle after the strip.
pub fn runMeshWith(h: *Harness, scene: Scene, extras: bool) !MeshRun {
    const s = &h.session;
    const overlay = try setUpGeometry(h);
    var writer = try s.commands(256);
    try queueScene(s, &writer, overlay, scene);
    const load = Encoder.vertexLoadCommand(try placeMesh(s), 0, vertex_count);
    try writer.overlayCommand(overlay, 4, @intCast(load.inline_argument), &load.arguments);
    const strip = Encoder.stripCommand(try placeTriangles(s), triangle_count * 3, true);
    try writer.overlayCommand(overlay, 11, @intCast(strip.inline_argument), &strip.arguments);
    if (extras) try queueExtras(&writer, overlay);
    const rdp_start = h.rdp_bytes.written().len;
    const measured = try h.measure(writer);
    const stream = h.rdp_bytes.written()[rdp_start..];
    const parts = [_][]const u8{ stream, h.dmem(symbols.vertex_buffer, symbols.vertex_buffer + vertex_count * 36) };
    return .{ .outcome = workloads.outcome(measured, &parts), .triangles = countTriangles(stream) };
}

fn queueExtras(writer: *Session.CommandWriter, overlay: Session.Overlay) !void {
    try writer.overlayCommand(overlay, 9, 0x0b, &.{});
    try writer.overlayCommand(overlay, 3, symbols.fog_scale_offset, &.{0x0001_0000});
    const vertex = struct {
        fn address(index: u32) u32 {
            return symbols.vertex_buffer + index * 36;
        }
    }.address;
    try writer.overlayCommand(overlay, 0, @intCast(vertex(0)), &.{vertex(1) << 16 | vertex(grid)});
    try writer.overlayCommand(overlay, 10, 0, &.{});
}

fn countTriangles(stream: []const u8) u32 {
    var count: u32 = 0;
    var offset: usize = 0;
    while (offset + 8 <= stream.len) {
        const opcode = stream[offset] & 0x3f;
        count += @intFromBool(opcode >= 0x08 and opcode <= 0x0f);
        offset += 8 * n64.rdp.command_encoder.packetWordCount(opcode);
    }
    return count;
}

fn litMesh(h: *Harness) !workloads.Outcome {
    return (try runMeshWith(h, on_screen, true)).outcome;
}

fn clippedMesh(h: *Harness) !workloads.Outcome {
    return (try runMesh(h, crossing_near_plane)).outcome;
}

test "on-screen mesh rasterizes every triangle" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    const run = try runMesh(&h, on_screen);
    try std.testing.expectEqual(@as(u32, triangle_count), run.triangles);
}

test "fog and an immediate triangle follow the strip" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    const run = try runMeshWith(&h, on_screen, true);
    try std.testing.expectEqual(@as(u32, triangle_count + 1), run.triangles);
    try std.testing.expectEqual(@as(u8, 0x0b), h.session.machine.dmemByte(symbols.fog_store_offset));
}

test "mesh crossing the near plane is clipped and still rasterized" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    var profile: @import("rsp_interp").Profile = .{};
    h.profile = &profile;
    const run = try runMesh(&h, crossing_near_plane);
    // The clip entry point and the swapped-in clipping payload both ran.
    try std.testing.expect(profile.instructions[symbols.clipTriangle / 4] > 0);
    try std.testing.expect(profile.instructions[programs.geometry_clipping_symbols._start / 4] > 0);
    try std.testing.expect(run.triangles > 0);
    try std.testing.expect(run.triangles != triangle_count);
}

/// The scalar register an RSP instruction writes, if any.
fn writtenRegister(word: u32) ?u5 {
    const opcode: u6 = @truncate(word >> 26);
    const rs: u5 = @truncate(word >> 21);
    const rt: u5 = @truncate(word >> 16);
    const rd: u5 = @truncate(word >> 11);
    return switch (opcode) {
        0 => switch (@as(u6, @truncate(word))) {
            8 => null, // jr
            else => rd,
        },
        1 => if (rt & 0x10 != 0) 31 else null, // bltzal, bgezal
        3 => 31, // jal
        8...15, 32...39 => rt, // immediate arithmetic, loads
        16, 18 => if (rs == 0 or rs == 2) rt else null, // mfc0, mfc2, cfc2
        else => null,
    };
}

test "clipping preserves the registers geometry keeps across a clip" {
    // Strips and sequences resume after a clip with their culling flag
    // ($v0), sequence step ($v1), loop state ($s1, $s2), and the queue's
    // $gp and $k1; the patch restores $s4 itself as it returns.
    const preserved = [_]u5{ 2, 3, 17, 18, 28, 27 };
    const text = programs.geometry_clipping.text;
    var restores: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) : (offset += 4) {
        const written = writtenRegister(std.mem.readInt(u32, text[offset..][0..4], .big)) orelse continue;
        for (preserved) |register| try std.testing.expect(written != register);
        if (written == 20) restores += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), restores);
}

const SequenceDraw = enum { sequence, quads, single_triangles, single_quads };

fn vertexAddress(index: u32) u32 {
    return symbols.vertex_buffer + index * 36;
}

/// Queues the triangle `first`, `first - 1`, `first - 2` the way a
/// sequence draws it.
fn queueTriangle(writer: *Session.CommandWriter, overlay: Session.Overlay, first: u32) !void {
    try writer.overlayCommand(overlay, 0, @intCast(vertexAddress(first)), &.{vertexAddress(first - 2) << 16 | vertexAddress(first - 1)});
}

/// The RDP commands for the mesh's first twelve vertices drawn as
/// triangles of three, or as quads of four, either by one sequence command
/// or by single triangles.
fn sequenceStream(draw: SequenceDraw) ![]u8 {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();
    const s = &h.session;
    const overlay = try setUpGeometry(&h);
    var writer = try s.commands(256);
    try queueScene(s, &writer, overlay, on_screen);
    const load = Encoder.vertexLoadCommand(try placeMesh(s), 0, vertex_count);
    try writer.overlayCommand(overlay, 4, @intCast(load.inline_argument), &load.arguments);
    const quad_step: u32 = 36;
    switch (draw) {
        .sequence => try writer.overlayCommand(overlay, 12, @intCast(vertexAddress(0)), &.{vertexAddress(12)}),
        .quads => try writer.overlayCommand(overlay, 12, @intCast(vertexAddress(0)), &.{quad_step << 16 | vertexAddress(12)}),
        .single_triangles => for (0..4) |group| try queueTriangle(&writer, overlay, @intCast(group * 3 + 2)),
        .single_quads => {
            for (0..3) |group| try queueTriangle(&writer, overlay, @intCast(group * 4 + 2));
            for (0..3) |group| try queueTriangle(&writer, overlay, @intCast(group * 4 + 3));
        },
    }
    try writer.overlayCommand(overlay, 10, 0, &.{});
    const start = h.rdp_bytes.written().len;
    _ = try h.measure(writer);
    return std.testing.allocator.dupe(u8, h.rdp_bytes.written()[start..]);
}

test "triangle sequences draw what the same single triangles draw" {
    // drawTriangleSequence has no runtime encoder; this pins its order,
    // including the second pass over quads.
    for ([_][2]SequenceDraw{ .{ .sequence, .single_triangles }, .{ .quads, .single_quads } }) |pair| {
        const drawn = try sequenceStream(pair[0]);
        defer std.testing.allocator.free(drawn);
        const expected = try sequenceStream(pair[1]);
        defer std.testing.allocator.free(expected);
        try std.testing.expect(countTriangles(drawn) > 0);
        try std.testing.expectEqualSlices(u8, expected, drawn);
    }
}
