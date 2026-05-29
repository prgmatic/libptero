const std = @import("std");

const title: []const u8 = "Libptero";

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(target_query);
    // const optimize = b.standardOptimizeOption(.{
    //     .preferred_optimize_mode = .ReleaseSmall
    // });

    // Create main n64 library as a module
    const n64_module = b.createModule(.{
        .root_source_file = b.path("src/n64/n64.zig"),
    });

    const tools = @import("build/tools.zig").build(b, n64_module);

    // build console font
    const font_step = b.addRunArtifact(tools.console_font_conv);
    font_step.addFileArg(b.path("assets/console_font.png"));
    const font_file = font_step.addOutputFileArg("console.font");

    n64_module.addAnonymousImport("console_font", .{
        .root_source_file = font_file,
    });

    const fill_dmem_zsp = b.addRunArtifact(tools.zsp);
    fill_dmem_zsp.addFileArg(b.path("src/n64/rsp/ucode/fill_dmem.zsp"));
    const fill_dmem_asm = fill_dmem_zsp.addOutputFileArg("fill_dmem.S");

    const fill_dmem_elf = b.addExecutable(.{
        .name = "fill_dmem_rsp.elf",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });
    fill_dmem_elf.root_module.addAssemblyFile(fill_dmem_asm);
    fill_dmem_elf.setLinkerScript(b.path("src/n64/rsp/link.ld"));
    fill_dmem_elf.entry = .{ .symbol_name = "_start" };
    fill_dmem_elf.bundle_compiler_rt = false;
    fill_dmem_elf.bundle_ubsan_rt = false;
    const fill_dmem_bin = fill_dmem_elf.addObjCopy(.{
        .format = .bin,
        .only_section = ".text",
    }).getOutput();

    n64_module.addAnonymousImport("fill_dmem_rsp", .{
        .root_source_file = fill_dmem_bin,
    });



    // Build the ipl3
    const ipl3 = @import("build/boot.zig").build(b, .{
        .title = title,
        .n64_module = n64_module,
        .target = target
    });

    // Has debug info
    const game_module = b.createModule(.{
        .root_source_file = b.path("src/game/entry.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = false,
        .imports = &.{
            .{ .name = "n64", .module = n64_module },
        },
    });
       const elf_debug = b.addExecutable(.{
        .name = "game_debug.elf",
        .root_module = game_module,
    });
    elf_debug.link_z_max_page_size = 8;
    elf_debug.setLinkerScript(b.path("src/game/link.ld"));
    elf_debug.root_module.addAssemblyFile(b.path("src/game/interrupt.S"));

    b.getInstallStep().dependOn(&b.addInstallArtifact(elf_debug, .{
        .dest_dir = .{ .override = .prefix },
    }).step);

    // Generate source map from elf file
    const srcmap_step = b.addRunArtifact(tools.srcmap);
    srcmap_step.addArtifactArg(elf_debug);
    const srcmap_file = srcmap_step.addOutputFileArg("game.srcmap");
    srcmap_step.addArg(b.pathFromRoot("."));

    // Remove debug info from elf and add srcmap
    const pack_step = b.addRunArtifact(tools.elf_pack);
    pack_step.addArtifactArg(elf_debug);
    pack_step.addFileArg(srcmap_file);
    const elf = pack_step.addOutputFileArg("game.elf");

    // Combine header, ipl3, and elf into binary
    const make_rom_step = b.addRunArtifact(tools.ipl3_cat);
    make_rom_step.addFileArg(ipl3);
    make_rom_step.addFileArg(elf);
    const rom = make_rom_step.addOutputFileArg("game.z64");

    // Save Artifacts
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(elf, .prefix, "game.elf").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(rom, .prefix, "game.z64").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(srcmap_file, .prefix, "game.srcmap").step);
}


const target_query = std.Target.Query {
    .cpu_arch = std.Target.Cpu.Arch.mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = std.Target.Os.Tag.freestanding,
    .abi = std.Target.Abi.none
};
