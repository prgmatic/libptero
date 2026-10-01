const std = @import("std");
const Tools = @import("tools.zig").Tools;

const Entry = struct {
    name: []const u8,
    path: std.Build.LazyPath,
    alignment: u29,
};
const SourceEntry = struct { name: []const u8, path: std.Build.LazyPath };

const TextureEntry = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    texels: std.Build.LazyPath,
};

const FontEntry = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    texels: std.Build.LazyPath,
};

const ModelEntry = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    data: std.Build.LazyPath,
};

pub const TextureFormat = enum {
    rgba16,
    rgba32,
    yuv16,
    ia4,
    ia8,
    ia16,
    i4,
    i8,
};

pub const TextureOptions = struct {
    format: TextureFormat = .rgba16,
};

pub const FontOptions = struct {
    kerning: bool = true,
    ellipsis_codepoint: u32 = '.',
    ellipsis_repetitions: u16 = 3,
};

pub const ModelOptions = struct {
    scale: f32 = 64,
    max_vertices_per_batch: usize = 70,
    preserve_triangle_order: bool = false,
};

pub const Resident = struct {
    elf: *std.Build.Step.Compile,
    interface: std.Build.LazyPath,
};

pub const AssetBundle = struct {
    b: *std.Build,
    root: std.Build.LazyPath,
    tools: Tools,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    asset_module: AssetModule,
    include_zsp_symbols: bool = true,

    pub fn omitZspSymbols(self: *AssetBundle) void {
        self.include_zsp_symbols = false;
    }

    pub fn embedFile(self: *AssetBundle, name: []const u8, path: std.Build.LazyPath) void {
        self.asset_module.embedFile(name, path);
    }

    pub fn embedGeneratedFile(self: *AssetBundle, name: []const u8, path: std.Build.LazyPath) void {
        self.asset_module.embedFile(name, path);
    }

    /// Convert a PNG into RDP-ready texels and expose it as a typed Image in this asset module.
    pub fn addTexture(
        self: *AssetBundle,
        name: []const u8,
        source: std.Build.LazyPath,
        options: TextureOptions,
    ) void {
        self.asset_module.validateName(name);
        const convert = self.b.addRunArtifact(self.tools.texture_compiler);
        convert.addFileArg(source);
        const texels = convert.addOutputFileArg(self.b.fmt("{s}.texels", .{name}));
        const generated_source = convert.addOutputFileArg(self.b.fmt("{s}.zig", .{name}));
        convert.addArg(name);
        convert.addArg(@tagName(options.format));
        self.asset_module.addTextureEntry(name, generated_source, texels);
    }

    /// Convert a text BMFont and its PNG pages into a typed native Font asset.
    pub fn addFont(
        self: *AssetBundle,
        name: []const u8,
        source: std.Build.LazyPath,
        options: FontOptions,
    ) void {
        self.asset_module.validateName(name);
        const compile = self.b.addRunArtifact(self.tools.font_compiler);
        compile.addFileArg(source);
        const texels = compile.addOutputFileArg(self.b.fmt("{s}.font.texels", .{name}));
        const generated_source = compile.addOutputFileArg(self.b.fmt("{s}.font.zig", .{name}));
        compile.addArg(name);
        if (!options.kerning) compile.addArg("--no-kerning");
        if (options.ellipsis_repetitions != 3 or options.ellipsis_codepoint != '.') {
            compile.addArg("--ellipsis");
            compile.addArg(self.b.fmt("{X},{d}", .{ options.ellipsis_codepoint, options.ellipsis_repetitions }));
        }
        self.asset_module.addFontEntry(name, generated_source, texels);
    }

    /// Convert a binary glTF into packed RSP vertex batches and expose a typed native Model.
    pub fn addModel(self: *AssetBundle, name: []const u8, source: std.Build.LazyPath, options: ModelOptions) void {
        self.asset_module.validateName(name);
        const convert = self.b.addRunArtifact(self.tools.gltf_compiler);
        convert.addFileArg(source);
        const data = convert.addOutputFileArg(self.b.fmt("{s}.model.bin", .{name}));
        const generated_source = convert.addOutputFileArg(self.b.fmt("{s}.model.zig", .{name}));
        convert.addArg(name);
        convert.addArg(self.b.fmt("{d}", .{options.scale}));
        convert.addArg(self.b.fmt("{d}", .{options.max_vertices_per_batch}));
        convert.addArg(if (options.preserve_triangle_order) "true" else "false");
        self.asset_module.addModelEntry(name, generated_source, data);
    }

    pub fn buildZspProgram(self: *AssetBundle, name: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
        return buildZsp(self, name, source, self.root.path(self.b, "src/n64/rsp/link.ld"), null).rsp;
    }

    pub fn addZspProgram(self: *AssetBundle, name: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
        const built = buildZsp(self, name, source, self.root.path(self.b, "src/n64/rsp/link.ld"), null);
        self.asset_module.addGeneratedFile(name, built.rsp, 8);
        if (self.include_zsp_symbols) self.asset_module.addSource(self.b.fmt("{s}_symbols", .{name}), built.symbols);
        return built.rsp;
    }

    pub fn addZspResident(self: *AssetBundle, name: []const u8, source: std.Build.LazyPath) Resident {
        const built = buildZsp(self, name, source, self.root.path(self.b, "src/n64/rsp/resident.ld"), null);
        self.asset_module.addGeneratedFile(name, built.rsp, 8);
        if (self.include_zsp_symbols) self.asset_module.addSource(self.b.fmt("{s}_symbols", .{name}), built.symbols);
        return .{ .elf = built.elf, .interface = built.interface };
    }

    pub fn addZspOverlay(
        self: *AssetBundle,
        name: []const u8,
        source: std.Build.LazyPath,
        resident: Resident,
    ) void {
        self.addZspOverlayWithStateStart(name, source, resident, 0x0a00);
    }

    pub fn addZspOverlayWithStateStart(
        self: *AssetBundle,
        name: []const u8,
        source: std.Build.LazyPath,
        resident: Resident,
        state_start: u16,
    ) void {
        const overlay_link = self.b.addRunArtifact(self.tools.rsp_overlay_link);
        overlay_link.addArtifactArg(resident.elf);
        overlay_link.addFileArg(resident.interface);
        overlay_link.addArg(self.b.fmt("0x{x}", .{state_start}));
        const linker_script = overlay_link.addOutputFileArg(self.b.fmt("{s}.ld", .{name}));
        const built = buildZsp(self, name, source, linker_script, resident.interface);
        self.asset_module.addGeneratedFile(name, built.rsp, 8);
        if (self.include_zsp_symbols) self.asset_module.addSource(self.b.fmt("{s}_symbols", .{name}), built.symbols);
    }

    pub fn createModule(self: *AssetBundle) *std.Build.Module {
        return self.asset_module.createModule();
    }
};

pub const AssetModule = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    n64_module: *std.Build.Module,
    name: []const u8,
    entries: std.ArrayList(Entry) = .empty,
    sources: std.ArrayList(SourceEntry) = .empty,
    textures: std.ArrayList(TextureEntry) = .empty,
    fonts: std.ArrayList(FontEntry) = .empty,
    models: std.ArrayList(ModelEntry) = .empty,
    finalized: bool = false,
    module: ?*std.Build.Module = null,

    pub fn embedFile(self: *AssetModule, name: []const u8, path: std.Build.LazyPath) void {
        self.addEntry(name, path, 1);
    }

    pub fn addGeneratedFile(self: *AssetModule, name: []const u8, path: std.Build.LazyPath, alignment: u29) void {
        self.addEntry(name, path, alignment);
    }

    pub fn createModule(self: *AssetModule) *std.Build.Module {
        if (self.module) |module| return module;
        self.finalized = true;

        var source: std.ArrayList(u8) = .empty;
        for (self.entries.items) |entry| {
            const declaration = self.b.fmt(
                "pub const {s} align({d}) = @embedFile(\"asset_{s}\").*;\n",
                .{ entry.name, entry.alignment, entry.name },
            );
            source.appendSlice(self.b.allocator, declaration) catch @panic("OOM");
        }
        for (self.sources.items) |entry| source.appendSlice(self.b.allocator, self.b.fmt(
            "pub const {s} = @import(\"source_{s}\");\n",
            .{ entry.name, entry.name },
        )) catch @panic("OOM");
        for (self.textures.items) |entry| {
            source.appendSlice(self.b.allocator, self.b.fmt(
                "pub const {s} = @import(\"texture_{s}\").{s};\n",
                .{ entry.name, entry.name, entry.name },
            )) catch @panic("OOM");
        }
        for (self.fonts.items) |entry| {
            source.appendSlice(self.b.allocator, self.b.fmt(
                "pub const {s} = @import(\"font_{s}\").{s};\n",
                .{ entry.name, entry.name, entry.name },
            )) catch @panic("OOM");
        }
        for (self.models.items) |entry| {
            source.appendSlice(self.b.allocator, self.b.fmt(
                "pub const {s} = @import(\"model_{s}\").{s};\n",
                .{ entry.name, entry.name, entry.name },
            )) catch @panic("OOM");
        }
        const root_source = self.b.addWriteFiles().add(self.b.fmt("{s}.zig", .{self.name}), source.items);
        const module = self.b.createModule(.{ .root_source_file = root_source, .target = self.target });
        for (self.entries.items) |entry| {
            module.addAnonymousImport(self.b.fmt("asset_{s}", .{entry.name}), .{ .root_source_file = entry.path });
        }
        for (self.sources.items) |entry| module.addImport(self.b.fmt("source_{s}", .{entry.name}), self.b.createModule(.{
            .root_source_file = entry.path,
            .target = self.target,
        }));
        for (self.textures.items) |entry| {
            const texture_module = self.b.createModule(.{
                .root_source_file = entry.source,
                .target = self.target,
                .imports = &.{.{ .name = "n64", .module = self.n64_module }},
            });
            texture_module.addAnonymousImport("texture_data", .{ .root_source_file = entry.texels });
            module.addImport(self.b.fmt("texture_{s}", .{entry.name}), texture_module);
        }
        for (self.fonts.items) |entry| {
            const font_module = self.b.createModule(.{
                .root_source_file = entry.source,
                .target = self.target,
                .imports = &.{.{ .name = "n64", .module = self.n64_module }},
            });
            font_module.addAnonymousImport("font_texels", .{ .root_source_file = entry.texels });
            module.addImport(self.b.fmt("font_{s}", .{entry.name}), font_module);
        }
        for (self.models.items) |entry| {
            const model_module = self.b.createModule(.{
                .root_source_file = entry.source,
                .target = self.target,
                .imports = &.{.{ .name = "n64", .module = self.n64_module }},
            });
            model_module.addAnonymousImport("model_data", .{ .root_source_file = entry.data });
            module.addImport(self.b.fmt("model_{s}", .{entry.name}), model_module);
        }
        self.module = module;
        return module;
    }

    fn addEntry(self: *AssetModule, name: []const u8, path: std.Build.LazyPath, alignment: u29) void {
        self.validateName(name);
        self.entries.append(self.b.allocator, .{ .name = self.b.dupe(name), .path = path, .alignment = alignment }) catch @panic("OOM");
    }

    fn addSource(self: *AssetModule, name: []const u8, path: std.Build.LazyPath) void {
        self.validateName(name);
        self.sources.append(self.b.allocator, .{ .name = self.b.dupe(name), .path = path }) catch @panic("OOM");
    }

    fn addTextureEntry(self: *AssetModule, name: []const u8, source: std.Build.LazyPath, texels: std.Build.LazyPath) void {
        self.textures.append(self.b.allocator, .{
            .name = self.b.dupe(name),
            .source = source,
            .texels = texels,
        }) catch @panic("OOM");
    }

    fn addFontEntry(self: *AssetModule, name: []const u8, source: std.Build.LazyPath, texels: std.Build.LazyPath) void {
        self.fonts.append(self.b.allocator, .{ .name = self.b.dupe(name), .source = source, .texels = texels }) catch @panic("OOM");
    }

    fn addModelEntry(self: *AssetModule, name: []const u8, source: std.Build.LazyPath, data: std.Build.LazyPath) void {
        self.models.append(self.b.allocator, .{ .name = self.b.dupe(name), .source = source, .data = data }) catch @panic("OOM");
    }

    fn validateName(self: *AssetModule, name: []const u8) void {
        if (self.finalized) std.debug.panic("cannot add '{s}' after asset bundle '{s}' was finalized", .{ name, self.name });
        if (!std.zig.isValidId(name)) std.debug.panic("asset name '{s}' is not a valid Zig identifier", .{name});
        for (self.entries.items) |entry|
            if (std.mem.eql(u8, entry.name, name)) std.debug.panic("duplicate asset name '{s}'", .{name});
        for (self.sources.items) |entry|
            if (std.mem.eql(u8, entry.name, name)) std.debug.panic("duplicate asset name '{s}'", .{name});
        for (self.textures.items) |entry|
            if (std.mem.eql(u8, entry.name, name)) std.debug.panic("duplicate asset name '{s}'", .{name});
        for (self.fonts.items) |entry|
            if (std.mem.eql(u8, entry.name, name)) std.debug.panic("duplicate asset name '{s}'", .{name});
        for (self.models.items) |entry|
            if (std.mem.eql(u8, entry.name, name)) std.debug.panic("duplicate asset name '{s}'", .{name});
    }
};

const ZspBuild = struct {
    rsp: std.Build.LazyPath,
    elf: *std.Build.Step.Compile,
    interface: std.Build.LazyPath,
    symbols: std.Build.LazyPath,
};

fn buildZsp(
    assets: *AssetBundle,
    name: []const u8,
    source: std.Build.LazyPath,
    linker_script: std.Build.LazyPath,
    resident_interface: ?std.Build.LazyPath,
) ZspBuild {
    const b = assets.b;
    const zsp = b.addRunArtifact(assets.tools.zsp);
    zsp.addFileArg(source);
    zsp.addArg("--module-dir");
    zsp.addDirectoryArg(assets.root.path(b, "src/n64/rsp/ucode"));
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
        .root_module = b.createModule(.{ .target = b.resolveTargetQuery(rsp_target), .optimize = .ReleaseSmall, .strip = false }),
    });
    elf.root_module.addAssemblyFile(asm_file);
    elf.setLinkerScript(linker_script);
    elf.entry = .{ .symbol_name = "_start" };
    elf.bundle_compiler_rt = false;
    elf.bundle_ubsan_rt = false;

    const pack = b.addRunArtifact(assets.tools.rsp_pack);
    pack.addArtifactArg(elf);
    pack.addArg("--symbols");
    const symbols = pack.addOutputFileArg(b.fmt("{s}_symbols.zig", .{name}));
    return .{
        .rsp = pack.addOutputFileArg(b.fmt("{s}.rsp", .{name})),
        .elf = elf,
        .interface = interface,
        .symbols = symbols,
    };
}

const rsp_target: std.Target.Query = .{
    .cpu_arch = .mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = .freestanding,
    .abi = .none,
};
