const std = @import("std");
const Sdk = @import("sdk.zig").Sdk;

const zsp_overlays = .{ "static_overlay", "static_overlay_2", "multi_slot_overlay" };

pub fn addConsumerFixtureTests(b: *std.Build) void {
    const fixture_dir = b.path("tests/fixtures/consumer");

    const full = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    full.setCwd(fixture_dir);
    b.step("test-consumer", "Build the external consumer fixture").dependOn(&full.step);

    const minimal = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-Dno-assets" });
    minimal.setCwd(fixture_dir);
    b.step("test-consumer-minimal", "Build the consumer fixture without asset pipelines").dependOn(&minimal.step);
}

pub fn addToolTests(b: *std.Build) void {
    const test_step = b.step("test", "Run host tool tests");
    inline for (.{
        .{ "zsp-tests", "tools/zsp/tests.zig" },
        .{ "ucode-tests", "src/n64/rsp/ucode_tests.zig" },
        .{ "command-queue-tests", "src/n64/rsp/command_queue_tests.zig" },
        .{ "rsp-overlay-link-tests", "tools/build/rsp_overlay_link.zig" },
        .{ "rsp-pack-tests", "tools/build/rsp_pack.zig" },
        .{ "test-protocol-tests", "tools/test_protocol.zig" },
    }) |test_config| {
        const test_artifact = b.addTest(.{
            .name = test_config[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_config[1]),
                .target = b.graph.host,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(test_artifact).step);
    }
}

pub fn addZspPrograms(b: *std.Build, sdk: *Sdk) *std.Build.Module {
    const fixtures = findZspFixtures(b, "src/tests/ucode");

    var assets = sdk.createAssets("zsp_test_assets");
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

    var module_source_bytes: std.ArrayList(u8) = .empty;
    module_source_bytes.appendSlice(b.allocator,
        \\const UCode = @import("n64").rsp.UCode;
        \\const assets = @import("assets");
        \\
    ) catch @panic("OOM");
    for (fixtures) |fixture| {
        const blob_expression = if (isOverlay(fixture))
            b.fmt("assets.{s}", .{fixture})
        else
            b.fmt("@embedFile(\"zsp_test_{s}_rsp\").*", .{fixture});
        const declaration = b.fmt(
            \\pub const {s}_rsp align(8) = {s};
            \\pub const {s} = UCode.fromBlob(&{s}_rsp);
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
