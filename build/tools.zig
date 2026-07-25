const std = @import("std");

const BuildOptions = struct {
    n64_module: *std.Build.Module,
};

const Tools = struct {
    srcmap: *std.Build.Step.Compile,
    elf_pack: *std.Build.Step.Compile,
    rsp_pack: *std.Build.Step.Compile,
    ipl3_cat: *std.Build.Step.Compile,
    console_font_conv: *std.Build.Step.Compile,
    zsp: *std.Build.Step.Compile,
};

pub fn build(b: *std.Build, n64_module: *std.Build.Module) Tools {
    
    const srcmap = b.addExecutable(.{
        .name = "srcmap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/n64srcmap/main.zig"),
            .target = b.graph.host,
            .imports = &.{ 
                .{.name = "n64", .module = n64_module },
            },
        }),
    });
    
    const ipl3_cat = b.addExecutable(.{
        .name = "ipl3_cat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/ipl3_cat.zig"),
            .target = b.graph.host
        }),
    });

    const elf_pack = b.addExecutable(.{
        .name = "elf_pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/elf_pack.zig"),
            .target = b.graph.host
        }),
    });

    const rsp_pack = b.addExecutable(.{
        .name = "rsp_pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/rsp_pack.zig"),
            .target = b.graph.host
        }),
    });

    const console_font_conv = b.addExecutable(.{
        .name = "console_font_conv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/console_font_conv.zig"),
            .target = b.graph.host
        }),
    });

    const zsp = b.addExecutable(.{
        .name = "zsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zsp/zsp.zig"),
            .target = b.graph.host,
        }),
    });

    return .{
        .srcmap = srcmap,
        .elf_pack = elf_pack,
        .rsp_pack = rsp_pack,
        .ipl3_cat = ipl3_cat,
        .console_font_conv = console_font_conv,
        .zsp = zsp,
    };
}
