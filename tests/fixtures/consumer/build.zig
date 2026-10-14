const std = @import("std");
const libptero = @import("libptero");

pub fn build(b: *std.Build) void {
    const no_install = b.option(bool, "no-install", "Do not install ROM outputs") orelse false;
    const no_assets = b.option(bool, "no-assets", "Exclude optional and built-in asset pipelines") orelse false;
    const override_handlers = b.option(bool, "override-handlers", "Use application-defined runtime handlers") orelse false;
    const custom_config = b.option(bool, "custom-config", "Use custom ROM layout and header metadata") orelse false;
    var sdk = libptero.init(b, .{
        .builtin_rsp_programs = !no_assets,
        .console_font = !override_handlers,
    });
    var assets = sdk.createAssets("assets");
    if (b.option(bool, "invalid-vadpcm", "Exercise the SDK's incompatible audio-options diagnostic") orelse false) {
        assets.addAudio("invalid", b.path("missing.wav"), .{ .compression = .vadpcm });
    }
    assets.embedFile("raw_data", b.path("assets/raw.bin"));
    const generated = b.addWriteFiles().add("generated.bin", "generated asset");
    assets.embedGeneratedFile("generated_data", generated);
    assets.addRomFile("rom_data", generated);
    assets.addTexture("fixture_ci4", b.path("../../../assets/console_font.png"), .{ .format = .ci4 });
    assets.addTexture("fixture_rom", b.path("../../../assets/console_font.png"), .{ .storage = .rom });
    assets.addTexture("fixture_rom_ci4", b.path("../../../assets/console_font.png"), .{ .storage = .rom, .format = .ci4 });
    assets.addModel("fixture_rom_model", @import("model_fixture.zig").create(b), .{ .storage = .rom });
    // Three mono PCM8 frames at 22050 Hz; generated inside the fixture build.
    const wave = "RIFF" ++ "\x28\x00\x00\x00" ++ "WAVEfmt " ++
        "\x10\x00\x00\x00\x01\x00\x01\x00" ++
        "\x22\x56\x00\x00\x22\x56\x00\x00\x01\x00\x08\x00" ++
        "data\x03\x00\x00\x00\x00\x80\xff\x00";
    const audio_fixture = b.addWriteFiles().add("fixture.wav", wave);
    assets.addAudio("fixture_audio", audio_fixture, .{});
    assets.addAudio("fixture_audio_rom", audio_fixture, .{ .storage = .rom });
    assets.addFont("fixture_font", b.path("assets/font.fnt"), .{});
    assets.addModel("fixture_model", @import("model_fixture.zig").create(b), .{ .texture_sizes = &.{.{ .material = 0, .width = 32, .height = 32 }} });
    _ = assets.addZspProgram("custom_rsp", b.path("assets/custom.zsp"));
    const rom = if (no_assets)
        sdk.addRom(.{
            .name = "consumer",
            .title = "Minimal Consumer",
            .app_source_file = b.path("src/minimal.zig"),
        })
    else if (custom_config)
        sdk.addRom(.{
            .name = "consumer",
            .title = "Configured Consumer",
            .app_source_file = b.path("src/main.zig"),
            .assets = &assets,
            .optimize = .ReleaseFast,
            .layout = .{
                .rdram = .expansion_pak,
                .stack_size = 128 * 1024,
            },
            .boot = .{ .ipl3_debug_logging = true },
            .metadata = .{
                .game_code = "LPTE".*,
                .rom_version = 7,
            },
            .install = .{ .outputs = .{ .rom = true, .debug_elf = true } },
        })
    else if (no_install)
        sdk.addRom(.{
            .name = "consumer",
            .title = "Libptero Consumer",
            .app_source_file = b.path("src/main.zig"),
            .assets = &assets,
            .install = null,
        })
    else if (override_handlers)
        sdk.addRom(.{
            .name = "consumer",
            .title = "Libptero Consumer",
            .app_source_file = b.path("src/main.zig"),
            .assets = &assets,
            .overrides = .{
                .entry = "alternateMain",
                .panic = "panicHandler",
                .exception = "exceptionHandler",
                .interrupt = "interruptHandler",
            },
            .install = .{
                .outputs = .{ .rom = true, .packed_elf = true },
                .name = "override-build",
                .directory = "roms",
            },
        })
    else
        sdk.addRom(.{
            .name = "consumer",
            .title = "Libptero Consumer",
            .app_source_file = b.path("src/main.zig"),
            .assets = &assets,
        });
    _ = rom;
}
