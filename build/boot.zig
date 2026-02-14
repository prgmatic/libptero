const std = @import("std");
const optimization = std.builtin.OptimizeMode.ReleaseSmall;

pub fn build(b: *std.Build, target: ?std.Build.ResolvedTarget, n64_module: *std.Build.Module, title: []const u8) void {
    const options = b.addOptions();
    options.addOption([]const u8, "title", title);

    const stage0 = b.addExecutable(.{
        .name = "stage1.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/stage1/ipl3.zig"),
            .optimize = optimization,
            .target = target,
            .imports = &.{ 
                .{.name = "n64", .module = n64_module },
                .{.name = "config", .module = options.createModule() },
            },
            .strip = false,
        }),
    });

    stage0.setLinkerScript(b.path("src/boot/link.ld"));
    stage0.addAssemblyFile(b.path("src/boot/stage1/boot_trampoline.S"));
    stage0.addAssemblyFile(b.path("src/boot/stage1/ique_trampoline.S"));
    
    // Install elf at prefix
    const install = b.addInstallArtifact(stage0, .{
        .dest_dir = .{ .override = .prefix }
    });
    b.getInstallStep().dependOn(&install.step);

    // Install bin at prefix
    const bin = stage0.addObjCopy(.{ .format = .bin });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(bin.getOutput(), .prefix, "ipl3.z64").step);
}
