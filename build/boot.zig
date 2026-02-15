const std = @import("std");
const optimization = std.builtin.OptimizeMode.ReleaseSmall;

pub fn build(b: *std.Build, target: ?std.Build.ResolvedTarget, n64_module: *std.Build.Module, title: []const u8) void {
    const options = b.addOptions();
    options.addOption([]const u8, "title", title);

    const ipl3 = b.addExecutable(.{
        .name = "ipl3.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/ipl3/ipl3.zig"),
            .optimize = optimization,
            .target = target,
            .imports = &.{ 
                .{.name = "n64", .module = n64_module },
                .{.name = "config", .module = options.createModule() },
            },
            .strip = false,
        }),
    });

    ipl3.setLinkerScript(b.path("src/boot/ipl3/link.ld"));
    ipl3.addAssemblyFile(b.path("src/boot/ipl3/boot_trampoline.S"));
    ipl3.addAssemblyFile(b.path("src/boot/ipl3/ique_trampoline.S"));

    const loader = buildLoader(b, target, n64_module);
    ipl3.root_module.addAnonymousImport("loader.bin", .{
        .root_source_file = loader
    });

    // Install elf at prefix
    const install = b.addInstallArtifact(ipl3, .{
        .dest_dir = .{ .override = .prefix }
    });
    b.getInstallStep().dependOn(&install.step);

    // Install bin at prefix
    const bin = ipl3.addObjCopy(.{ .format = .bin });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(bin.getOutput(), .prefix, "ipl3.z64").step);
}

fn buildLoader(b: *std.Build, target: ?std.Build.ResolvedTarget, n64_module: *std.Build.Module) std.Build.LazyPath {
    const loader = b.addExecutable(.{
        .name = "loader.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/loader/loader.zig"),
            .optimize = optimization,
            .target = target,
            .imports = &.{ .{ .name = "n64", .module = n64_module } },
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
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(bin.getOutput(), .prefix, "loader.z64").step);

    return bin.getOutput();
}
