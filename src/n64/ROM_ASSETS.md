# ROM assets

`AssetBundle.addRomFile(name, path)` exposes an `n64.rom.Region` handle. Unlike
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

`n64.pi.Transfer` provides lower-level asynchronous ROM DMA into complete,
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

## Typed textures, models and PCM

`addTexture` and `addModel` accept `.storage = .rom`. Their converted texels,
palettes, packed vertices and triangle indices remain on cartridge until loaded.
The default `.resident` preserves the embedded startup-loaded API. ROM PCM audio
also uses this shared loaded-owner lifecycle: `addAudio(..., .{ .storage = .rom })`
emits a `RomSample` with `init`, `initBuffer`, and `storageSize`; its owner exposes
`view()` as an `audio.Sample`. The same descriptor can feed `audio.Stream` without
loading the full clip. See [audio loading](audio/README.md#pcm-loaded-into-ram-at-runtime)
for playback lifetime rules and format limits.

```zig
// build.zig
assets.addTexture("crate", b.path("crate.png"), .{ .storage = .rom, .format = .ci8 });
assets.addModel("room", b.path("room.glb"), .{ .storage = .rom });
// Pass .assets = &assets to sdk.addRom, as for addRomFile.

// Runtime: initialization allocates storage, loading fills it.
var room = try assets.room.init(allocator);
const model = try room.load(.{});
renderer.geometry.drawModel(model);
try renderer.submit().wait(.{});
try room.deinit(allocator);
```

`load(.{})` returns the borrowed native value after a successful read, and
`view()` retrieves it after asynchronous completion. Both `load` and `wait`
accept owner-scoped `LoadOptions`/`WaitOptions` with
`.max_attempts = 1_000_000` by default. For a different bounded budget, use
`load(.{ .max_attempts = ... })` or `wait(.{ .max_attempts = ... })`.

`view()` returns the same borrowed native `n64.graphics.ModelAsset`, `ConstImage`
or `PalettedImage` used by the embedded path. Recorded models, CPU skinning and
first-joint RSP poses work with loaded assets. A loaded model is a runtime value,
so override its materials with `withOverridesInto`; size that storage with
`assets.room.materialCount()`. Bindings, including the material table and its
texture references into the payload, are established once when DMA completes;
`view()` does not traverse model parts or allocate. The hot drawing path needs no asset lookup or loader.
Model material and rig definitions (including animation tracks and weighted
influences) remain generated native Zig metadata resident in the program. The
ROM option moves the binary geometry and image payload, rather than every byte
of model metadata. Fonts currently retain their embedded path.

For an allocation-free load, supply complete, aligned DMA cache lines:

```zig
var memory: [assets.crate.storageSize()]u8 align(16) = undefined;
var crate = try assets.crate.initBuffer(&memory);
try crate.begin();
// Service application work between polls; PI DMA continues independently.
if (try crate.poll()) {
    render.drawSprite(try crate.view(), 0, 0, .{});
}
// Before returning memory or destroying the owner, finish any pending load:
try crate.wait(.{});
```

`storageSize()` includes the cartridge's 16-byte DMA tail padding. Larger supplied
buffers are accepted; extra bytes are untouched. `init` owns one aligned payload
allocation. `initBuffer` borrows its storage; `deinit(allocator)` never frees it.
Each owner also contains its transfer record and native model-part bindings.
Loading uses one PI DMA directly into the final storage, without a Reader's
staging buffer, copy, allocation, decompression or serialized-pointer relocation.

Keep the owner at a stable address from `begin` until it is deinitialized, and
never copy it. Keep its storage unchanged and alive until all RSP/RDP work and
other consumers of its views complete. Recorded command blocks must be discarded
before their asset is unloaded. `deinit` and `unload` do not wait for rendering.
Use the same allocator for owning initialization and teardown.

`begin` returns `PiBusy` if another transfer owns PI; retry admission later.
`poll` returns false while DMA is pending. `wait` and `load` use bounded polling
budgets, measured in attempts rather than elapsed time. `PiTimeout` retains the
pending transfer and destination: retry `wait` or `load` at the same owner address.
`view` returns `NotLoaded` until completion. `unload` and `deinit` return
`AssetBusy` during pending DMA. A completed load is idempotent: another `load`
does not read again. `begin` on a completed owner returns `AlreadyLoaded`.

After all consumers finish, `unload` drops its view while retaining the buffer
for another load; `deinit` frees owned storage. A successful new load receives
a fresh texture-content identity. The renderer uses that identity alongside
the address to reload recycled texels and palettes without discarding unrelated
texture residency. Embedded images retain identity zero and their normal caching.
Like Reader and Transfer, the loading API is single-threaded and used outside
interrupt handlers. Callers coordinate PI use and never access pending DMA
destinations through cached or uncached aliases.

This API loads complete converted assets. Automatic eviction, partial model
streaming, background scheduling and graphics-asset compression are future work.

## Cooperative loading and typed slots

`n64.rom.Scheduler` holds eight jobs and owns one PI transfer at a stable address.
It allocates nothing. Jobs transfer directly into final caller-owned aligned
storage, in 4 KiB chunks by default. `init(.{ .chunk_bytes = ... })` accepts
16-byte multiples up to 64 KiB. Higher priorities run first; equal priorities
rotate between chunks. An already running DMA is never preempted.

```zig
var loads = try n64.rom.Scheduler.init(.{});
var room = try assets.room.init(allocator);
try room.beginScheduled(&loads, .background);
// Each iteration:
try loads.serviceAudio(&player, .{});
if (try room.poll()) {
    // Native view is ready; drawing uses the existing public geometry API.
}
```

`serviceAudio` retires a completed background DMA, services AI, fills available
audio buffers while PI is free, then admits one background chunk. Without audio,
use `service`. The separate `poll` and `dispatch` operations allow custom
scheduling. Continue servicing and polling each owner until completion before
freeing its destination or destroying the scheduler. A completed job retains
its queue slot until its owner consumes the ticket. `isIdle` means all tickets
have been released. `bytes_transferred`, `transfers`, and `pi_busy` expose costs.
This is cooperative scheduling: service frequency and chunk size still belong
in the application's audio budget.

Scheduled owners use `poll`; blocking `wait/load` returns
`ScheduledLoadRequiresService` while a scheduler ticket is outstanding, avoiding
a wait that starves the driver. Direct `begin/load` behavior is unchanged after
scheduled completion. PI failures retain releasable tickets; poll the affected
owner to observe failure and release its ticket before reusing storage.

For several different generated models sharing storage, declare:

```zig
const RoomSlot = n64.rom.Slot(.{
    .atrium = assets.atrium,
    .gallery = assets.gallery,
});
var slot: RoomSlot = .{};
var bytes: [RoomSlot.storageSize()]u8 align(16) = undefined;
// After both are at stable addresses:
try slot.request(.atrium, &bytes, &loads);
// After scheduler service and slot.poll() return ready:
try slot.draw(&geometry);
// After all GPU users complete:
try slot.retire();
```

The slot generates a tagged union of concrete owners, keeps each loaded material
table in its owner, and allocates no memory. `request` rejects occupied slots; `retire`
rejects pending loads. The caller determines when GPU borrowers have finished.
Use two slots for background loading while an active room renders, as shown in
the `room-stream` example. Queue tickets can be cancelled only between chunks;
the typed-slot interface deliberately requires pending loads to finish.
