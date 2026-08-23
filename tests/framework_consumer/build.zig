const std = @import("std");
const libptero = @import("libptero");

pub fn build(b: *std.Build) void {
    var sdk = libptero.init(b, .{});
    const no_install = b.option(bool, "no-install", "Do not install ROM outputs") orelse false;
    const override_handlers = b.option(bool, "override-handlers", "Use application-defined runtime handlers") orelse false;
    const custom_config = b.option(bool, "custom-config", "Use custom ROM layout and header metadata") orelse false;
    const rom = if (custom_config)
        sdk.addRom(.{
            .name = "consumer",
            .title = "Configured Consumer",
            .app_source_file = b.path("src/main.zig"),
            .optimize = .ReleaseFast,
            .layout = .{
                .rdram = .expansion_pak,
                .stack_size = 128 * 1024,
            },
            .boot = .{ .ipl3_debug_logging = true },
            .metadata = .{
                .game_code = "LPTE".*,
                .rom_version = 7,
            },
            .install = .{ .outputs = .{ .rom = true, .debug_elf = true } },
        })
    else if (no_install)
        sdk.addRom(.{
            .name = "consumer",
            .title = "Libptero Consumer",
            .app_source_file = b.path("src/main.zig"),
            .install = null,
        })
    else if (override_handlers)
        sdk.addRom(.{
            .name = "consumer",
            .title = "Libptero Consumer",
            .app_source_file = b.path("src/main.zig"),
            .overrides = .{
                .entry = "alternateMain",
                .panic = "panicHandler",
                .exception = "exceptionHandler",
                .interrupt = "interruptHandler",
            },
            .install = .{
                .outputs = .{ .rom = true, .packed_elf = true },
                .name = "override-build",
                .directory = "roms",
            },
        })
    else
        sdk.addRom(.{
            .name = "consumer",
            .title = "Libptero Consumer",
            .app_source_file = b.path("src/main.zig"),
        });
    _ = rom;
}
