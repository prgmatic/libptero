const std = @import("std");
const sdk_build = @import("build/sdk.zig");
const tests_build = @import("build/tests.zig");

pub const Sdk = sdk_build.Sdk;
pub const InitOptions = struct {
    root: ?std.Build.LazyPath = null,
    target: ?std.Build.ResolvedTarget = null,
    builtin_rsp_programs: bool = true,
    console_font: bool = true,
};

pub fn init(b: *std.Build, options: InitOptions) Sdk {
    const root = options.root orelse b.dependencyFromBuildZig(@This(), .{}).path("");
    return Sdk.init(b, .{
        .root = root,
        .target = options.target,
        .builtin_rsp_programs = options.builtin_rsp_programs,
        .console_font = options.console_font,
    });
}

pub fn build(b: *std.Build) void {
    // A dependency imports this file for its public API. Its project-only ROMs
    // and tests should not become part of the consumer's build graph.
    if (b.pkg_hash.len != 0) return;

    const coverage = b.option(bool, "coverage", "Enable zcov instrumentation") orelse false;
    const coverage_runtime = b.option([]const u8, "coverage-rt", "Path to zcov runtime object");
    var sdk = init(b, .{ .root = b.path("") });
    b.installArtifact(sdk.tools.font_compiler);
    b.installArtifact(sdk.tools.audio_compiler);
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

    tests_build.addToolTests(b, coverage, coverage_runtime);
    tests_build.addConsumerFixtureTests(b);
    const zsp_test_programs = tests_build.addZspPrograms(b, &sdk);

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
        audio_assets.addAudio(fixture[0], b.addWriteFiles().add(fixture[0] ++ ".wav", wave), .{ .loop = true });
    }
    const finite_wave = wav_fixture.fixture(16, 1, &([_]u8{ 0, 4 } ** 64), b.allocator) catch @panic("OOM");
    audio_assets.addAudio("finite", b.addWriteFiles().add("finite.wav", finite_wave), .{});
    const test_rom = sdk.addRom(.{
        .name = "tests",
        .title = "Libptero Tests",
        .root_source_file = b.path("src/tests/entry.zig"),
        .assembly_files = &.{},
        .imports = &.{
            .{ .name = "zsp_test_programs", .module = zsp_test_programs },
            .{ .name = "audio_test_assets", .module = audio_assets.createModule() },
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
