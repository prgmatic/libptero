const std = @import("std");
const Tools = @import("tools.zig").Tools;

pub const Options = struct {
    name: []const u8,
    title: []const u8,
    root_source_file: std.Build.LazyPath,
    linker_script: std.Build.LazyPath,
    assembly_files: []const std.Build.LazyPath = &.{},
    target: std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    tools: Tools,
    libptero_root: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    layout: MemoryLayout,
    boot: BootOptions,
    metadata: MetadataOptions,
    imports: []const std.Build.Module.Import = &.{},
};

pub const MemoryLayout = struct {
    rdram: Rdram = .standard,
    stack_size: u32 = 64 * 1024,
    rom_length: u32 = 64 * 1024 * 1024,
};

pub const Rdram = enum(u32) {
    standard = 4 * 1024 * 1024,
    expansion_pak = 8 * 1024 * 1024,
};

pub const boot_reserve = 64 * 1024;

pub const BootOptions = struct {
    ipl3_debug_logging: bool = false,
    ipl3_linker_script: ?std.Build.LazyPath = null,
    loader_linker_script: ?std.Build.LazyPath = null,
    ipl3_assembly_files: ?[]const std.Build.LazyPath = null,
};

pub const MetadataOptions = struct {
    game_code: [4]u8 = .{ 0, 0, 0, 0 },
    rom_version: u8 = 0,
};

pub const Rom = struct {
    name: []const u8,
    debug_elf: *std.Build.Step.Compile,
    elf: std.Build.LazyPath,
    srcmap: std.Build.LazyPath,
    image: std.Build.LazyPath,
    install_step: ?*std.Build.Step = null,

    pub fn configureInstall(
        self: *Rom,
        b: *std.Build,
        options: InstallOptions,
    ) *std.Build.Step {
        const install_name = options.name orelse self.name;
        const step_name = options.step_name orelse self.name;
        const description = options.description orelse b.fmt("Build and install the {s} ROM", .{self.name});
        const step = b.step(step_name, description);
        if (options.outputs.debug_elf) {
            step.dependOn(&b.addInstallArtifact(self.debug_elf, .{
                .dest_dir = .{ .override = .prefix },
                .dest_sub_path = installPath(b, options.directory, b.fmt("{s}_debug.elf", .{install_name})),
            }).step);
        }
        if (options.outputs.packed_elf) {
            step.dependOn(&b.addInstallFileWithDir(
                self.elf,
                .prefix,
                installPath(b, options.directory, b.fmt("{s}.elf", .{install_name})),
            ).step);
        }
        if (options.outputs.source_map) {
            step.dependOn(&b.addInstallFileWithDir(
                self.srcmap,
                .prefix,
                installPath(b, options.directory, b.fmt("{s}.srcmap", .{install_name})),
            ).step);
        }
        if (options.outputs.rom) {
            step.dependOn(&b.addInstallFileWithDir(
                self.image,
                .prefix,
                installPath(b, options.directory, b.fmt("{s}.z64", .{install_name})),
            ).step);
        }
        if (options.add_to_default) b.getInstallStep().dependOn(step);
        self.install_step = step;
        return step;
    }
};

pub const InstallOptions = struct {
    outputs: OutputSelection = .{},
    name: ?[]const u8 = null,
    directory: []const u8 = "",
    step_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    add_to_default: bool = true,
};

pub const OutputSelection = struct {
    rom: bool = true,
    packed_elf: bool = false,
    debug_elf: bool = false,
    source_map: bool = false,
};

fn installPath(b: *std.Build, directory: []const u8, filename: []const u8) []const u8 {
    if (directory.len == 0) return filename;
    return std.fs.path.join(b.allocator, &.{ directory, filename }) catch @panic("OOM");
}

pub fn build(b: *std.Build, options: Options) Rom {
    const boot = @import("boot.zig").build(b, .{
        .name = options.name,
        .target = options.target,
        .n64_module = options.n64_module,
        .libptero_root = options.libptero_root,
        .header = .{
            .title = options.title,
            .game_code = options.metadata.game_code,
            .rom_version = options.metadata.rom_version,
        },
        .debug_logging = options.boot.ipl3_debug_logging,
        .required_rdram = @intFromEnum(options.layout.rdram),
        .ipl3_linker_script = options.boot.ipl3_linker_script,
        .loader_linker_script = options.boot.loader_linker_script,
        .ipl3_assembly_files = options.boot.ipl3_assembly_files,
    });

    const root_imports = b.allocator.alloc(std.Build.Module.Import, options.imports.len + 1) catch @panic("OOM");
    root_imports[0] = .{ .name = "n64", .module = options.n64_module };
    @memcpy(root_imports[1..], options.imports);

    const game_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .strip = false,
        .imports = root_imports,
    });
    const debug_elf = b.addExecutable(.{
        .name = b.fmt("{s}_debug.elf", .{options.name}),
        .root_module = game_module,
    });
    debug_elf.link_z_max_page_size = 8;
    debug_elf.setLinkerScript(options.linker_script);
    for (options.assembly_files) |assembly_file| {
        debug_elf.root_module.addAssemblyFile(assembly_file);
    }

    const srcmap_step = b.addRunArtifact(options.tools.srcmap);
    srcmap_step.addArtifactArg(debug_elf);
    const srcmap = srcmap_step.addOutputFileArg(b.fmt("{s}.srcmap", .{options.name}));
    srcmap_step.addArg(b.pathFromRoot("."));

    const pack_step = b.addRunArtifact(options.tools.elf_pack);
    pack_step.addArtifactArg(debug_elf);
    pack_step.addFileArg(srcmap);
    const elf = pack_step.addOutputFileArg(b.fmt("{s}.elf", .{options.name}));

    const make_rom_step = b.addRunArtifact(options.tools.ipl3_cat);
    make_rom_step.addFileArg(boot);
    make_rom_step.addFileArg(elf);
    const image = make_rom_step.addOutputFileArg(b.fmt("{s}.z64", .{options.name}));

    return .{
        .name = options.name,
        .debug_elf = debug_elf,
        .elf = elf,
        .srcmap = srcmap,
        .image = image,
    };
}
