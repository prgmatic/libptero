const std = @import("std");

pub const Options = struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    libptero_root: std.Build.LazyPath,
    header: HeaderOptions,
    debug_logging: bool = false,
    required_rdram: u32,
    ipl3_linker_script: ?std.Build.LazyPath = null,
    loader_linker_script: ?std.Build.LazyPath = null,
    ipl3_assembly_files: ?[]const std.Build.LazyPath = null,
};

pub const HeaderOptions = struct {
    title: []const u8,
    game_code: [4]u8 = .{ 0, 0, 0, 0 },
    rom_version: u8 = 0,
};

pub fn build(b: *std.Build, options: Options) std.Build.LazyPath {
    const config = b.addOptions();
    config.addOption([]const u8, "title", options.header.title);
    config.addOption([4]u8, "game_code", options.header.game_code);
    config.addOption(u8, "rom_version", options.header.rom_version);
    config.addOption(bool, "debug_logging", options.debug_logging);
    config.addOption(u32, "required_rdram", options.required_rdram);
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
            .root_source_file = options.libptero_root.path(b, "src/boot/ipl3/ipl3.zig"),
            .optimize = .ReleaseSmall,
            .target = options.target,
            .imports = &.{
                .{ .name = "n64", .module = options.n64_module },
                .{ .name = "config", .module = config_module },
            },
            .strip = false,
        }),
    });

    ipl3.setLinkerScript(options.ipl3_linker_script orelse options.libptero_root.path(b, "src/boot/ipl3/link.ld"));
    const default_assembly = [_]std.Build.LazyPath{
        options.libptero_root.path(b, "src/boot/ipl3/boot_trampoline.S"),
        options.libptero_root.path(b, "src/boot/ipl3/ique_trampoline.S"),
    };
    for (options.ipl3_assembly_files orelse &default_assembly) |assembly_file| {
        ipl3.root_module.addAssemblyFile(assembly_file);
    }
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
            .root_source_file = options.libptero_root.path(b, "src/boot/loader/loader.zig"),
            .optimize = .ReleaseSmall,
            .target = options.target,
            .imports = &.{
                .{ .name = "n64", .module = options.n64_module },
                .{ .name = "config", .module = config_module },
            },
            .strip = false,
            .pic = true,
        }),
    });

    loader.setLinkerScript(options.loader_linker_script orelse options.libptero_root.path(b, "src/boot/loader/link.ld"));
    return loader.addObjCopy(.{ .format = .bin }).getOutput();
}
