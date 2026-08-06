const std = @import("std");

pub const Tools = struct {
    srcmap: *std.Build.Step.Compile,
    elf_pack: *std.Build.Step.Compile,
    rsp_pack: *std.Build.Step.Compile,
    rsp_overlay_link: *std.Build.Step.Compile,
    ipl3_cat: *std.Build.Step.Compile,
    console_font_conv: *std.Build.Step.Compile,
    zsp: *std.Build.Step.Compile,
};

pub fn build(b: *std.Build, n64_module: *std.Build.Module) Tools {
    return .{
        .srcmap = addTool(b, "srcmap", "tools/n64srcmap/main.zig", &.{
            .{ .name = "n64", .module = n64_module },
        }),
        .elf_pack = addTool(b, "elf_pack", "tools/build/elf_pack.zig", &.{}),
        .rsp_pack = addTool(b, "rsp_pack", "tools/build/rsp_pack.zig", &.{}),
        .rsp_overlay_link = addTool(b, "rsp_overlay_link", "tools/build/rsp_overlay_link.zig", &.{}),
        .ipl3_cat = addTool(b, "ipl3_cat", "tools/build/ipl3_cat.zig", &.{}),
        .console_font_conv = addTool(b, "console_font_conv", "tools/console_font_conv.zig", &.{}),
        .zsp = addTool(b, "zsp", "tools/zsp/zsp.zig", &.{}),
    };
}

fn addTool(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .imports = imports,
        }),
    });
}
