# Libptero
Libptero is an attempt to create an open-soure SDK for the Nentendo 64 written in zig. It borrows a ton from Libdragon.

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
