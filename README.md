# Libptero
Libptero is a Nintendo 64 SDK written in Zig, with native generated assets, explicit memory ownership, and RSP/RDP rendering. It builds on ideas and code from libdragon and Tiny3D.

Start with [Game loops and render passes](src/n64/app/README.md) for borrowed
geometry, explicit geometry/overlay state, sprites, and text, or
[Runtime APIs](src/n64/README.md) for independently managed subsystems. The examples
repository's `collect` game demonstrates movement, pause/restart, audio and HUD.

## Building a game

Use Zig 0.16. Add a pinned libptero dependency to `build.zig.zon`, then use the
public SDK from `build.zig`:

```zig
const std = @import("std");
const libptero = @import("libptero");

pub fn build(b: *std.Build) void {
    var sdk = libptero.init(b, .{ .optimize = libptero.standardOptimizeOption(b) });
    var assets = sdk.createAssets("assets");
    assets.addTexture("player", b.path("assets/player.png"), .{ .format = .rgba16 });
    _ = sdk.addRom(.{
        .name = "game",
        .title = "My Game",
        .app_source_file = b.path("src/main.zig"),
        .assets = &assets,
        .install = .{ .outputs = .{ .rom = true, .debug_elf = true } },
    });
}
```

`zig build` converts assets and installs the ROM and debug ELF in `zig-out/`.
Application code imports `n64` and `assets`; `assets.player` is a native typed
image. Conversion is cached, including bitmap-font page dependencies. No
runtime parsing or path lookup is required for generated embedded assets.

The default is `ReleaseSmall`. `zig build -Doptimize=ReleaseFast` changes the
SDK modules and ROM together; individual ROMs can override `.optimize`.
`ReleaseSafe` and `Debug` retain Zig safety checks and cost more CPU time and
ROM space. Host tools target the build machine independently of the N64 target.

In this repository, `zig build test` runs host tests, `zig build tests` builds
the hardware suite, and `zig build install` installs the asset compilers and
diagnostic tools. `zig build test-consumer` checks the public build SDK and
`zig build test-asset-cache` checks font page invalidation (requires Python 3).

## Runtime documentation

Opt-in framebuffer capture, vertex cache probes, and render-timeout snapshots are
documented in [Render diagnostics](tools/framebuffer_capture/README.md).

The CPU-rendered panic and exception UI, controller navigation and one-bit fonts
are documented in [Emergency crash screen](src/n64/debug/crash_screen/README.md).

[ROM assets](src/n64/ROM_ASSETS.md) stay on cartridge and support bounded reads,
explicit typed texture/model loading, and direct DMA into caller-owned storage.

Resident and streamed PCM assets, AI output buffers, and the instruction-identical libdragon
RSP mixer are documented in [PCM audio](src/n64/audio/README.md).

Bounded hardware traces and the standalone timeline viewer are documented in
[Hardware profiler](tools/profiler/README.md).

## Deployment

`zig build install` installs `zig-out/bin/ptero-deploy` for native SC64 and
EverDrive USB deployment, ares runs, and optional Home Assistant power control.
ROMs report completion through `n64.debug.finish(...)`. See the
[deploy guide](tools/deploy/README.md).
