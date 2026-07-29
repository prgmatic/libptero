const std = @import("std");

const enable_ipl3_debug = false;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(target_query);

    const n64_module = b.createModule(.{
        .root_source_file = b.path("src/n64/n64.zig"),
    });
    const tools = @import("build/tools.zig").build(b, n64_module);

    addToolTests(b);
    addGeneratedN64Assets(b, n64_module, tools);
    const zsp_test_programs = addZspTestPrograms(b, target, n64_module, tools);

    const game = @import("build/rom.zig").build(b, .{
        .name = "game",
        .title = "Libptero",
        .root_source_file = "src/game/entry.zig",
        .linker_script = "src/game/link.ld",
        .assembly_files = &.{"src/game/interrupt.S"},
        .target = target,
        .n64_module = n64_module,
        .tools = tools,
        .ipl3_debug = enable_ipl3_debug,
    });

    const game_step = game.addInstallStep(b, "game", "Build the game ROM");
    b.getInstallStep().dependOn(game_step);

    const test_rom = @import("build/rom.zig").build(b, .{
        .name = "tests",
        .title = "Libptero Tests",
        .root_source_file = "src/tests/entry.zig",
        .linker_script = "src/game/link.ld",
        .target = target,
        .n64_module = n64_module,
        .tools = tools,
        .ipl3_debug = enable_ipl3_debug,
        .imports = &.{
            .{ .name = "zsp_test_programs", .module = zsp_test_programs },
        },
    });
    const test_rom_step = test_rom.addInstallStep(b, "test-rom", "Build the test ROM");
    b.step("tests", "Build the test ROM").dependOn(test_rom_step);
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

fn addGeneratedN64Assets(
    b: *std.Build,
    n64_module: *std.Build.Module,
    tools: @import("build/tools.zig").Tools,
) void {
    const font_step = b.addRunArtifact(tools.console_font_conv);
    font_step.addFileArg(b.path("assets/console_font.png"));
    n64_module.addAnonymousImport("console_font", .{
        .root_source_file = font_step.addOutputFileArg("console.font"),
    });

    n64_module.addAnonymousImport("fill_dmem_rsp", .{
        .root_source_file = buildRspUcode(b, tools, "fill_dmem", "src/n64/rsp/ucode/fill_dmem.zsp"),
    });
    n64_module.addAnonymousImport("command_dispatcher_rsp", .{
        .root_source_file = buildRspUcode(
            b,
            tools,
            "command_dispatcher",
            "src/n64/rsp/ucode/command_dispatcher.zsp",
        ),
    });
}

fn addZspTestPrograms(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    tools: @import("build/tools.zig").Tools,
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
        .target = target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "n64", .module = n64_module }},
    });

    for (fixtures) |fixture| {
        const name = b.fmt("zsp_test_{s}", .{fixture});
        const import_name = b.fmt("zsp_test_{s}_rsp", .{fixture});
        const source = b.fmt("src/tests/ucode/{s}.zsp", .{fixture});
        module.addAnonymousImport(import_name, .{
            .root_source_file = buildRspUcode(b, tools, name, source),
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

fn buildRspUcode(
    b: *std.Build,
    tools: @import("build/tools.zig").Tools,
    name: []const u8,
    source: []const u8,
) std.Build.LazyPath {
    return buildRspUcodeFromPath(b, tools, name, b.path(source));
}

fn buildRspUcodeFromPath(
    b: *std.Build,
    tools: @import("build/tools.zig").Tools,
    name: []const u8,
    source: std.Build.LazyPath,
) std.Build.LazyPath {
    const zsp = b.addRunArtifact(tools.zsp);
    zsp.addFileArg(source);
    zsp.addArg("--module-dir");
    zsp.addDirectoryArg(b.path("src/n64/rsp/ucode"));
    zsp.addArg("--depfile");
    _ = zsp.addDepFileOutputArg(b.fmt("{s}.d", .{name}));
    const asm_file = zsp.addOutputFileArg(b.fmt("{s}.S", .{name}));

    const elf = b.addExecutable(.{
        .name = b.fmt("{s}_rsp.elf", .{name}),
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(target_query),
            .optimize = .ReleaseSmall,
        }),
    });
    elf.root_module.addAssemblyFile(asm_file);
    elf.setLinkerScript(b.path("src/n64/rsp/link.ld"));
    elf.entry = .{ .symbol_name = "_start" };
    elf.bundle_compiler_rt = false;
    elf.bundle_ubsan_rt = false;

    const pack = b.addRunArtifact(tools.rsp_pack);
    pack.addArtifactArg(elf);
    return pack.addOutputFileArg(b.fmt("{s}.rsp", .{name}));
}

const target_query: std.Target.Query = .{
    .cpu_arch = .mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = .freestanding,
    .abi = .none,
};
