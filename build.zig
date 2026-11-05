const std = @import("std");
const sdk_build = @import("build/sdk.zig");
const tests_build = @import("build/tests.zig");

pub const Sdk = sdk_build.Sdk;
pub const InitOptions = struct {
    root: ?std.Build.LazyPath = null,
    target: ?std.Build.ResolvedTarget = null,
    builtin_rsp_programs: bool = true,
    console_font: bool = true,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
};

pub fn init(b: *std.Build, options: InitOptions) Sdk {
    const root = options.root orelse b.dependencyFromBuildZig(@This(), .{}).path("");
    return Sdk.init(b, .{
        .root = root,
        .target = options.target,
        .builtin_rsp_programs = options.builtin_rsp_programs,
        .console_font = options.console_font,
        .optimize = options.optimize,
    });
}

/// Standard optimization spelling with the SDK's size-oriented default.
pub fn standardOptimizeOption(b: *std.Build) std.builtin.OptimizeMode {
    return b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse switch (b.release_mode) {
        .off, .any, .small => .ReleaseSmall,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
    };
}

pub fn build(b: *std.Build) void {
    // A dependency imports this file for its public API. Its project-only ROMs
    // and tests should not become part of the consumer's build graph.
    if (b.pkg_hash.len != 0) return;

    const coverage = b.option(bool, "coverage", "Enable zcov instrumentation") orelse false;
    const coverage_runtime = b.option([]const u8, "coverage-rt", "Path to zcov runtime object");
    var sdk = init(b, .{ .root = b.path(""), .optimize = standardOptimizeOption(b) });
    const crash_options = b.addOptions();
    crash_options.addOption(bool, "exception", b.option(bool, "crash-screen-exception", "Trigger a CPU breakpoint instead of a Zig panic in the crash-screen smoke ROM") orelse false);
    _ = sdk.addRom(.{
        .name = "crash-screen-smoke",
        .title = "Real Crash Screen Test",
        .app_source_file = b.path("src/tests/crash_screen_smoke.zig"),
        .imports = &.{.{ .name = "crash_smoke_options", .module = crash_options.createModule() }},
        .install = .{ .outputs = .{ .rom = true, .debug_elf = true }, .step_name = "crash-screen-smoke", .description = "Build a deliberate real panic or CPU exception" },
    });
    b.installArtifact(sdk.tools.zsp);
    b.installArtifact(sdk.tools.texture_compiler);
    b.installArtifact(sdk.tools.font_compiler);
    b.installArtifact(sdk.tools.audio_compiler);
    b.installArtifact(sdk.tools.rom_assets);
    b.installArtifact(sdk.tools.deploy);
    _ = sdk.addRom(.{
        .name = "deploy-smoke",
        .title = "Deploy Smoke Test",
        .app_source_file = b.path("src/tests/deploy_smoke.zig"),
        .install = .{ .step_name = "deploy-smoke", .description = "Build a finite deploy/debug transport smoke ROM", .add_to_default = false },
    });
    b.installArtifact(sdk.tools.gltf_compiler);
    const capture_module = b.createModule(.{
        .root_source_file = b.path("tools/framebuffer_capture/root.zig"),
        .target = b.graph.host,
    });
    b.installArtifact(b.addExecutable(.{
        .name = "framebuffer-capture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/framebuffer_capture/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "framebuffer_capture", .module = capture_module }},
        }),
    }));

    b.installArtifact(b.addExecutable(.{
        .name = "rsp-interp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/rsp_interp/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "rsp_interp", .module = @import("build/tools.zig").rspInterpModule(b, b.path(".")) }},
        }),
    }));

    const profiler_trace = b.createModule(.{ .root_source_file = b.path("src/n64/debug/profiler/trace.zig"), .target = b.graph.host });
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("tools/profiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "profiler_trace", .module = profiler_trace }},
    });
    b.installArtifact(b.addExecutable(.{
        .name = "ptero-profiler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profiler/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "profiler", .module = profiler_module }},
        }),
    }));
    tests_build.addToolTests(b, coverage, coverage_runtime);
    tests_build.addConsumerFixtureTests(b);
    const zsp_programs = tests_build.addZspPrograms(b, &sdk);
    tests_build.addZspInterpreterTests(b, zsp_programs.host_blobs, coverage, coverage_runtime);
    tests_build.addMicrocodeBaseline(b, &sdk, coverage, coverage_runtime);
    const zsp_test_programs = zsp_programs.module;

    _ = sdk.addRom(.{
        .name = "game",
        .title = "Libptero",
        .app_source_file = b.path("src/game/game.zig"),
        .linker_script = b.path("src/game/link.ld"),
        .install = .{
            .outputs = .{ .rom = true, .packed_elf = true, .debug_elf = true, .source_map = true },
            .description = "Build the game ROM",
        },
    });

    var audio_assets = sdk.createAssets("audio_test_assets");
    const fixtures = @import("build/asset_fixtures.zig");
    const texture_fixture = fixtures.texture(b, "red.png", .{ 255, 0, 0, 255 } ** 4);
    const blue_fixture = fixtures.texture(b, "blue.png", .{ 0, 0, 255, 255 } ** 4);
    inline for (.{ "rgba16", "rgba32", "yuv16", "ci4", "ci8", "ia4", "ia8", "ia16", "i4", "i8" }) |format| {
        const selected = std.meta.stringToEnum(@import("build/assets.zig").TextureFormat, format).?;
        audio_assets.addTexture("texture_rom_" ++ format, texture_fixture, .{ .storage = .rom, .format = selected });
        audio_assets.addTexture("texture_resident_" ++ format, texture_fixture, .{ .format = selected });
    }
    audio_assets.addTexture("blue_rom", blue_fixture, .{ .storage = .rom });
    audio_assets.addTexture("blue_palette_rom", blue_fixture, .{ .storage = .rom, .format = .ci4 });
    const model_fixture = fixtures.model(b);
    audio_assets.addModel("model_rom", model_fixture, .{ .storage = .rom });
    audio_assets.addModel("model_resident", model_fixture, .{});
    const skinned_fixture = fixtures.skinnedModel(b);
    audio_assets.addModel("weighted_rom", skinned_fixture, .{ .storage = .rom });
    audio_assets.addModel("weighted_resident", skinned_fixture, .{});
    audio_assets.addModel("joint_rom", skinned_fixture, .{ .storage = .rom, .skinning = .first_joint });
    audio_assets.addModel("joint_resident", skinned_fixture, .{ .skinning = .first_joint });
    var rom_bytes: [5003]u8 = undefined;
    for (&rom_bytes, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    audio_assets.addRomFile("raw_rom", b.addWriteFiles().add("raw-rom.bin", &rom_bytes));
    audio_assets.addRomFile("empty_rom", b.addWriteFiles().add("empty-rom.bin", ""));
    const wav_fixture = @import("tools/audio_compiler/wav.zig");
    inline for (.{ .{ "mono8", 8, 1 }, .{ "mono16", 16, 1 }, .{ "stereo8", 8, 2 }, .{ "stereo16", 16, 2 } }) |fixture| {
        var bytes: [64 * fixture[2] * (fixture[1] / 8)]u8 = undefined;
        for (0..64) |frame| {
            for (0..fixture[2]) |channel| {
                const value: i16 = @as(i16, @intCast(frame % 32)) - 16;
                const signed = if (channel == 0) value else -value;
                const offset = (frame * fixture[2] + channel) * (fixture[1] / 8);
                if (fixture[1] == 8) bytes[offset] = @as(u8, @bitCast(@as(i8, @intCast(signed)))) ^ 0x80 else std.mem.writeInt(i16, bytes[offset..][0..2], signed * 256, .little);
            }
        }
        const wave = wav_fixture.fixture(fixture[1], fixture[2], &bytes, b.allocator) catch @panic("OOM");
        audio_assets.addAudio(fixture[0] ++ "_vadpcm", b.addWriteFiles().add(fixture[0] ++ "-vadpcm.wav", wave), .{ .loop = true, .compression = .vadpcm, .storage = .rom });
        audio_assets.addAudio(fixture[0] ++ "_stream", b.addWriteFiles().add(fixture[0] ++ "-stream.wav", wave), .{ .loop = true, .storage = .rom });
        audio_assets.addAudio(fixture[0], b.addWriteFiles().add(fixture[0] ++ ".wav", wave), .{ .loop = true });
    }
    const finite_wave = wav_fixture.fixture(16, 1, &([_]u8{ 0, 4 } ** 64), b.allocator) catch @panic("OOM");
    audio_assets.addAudio("finite_vadpcm", b.addWriteFiles().add("finite-vadpcm.wav", finite_wave), .{ .compression = .vadpcm, .storage = .rom });
    audio_assets.addAudio("finite_stream", b.addWriteFiles().add("finite-stream.wav", finite_wave), .{ .storage = .rom });
    audio_assets.addAudio("finite", b.addWriteFiles().add("finite.wav", finite_wave), .{});
    var compressed_long_pcm: [1201 * 4]u8 = undefined;
    for (0..1201) |frame| {
        std.mem.writeInt(i16, compressed_long_pcm[frame * 4 ..][0..2], @intCast(@as(i32, @intCast(frame % 127)) * 450 - 28000), .little);
        std.mem.writeInt(i16, compressed_long_pcm[frame * 4 + 2 ..][0..2], @intCast(@as(i32, @intCast(frame % 157)) * 350 - 27000), .little);
    }
    const compressed_wave = wav_fixture.fixture(16, 2, &compressed_long_pcm, b.allocator) catch @panic("OOM");
    audio_assets.addAudio("long_vadpcm", b.addWriteFiles().add("long-vadpcm.wav", compressed_wave), .{ .compression = .vadpcm, .storage = .rom, .loop = true });
    const test_rom = sdk.addRom(.{
        .name = "tests",
        .title = "Libptero Tests",
        .root_source_file = b.path("src/tests/entry.zig"),
        .assembly_files = &.{},
        .assets = &audio_assets,
        .imports = &.{
            .{ .name = "zsp_test_programs", .module = zsp_test_programs },
            .{ .name = "rsp_calibration", .module = b.createModule(.{
                .root_source_file = b.path("tools/rsp_interp/calibration.zig"),
                .target = sdk.target,
                .optimize = .ReleaseSmall,
            }) },
        },
        .install = .{
            .outputs = .{ .rom = true, .packed_elf = true, .debug_elf = true, .source_map = true },
            .step_name = "test-rom",
            .description = "Build the test ROM",
            .add_to_default = false,
        },
    });
    b.step("tests", "Build the test ROM").dependOn(test_rom.install_step.?);
}
