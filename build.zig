const std = @import("std");

const title: []const u8 = "Libptero";

const target_query = std.Target.Query {
    .cpu_arch = std.Target.Cpu.Arch.mips,
    .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips3 },
    .os_tag = std.Target.Os.Tag.freestanding,
    .abi = std.Target.Abi.none
};

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(target_query);
    
    const n64_module = b.createModule(.{
        .root_source_file = b.path("src/n64/root.zig"),
    });

    @import("build/boot.zig").build(b, target, n64_module, title);
}
