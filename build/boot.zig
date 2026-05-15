const std = @import("std");
const optimization = std.builtin.OptimizeMode.ReleaseSmall;


const BuildOptions = struct {
    title: []const u8 = "Libptero",
    target: ?std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    write_artifacts: bool = true,
};

pub fn build(b: *std.Build, options: BuildOptions) std.Build.LazyPath {

    const elf_loader = buildElfLoader(b, options);
    return buildIpl3(b, elf_loader, options);
}

fn buildIpl3(b: *std.Build, loader: std.Build.LazyPath, options: BuildOptions) std.Build.LazyPath {
    // Create a config module to pass the rom name to 
    // the header.
    const config = b.addOptions();
    config.addOption([]const u8, "title", options.title);

    const ipl3 = b.addExecutable(.{
        .name = "ipl3.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/ipl3/ipl3.zig"),
            .optimize = optimization,
            .target = options.target,
            .imports = &.{ 
                .{.name = "n64", .module = options.n64_module },
                .{.name = "config", .module = config.createModule() },
            },
            .strip = false,  // Elf gets run through objdump. Fine to keep symbols.
        }),
    });

    ipl3.setLinkerScript(b.path("src/boot/ipl3/link.ld"));
    ipl3.root_module.addAssemblyFile(b.path("src/boot/ipl3/boot_trampoline.S"));
    ipl3.root_module.addAssemblyFile(b.path("src/boot/ipl3/ique_trampoline.S"));

    // Add the elf loader program as a anonymous import
    // This file is embedded via @embedFile
    ipl3.root_module.addAnonymousImport("loader.bin", .{
        .root_source_file = loader
    });

    // Save elf atrifact at prefix (no bin sub directory)
    const install = b.addInstallArtifact(ipl3, .{
        .dest_dir = .{ .override = .prefix }
    });
    b.getInstallStep().dependOn(&install.step);

    // Install bin at prefix
    const bin = ipl3.addObjCopy(.{ .format = .bin });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(bin.getOutput(), .prefix, "ipl3.z64").step);
    return bin.getOutput();
}

fn buildElfLoader(b: *std.Build, options: BuildOptions) std.Build.LazyPath {
    const loader = b.addExecutable(.{
        .name = "loader.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/loader/loader.zig"),
            .optimize = optimization,
            .target = options.target,
            .imports = &.{ .{ .name = "n64", .module = options.n64_module } },
            .strip = false,
            .pic = true,
        })
    });

    loader.setLinkerScript(b.path("src/boot/loader/link.ld"));

    const install = b.addInstallArtifact(loader, .{
        .dest_dir = .{ .override = .prefix }
    });
    b.getInstallStep().dependOn(&install.step);

    const bin = loader.addObjCopy(.{ .format = .bin });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(bin.getOutput(), .prefix, "loader.bin").step);

    return bin.getOutput();
}
