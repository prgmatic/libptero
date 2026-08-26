const std = @import("std");

const rom_build = @import("rom.zig");
const tools_build = @import("tools.zig");
const assets_build = @import("assets.zig");

pub const Options = struct {
    root: std.Build.LazyPath,
    target: ?std.Build.ResolvedTarget = null,
    builtin_rsp_programs: bool = true,
    console_font: bool = true,
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
    layout: MemoryLayout = .{},
    boot: BootOptions = .{},
    metadata: MetadataOptions = .{},
    imports: []const std.Build.Module.Import = &.{},
    assets: ?*assets_build.AssetBundle = null,
    install: ?InstallOptions = .{},
};

pub const InstallOptions = rom_build.InstallOptions;
pub const OutputSelection = rom_build.OutputSelection;
pub const MemoryLayout = rom_build.MemoryLayout;
pub const Rdram = rom_build.Rdram;
pub const BootOptions = rom_build.BootOptions;
pub const MetadataOptions = rom_build.MetadataOptions;
pub const AssetBundle = assets_build.AssetBundle;
pub const TextureFormat = assets_build.TextureFormat;
pub const TextureOptions = assets_build.TextureOptions;

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
    console_font: bool,

    pub fn init(b: *std.Build, options: Options) Sdk {
        const target = options.target orelse b.resolveTargetQuery(target_query);
        const tools = tools_build.build(b, options.root);
        const n64_module = b.createModule(.{
            .root_source_file = options.root.path(b, "src/n64/n64.zig"),
        });
        var sdk: Sdk = .{
            .b = b,
            .root = options.root,
            .target = target,
            .n64_module = n64_module,
            .tools = tools,
            .console_font = options.console_font,
        };
        if (options.console_font) addConsoleFont(b, options.root, n64_module, tools);
        if (options.builtin_rsp_programs) sdk.addBuiltinRspPrograms();
        return sdk;
    }

    pub fn createAssets(self: *Sdk, name: []const u8) AssetBundle {
        return .{
            .b = self.b,
            .root = self.root,
            .tools = self.tools,
            .target = self.target,
            .name = name,
            .asset_module = .{
                .b = self.b,
                .target = self.target,
                .n64_module = self.n64_module,
                .name = name,
            },
        };
    }

    pub fn addRom(self: *Sdk, options: RomOptions) rom_build.Rom {
        const uses_default_entry = options.app_source_file != null;
        if (uses_default_entry == (options.root_source_file != null)) {
            std.debug.panic("ROM '{s}' must set exactly one of app_source_file or root_source_file", .{options.name});
        }
        const extra_import_count: usize = if (options.assets != null) 1 else 0;
        const option_imports = self.b.allocator.alloc(std.Build.Module.Import, options.imports.len + extra_import_count) catch @panic("OOM");
        @memcpy(option_imports[0..options.imports.len], options.imports);
        if (options.assets) |assets| {
            option_imports[options.imports.len] = .{ .name = assets.name, .module = assets.createModule() };
        }

        var root_source_file = options.root_source_file;
        var root_imports: []const std.Build.Module.Import = option_imports;
        if (options.app_source_file) |app_source_file| {
            if (!self.console_font and
                (options.overrides.panic.len == 0 or options.overrides.exception.len == 0))
            {
                std.debug.panic(
                    "ROM '{s}' uses default panic or exception handlers, which require SDK console_font support",
                    .{options.name},
                );
            }

            const app_imports = self.b.allocator.alloc(std.Build.Module.Import, option_imports.len + 1) catch @panic("OOM");
            app_imports[0] = .{ .name = "n64", .module = self.n64_module };
            @memcpy(app_imports[1..], option_imports);
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
        const linker_script = options.linker_script orelse makeLinkerScript(self.b, options.name, options.layout);
        var rom = rom_build.build(self.b, .{
            .name = options.name,
            .title = options.title,
            .root_source_file = root_source_file.?,
            .linker_script = linker_script,
            .assembly_files = options.assembly_files orelse default_assembly,
            .target = self.target,
            .n64_module = self.n64_module,
            .tools = self.tools,
            .libptero_root = self.root,
            .optimize = options.optimize,
            .layout = options.layout,
            .boot = options.boot,
            .metadata = options.metadata,
            .imports = root_imports,
        });
        if (options.install) |install| _ = rom.configureInstall(self.b, install);
        return rom;
    }

    fn addBuiltinRspPrograms(self: *Sdk) void {
        var assets = self.createAssets("libptero_rsp_assets");
        const resident = assets.addZspResident(
            "command_dispatcher",
            self.root.path(self.b, "src/n64/rsp/ucode/command_dispatcher.zsp"),
        );
        assets.addZspOverlay(
            "rdp_overlay",
            self.root.path(self.b, "src/n64/rsp/ucode/rdp_overlay.zsp"),
            resident,
        );
        assets.addZspOverlayWithStateStart(
            "geometry_overlay",
            self.root.path(self.b, "src/n64/rsp/ucode/geometry_overlay.zsp"),
            resident,
            0x0230,
        );
        assets.addZspOverlayWithStateStart(
            "geometry_clipping",
            self.root.path(self.b, "src/n64/rsp/ucode/geometry_clipping.zsp"),
            resident,
            0x0230,
        );
        self.n64_module.addImport("libptero_rsp_assets", assets.createModule());
    }
};

fn makeLinkerScript(b: *std.Build, name: []const u8, layout: MemoryLayout) std.Build.LazyPath {
    const rdram_size: u32 = @intFromEnum(layout.rdram);
    if (layout.stack_size < 1024) {
        std.debug.panic("ROM '{s}' must reserve at least 1 KiB for the stack", .{name});
    }
    if (layout.stack_size + rom_build.boot_reserve >= rdram_size - 0x400) {
        std.debug.panic("ROM '{s}' stack reservation leaves no space for program data", .{name});
    }
    const program_ram_length = rdram_size - rom_build.boot_reserve - layout.stack_size;
    const source = b.fmt(
        \\OUTPUT_ARCH (mips)
        \\
        \\MEMORY {{
        \\    ROM : ORIGIN = 0x0, LENGTH = 0x{x}
        \\    RAM : ORIGIN = 0x{x}, LENGTH = 0x{x}
        \\}}
        \\
        \\SECTIONS {{
        \\    .interrupt.text ORIGIN(RAM) : {{
        \\        KEEP(*(.interrupt.text))
        \\    }} > RAM AT > ROM
        \\
        \\    .text ORIGIN(RAM) + 0x400 : {{
        \\        __text_start = .;
        \\        *(.text.startup)
        \\        *(.text*)
        \\        __text_end = .;
        \\    }} > RAM AT > ROM
        \\
        \\    .data : ALIGN(8) {{
        \\        *(.data*)
        \\        *(.sdata*)
        \\        *(.rodata*)
        \\    }} > RAM AT > ROM
        \\
        \\    .bss : ALIGN(8) {{
        \\        __bss_start = .;
        \\        *(.bss*)
        \\        __bss_end = .;
        \\    }} > RAM
        \\
        \\    /DISCARD/ : {{
        \\    }}
        \\}}
    , .{ layout.rom_length, @as(u32, 0x80000000), program_ram_length });
    return b.addWriteFiles().add(b.fmt("{s}.ld", .{name}), source);
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

const target_query: std.Target.Query = .{
    .cpu_arch = .mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = .freestanding,
    .abi = .none,
};
