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

    // Build the ipl3
    const ipl3 = @import("build/boot.zig").build(b, .{
        .title = title,
        .n64_module = n64_module,
        .target = target
    });

    // Build the game
    const elf = b.addExecutable(.{
        .name = "game.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/game/entry.zig"),
            .target = target,
            .optimize = .ReleaseSmall, //optimize,
            .imports = &.{ 
                .{.name = "n64", .module = n64_module },
            },
            .strip = false
        })
    });

    elf.setLinkerScript(b.path("src/game/link.ld"));
    elf.root_module.addAssemblyFile(b.path("src/game/interrupt.S"));
    
    // Save elf atrifact at prefix (no bin sub directory)
    const elf_install = b.addInstallArtifact(elf, .{
        .dest_dir = .{ .override = .prefix }
    });
    b.getInstallStep().dependOn(&elf_install.step);

    // Glue ipl3 and game elf together
    const cat_tool = b.addExecutable(.{
        .name = "ipl3_cat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/ipl3_cat.zig"),
            .target = b.graph.host
        }),
    });

    

    const make_rom_step = b.addRunArtifact(cat_tool);
    make_rom_step.addFileArg(ipl3);
    make_rom_step.addArtifactArg(elf);
    const rom = make_rom_step.addOutputFileArg("game.z64");

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(rom, .prefix, "game.z64").step);
}

const target_query = std.Target.Query {
    .cpu_arch = std.Target.Cpu.Arch.mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = std.Target.Os.Tag.freestanding,
    .abi = std.Target.Abi.none
};
