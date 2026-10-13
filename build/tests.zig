const std = @import("std");
const Sdk = @import("sdk.zig").Sdk;

const zsp_overlays = .{ "static_overlay", "static_overlay_2", "multi_slot_overlay" };

pub fn addConsumerFixtureTests(b: *std.Build) void {
    const fixture_dir = b.path("tests/fixtures/consumer");

    const full = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    full.setCwd(fixture_dir);
    const consumer = b.step("test-consumer", "Build the external consumer fixture");
    consumer.dependOn(&full.step);
    const invalid_audio = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-Dinvalid-vadpcm" });
    invalid_audio.setCwd(fixture_dir);
    invalid_audio.has_side_effects = true;
    invalid_audio.expectExitCode(1);
    invalid_audio.expectStdErrMatch("audio asset 'invalid': VADPCM requires .storage = .rom");
    consumer.dependOn(&invalid_audio.step);

    const minimal = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-Dno-assets" });
    minimal.setCwd(fixture_dir);
    b.step("test-consumer-minimal", "Build the consumer fixture without asset pipelines").dependOn(&minimal.step);
}

pub fn addToolTests(b: *std.Build, coverage: bool, coverage_runtime: ?[]const u8) void {
    const test_step = b.step("test", "Run host tool tests");
    addMaterialIdentifierChecks(b, test_step);
    const deploy_tests = b.addTest(.{ .name = "deploy-tests", .root_module = @import("tools.zig").deployModule(b, b.path(".")) });
    instrumentTests(deploy_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(deploy_tests).step);
    if (b.findProgram(&.{"python3"}, &.{}) catch null) |python| {
        const fonts = b.addSystemCommand(&.{ python, b.pathFromRoot("tests/integration/font_dependencies.py"), b.graph.zig_exe, b.pathFromRoot(".") });
        b.step("test-asset-cache", "Verify font page edits invalidate converted assets").dependOn(&fonts.step);
    }

    if (b.findProgram(&.{"node"}, &.{}) catch null) |node| {
        const viewer_tests = b.addSystemCommand(&.{ node, b.pathFromRoot("tools/profiler/viewer_test.mjs") });
        test_step.dependOn(&viewer_tests.step);
        b.step("test-profiler-viewer", "Exercise the embedded timeline viewer without a browser").dependOn(&viewer_tests.step);
    }
    const profiler_trace = b.createModule(.{ .root_source_file = b.path("src/n64/debug/profiler/trace.zig"), .target = b.graph.host });
    const profiler_module = b.createModule(.{
        .root_source_file = b.path("tools/profiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "profiler_trace", .module = profiler_trace }},
    });
    const profiler_tests = b.addTest(.{ .name = "profiler-tests", .root_module = profiler_module });
    instrumentTests(profiler_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(profiler_tests).step);
    const profiler_cli_tests = b.addTest(.{
        .name = "profiler-cli-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/profiler/main.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "profiler_trace", .module = profiler_trace }, .{ .name = "profiler", .module = b.createModule(.{
                .root_source_file = b.path("tools/profiler/root.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "profiler_trace", .module = profiler_trace }},
            }) } },
        }),
    });
    instrumentTests(profiler_cli_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(profiler_cli_tests).step);
    const gltf_compiler_tests = b.addTest(.{
        .name = "gltf-compiler-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gltf_compiler/root.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "fast_math", .module = b.createModule(.{
                .root_source_file = b.path("src/n64/math/fast.zig"),
                .target = b.graph.host,
            }) }, .{ .name = "texture_compiler", .module = b.createModule(.{
                .root_source_file = b.path("tools/texture_compiler/root.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "png", .module = b.createModule(.{
                    .root_source_file = b.path("tools/imgparse/png.zig"),
                    .target = b.graph.host,
                }) }},
            }) } },
        }),
    });
    instrumentTests(gltf_compiler_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(gltf_compiler_tests).step);
    const audio_cli_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/audio_compiler/main.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "audio_compiler", .module = @import("tools.zig").audioCompilerModule(b, b.path(".")) }},
    }) });
    instrumentTests(audio_cli_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(audio_cli_tests).step);
    const rom_cli_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/rom_assets/main.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "rom_assets", .module = b.createModule(.{ .root_source_file = b.path("tools/rom_assets/root.zig"), .target = b.graph.host }) }},
    }) });
    instrumentTests(rom_cli_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(rom_cli_tests).step);
    const png = b.createModule(.{
        .root_source_file = b.path("tools/imgparse/png.zig"),
        .target = b.graph.host,
    });
    const capture_tests = b.addTest(.{
        .name = "framebuffer-capture-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/framebuffer_capture/root.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "png", .module = png }},
        }),
    });
    instrumentTests(capture_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(capture_tests).step);
    const capture_cli_tests = b.addTest(.{
        .name = "framebuffer-capture-cli-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/framebuffer_capture/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "framebuffer_capture", .module = b.createModule(.{
                .root_source_file = b.path("tools/framebuffer_capture/root.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "png", .module = png }},
            }) }},
        }),
    });
    instrumentTests(capture_cli_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(capture_cli_tests).step);
    const texture_compiler_module = b.createModule(.{
        .root_source_file = b.path("tools/texture_compiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "png", .module = png }},
    });
    const texture_compiler_tests = b.addTest(.{
        .name = "texture-compiler-tests",
        .root_module = texture_compiler_module,
    });
    instrumentTests(texture_compiler_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(texture_compiler_tests).step);
    const texture_cli_tests = b.addTest(.{
        .name = "texture-compiler-cli-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/texture_compiler/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "texture_compiler", .module = b.createModule(.{
                .root_source_file = b.path("tools/texture_compiler/root.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "png", .module = png }},
            }) }},
        }),
    });
    instrumentTests(texture_cli_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(texture_cli_tests).step);
    const font_texture_compiler_module = b.createModule(.{
        .root_source_file = b.path("tools/texture_compiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "png", .module = png }},
    });
    const font_compiler_module = b.createModule(.{
        .root_source_file = b.path("tools/font_compiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "texture_compiler", .module = font_texture_compiler_module }},
    });
    const font_compiler_root_test_module = b.createModule(.{
        .root_source_file = b.path("tools/font_compiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "texture_compiler", .module = b.createModule(.{
            .root_source_file = b.path("tools/texture_compiler/root.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "png", .module = png }},
        }) }},
    });
    const font_compiler_root_tests = b.addTest(.{
        .name = "font-compiler-root-tests",
        .root_module = font_compiler_root_test_module,
    });
    instrumentTests(font_compiler_root_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(font_compiler_root_tests).step);
    const font_compiler_tests = b.addTest(.{
        .name = "font-compiler-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/font_compiler/main.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "font_compiler", .module = font_compiler_module },
                .{ .name = "png", .module = png },
            },
        }),
    });
    instrumentTests(font_compiler_tests, coverage, coverage_runtime);
    test_step.dependOn(&b.addRunArtifact(font_compiler_tests).step);
    inline for (.{
        .{ "audio-compiler-tests", "tools/audio_compiler/root.zig" },
        .{ "rom-assets-tests", "tools/rom_assets/root.zig" },
        .{ "elf-pack-tests", "tools/build/elf_pack.zig" },
        .{ "png-decoder-tests", "tools/imgparse/png.zig" },
        .{ "runtime-host-tests", "src/n64/n64.zig" },
        .{ "asset-options-tests", "build/assets.zig" },
        .{ "zsp-tests", "tools/zsp/tests.zig" },
        .{ "rsp-overlay-link-tests", "tools/build/rsp_overlay_link.zig" },
        .{ "rsp-pack-tests", "tools/build/rsp_pack.zig" },
        .{ "run-protocol-tests", "src/n64/debug/run_protocol.zig" },
        .{ "framebuffer-hex-tests", "src/n64/debug/framebuffer_hex.zig" },
    }) |test_config| {
        const test_artifact = b.addTest(.{
            .name = test_config[0],
            .root_module = if (comptime std.mem.eql(u8, test_config[0], "audio-compiler-tests")) @import("tools.zig").audioCompilerModule(b, b.path(".")) else b.createModule(.{
                .root_source_file = b.path(test_config[1]),
                .target = b.graph.host,
            }),
        });
        instrumentTests(test_artifact, coverage, coverage_runtime);
        test_step.dependOn(&b.addRunArtifact(test_artifact).step);
    }
}

fn instrumentTests(tests: *std.Build.Step.Compile, enabled: bool, runtime_path: ?[]const u8) void {
    if (!enabled) return;
    tests.root_module.link_libc = true;
    tests.use_llvm = true;
    tests.sanitize_coverage_trace_pc_guard = true;
    tests.forceUndefinedSymbol("__sanitizer_cov_trace_pc_guard_init");
    if (runtime_path) |path| tests.root_module.addObjectFile(.{ .cwd_relative = path });
}

pub fn addZspPrograms(b: *std.Build, sdk: *Sdk) *std.Build.Module {
    const fixtures = findZspFixtures(b, "src/tests/ucode");

    var assets = sdk.createAssets("zsp_test_assets");
    assets.omitZspSymbols();
    const resident = assets.addZspResident(
        "command_dispatcher",
        sdk.root.path(b, "src/n64/rsp/ucode/command_dispatcher.zsp"),
    );
    inline for (zsp_overlays) |name| {
        assets.addZspOverlay(
            name,
            sdk.root.path(b, "src/tests/ucode/" ++ name ++ ".zsp"),
            resident,
        );
    }
    assets.addZspOverlayWithStateStart(
        "geometry_overlay",
        sdk.root.path(b, "src/n64/rsp/ucode/geometry_overlay.zsp"),
        resident,
        0x0230,
    );
    assets.addZspOverlayWithStateStart(
        "geometry_clipping",
        sdk.root.path(b, "src/n64/rsp/ucode/geometry_clipping.zsp"),
        resident,
        0x0230,
    );

    var module_source_bytes: std.ArrayList(u8) = .empty;
    module_source_bytes.appendSlice(b.allocator,
        \\const Program = @import("n64").rsp.Program;
        \\const assets = @import("assets");
        \\
    ) catch @panic("OOM");
    module_source_bytes.appendSlice(b.allocator,
        \\pub const geometry_overlay_rsp align(8) = assets.geometry_overlay;
        \\pub const geometry_overlay = Program.fromBlob(&geometry_overlay_rsp);
        \\pub const geometry_clipping_rsp align(8) = assets.geometry_clipping;
        \\pub const geometry_clipping = Program.fromBlob(&geometry_clipping_rsp);
        \\
        \\
    ) catch @panic("OOM");
    for (fixtures) |fixture| {
        const blob_expression = if (isOverlay(fixture))
            b.fmt("assets.{s}", .{fixture})
        else
            b.fmt("@embedFile(\"zsp_test_{s}_rsp\").*", .{fixture});
        const declaration = b.fmt(
            \\pub const {s}_rsp align(8) = {s};
            \\pub const {s} = Program.fromBlob(&{s}_rsp);
            \\
            \\
        , .{ fixture, blob_expression, fixture, fixture });
        module_source_bytes.appendSlice(b.allocator, declaration) catch @panic("OOM");
    }

    const module_source = b.addWriteFiles().add("zsp_test_programs.zig", module_source_bytes.items);
    const module = b.createModule(.{
        .root_source_file = module_source,
        .target = sdk.target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "n64", .module = sdk.n64_module },
            .{ .name = "assets", .module = assets.createModule() },
        },
    });

    for (fixtures) |fixture| {
        if (isOverlay(fixture)) continue;
        const name = b.fmt("zsp_test_{s}", .{fixture});
        module.addAnonymousImport(b.fmt("{s}_rsp", .{name}), .{
            .root_source_file = assets.buildZspProgram(
                name,
                b.path(b.fmt("src/tests/ucode/{s}.zsp", .{fixture})),
            ),
        });
    }
    return module;
}

fn findZspFixtures(b: *std.Build, comptime dir_path: []const u8) []const []const u8 {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, b.pathFromRoot(dir_path), .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open {s}: {}", .{ dir_path, err });
    };
    defer dir.close(io);

    var fixtures: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| {
        std.debug.panic("unable to read {s}: {}", .{ dir_path, err });
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zsp")) continue;
        const basename = entry.name[0 .. entry.name.len - ".zsp".len];
        if (!std.zig.isValidId(basename)) {
            std.debug.panic("{s}/{s} cannot be imported because {s} is not a valid Zig identifier", .{
                dir_path,
                entry.name,
                basename,
            });
        }
        fixtures.append(b.allocator, b.dupe(basename)) catch @panic("OOM");
    }

    const owned = fixtures.toOwnedSlice(b.allocator) catch @panic("OOM");
    std.mem.sort([]const u8, owned, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return owned;
}

fn isOverlay(name: []const u8) bool {
    inline for (zsp_overlays) |overlay| {
        if (std.mem.eql(u8, name, overlay)) return true;
    }
    return false;
}

fn addMaterialIdentifierChecks(b: *std.Build, test_step: *std.Build.Step) void {
    const n64 = b.createModule(.{ .root_source_file = b.path("src/n64/n64.zig"), .target = b.graph.host });
    inline for (.{ .{ "missing", "UnknownMaterialName" }, .{ "body", "AmbiguousMaterialName" } }) |check| {
        const source = b.addWriteFiles().add(b.fmt("material-id-{s}.zig", .{check[0]}), b.fmt(
            \\const n64 = @import("n64");
            \\const Provider = struct {{ pub const material_names = [_][]const u8{{ "body", "body" }}; }};
            \\comptime {{ _ = @as(n64.graphics.ModelAsset(Provider), undefined).materialIndex("{s}"); }}
        , .{check[0]}));
        const invalid = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            .imports = &.{.{ .name = "n64", .module = n64 }},
        }) });
        invalid.expect_errors = .{ .contains = b.fmt("material '{s}': {s}; use a unique nonempty source name or a numeric index", .{ check[0], check[1] }) };
        test_step.dependOn(&invalid.step);
    }
}
