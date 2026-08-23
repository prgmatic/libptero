const std = @import("std");

const rom_build = @import("rom.zig");
const tools_build = @import("tools.zig");

pub const Options = struct {
    root: std.Build.LazyPath,
    target: ?std.Build.ResolvedTarget = null,
    generated: GeneratedFeatures = .{},
};

pub const GeneratedFeatures = struct {
    console_font: bool = false,
    rsp_programs: bool = false,
};

pub const RomOptions = struct {
    name: []const u8,
    title: []const u8,
    app_source_file: ?std.Build.LazyPath = null,
    root_source_file: ?std.Build.LazyPath = null,
    overrides: HandlerOverrides = .{},
    linker_script: ?std.Build.LazyPath = null,
    assembly_files: ?[]const std.Build.LazyPath = null,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    ipl3_debug: bool = false,
    imports: []const std.Build.Module.Import = &.{},
    install: ?InstallOptions = .{},
};

pub const InstallOptions = rom_build.InstallOptions;
pub const OutputSelection = rom_build.OutputSelection;

pub const HandlerOverrides = struct {
    entry: []const u8 = "main",
    panic: []const u8 = "",
    exception: []const u8 = "",
    interrupt: []const u8 = "",
};

pub const Sdk = struct {
    b: *std.Build,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    tools: tools_build.Tools,
    console_font_added: bool,

    pub fn init(b: *std.Build, options: Options) Sdk {
        const target = options.target orelse b.resolveTargetQuery(target_query);
        const n64_module = b.createModule(.{
            .root_source_file = options.root.path(b, "src/n64/n64.zig"),
        });
        const tools = tools_build.build(b, options.root);
        addGeneratedN64Assets(b, options.root, n64_module, tools, options.generated);

        return .{
            .b = b,
            .root = options.root,
            .target = target,
            .n64_module = n64_module,
            .tools = tools,
            .console_font_added = options.generated.console_font,
        };
    }

    pub fn addRom(self: *Sdk, options: RomOptions) rom_build.Rom {
        const uses_default_entry = options.app_source_file != null;
        if (uses_default_entry == (options.root_source_file != null)) {
            std.debug.panic("ROM '{s}' must set exactly one of app_source_file or root_source_file", .{options.name});
        }

        var root_source_file = options.root_source_file;
        var root_imports = options.imports;
        if (options.app_source_file) |app_source_file| {
            if (!self.console_font_added and
                (options.overrides.panic.len == 0 or options.overrides.exception.len == 0))
            {
                addConsoleFont(self.b, self.root, self.n64_module, self.tools);
                self.console_font_added = true;
            }

            const app_imports = self.b.allocator.alloc(std.Build.Module.Import, options.imports.len + 1) catch @panic("OOM");
            app_imports[0] = .{ .name = "n64", .module = self.n64_module };
            @memcpy(app_imports[1..], options.imports);
            const app_module = self.b.createModule(.{
                .root_source_file = app_source_file,
                .target = self.target,
                .optimize = options.optimize,
                .strip = false,
                .imports = app_imports,
            });

            const config = self.b.addOptions();
            config.addOption([]const u8, "entry", options.overrides.entry);
            config.addOption([]const u8, "panic_handler", options.overrides.panic);
            config.addOption([]const u8, "exception_handler", options.overrides.exception);
            config.addOption([]const u8, "interrupt_handler", options.overrides.interrupt);
            root_source_file = self.root.path(self.b, "src/runtime/entry.zig");
            root_imports = self.b.allocator.dupe(std.Build.Module.Import, &.{
                .{ .name = "app", .module = app_module },
                .{ .name = "runtime_config", .module = config.createModule() },
            }) catch @panic("OOM");
        }

        const default_assembly = self.b.allocator.dupe(std.Build.LazyPath, &.{
            self.root.path(self.b, "src/game/interrupt.S"),
        }) catch @panic("OOM");
        var rom = rom_build.build(self.b, .{
            .name = options.name,
            .title = options.title,
            .root_source_file = root_source_file.?,
            .linker_script = options.linker_script orelse self.root.path(self.b, "src/game/link.ld"),
            .assembly_files = options.assembly_files orelse default_assembly,
            .target = self.target,
            .n64_module = self.n64_module,
            .tools = self.tools,
            .libptero_root = self.root,
            .optimize = options.optimize,
            .ipl3_debug = options.ipl3_debug,
            .imports = root_imports,
        });
        if (options.install) |install| _ = rom.configureInstall(self.b, install);
        return rom;
    }

    pub fn addRspUcode(self: *const Sdk, name: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
        return buildRspUcodeFromPath(
            self.b,
            self.root,
            self.tools,
            name,
            source,
            self.root.path(self.b, "src/n64/rsp/link.ld"),
            null,
        );
    }
};

fn addGeneratedN64Assets(
    b: *std.Build,
    root: std.Build.LazyPath,
    n64_module: *std.Build.Module,
    tools: tools_build.Tools,
    features: GeneratedFeatures,
) void {
    if (features.console_font) {
        addConsoleFont(b, root, n64_module, tools);
    }

    if (!features.rsp_programs) return;

    n64_module.addAnonymousImport("fill_dmem_rsp", .{
        .root_source_file = buildRspUcode(b, root, tools, "fill_dmem", "src/n64/rsp/ucode/fill_dmem.zsp"),
    });
    const resident = buildRspUcodeWithLinkerScript(
        b,
        root,
        tools,
        "command_dispatcher",
        "src/n64/rsp/ucode/command_dispatcher.zsp",
        "src/n64/rsp/resident.ld",
    );
    n64_module.addAnonymousImport("command_dispatcher_rsp", .{ .root_source_file = resident.rsp });

    const overlay_link = b.addRunArtifact(tools.rsp_overlay_link);
    overlay_link.addArtifactArg(resident.elf);
    overlay_link.addFileArg(resident.interface);
    const overlay_linker_script = overlay_link.addOutputFileArg("overlay.ld");
    inline for (.{ "static_overlay", "static_overlay_2", "multi_slot_overlay", "rdp_overlay" }) |name| {
        n64_module.addAnonymousImport(name ++ "_rsp", .{
            .root_source_file = buildRspUcodeFromPath(
                b,
                root,
                tools,
                name,
                root.path(b, "src/n64/rsp/ucode/" ++ name ++ ".zsp"),
                overlay_linker_script,
                resident.interface,
            ),
        });
    }
}

fn addConsoleFont(
    b: *std.Build,
    root: std.Build.LazyPath,
    n64_module: *std.Build.Module,
    tools: tools_build.Tools,
) void {
    const font_step = b.addRunArtifact(tools.console_font_conv);
    font_step.addFileArg(root.path(b, "assets/console_font.png"));
    n64_module.addAnonymousImport("console_font", .{
        .root_source_file = font_step.addOutputFileArg("console.font"),
    });
}

fn buildRspUcode(
    b: *std.Build,
    root: std.Build.LazyPath,
    tools: tools_build.Tools,
    name: []const u8,
    source: []const u8,
) std.Build.LazyPath {
    return buildRspUcodeFromPath(
        b,
        root,
        tools,
        name,
        root.path(b, source),
        root.path(b, "src/n64/rsp/link.ld"),
        null,
    );
}

const RspUcodeBuild = struct {
    rsp: std.Build.LazyPath,
    elf: *std.Build.Step.Compile,
    interface: std.Build.LazyPath,
};

fn buildRspUcodeWithLinkerScript(
    b: *std.Build,
    root: std.Build.LazyPath,
    tools: tools_build.Tools,
    name: []const u8,
    source: []const u8,
    linker_script: []const u8,
) RspUcodeBuild {
    return buildRspUcodeArtifactFromPath(
        b,
        root,
        tools,
        name,
        root.path(b, source),
        root.path(b, linker_script),
        null,
    );
}

fn buildRspUcodeFromPath(
    b: *std.Build,
    root: std.Build.LazyPath,
    tools: tools_build.Tools,
    name: []const u8,
    source: std.Build.LazyPath,
    linker_script: std.Build.LazyPath,
    resident_interface: ?std.Build.LazyPath,
) std.Build.LazyPath {
    return buildRspUcodeArtifactFromPath(
        b,
        root,
        tools,
        name,
        source,
        linker_script,
        resident_interface,
    ).rsp;
}

fn buildRspUcodeArtifactFromPath(
    b: *std.Build,
    root: std.Build.LazyPath,
    tools: tools_build.Tools,
    name: []const u8,
    source: std.Build.LazyPath,
    linker_script: std.Build.LazyPath,
    resident_interface: ?std.Build.LazyPath,
) RspUcodeBuild {
    const zsp = b.addRunArtifact(tools.zsp);
    zsp.addFileArg(source);
    zsp.addArg("--module-dir");
    zsp.addDirectoryArg(root.path(b, "src/n64/rsp/ucode"));
    zsp.addArg("--depfile");
    _ = zsp.addDepFileOutputArg(b.fmt("{s}.d", .{name}));
    if (resident_interface) |interface| {
        zsp.addArg("--module-file");
        zsp.addArg("resident_api.zsp");
        zsp.addFileArg(interface);
    }
    zsp.addArg("--interface");
    const interface = zsp.addOutputFileArg(b.fmt("{s}.zspi", .{name}));
    const asm_file = zsp.addOutputFileArg(b.fmt("{s}.S", .{name}));

    const elf = b.addExecutable(.{
        .name = b.fmt("{s}_rsp.elf", .{name}),
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(target_query),
            .optimize = .ReleaseSmall,
            .strip = false,
        }),
    });
    elf.root_module.addAssemblyFile(asm_file);
    elf.setLinkerScript(linker_script);
    elf.entry = .{ .symbol_name = "_start" };
    elf.bundle_compiler_rt = false;
    elf.bundle_ubsan_rt = false;

    const pack = b.addRunArtifact(tools.rsp_pack);
    pack.addArtifactArg(elf);
    return .{
        .rsp = pack.addOutputFileArg(b.fmt("{s}.rsp", .{name})),
        .elf = elf,
        .interface = interface,
    };
}

const target_query: std.Target.Query = .{
    .cpu_arch = .mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = .freestanding,
    .abi = .none,
};
