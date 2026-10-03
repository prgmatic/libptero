const n64 = @import("n64");
const assets = @import("assets");
const std = @import("std");

comptime {
    if (@TypeOf(assets.fixture_ci4).format != .color_indexed) @compileError("indexed asset was not generated");
    if (assets.fixture_ci4.palette.len == 0 or assets.fixture_ci4.palette.len > 16) @compileError("CI4 palette was not generated");
    if (assets.fixture_ci4.texel_data.len != 4096) @compileError("CI4 texels were not packed");
    if (!@typeInfo(@TypeOf(assets.fixture_ci4.palette)).pointer.is_const) @compileError("embedded palette must be read-only");
    if (assets.raw_data.len != 10) @compileError("raw asset was not embedded");
    if (assets.generated_data.len != 15) @compileError("generated asset was not embedded");
    if (@TypeOf(assets.rom_data) != n64.rom.Asset or assets.rom_data.size != 15) @compileError("ROM handle was not generated");
    if (assets.custom_rsp.len == 0) @compileError("ZSP asset was not embedded");
    if (!@typeInfo(@TypeOf(assets.fixture_font.atlases[0].texel_data)).pointer.is_const)
        @compileError("embedded font atlas must be read-only");
    if (assets.fixture_font.glyphs.len != 2) @compileError("font asset was not generated");
    const part = assets.fixture_model.model.parts[0];
    if (part.vertex_count != 3 or part.vertices.len != 2) @compileError("model vertices were not paired");
    if (part.vertices[0].pos_a[0] != -64) @compileError("model vertices were not emitted in hardware byte order");
    if (!@typeInfo(@TypeOf(part.vertices)).pointer.is_const) @compileError("model source must be immutable");
    if (@as(u16, @bitCast(part.strip_indices[2])) & 0x4000 == 0) @compileError("model triangle end marker is missing");
}

var renderer: n64.graphics.geometry.Renderer = undefined;
var pixels: [8 * 8]n64.graphics.color.Rgba16 align(64) = undefined;
var reader: n64.rom.Reader = .{};
var rom_bytes: [15]u8 = undefined;

pub fn main() !void {
    try reader.read(assets.rom_data, 0, &rom_bytes, 1_000_000);
    if (!std.mem.eql(u8, &rom_bytes, &assets.generated_data)) return error.RomReadMismatch;
    var memory: [1024]u8 align(64) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fixed.allocator();
    var mesh = try n64.graphics.model.MutableModel.init(allocator, assets.fixture_model.model);
    defer mesh.deinit(allocator);
    mesh.vertices(0).get(0).position[0] = 0;
    if (assets.fixture_model.model.parts[0].vertices[0].pos_a[0] != -64) return error.ModifiedSource;
    const model = assets.fixture_model.withModel(mesh.model()).withOverrides(.{.{
        .texture = assets.fixture_font.atlases[0],
        .flags = n64.graphics.geometry.DrawFlags{ .textured = true, .no_light = true },
        .combine = n64.graphics.rdp.CombineMode.single(.{ .rgb_d = .tex0, .alpha_d = .one }),
        .fog = false,
    }});
    renderer.init();
    renderer.beginFrame(try n64.graphics.image.ImgRgba16.initBuffer(&pixels, 8, 8), .{ .clear_color = .black });
    var viewport = n64.graphics.geometry.Viewport.init(8, 8);
    renderer.geometry.attachViewport(&viewport);
    renderer.geometry.drawModel(model);
    renderer.rdp.render.setState(.textured_sprite);
    var text: [16]u8 = undefined;
    _ = try assets.fixture_font.drawPrint(&renderer.rdp.render, 0, 0, &text, .{}, "{s}", .{"AB"});
    try renderer.submit().wait(.{});
    renderer.deinit();
}

pub fn alternateMain() !void {}

pub fn panicHandler(_: []const u8, _: ?usize) noreturn {
    while (true) {}
}

pub fn exceptionHandler(_: *n64.debug.TrapFrame) noreturn {
    while (true) {}
}

pub fn interruptHandler() void {}
