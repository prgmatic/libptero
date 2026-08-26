const std = @import("std");

pub const Tools = struct {
    srcmap: *std.Build.Step.Compile,
    elf_pack: *std.Build.Step.Compile,
    rsp_pack: *std.Build.Step.Compile,
    rsp_overlay_link: *std.Build.Step.Compile,
    ipl3_cat: *std.Build.Step.Compile,
    console_font_conv: *std.Build.Step.Compile,
    zsp: *std.Build.Step.Compile,
    texture_compiler: *std.Build.Step.Compile,
    font_compiler: *std.Build.Step.Compile,
};

pub fn build(b: *std.Build, root: std.Build.LazyPath) Tools {
    const srcmap_format = b.createModule(.{
        .root_source_file = root.path(b, "src/n64/debug/srcmap_format.zig"),
        .target = b.graph.host,
    });
    const png = b.createModule(.{
        .root_source_file = root.path(b, "tools/imgparse/png.zig"),
        .target = b.graph.host,
    });
    const texture_compiler = b.createModule(.{
        .root_source_file = root.path(b, "tools/texture_compiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "png", .module = png }},
    });
    const font_compiler = b.createModule(.{
        .root_source_file = root.path(b, "tools/font_compiler/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "texture_compiler", .module = texture_compiler }},
    });
    return .{
        .srcmap = addTool(b, root, "srcmap", "tools/n64srcmap/main.zig", &.{
            .{ .name = "srcmap_format", .module = srcmap_format },
        }),
        .elf_pack = addTool(b, root, "elf_pack", "tools/build/elf_pack.zig", &.{}),
        .rsp_pack = addTool(b, root, "rsp_pack", "tools/build/rsp_pack.zig", &.{}),
        .rsp_overlay_link = addTool(b, root, "rsp_overlay_link", "tools/build/rsp_overlay_link.zig", &.{}),
        .ipl3_cat = addTool(b, root, "ipl3_cat", "tools/build/ipl3_cat.zig", &.{}),
        .console_font_conv = addTool(b, root, "console_font_conv", "tools/console_font_conv.zig", &.{}),
        .zsp = addTool(b, root, "zsp", "tools/zsp/zsp.zig", &.{}),
        .texture_compiler = addTool(b, root, "texture-compiler", "tools/texture_compiler/main.zig", &.{
            .{ .name = "texture_compiler", .module = texture_compiler },
        }),
        .font_compiler = addTool(b, root, "font-compiler", "tools/font_compiler/main.zig", &.{
            .{ .name = "font_compiler", .module = font_compiler },
            .{ .name = "png", .module = png },
        }),
    };
}

fn addTool(
    b: *std.Build,
    root: std.Build.LazyPath,
    name: []const u8,
    source: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root.path(b, source),
            .target = b.graph.host,
            .imports = imports,
        }),
    });
}
