const std = @import("std");
const libptero = @import("libptero");

pub fn build(b: *std.Build) void {
    const sdk = libptero.init(b, .{});
    const rom = sdk.addRom(.{
        .name = "consumer",
        .title = "Libptero Consumer",
        .root_source_file = b.path("src/entry.zig"),
    });
    b.getInstallStep().dependOn(rom.addInstallStep(b, "rom", "Build the consumer ROM"));
}
