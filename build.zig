const std = @import("std");
const sdk_build = @import("build/sdk.zig");

pub const Sdk = sdk_build.Sdk;
pub const InitOptions = struct {
    root: ?std.Build.LazyPath = null,
    target: ?std.Build.ResolvedTarget = null,
};

pub fn init(b: *std.Build, options: InitOptions) Sdk {
    const root = options.root orelse b.dependencyFromBuildZig(@This(), .{}).path("");
    return Sdk.init(b, .{
        .root = root,
        .target = options.target,
    });
}

pub fn build(b: *std.Build) void {
    // A dependency imports this file for its public API. Its project-only ROMs
    // and tests should not become part of the consumer's build graph.
    if (b.pkg_hash.len != 0) return;

    var sdk = init(b, .{ .root = b.path("") });

    addToolTests(b);
    addConsumerFixtureTests(b);
    const zsp_test_programs = addZspTestPrograms(b, &sdk);

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

fn addConsumerFixtureTests(b: *std.Build) void {
    const fixture_dir = b.path("tests/fixtures/consumer");

    const full = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    full.setCwd(fixture_dir);
    b.step("test-consumer", "Build the external consumer fixture").dependOn(&full.step);

    const minimal = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-Dno-assets" });
    minimal.setCwd(fixture_dir);
    b.step("test-consumer-minimal", "Build the consumer fixture without asset pipelines").dependOn(&minimal.step);
}

fn addToolTests(b: *std.Build) void {
    const test_step = b.step("test", "Run host tool tests");

    const zsp_tests = b.addTest(.{
        .name = "zsp-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zsp/tests.zig"),
            .target = b.graph.host,
        }),
    });
    const run_zsp_tests = b.addRunArtifact(zsp_tests);
    test_step.dependOn(&run_zsp_tests.step);

    const ucode_tests = b.addTest(.{
        .name = "ucode-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/n64/rsp/ucode_tests.zig"),
            .target = b.graph.host,
        }),
    });
    const run_ucode_tests = b.addRunArtifact(ucode_tests);
    test_step.dependOn(&run_ucode_tests.step);

    const command_queue_tests = b.addTest(.{
        .name = "command-queue-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/n64/rsp/command_queue_tests.zig"),
            .target = b.graph.host,
        }),
    });
    const run_command_queue_tests = b.addRunArtifact(command_queue_tests);
    test_step.dependOn(&run_command_queue_tests.step);

    const rsp_overlay_link_tests = b.addTest(.{
        .name = "rsp-overlay-link-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/rsp_overlay_link.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(rsp_overlay_link_tests).step);

    const rsp_pack_tests = b.addTest(.{
        .name = "rsp-pack-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/rsp_pack.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(rsp_pack_tests).step);

    const test_protocol_tests = b.addTest(.{
        .name = "test-protocol-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/test_protocol.zig"),
            .target = b.graph.host,
        }),
    });
    const run_test_protocol_tests = b.addRunArtifact(test_protocol_tests);
    test_step.dependOn(&run_test_protocol_tests.step);
}

fn addZspTestPrograms(
    b: *std.Build,
    sdk: *const Sdk,
) *std.Build.Module {
    const fixtures = findZspTestFixtures(b, "src/tests/ucode");

    var module_source_bytes: std.ArrayList(u8) = .empty;
    module_source_bytes.appendSlice(b.allocator,
        \\const UCode = @import("n64").rsp.UCode;
        \\
    ) catch @panic("OOM");
    for (fixtures) |fixture| {
        const decl = std.fmt.allocPrint(b.allocator,
            \\pub const {s}_rsp align(8) = @embedFile("zsp_test_{s}_rsp").*;
            \\pub const {s} = UCode.fromBlob(&{s}_rsp);
            \\
            \\
        , .{ fixture, fixture, fixture, fixture }) catch @panic("OOM");
        module_source_bytes.appendSlice(b.allocator, decl) catch @panic("OOM");
    }

    const module_source = b.addWriteFiles().add("zsp_test_programs.zig", module_source_bytes.items);

    const module = b.createModule(.{
        .root_source_file = module_source,
        .target = sdk.target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "n64", .module = sdk.n64_module }},
    });

    for (fixtures) |fixture| {
        const name = b.fmt("zsp_test_{s}", .{fixture});
        const import_name = b.fmt("zsp_test_{s}_rsp", .{fixture});
        const source = b.fmt("src/tests/ucode/{s}.zsp", .{fixture});
        module.addAnonymousImport(import_name, .{
            .root_source_file = sdk.addRspUcode(name, b.path(source)),
        });
    }

    return module;
}

fn findZspTestFixtures(b: *std.Build, comptime dir_path: []const u8) []const []const u8 {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open {s}: {}", .{ dir_path, err });
    };
    defer dir.close(io);

    var fixtures: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| {
        std.debug.panic("unable to read {s}: {}", .{ dir_path, err });
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zsp")) continue;

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
