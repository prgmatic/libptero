const std = @import("std");
const Tools = @import("tools.zig").Tools;

const Entry = struct {
    name: []const u8,
    path: std.Build.LazyPath,
    alignment: u29,
};

const TextureEntry = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    texels: std.Build.LazyPath,
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

    pub fn buildZspProgram(self: *AssetBundle, name: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
        return buildZsp(self, name, source, self.root.path(self.b, "src/n64/rsp/link.ld"), null).rsp;
    }

    pub fn addZspProgram(self: *AssetBundle, name: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
        const rsp = self.buildZspProgram(name, source);
        self.asset_module.addGeneratedFile(name, rsp, 8);
        return rsp;
    }

    pub fn addZspResident(self: *AssetBundle, name: []const u8, source: std.Build.LazyPath) Resident {
        const built = buildZsp(self, name, source, self.root.path(self.b, "src/n64/rsp/resident.ld"), null);
        self.asset_module.addGeneratedFile(name, built.rsp, 8);
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
        self.asset_module.addGeneratedFile(name, buildZsp(self, name, source, linker_script, resident.interface).rsp, 8);
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
    textures: std.ArrayList(TextureEntry) = .empty,
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
        for (self.textures.items) |entry| {
            source.appendSlice(self.b.allocator, self.b.fmt(
                "pub const {s} = @import(\"texture_{s}\").{s};\n",
                .{ entry.name, entry.name, entry.name },
            )) catch @panic("OOM");
        }
        const root_source = self.b.addWriteFiles().add(self.b.fmt("{s}.zig", .{self.name}), source.items);
        const module = self.b.createModule(.{ .root_source_file = root_source, .target = self.target });
        for (self.entries.items) |entry| {
            module.addAnonymousImport(self.b.fmt("asset_{s}", .{entry.name}), .{ .root_source_file = entry.path });
        }
        for (self.textures.items) |entry| {
            const texture_module = self.b.createModule(.{
                .root_source_file = entry.source,
                .target = self.target,
                .imports = &.{.{ .name = "n64", .module = self.n64_module }},
            });
            texture_module.addAnonymousImport("texture_data", .{ .root_source_file = entry.texels });
            module.addImport(self.b.fmt("texture_{s}", .{entry.name}), texture_module);
        }
        self.module = module;
        return module;
    }

    fn addEntry(self: *AssetModule, name: []const u8, path: std.Build.LazyPath, alignment: u29) void {
        self.validateName(name);
        self.entries.append(self.b.allocator, .{ .name = self.b.dupe(name), .path = path, .alignment = alignment }) catch @panic("OOM");
    }

    fn addTextureEntry(self: *AssetModule, name: []const u8, source: std.Build.LazyPath, texels: std.Build.LazyPath) void {
        self.textures.append(self.b.allocator, .{
            .name = self.b.dupe(name),
            .source = source,
            .texels = texels,
        }) catch @panic("OOM");
    }

    fn validateName(self: *AssetModule, name: []const u8) void {
        if (self.finalized) std.debug.panic("cannot add '{s}' after asset bundle '{s}' was finalized", .{ name, self.name });
        if (!std.zig.isValidId(name)) std.debug.panic("asset name '{s}' is not a valid Zig identifier", .{name});
        for (self.entries.items) |entry|
            if (std.mem.eql(u8, entry.name, name)) std.debug.panic("duplicate asset name '{s}'", .{name});
        for (self.textures.items) |entry|
            if (std.mem.eql(u8, entry.name, name)) std.debug.panic("duplicate asset name '{s}'", .{name});
    }
};

const ZspBuild = struct {
    rsp: std.Build.LazyPath,
    elf: *std.Build.Step.Compile,
    interface: std.Build.LazyPath,
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
    return .{
        .rsp = pack.addOutputFileArg(b.fmt("{s}.rsp", .{name})),
        .elf = elf,
        .interface = interface,
    };
}

const rsp_target: std.Target.Query = .{
    .cpu_arch = .mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = .freestanding,
    .abi = .none,
};
