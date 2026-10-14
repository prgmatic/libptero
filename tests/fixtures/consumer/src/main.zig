const n64 = @import("n64");
const assets = @import("assets");
const std = @import("std");

comptime {
    const App = n64.App(.{ .geometry = true });
    const Display = n64.display.Swapchain(n64.graphics.pixel.Rgba16);
    const app_options: App.Options = .{};
    const pass_options: App.GeometryPass.State = .{};
    const overlay_options: App.OverlayPass.Options = .{};
    const display_options: Display.Options = .{};
    const present_options: Display.PresentOptions = .{};
    const audio_options: n64.audio.Player.Options = .{};
    const play_options: n64.audio.Player.PlayOptions = .{};
    const update_options: n64.audio.Player.UpdateOptions = .{};
    const text_options: n64.graphics.Font.DrawOptions = .{};
    const load_options: n64.audio.RomSample.Loaded.LoadOptions = .{};
    const wait_options: @TypeOf(assets.fixture_rom).Loaded.WaitOptions = .{};
    const scheduler_options: n64.rom.Scheduler.Options = .{};
    const fps_options: n64.time.FpsCounter.Options = .{};
    _ = .{ app_options, pass_options, overlay_options, display_options, present_options, audio_options, play_options, update_options, load_options, wait_options, text_options, scheduler_options, fps_options };

    if (assets.fixture_model.materialIndex("fixture") != 0) @compileError("resident material identifier was not generated");
    if (assets.fixture_rom_model.materialIndex("fixture") != 0) @compileError("ROM material identifier was not generated");
    if (assets.fixture_model.materialIndex("trim \"blue\" café") != 1) @compileError("escaped source material name was not preserved");
    if (assets.fixture_rom_model.materialIndex("trim \"blue\" café") != 1) @compileError("ROM source material name was not preserved");
    const overridden = assets.fixture_model.withOverrides(.{.{ .index = assets.fixture_model.materialIndex("fixture"), .fog = false }});
    if (overridden.withOverrides(.{.{ .no_light = true }}).materialIndex("fixture") != 0) @compileError("overrides lost material identifiers");
    if (@TypeOf(assets.fixture_ci4).format != .color_indexed) @compileError("indexed asset was not generated");
    if (assets.fixture_ci4.palette.len == 0 or assets.fixture_ci4.palette.len > 16) @compileError("CI4 palette was not generated");
    if (assets.fixture_ci4.texel_data.len != 4096) @compileError("CI4 texels were not packed");
    if (!@typeInfo(@TypeOf(assets.fixture_ci4.palette)).pointer.is_const) @compileError("embedded palette must be read-only");
    if (assets.raw_data.len != 10) @compileError("raw asset was not embedded");
    if (assets.generated_data.len != 15) @compileError("generated asset was not embedded");
    if (@TypeOf(assets.rom_data) != n64.rom.Region or assets.rom_data.size != 15) @compileError("ROM handle was not generated");
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

var audio_storage: [assets.fixture_audio_rom.storageSize()]u8 align(16) = undefined;
var stream_storage: [256]u8 align(16) = undefined;
var renderer: n64.graphics.Renderer = undefined;
var pixels: [8 * 8]n64.graphics.pixel.Rgba16 align(64) = undefined;
var reader: n64.rom.Reader = .{};
var rom_bytes: [15]u8 = undefined;
var rom_model_storage: [assets.fixture_rom_model.storageSize()]u8 align(16) = undefined;
var rom_texture_storage: [assets.fixture_rom.storageSize()]u8 align(16) = undefined;
var rom_ci_storage: [assets.fixture_rom_ci4.storageSize()]u8 align(16) = undefined;

pub fn main() !void {
    var memory: [1024]u8 align(64) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fixed.allocator();
    var loaded_audio = try assets.fixture_audio_rom.initBuffer(&audio_storage);
    const audio_sample = try loaded_audio.load(.{});
    try audio_sample.validate();
    if (!std.mem.eql(u8, assets.fixture_audio.data, audio_sample.data)) return error.AudioMismatch;
    _ = try n64.audio.Stream.init(assets.fixture_audio_rom, &stream_storage);
    try loaded_audio.deinit(allocator);
    var rom_model = try assets.fixture_rom_model.initBuffer(&rom_model_storage);
    defer rom_model.deinit(allocator) catch unreachable;
    const loaded_model = try rom_model.load(.{});
    var rom_texture = try assets.fixture_rom.initBuffer(&rom_texture_storage);
    defer rom_texture.deinit(allocator) catch unreachable;
    const loaded_texture = try rom_texture.load(.{});
    var rom_ci = try assets.fixture_rom_ci4.initBuffer(&rom_ci_storage);
    defer rom_ci.deinit(allocator) catch unreachable;
    const loaded_ci = try rom_ci.load(.{});
    try reader.read(assets.rom_data, 0, &rom_bytes, 1_000_000);
    if (!std.mem.eql(u8, &rom_bytes, &assets.generated_data)) return error.RomReadMismatch;
    var mesh = try n64.graphics.MutableModel.init(allocator, assets.fixture_model.model);
    defer mesh.deinit(allocator);
    mesh.vertices(0).get(0).position[0] = 0;
    if (assets.fixture_model.model.parts[0].vertices[0].pos_a[0] != -64) return error.ModifiedSource;
    const model = assets.fixture_model.withModel(mesh.model()).withOverrides(.{.{
        .texture = assets.fixture_font.atlases[0],
        .flags = n64.graphics.DrawFlags{ .textured = true, .no_light = true },
        .combine = n64.rdp.CombineMode.single(.{ .rgb_d = .tex0, .alpha_d = .one }),
        .fog = false,
    }});
    renderer.init();
    renderer.beginFrame(try n64.graphics.Image(n64.graphics.pixel.Rgba16).initBuffer(&pixels, 8, 8), .{ .clear_color = .black });
    var viewport = n64.graphics.Viewport.init(8, 8);
    renderer.geometry.attachViewport(&viewport);
    renderer.geometry.drawModel(model);
    const loaded_id = loaded_model.materialIndex("fixture");
    if (loaded_id != assets.fixture_rom_model.materialIndex("fixture")) return error.MaterialIdentifierMismatch;
    const loaded_override = loaded_model.withOverrides(.{.{ .index = loaded_id, .texture = assets.fixture_font.atlases[0] }});
    if (loaded_override.materialIndex("fixture") != loaded_id) return error.MaterialIdentifierMismatch;
    renderer.geometry.drawModel(loaded_override);
    if (loaded_texture.width == 0 or loaded_ci.palette.len == 0) return error.InvalidLoadedTexture;
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

pub fn exceptionHandler(_: *n64.cpu.exception.TrapFrame) noreturn {
    while (true) {}
}

pub fn interruptHandler() void {}
