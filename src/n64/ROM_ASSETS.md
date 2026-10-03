# ROM assets

`AssetBundle.addRomFile(name, path)` exposes an `n64.rom.Asset` handle. Unlike
`embedFile`, the bytes are appended outside ELF load segments and remain in
cartridge ROM at boot. Pass the bundle through `Sdk.addRom(.{ .assets = &bundle })`;
importing its module alone does not attach the payload to a ROM. Packing follows
insertion order, aligns entries to 16 bytes, records logical sizes and pads tails.
No runtime directory, file descriptor, or pointer fixup is required.
The packed ROM, including boot data and final cartridge padding, must fit the
selected layout's `rom_length` and the 64 MiB cartridge address space. Oversized
payloads fail the build before a ROM is emitted.

```zig
// build.zig
var assets = sdk.createAssets("assets");
assets.addRomFile("level", b.path("assets/level.bin"));
_ = sdk.addRom(.{ .name = "game", .title = "Game",
    .app_source_file = b.path("src/main.zig"), .assets = &assets });
```

```zig
// Caller-owned persistent storage in main.zig
var reader: n64.rom.Reader = .{};
var level: [512]u8 = undefined;
// Read any logical byte range, including odd addresses and lengths.
try reader.read(assets.level, 1, &level, 1_000_000);
```

A reader contains a 4 KiB DMA staging buffer and copies completed chunks into the
requested destination. `begin` records a read, `poll` advances it, and `wait`
provides a bounded polling budget. Keep reader and destination stable until the
read completes. A `PiTimeout` keeps both borrowed: retry `wait` before reusing or
releasing them. `PiBusy` is retried during polling when another reader owns PI.
Bounds, ROM limits, and generated alignment are checked. Empty end reads work.
`bytes_read` and `transfers` count completed logical bytes and issued DMAs.

`n64.io.pi.Transfer` provides lower-level asynchronous ROM DMA into complete,
caller-owned 16-byte cache lines. Its destination address and length must be
16-byte aligned, and its ROM range must fit the 64 MiB cartridge space. It handles
cache writeback/invalidation, exclusive transfer ownership, an idle sticky-error
reset, and PI acknowledgement. The buffer and Transfer remain borrowed on timeout;
retry `wait`. Transfer admission briefly masks CPU interrupts. Raw MMIO functions
remain available but must not issue competing DMA while a Transfer owns PI.

Use these APIs outside interrupts. Do not access an outstanding DMA destination
through either cached or uncached aliases. Readers are separate operations and
may interleave between chunks; a single Reader cannot begin a second operation.
No heap allocation occurs in the read path. The initial asset packer and runtime
support uncompressed, read-only cartridge payloads and generated handles. They
provide no runtime filename lookup, decompression, writable filesystem or SD IO.

Streamed PCM builds on these handles; see [audio](audio/README.md).
