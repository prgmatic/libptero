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

    // Build the ipl3
    const ipl3 = @import("build/boot.zig").build(b, .{
        .title = title,
        .n64_module = n64_module,
        .target = target
    });

    // Canonical game ELF: this is the only linked game image. It keeps DWARF
    // so tools can derive source maps from the exact code layout that runs.
    const elf_debug = b.addExecutable(.{
        .name = "game_debug.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/game/entry.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .imports = &.{
                .{ .name = "n64", .module = n64_module },
            },
        })
    });
    elf_debug.link_z_max_page_size = 8;
    elf_debug.setLinkerScript(b.path("src/game/link.ld"));
    elf_debug.root_module.addAssemblyFile(b.path("src/game/interrupt.S"));
    b.getInstallStep().dependOn(&b.addInstallArtifact(elf_debug, .{
        .dest_dir = .{ .override = .prefix },
    }).step);

    // Generate srcmap from that exact ELF, then strip/pack the same image with
    // the srcmap appended as an extra PT_LOAD segment.
    const srcmap_step = b.addRunArtifact(tools.srcmap);
    srcmap_step.addArtifactArg(elf_debug);
    const srcmap_file = srcmap_step.addOutputFileArg("game.srcmap");

    const pack_step = b.addRunArtifact(tools.elf_pack);
    pack_step.addArtifactArg(elf_debug);
    pack_step.addFileArg(srcmap_file);
    const elf = pack_step.addOutputFileArg("game.elf");

    const make_rom_step = b.addRunArtifact(tools.ipl3_cat);
    make_rom_step.addFileArg(ipl3);
    make_rom_step.addFileArg(elf);
    const rom = make_rom_step.addOutputFileArg("game.z64");

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
