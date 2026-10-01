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

    const test_rom = sdk.addRom(.{
        .name = "tests",
        .title = "Libptero Tests",
        .root_source_file = b.path("src/tests/entry.zig"),
        .assembly_files = &.{},
        .imports = &.{
            .{ .name = "zsp_test_programs", .module = zsp_test_programs },
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
