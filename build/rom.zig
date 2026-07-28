const std = @import("std");
const Tools = @import("tools.zig").Tools;

pub const Options = struct {
    name: []const u8,
    title: []const u8,
    root_source_file: []const u8,
    linker_script: []const u8,
    assembly_files: []const []const u8 = &.{},
    target: std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    tools: Tools,
    ipl3_debug: bool = false,
    imports: []const std.Build.Module.Import = &.{},
};

pub const Rom = struct {
    name: []const u8,
    debug_elf: *std.Build.Step.Compile,
    elf: std.Build.LazyPath,
    srcmap: std.Build.LazyPath,
    image: std.Build.LazyPath,

    pub fn addInstallStep(
        self: Rom,
        b: *std.Build,
        step_name: []const u8,
        description: []const u8,
    ) *std.Build.Step {
        const step = b.step(step_name, description);
        step.dependOn(&b.addInstallArtifact(self.debug_elf, .{
            .dest_dir = .{ .override = .prefix },
        }).step);
        step.dependOn(&b.addInstallFileWithDir(
            self.elf,
            .prefix,
            b.fmt("{s}.elf", .{self.name}),
        ).step);
        step.dependOn(&b.addInstallFileWithDir(
            self.srcmap,
            .prefix,
            b.fmt("{s}.srcmap", .{self.name}),
        ).step);
        step.dependOn(&b.addInstallFileWithDir(
            self.image,
            .prefix,
            b.fmt("{s}.z64", .{self.name}),
        ).step);
        return step;
    }
};

pub fn build(b: *std.Build, options: Options) Rom {
    const boot = @import("boot.zig").build(b, .{
        .name = options.name,
        .title = options.title,
        .target = options.target,
        .n64_module = options.n64_module,
        .debug_logging = options.ipl3_debug,
    });

    const root_imports = b.allocator.alloc(std.Build.Module.Import, options.imports.len + 1) catch @panic("OOM");
    root_imports[0] = .{ .name = "n64", .module = options.n64_module };
    @memcpy(root_imports[1..], options.imports);

    const game_module = b.createModule(.{
        .root_source_file = b.path(options.root_source_file),
        .target = options.target,
        .optimize = .ReleaseSmall,
        .strip = false,
        .imports = root_imports,
    });
    const debug_elf = b.addExecutable(.{
        .name = b.fmt("{s}_debug.elf", .{options.name}),
        .root_module = game_module,
    });
    debug_elf.link_z_max_page_size = 8;
    debug_elf.setLinkerScript(b.path(options.linker_script));
    for (options.assembly_files) |assembly_file| {
        debug_elf.root_module.addAssemblyFile(b.path(assembly_file));
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
