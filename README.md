# Libptero
Libptero is an attempt to create an open-soure SDK for the Nentendo 64 written in zig. It borrows a ton from Libdragon.

Opt-in framebuffer capture, vertex cache probes, and render-timeout snapshots are
documented in [Render diagnostics](tools/framebuffer_capture/README.md).

Native PCM assets, AI output buffers, and the instruction-identical libdragon
RSP mixer are documented in [PCM audio](src/n64/audio/README.md).
