const std = @import("std");

const optimization = std.builtin.OptimizeMode.ReleaseSmall;

pub const Options = struct {
    name: []const u8,
    title: []const u8,
    target: std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    debug_logging: bool = false,
};

pub fn build(b: *std.Build, options: Options) std.Build.LazyPath {
    const config = b.addOptions();
    config.addOption([]const u8, "title", options.title);
    config.addOption(bool, "debug_logging", options.debug_logging);
    const config_module = config.createModule();

    const loader = buildElfLoader(b, options, config_module);
    return buildIpl3(b, loader, options, config_module);
}

fn buildIpl3(
    b: *std.Build,
    loader: std.Build.LazyPath,
    options: Options,
    config_module: *std.Build.Module,
) std.Build.LazyPath {
    const ipl3 = b.addExecutable(.{
        .name = b.fmt("{s}_ipl3.elf", .{options.name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/ipl3/ipl3.zig"),
            .optimize = optimization,
            .target = options.target,
            .imports = &.{
                .{ .name = "n64", .module = options.n64_module },
                .{ .name = "config", .module = config_module },
            },
            .strip = false,
        }),
    });

    ipl3.setLinkerScript(b.path("src/boot/ipl3/link.ld"));
    ipl3.root_module.addAssemblyFile(b.path("src/boot/ipl3/boot_trampoline.S"));
    ipl3.root_module.addAssemblyFile(b.path("src/boot/ipl3/ique_trampoline.S"));
    ipl3.root_module.addAnonymousImport("loader.bin", .{
        .root_source_file = loader,
    });

    return ipl3.addObjCopy(.{ .format = .bin }).getOutput();
}

fn buildElfLoader(
    b: *std.Build,
    options: Options,
    config_module: *std.Build.Module,
) std.Build.LazyPath {
    const loader = b.addExecutable(.{
        .name = b.fmt("{s}_loader.elf", .{options.name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/loader/loader.zig"),
            .optimize = optimization,
            .target = options.target,
            .imports = &.{
                .{ .name = "n64", .module = options.n64_module },
                .{ .name = "config", .module = config_module },
            },
            .strip = false,
            .pic = true,
        }),
    });

    loader.setLinkerScript(b.path("src/boot/loader/link.ld"));
    return loader.addObjCopy(.{ .format = .bin }).getOutput();
}
